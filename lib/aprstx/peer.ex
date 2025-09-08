defmodule Aprstx.Peer do
  @moduledoc """
  Peer-to-peer connections between APRS servers.
  Implements server interconnection for packet distribution.
  """
  use GenServer

  require Logger

  defstruct [
    :peers,
    :connections,
    :config
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      peers: %{},
      connections: %{},
      config: %{
        server_id: Keyword.get(opts, :server_id, generate_server_id()),
        port: Keyword.get(opts, :port, 10_152),
        auth_key: Keyword.get(opts, :auth_key)
      }
    }

    # Start peer listener
    spawn_link(fn -> start_peer_listener(state.config.port) end)

    # Connect to configured peers
    Enum.each(Keyword.get(opts, :peers, []), fn peer_config ->
      connect_to_peer(peer_config)
    end)

    {:ok, state}
  end

  @doc """
  Connect to a peer server.
  """
  def connect_to_peer(peer_config) do
    GenServer.cast(__MODULE__, {:connect_peer, peer_config})
  end

  @doc """
  Disconnect from a peer.
  """
  def disconnect_peer(peer_id) do
    GenServer.cast(__MODULE__, {:disconnect_peer, peer_id})
  end

  @doc """
  Broadcast packet to all peers.
  """
  def broadcast_to_peers(packet, exclude_peer \\ nil) do
    GenServer.cast(__MODULE__, {:broadcast, packet, exclude_peer})
  end

  @impl true
  def handle_cast({:connect_peer, config}, state) do
    peer_id = Map.get(config, :id, generate_peer_id())

    Task.start(fn ->
      case establish_peer_connection(config) do
        {:ok, socket} ->
          send(__MODULE__, {:peer_connected, peer_id, socket, config})

        {:error, reason} ->
          Logger.error("Failed to connect to peer #{peer_id}: #{inspect(reason)}")
          schedule_reconnect(peer_id, config)
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:disconnect_peer, peer_id}, state) do
    case Map.get(state.connections, peer_id) do
      nil ->
        {:noreply, state}

      conn ->
        :gen_tcp.close(conn.socket)
        new_connections = Map.delete(state.connections, peer_id)
        new_peers = Map.delete(state.peers, peer_id)
        {:noreply, %{state | connections: new_connections, peers: new_peers}}
    end
  end

  @impl true
  def handle_cast({:broadcast, packet, exclude_peer}, state) do
    encoded = Aprstx.Packet.encode(packet)

    Enum.each(state.connections, fn {peer_id, conn} ->
      if peer_id != exclude_peer do
        :gen_tcp.send(conn.socket, "PEER:#{encoded}\r\n")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:peer_connected, peer_id, socket, config}, state) do
    conn = %{
      socket: socket,
      config: config,
      connected_at: DateTime.utc_now(),
      stats: %{
        packets_sent: 0,
        packets_received: 0
      }
    }

    # Start handler for this peer
    Task.start_link(fn -> handle_peer_connection(socket, peer_id) end)

    new_connections = Map.put(state.connections, peer_id, conn)
    new_peers = Map.put(state.peers, peer_id, config)

    Logger.info("Connected to peer #{peer_id}")

    {:noreply, %{state | connections: new_connections, peers: new_peers}}
  end

  @impl true
  def handle_info({:peer_disconnected, peer_id}, state) do
    Logger.info("Peer #{peer_id} disconnected")

    new_connections = Map.delete(state.connections, peer_id)

    # Schedule reconnect if this was an outgoing connection
    if Map.has_key?(state.peers, peer_id) do
      config = state.peers[peer_id]
      schedule_reconnect(peer_id, config)
    end

    {:noreply, %{state | connections: new_connections}}
  end

  @impl true
  def handle_info({:peer_data, peer_id, data}, state) do
    case parse_peer_message(data) do
      {:packet, packet_data} ->
        case Aprstx.Packet.parse(packet_data) do
          {:ok, packet} ->
            # Check for loops
            if !seen_before?(packet, peer_id) do
              # Process and forward to local clients
              GenServer.cast(Aprstx.Server, {:broadcast, packet, peer_id})

              # Forward to other peers
              broadcast_to_peers(packet, peer_id)
            end

          {:error, _reason} ->
            :ok
        end

      {:command, command, args} ->
        handle_peer_command(peer_id, command, args, state)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:reconnect, peer_id, config}, state) do
    connect_to_peer(config)
    {:noreply, state}
  end

  defp establish_peer_connection(config) do
    host = Map.fetch!(config, :host)
    port = Map.get(config, :port, 10_152)

    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, packet: :line, active: false],
           5000
         ) do
      {:ok, socket} ->
        # Send authentication
        auth_message = build_auth_message(config)
        :gen_tcp.send(socket, auth_message)
        {:ok, socket}

      error ->
        error
    end
  end

  defp build_auth_message(config) do
    server_id = get_server_id()
    auth_key = Map.get(config, :auth_key, "")
    "PEER:AUTH:#{server_id}:#{auth_key}\r\n"
  end

  defp start_peer_listener(port) do
    case :gen_tcp.listen(port, [
           :binary,
           packet: :line,
           active: false,
           reuseaddr: true
         ]) do
      {:ok, listen_socket} ->
        Logger.info("Peer listener started on port #{port}")
        accept_peer_loop(listen_socket)

      {:error, reason} ->
        Logger.error("Failed to start peer listener: #{inspect(reason)}")
    end
  end

  defp accept_peer_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        peer_id = generate_peer_id()
        send(__MODULE__, {:peer_connected, peer_id, socket, %{}})
        accept_peer_loop(listen_socket)

      {:error, reason} ->
        Logger.error("Peer accept error: #{inspect(reason)}")
    end
  end

  defp handle_peer_connection(socket, peer_id) do
    case :gen_tcp.recv(socket, 0, 60_000) do
      {:ok, data} ->
        send(__MODULE__, {:peer_data, peer_id, data})
        handle_peer_connection(socket, peer_id)

      {:error, :closed} ->
        send(__MODULE__, {:peer_disconnected, peer_id})

      {:error, reason} ->
        Logger.error("Peer connection error: #{inspect(reason)}")
        send(__MODULE__, {:peer_disconnected, peer_id})
    end
  end

  defp parse_peer_message(data) do
    data = String.trim(data)

    cond do
      String.starts_with?(data, "PEER:AUTH:") ->
        parts = String.split(data, ":", parts: 4)
        {:command, :auth, Enum.drop(parts, 2)}

      String.starts_with?(data, "PEER:PING") ->
        {:command, :ping, []}

      String.starts_with?(data, "PEER:PONG") ->
        {:command, :pong, []}

      String.starts_with?(data, "PEER:") ->
        packet_data = String.slice(data, 5..-1//1)
        {:packet, packet_data}

      true ->
        {:packet, data}
    end
  end

  defp handle_peer_command(peer_id, :ping, _args, _state) do
    case get_peer_socket(peer_id) do
      {:ok, socket} ->
        :gen_tcp.send(socket, "PEER:PONG\r\n")

      _ ->
        :ok
    end
  end

  defp handle_peer_command(_peer_id, :pong, _args, _state) do
    # Record pong received
    :ok
  end

  defp handle_peer_command(peer_id, :auth, [remote_id, _auth_key], _state) do
    Logger.info("Peer #{peer_id} authenticated as #{remote_id}")
    :ok
  end

  defp handle_peer_command(_peer_id, _command, _args, _state) do
    :ok
  end

  defp get_peer_socket(peer_id) do
    case GenServer.call(__MODULE__, {:get_peer_socket, peer_id}) do
      nil -> {:error, :not_found}
      socket -> {:ok, socket}
    end
  end

  @impl true
  def handle_call({:get_peer_socket, peer_id}, _from, state) do
    socket =
      case Map.get(state.connections, peer_id) do
        nil -> nil
        conn -> conn.socket
      end

    {:reply, socket, state}
  end

  defp seen_before?(_packet, _peer_id) do
    # Could implement loop detection here
    false
  end

  defp schedule_reconnect(peer_id, config) do
    Process.send_after(self(), {:reconnect, peer_id, config}, 30_000)
  end

  defp generate_server_id do
    8 |> :crypto.strong_rand_bytes() |> Base.encode16()
  end

  defp generate_peer_id do
    8 |> :crypto.strong_rand_bytes() |> Base.encode16()
  end

  defp get_server_id do
    Application.get_env(:aprstx, :server_id, "APRSTX")
  end

  @doc """
  Get peer statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      connected_peers: map_size(state.connections),
      configured_peers: map_size(state.peers),
      connections:
        Enum.map(state.connections, fn {id, conn} ->
          %{
            peer_id: id,
            connected_at: conn.connected_at,
            stats: conn.stats
          }
        end)
    }

    {:reply, stats, state}
  end
end
