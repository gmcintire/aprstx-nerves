defmodule Aprstx.Server do
  @moduledoc """
  Main APRS server implementation handling client connections.
  """
  use GenServer
  require Logger

  defstruct [
    :port,
    :listen_socket,
    :clients,
    :stats,
    :config
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 14580)
    
    state = %__MODULE__{
      port: port,
      clients: %{},
      stats: init_stats(),
      config: opts
    }

    {:ok, state, {:continue, :start_listening}}
  end

  @impl true
  def handle_continue(:start_listening, state) do
    case :gen_tcp.listen(state.port, [
      :binary,
      packet: :line,
      active: false,
      reuseaddr: true,
      keepalive: true
    ]) do
      {:ok, listen_socket} ->
        Logger.info("APRS server listening on port #{state.port}")
        spawn_link(fn -> accept_loop(listen_socket) end)
        {:noreply, %{state | listen_socket: listen_socket}}
      
      {:error, reason} ->
        Logger.error("Failed to start server: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({:new_client, socket}, state) do
    {:ok, {ip, port}} = :inet.peername(socket)
    client_id = generate_client_id()
    
    client = %{
      id: client_id,
      socket: socket,
      ip: ip,
      port: port,
      connected_at: DateTime.utc_now(),
      authenticated: false,
      callsign: nil,
      filter: nil
    }
    
    Logger.info("New client connected: #{format_ip(ip)}:#{port}")
    
    Task.start_link(fn -> handle_client(socket, client_id) end)
    
    new_state = put_in(state.clients[client_id], client)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:client_data, client_id, data}, state) do
    case Map.get(state.clients, client_id) do
      nil ->
        {:noreply, state}
      
      client ->
        case process_client_data(client, data, state) do
          {:ok, updated_client} ->
            new_state = put_in(state.clients[client_id], updated_client)
            {:noreply, new_state}
          
          {:error, _reason} ->
            new_state = Map.delete(state.clients, client_id)
            {:noreply, new_state}
        end
    end
  end

  @impl true
  def handle_info({:client_disconnected, client_id}, state) do
    case Map.get(state.clients, client_id) do
      nil ->
        {:noreply, state}
      
      client ->
        Logger.info("Client disconnected: #{client.callsign || "unknown"}")
        new_state = Map.delete(state.clients, client_id)
        {:noreply, new_state}
    end
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        send(__MODULE__, {:new_client, socket})
        accept_loop(listen_socket)
      
      {:error, reason} ->
        Logger.error("Accept error: #{inspect(reason)}")
    end
  end

  defp handle_client(socket, client_id) do
    send_server_banner(socket)
    
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        send(__MODULE__, {:client_data, client_id, data})
        handle_client(socket, client_id)
      
      {:error, :closed} ->
        send(__MODULE__, {:client_disconnected, client_id})
      
      {:error, reason} ->
        Logger.error("Client error: #{inspect(reason)}")
        send(__MODULE__, {:client_disconnected, client_id})
    end
  end

  defp process_client_data(client, data, _state) do
    data = String.trim(data)
    
    cond do
      String.starts_with?(data, "user ") ->
        process_login(client, data)
      
      client.authenticated ->
        process_packet(client, data)
      
      true ->
        send_to_client(client.socket, "# Login required")
        {:ok, client}
    end
  end

  defp process_login(client, data) do
    case parse_login(data) do
      {:ok, callsign, _passcode, filter} ->
        if Aprstx.Packet.valid_callsign?(callsign) do
          updated_client = %{client | 
            authenticated: true,
            callsign: callsign,
            filter: filter
          }
          
          send_to_client(client.socket, "# logresp #{callsign} verified")
          Logger.info("Client authenticated: #{callsign}")
          {:ok, updated_client}
        else
          send_to_client(client.socket, "# Login failed")
          {:error, :invalid_callsign}
        end
      
      _ ->
        send_to_client(client.socket, "# Login failed")
        {:error, :invalid_login}
    end
  end

  defp parse_login(data) do
    case String.split(data, " ", parts: 5) do
      ["user", callsign, "pass", passcode | rest] ->
        filter = 
          case rest do
            [filter_str] -> filter_str
            _ -> nil
          end
        {:ok, callsign, passcode, filter}
      
      _ ->
        {:error, :invalid_format}
    end
  end

  defp process_packet(client, data) do
    case Aprstx.Packet.parse(data) do
      {:ok, packet} ->
        Logger.debug("Packet from #{client.callsign}: #{packet.type}")
        broadcast_packet(packet, client)
        {:ok, client}
      
      {:error, reason} ->
        Logger.warn("Invalid packet from #{client.callsign}: #{inspect(reason)}")
        {:ok, client}
    end
  end

  defp broadcast_packet(packet, sender_client) do
    GenServer.cast(__MODULE__, {:broadcast, packet, sender_client.id})
  end

  @impl true
  def handle_cast({:broadcast, packet, sender_id}, state) do
    Enum.each(state.clients, fn {client_id, client} ->
      if client_id != sender_id and client.authenticated do
        if should_send_packet?(packet, client.filter) do
          encoded = Aprstx.Packet.encode(packet)
          send_to_client(client.socket, encoded)
        end
      end
    end)
    
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_clients, _from, state) do
    {:reply, state.clients, state}
  end

  defp should_send_packet?(_packet, nil), do: true
  defp should_send_packet?(_packet, _filter) do
    true
  end

  defp send_server_banner(socket) do
    banner = "# aprsc-elixir 1.0.0\r\n"
    send_to_client(socket, banner)
  end

  defp send_to_client(socket, data) do
    :gen_tcp.send(socket, data <> "\r\n")
  end

  defp generate_client_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16()
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: inspect(ip)

  defp init_stats do
    %{
      packets_received: 0,
      packets_sent: 0,
      clients_connected: 0,
      started_at: DateTime.utc_now()
    }
  end
end