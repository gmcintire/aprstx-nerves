defmodule Aprstx.Digipeater do
  @moduledoc """
  APRS digipeater functionality for packet repeating.
  Supports WIDEn-N, TRACEn-N, and fill-in digipeating.
  """
  use GenServer

  require Logger

  defstruct [
    :callsign,
    :ssid,
    :aliases,
    :config,
    :stats,
    :recent_packets,
    :kiss_tnc
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    callsign = Keyword.get(opts, :callsign, "NOCALL")
    ssid = Keyword.get(opts, :ssid, 0)

    state = %__MODULE__{
      callsign: callsign,
      ssid: ssid,
      aliases: Keyword.get(opts, :aliases, ["WIDE1-1", "WIDE2", "TRACE"]),
      config: %{
        enabled: Keyword.get(opts, :enabled, true),
        max_hops: Keyword.get(opts, :max_hops, 7),
        # seconds
        dupe_window: Keyword.get(opts, :dupe_window, 30),
        fill_in: Keyword.get(opts, :fill_in, true),
        new_paradigm: Keyword.get(opts, :new_paradigm, true),
        preemptive: Keyword.get(opts, :preemptive, true),
        # milliseconds
        viscous_delay: Keyword.get(opts, :viscous_delay, 0),
        limit_hops: Keyword.get(opts, :limit_hops, true),
        direct_only: Keyword.get(opts, :direct_only, false)
      },
      stats: %{
        packets_received: 0,
        packets_digipeated: 0,
        packets_dropped: 0,
        duplicates: 0
      },
      recent_packets: %{},
      kiss_tnc: Keyword.get(opts, :kiss_tnc)
    }

    # Schedule cleanup of old packets
    schedule_cleanup()

    Logger.info("Digipeater started: #{callsign}-#{ssid}")
    {:ok, state}
  end

  @doc """
  Process a packet for digipeating.
  """
  def process_packet(packet, from_rf \\ true) do
    GenServer.cast(__MODULE__, {:process_packet, packet, from_rf})
  end

  @impl true
  def handle_cast({:process_packet, packet, from_rf}, state) do
    if state.config.enabled do
      state = update_stats(state, :packets_received)

      # Check if we should digipeat this packet
      case should_digipeat?(packet, state, from_rf) do
        {:yes, reason} ->
          # Check for duplicate
          if is_duplicate?(packet, state) do
            Logger.debug("Duplicate packet, not digipeating")
            update_stats(state, :duplicates)
          else
            # Digipeat the packet
            new_state = digipeat_packet(packet, reason, state)

            # Record packet to prevent duplicates
            new_state = record_packet(packet, new_state)

            new_state
          end

        {:no, reason} ->
          Logger.debug("Not digipeating: #{reason}")
          update_stats(state, :packets_dropped)
      end
    else
      {:noreply, state}
    end
  end

  defp should_digipeat?(packet, state, from_rf) do
    cond do
      # Don't digipeat if not from RF and direct_only is set
      not from_rf and state.config.direct_only ->
        {:no, :not_from_rf}

      # Check if packet has already been digipeated by us
      already_digipeated?(packet, state) ->
        {:no, :already_digipeated}

      # Check path for digipeat aliases
      true ->
        check_path_for_digipeat(packet.path, state)
    end
  end

  defp check_path_for_digipeat([], _state), do: {:no, :no_path}

  defp check_path_for_digipeat(path, state) do
    # Find the first unused hop in the path
    case find_next_hop(path) do
      {index, hop} ->
        check_hop_for_digipeat(hop, index, path, state)

      nil ->
        {:no, :all_hops_used}
    end
  end

  defp find_next_hop(path) do
    path
    |> Enum.with_index()
    |> Enum.find(fn {hop, _index} ->
      not String.ends_with?(hop, "*")
    end)
  end

  defp check_hop_for_digipeat(hop, index, path, state) do
    hop_clean = String.replace(hop, "*", "")
    my_call = "#{state.callsign}-#{state.ssid}"

    cond do
      # Explicit callsign match
      hop_clean == state.callsign or hop_clean == my_call ->
        {:yes, {:explicit, index}}

      # WIDEn-N paradigm
      String.starts_with?(hop_clean, "WIDE") ->
        check_wide_paradigm(hop_clean, index, path, state)

      # TRACEn-N paradigm
      String.starts_with?(hop_clean, "TRACE") ->
        check_trace_paradigm(hop_clean, index, path, state)

      # Check aliases
      hop_clean in state.aliases ->
        {:yes, {:alias, index, hop_clean}}

      true ->
        {:no, :no_match}
    end
  end

  defp check_wide_paradigm(hop, index, _path, state) do
    case parse_paradigm_hop(hop) do
      {n, n} when n > 0 and n <= state.config.max_hops ->
        # First hop of WIDEn-N
        if n == 1 and state.config.fill_in do
          {:yes, {:wide_fill_in, index, n}}
        else
          {:yes, {:wide, index, n}}
        end

      {total, remaining} when remaining > 0 and total <= state.config.max_hops ->
        # Subsequent hop of WIDEn-N
        {:yes, {:wide, index, remaining}}

      _ ->
        {:no, :invalid_wide}
    end
  end

  defp check_trace_paradigm(hop, index, _path, state) do
    case parse_paradigm_hop(hop) do
      {n, n} when n > 0 and n <= state.config.max_hops ->
        # First hop of TRACEn-N
        {:yes, {:trace, index, n}}

      {total, remaining} when remaining > 0 and total <= state.config.max_hops ->
        # Subsequent hop of TRACEn-N
        {:yes, {:trace, index, remaining}}

      _ ->
        {:no, :invalid_trace}
    end
  end

  defp parse_paradigm_hop(hop) do
    case Regex.run(~r/^(?:WIDE|TRACE)(\d)-(\d)$/, hop) do
      [_, total_str, remaining_str] ->
        {String.to_integer(total_str), String.to_integer(remaining_str)}

      _ ->
        {0, 0}
    end
  end

  defp already_digipeated?(packet, state) do
    my_call = "#{state.callsign}-#{state.ssid}"

    Enum.any?(packet.path, fn hop ->
      hop_clean = String.replace(hop, "*", "")
      hop_clean == state.callsign or hop_clean == my_call
    end)
  end

  defp is_duplicate?(packet, state) do
    key = generate_packet_key(packet)
    now = System.monotonic_time(:second)

    case Map.get(state.recent_packets, key) do
      nil -> false
      timestamp -> now - timestamp < state.config.dupe_window
    end
  end

  defp generate_packet_key(packet) do
    "#{packet.source}>#{packet.destination}:#{:erlang.phash2(packet.data)}"
  end

  defp record_packet(packet, state) do
    key = generate_packet_key(packet)
    now = System.monotonic_time(:second)

    %{state | recent_packets: Map.put(state.recent_packets, key, now)}
  end

  defp digipeat_packet(packet, reason, state) do
    # Apply viscous delay if configured
    if state.config.viscous_delay > 0 do
      Process.sleep(state.config.viscous_delay)
    end

    # Modify path based on digipeat reason
    new_path = modify_path_for_digipeat(packet.path, reason, state)

    # Check if we should limit hops
    new_path =
      if state.config.limit_hops and too_many_hops?(new_path) do
        limit_path_hops(new_path, state.config.max_hops)
      else
        new_path
      end

    # Create digipeated packet
    digi_packet = %{packet | path: new_path}

    # Transmit via KISS TNC if available
    if state.kiss_tnc do
      Aprstx.KissTnc.send_packet(digi_packet)
    end

    # Also forward to connected clients (acting as igate)
    GenServer.cast(Aprstx.Server, {:broadcast, digi_packet, :digipeater})

    Logger.info("Digipeated: #{Aprstx.Packet.encode(digi_packet)}")

    update_stats(state, :packets_digipeated)
  end

  defp modify_path_for_digipeat(path, {:explicit, index}, _state) do
    # Mark the explicit callsign as used
    List.update_at(path, index, &(&1 <> "*"))
  end

  defp modify_path_for_digipeat(path, {:wide_fill_in, index, _n}, state) do
    # WIDE1-1 fill-in: insert our callsign before and mark as used
    my_call = "#{state.callsign}-#{state.ssid}*"

    path
    |> List.insert_at(index, my_call)
    |> List.update_at(index + 1, fn _ -> "WIDE1*" end)
  end

  defp modify_path_for_digipeat(path, {:wide, index, remaining}, state) do
    # WIDEn-N: decrement or mark as used
    if state.config.preemptive and remaining > 1 do
      # Preemptive digipeating: insert our call and decrement
      my_call = "#{state.callsign}-#{state.ssid}*"
      new_hop = "WIDE#{remaining}-#{remaining - 1}"

      path
      |> List.insert_at(index, my_call)
      |> List.replace_at(index + 1, new_hop)
    else
      # Mark as used
      List.update_at(path, index, &String.replace(&1, ~r/\d$/, "*"))
    end
  end

  defp modify_path_for_digipeat(path, {:trace, index, remaining}, state) do
    # TRACEn-N: always insert callsign
    my_call = "#{state.callsign}-#{state.ssid}*"

    if remaining > 1 do
      new_hop = "TRACE#{remaining}-#{remaining - 1}"

      path
      |> List.insert_at(index, my_call)
      |> List.replace_at(index + 1, new_hop)
    else
      path
      |> List.insert_at(index, my_call)
      |> List.update_at(index + 1, &(&1 <> "*"))
    end
  end

  defp modify_path_for_digipeat(path, {:alias, index, _alias}, state) do
    # Replace alias with our callsign
    my_call = "#{state.callsign}-#{state.ssid}*"
    List.replace_at(path, index, my_call)
  end

  defp too_many_hops?(path) do
    unused_hops = Enum.count(path, &(not String.ends_with?(&1, "*")))
    unused_hops > 2
  end

  defp limit_path_hops(path, max_hops) do
    # Truncate path to limit propagation
    used = Enum.take_while(path, &String.ends_with?(&1, "*"))

    unused =
      path
      |> Enum.drop(length(used))
      |> Enum.take(max_hops - length(used))

    used ++ unused
  end

  defp update_stats(state, stat) do
    %{state | stats: Map.update!(state.stats, stat, &(&1 + 1))}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:second)
    cutoff = now - state.config.dupe_window

    recent =
      state.recent_packets
      |> Enum.filter(fn {_key, timestamp} -> timestamp > cutoff end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | recent_packets: recent}}
  end

  defp schedule_cleanup do
    # Every minute
    Process.send_after(self(), :cleanup, 60_000)
  end

  @doc """
  Get digipeater statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @doc """
  Update digipeater configuration.
  """
  def update_config(config) do
    GenServer.cast(__MODULE__, {:update_config, config})
  end

  @impl true
  def handle_cast({:update_config, config}, state) do
    new_config = Map.merge(state.config, config)
    {:noreply, %{state | config: new_config}}
  end

  @doc """
  Enable or disable digipeater.
  """
  def set_enabled(enabled) do
    GenServer.cast(__MODULE__, {:set_enabled, enabled})
  end

  @impl true
  def handle_cast({:set_enabled, enabled}, state) do
    Logger.info("Digipeater #{if enabled, do: "enabled", else: "disabled"}")
    {:noreply, put_in(state.config.enabled, enabled)}
  end
end
