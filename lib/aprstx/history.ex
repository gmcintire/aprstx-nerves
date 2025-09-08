defmodule Aprstx.History do
  @moduledoc """
  Packet history storage and replay functionality.
  Maintains a circular buffer of recent packets for replay to new clients.
  """
  use GenServer

  require Logger

  @default_history_size 10_000
  @default_replay_limit 100

  defstruct [
    :max_size,
    :packets,
    :index,
    :stats
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    max_size = Keyword.get(opts, :max_size, @default_history_size)

    state = %__MODULE__{
      max_size: max_size,
      packets: :queue.new(),
      index: %{},
      stats: %{
        total_stored: 0,
        replays_served: 0
      }
    }

    {:ok, state}
  end

  @doc """
  Store a packet in history.
  """
  def store_packet(packet) do
    GenServer.cast(__MODULE__, {:store, packet})
  end

  @doc """
  Get recent packets matching filter criteria.
  """
  def get_history(opts \\ []) do
    GenServer.call(__MODULE__, {:get_history, opts})
  end

  @doc """
  Replay packets to a client based on their filter.
  """
  def replay_to_client(client_socket, filter, limit \\ @default_replay_limit) do
    GenServer.cast(__MODULE__, {:replay, client_socket, filter, limit})
  end

  @impl true
  def handle_cast({:store, packet}, state) do
    # Add timestamp if not present
    packet = ensure_timestamp(packet)

    # Add to queue
    new_queue = :queue.in(packet, state.packets)

    # Trim if necessary
    new_queue =
      if :queue.len(new_queue) > state.max_size do
        {_, trimmed} = :queue.out(new_queue)
        trimmed
      else
        new_queue
      end

    # Update index
    new_index = update_index(state.index, packet)

    # Update stats
    new_stats = Map.update!(state.stats, :total_stored, &(&1 + 1))

    {:noreply, %{state | packets: new_queue, index: new_index, stats: new_stats}}
  end

  @impl true
  def handle_cast({:replay, socket, filter, limit}, state) do
    # Get matching packets
    packets = get_filtered_packets(state, filter, limit)

    # Send to client
    Task.start(fn ->
      Enum.each(packets, fn packet ->
        encoded = Aprstx.Packet.encode(packet)
        :gen_tcp.send(socket, encoded <> "\r\n")
        # Small delay to avoid overwhelming client
        Process.sleep(10)
      end)
    end)

    # Update stats
    new_stats = Map.update!(state.stats, :replays_served, &(&1 + 1))

    {:noreply, %{state | stats: new_stats}}
  end

  @impl true
  def handle_call({:get_history, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, @default_replay_limit)
    filter = Keyword.get(opts, :filter)
    callsign = Keyword.get(opts, :callsign)
    since = Keyword.get(opts, :since)

    packets =
      state.packets
      |> :queue.to_list()
      |> filter_packets(filter, callsign, since)
      # Take last N packets
      |> Enum.take(-limit)

    {:reply, packets, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        current_size: :queue.len(state.packets),
        max_size: state.max_size,
        memory_usage: self() |> :erlang.process_info(:memory) |> elem(1)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:position_history, callsign, limit}, _from, state) do
    positions =
      case Map.get(state.index, callsign) do
        nil ->
          []

        packets ->
          packets
          |> Enum.filter(&position_packet?/1)
          |> Enum.map(&extract_position_data/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(limit)
      end

    {:reply, positions, state}
  end

  @impl true
  def handle_call({:export, path}, _from, state) do
    packets = :queue.to_list(state.packets)

    content = Enum.map_join(packets, "\n", &Aprstx.Packet.encode/1)

    case File.write(path, content) do
      :ok ->
        {:reply, {:ok, length(packets)}, state}

      error ->
        {:reply, error, state}
    end
  end

  defp ensure_timestamp(packet) do
    if packet.timestamp do
      packet
    else
      %{packet | timestamp: DateTime.utc_now()}
    end
  end

  defp update_index(index, packet) do
    # Index by callsign for quick lookups
    Map.update(index, packet.source, [packet], &[packet | &1])
  end

  defp get_filtered_packets(state, filter, limit) do
    packets = :queue.to_list(state.packets)

    filtered =
      if filter do
        filters = Aprstx.Filter.parse(filter)
        Enum.filter(packets, &Aprstx.Filter.matches?(&1, filters))
      else
        packets
      end

    Enum.take(filtered, -limit)
  end

  defp filter_packets(packets, filter, callsign, since) do
    packets
    |> filter_by_parsed_filter(filter)
    |> filter_by_callsign(callsign)
    |> filter_by_time(since)
  end

  defp filter_by_parsed_filter(packets, nil), do: packets

  defp filter_by_parsed_filter(packets, filter) do
    filters = Aprstx.Filter.parse(filter)
    Enum.filter(packets, &Aprstx.Filter.matches?(&1, filters))
  end

  defp filter_by_callsign(packets, nil), do: packets

  defp filter_by_callsign(packets, callsign) do
    Enum.filter(packets, fn packet ->
      packet.source == callsign or
        packet.destination == callsign or
        callsign in packet.path
    end)
  end

  defp filter_by_time(packets, nil), do: packets

  defp filter_by_time(packets, since) do
    Enum.filter(packets, fn packet ->
      DateTime.after?(packet.timestamp, since)
    end)
  end

  @doc """
  Get position history for a specific station.
  """
  def get_position_history(callsign, limit \\ 50) do
    GenServer.call(__MODULE__, {:position_history, callsign, limit})
  end

  defp position_packet?(packet) do
    packet.type in [
      :position_no_timestamp,
      :position_with_timestamp,
      :position_with_timestamp_msg,
      :position_with_timestamp_compressed
    ]
  end

  defp extract_position_data(packet) do
    case Aprstx.Packet.extract_position(packet) do
      {:ok, pos} ->
        %{
          callsign: packet.source,
          latitude: pos.latitude,
          longitude: pos.longitude,
          timestamp: packet.timestamp,
          data: packet.data
        }

      _ ->
        nil
    end
  end

  @doc """
  Clear history for a specific callsign or all.
  """
  def clear_history(callsign \\ nil) do
    GenServer.cast(__MODULE__, {:clear, callsign})
  end

  @doc """
  Export history to file.
  """
  def export_to_file(path) do
    GenServer.call(__MODULE__, {:export, path})
  end

  @doc """
  Get history statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end
end
