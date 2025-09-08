defmodule Aprstx.UdpListener do
  @moduledoc """
  UDP listener for APRS packets.
  Supports both unidirectional and bidirectional UDP connections.
  """
  use GenServer

  require Logger

  defstruct [
    :port,
    :socket,
    :clients,
    :stats,
    :mode
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 8080)
    # :unidirectional or :bidirectional
    mode = Keyword.get(opts, :mode, :bidirectional)

    state = %__MODULE__{
      port: port,
      mode: mode,
      clients: %{},
      stats: %{
        packets_received: 0,
        packets_sent: 0,
        bytes_received: 0,
        bytes_sent: 0
      }
    }

    {:ok, state, {:continue, :open_socket}}
  end

  @impl true
  def handle_continue(:open_socket, state) do
    case :gen_udp.open(state.port, [:binary, active: true, reuseaddr: true]) do
      {:ok, socket} ->
        Logger.info("UDP listener started on port #{state.port} (#{state.mode})")
        {:noreply, %{state | socket: socket}}

      {:error, reason} ->
        Logger.error("Failed to open UDP socket: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_info({:udp, socket, ip, port, data}, %{socket: socket} = state) do
    # Update client tracking
    client_key = {ip, port}
    now = DateTime.utc_now()

    clients =
      Map.put(state.clients, client_key, %{
        last_seen: now,
        packets_received: Map.get(state.clients, client_key, %{})[:packets_received] || 0 + 1
      })

    # Update stats
    stats =
      state.stats
      |> Map.update!(:packets_received, &(&1 + 1))
      |> Map.update!(:bytes_received, &(&1 + byte_size(data)))

    # Process packet
    process_udp_packet(data, ip, port, state)

    {:noreply, %{state | clients: clients, stats: stats}}
  end

  defp process_udp_packet(data, ip, port, state) do
    data = String.trim(data)

    case parse_udp_format(data) do
      {:aprs, packet_data} ->
        process_aprs_packet(packet_data, ip, port, state)

      {:kiss, kiss_data} ->
        process_kiss_packet(kiss_data, ip, port, state)

      {:json, json_data} ->
        process_json_packet(json_data, ip, port, state)

      _ ->
        # Try as raw APRS
        process_aprs_packet(data, ip, port, state)
    end
  end

  defp parse_udp_format(data) do
    cond do
      String.starts_with?(data, "{") ->
        {:json, data}

      String.starts_with?(data, <<0xC0>>) ->
        {:kiss, data}

      String.contains?(data, ">") and String.contains?(data, ":") ->
        {:aprs, data}

      true ->
        {:unknown, data}
    end
  end

  defp process_aprs_packet(data, ip, _port, state) do
    case Aprstx.Packet.parse(data) do
      {:ok, packet} ->
        # Add UDP source info
        packet = Map.put(packet, :udp_source, format_ip(ip))

        # Check if duplicate
        if !Aprstx.DuplicateFilter.is_duplicate?(packet) do
          Aprstx.DuplicateFilter.record_packet(packet)

          # Add Q-construct for UDP
          client_info = %{
            verified: false,
            server_call: "APRSTX"
          }

          packet = Aprstx.QConstruct.process(packet, client_info)

          # Broadcast to TCP clients
          GenServer.cast(Aprstx.Server, {:broadcast, packet, :udp})

          # Forward to peers
          Aprstx.Peer.broadcast_to_peers(packet)

          # Send to other UDP clients if bidirectional
          if state.mode == :bidirectional do
            broadcast_to_udp_clients(packet, ip, state)
          end
        end

      {:error, reason} ->
        Logger.debug("Invalid UDP packet from #{format_ip(ip)}: #{inspect(reason)}")
    end
  end

  defp process_kiss_packet(data, ip, port, state) do
    # Decode KISS frame
    case decode_simple_kiss(data) do
      {:ok, aprs_data} ->
        process_aprs_packet(aprs_data, ip, port, state)

      {:error, _reason} ->
        :ok
    end
  end

  defp process_json_packet(data, ip, port, state) do
    case Jason.decode(data) do
      {:ok, json} ->
        # Convert JSON to APRS packet
        case json_to_aprs(json) do
          {:ok, packet} ->
            process_aprs_packet(Aprstx.Packet.encode(packet), ip, port, state)

          {:error, _reason} ->
            :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp decode_simple_kiss(<<0xC0, 0x00, data::binary>>) do
    # Simple KISS data frame extraction
    case :binary.match(data, <<0xC0>>) do
      {pos, _} ->
        frame_data = :binary.part(data, 0, pos)
        {:ok, frame_data}

      :nomatch ->
        {:error, :incomplete_frame}
    end
  end

  defp decode_simple_kiss(_), do: {:error, :invalid_kiss}

  defp json_to_aprs(json) do
    packet = %Aprstx.Packet{
      source: Map.fetch!(json, "source"),
      destination: Map.get(json, "destination", "APRS"),
      path: Map.get(json, "path", []),
      data: Map.fetch!(json, "data"),
      timestamp: DateTime.utc_now()
    }

    {:ok, packet}
  rescue
    _ -> {:error, :invalid_json_format}
  end

  defp broadcast_to_udp_clients(packet, exclude_ip, state) do
    encoded = Aprstx.Packet.encode(packet)

    Enum.each(state.clients, fn {{ip, port}, _info} ->
      if ip != exclude_ip do
        :gen_udp.send(state.socket, ip, port, encoded <> "\r\n")
      end
    end)
  end

  @doc """
  Send packet via UDP to a specific client.
  """
  def send_to_client(ip, port, packet) do
    GenServer.cast(__MODULE__, {:send_to_client, ip, port, packet})
  end

  @impl true
  def handle_cast({:send_to_client, ip, port, packet}, state) do
    encoded = Aprstx.Packet.encode(packet)
    :gen_udp.send(state.socket, ip, port, encoded <> "\r\n")

    stats =
      state.stats
      |> Map.update!(:packets_sent, &(&1 + 1))
      |> Map.update!(:bytes_sent, &(&1 + byte_size(encoded) + 2))

    {:noreply, %{state | stats: stats}}
  end

  @doc """
  Broadcast packet to all UDP clients.
  """
  def broadcast(packet) do
    GenServer.cast(__MODULE__, {:broadcast, packet})
  end

  @impl true
  def handle_cast({:broadcast, packet}, state) do
    if state.mode == :bidirectional do
      encoded = Aprstx.Packet.encode(packet)

      Enum.each(state.clients, fn {{ip, port}, _info} ->
        :gen_udp.send(state.socket, ip, port, encoded <> "\r\n")
      end)

      count = map_size(state.clients)

      stats =
        state.stats
        |> Map.update!(:packets_sent, &(&1 + count))
        |> Map.update!(:bytes_sent, &(&1 + count * (byte_size(encoded) + 2)))

      {:noreply, %{state | stats: stats}}
    else
      {:noreply, state}
    end
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: inspect(ip)

  @doc """
  Get UDP listener statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        active_clients: map_size(state.clients),
        mode: state.mode,
        port: state.port
      })

    {:reply, stats, state}
  end

  @doc """
  Clean up old UDP clients.
  """
  def cleanup_old_clients do
    GenServer.cast(__MODULE__, :cleanup_clients)
  end

  @impl true
  def handle_cast(:cleanup_clients, state) do
    # 5 minutes
    cutoff = DateTime.add(DateTime.utc_now(), -300, :second)

    new_clients =
      state.clients
      |> Enum.filter(fn {_key, info} ->
        DateTime.after?(info.last_seen, cutoff)
      end)
      |> Map.new()

    {:noreply, %{state | clients: new_clients}}
  end
end
