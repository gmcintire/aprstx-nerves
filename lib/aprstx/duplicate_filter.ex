defmodule Aprstx.DuplicateFilter do
  @moduledoc """
  Duplicate packet detection and filtering.
  Maintains a sliding window of recent packets to detect duplicates.
  """
  use GenServer

  require Logger

  # 30 seconds
  @duplicate_window 30_000
  # 1 minute
  @cleanup_interval 60_000

  defstruct [
    :cache,
    :stats
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      cache: %{},
      stats: %{
        duplicates_filtered: 0,
        unique_packets: 0
      }
    }

    schedule_cleanup()
    {:ok, state}
  end

  @doc """
  Check if a packet is a duplicate.
  Returns true if duplicate, false if unique.
  """
  def is_duplicate?(packet) do
    GenServer.call(__MODULE__, {:check_duplicate, packet})
  end

  @doc """
  Record a packet for duplicate detection.
  """
  def record_packet(packet) do
    GenServer.cast(__MODULE__, {:record, packet})
  end

  @impl true
  def handle_call({:check_duplicate, packet}, _from, state) do
    key = generate_key(packet)
    now = System.monotonic_time(:millisecond)

    case Map.get(state.cache, key) do
      nil ->
        # Not a duplicate
        {:reply, false, state}

      timestamp when now - timestamp <= @duplicate_window ->
        # Duplicate within window
        new_stats = Map.update!(state.stats, :duplicates_filtered, &(&1 + 1))
        {:reply, true, %{state | stats: new_stats}}

      _timestamp ->
        # Old entry, not considered duplicate
        {:reply, false, state}
    end
  end

  @impl true
  def handle_cast({:record, packet}, state) do
    key = generate_key(packet)
    now = System.monotonic_time(:millisecond)

    new_cache = Map.put(state.cache, key, now)
    new_stats = Map.update!(state.stats, :unique_packets, &(&1 + 1))

    {:noreply, %{state | cache: new_cache, stats: new_stats}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @duplicate_window

    new_cache =
      state.cache
      |> Enum.filter(fn {_key, timestamp} -> timestamp > cutoff end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | cache: new_cache}}
  end

  defp generate_key(packet) do
    # Generate unique key based on packet content
    # Include source, destination, and data hash
    data_hash = :md5 |> :crypto.hash(packet.data) |> Base.encode16()
    "#{packet.source}>#{packet.destination}:#{data_hash}"
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end
end
