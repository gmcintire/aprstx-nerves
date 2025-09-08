defmodule Aprstx.Digipeater do
  @moduledoc """
  APRS digipeater with aprx-style features including viscous delay,
  flooding prevention, and smart path handling.
  """
  use GenServer

  require Logger

  defstruct [
    :callsign,
    :ssid,
    :config,
    :stats,
    :recent_packets,
    :viscous_queue,
    :aliases
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      callsign: Keyword.get(opts, :callsign, "N0CALL"),
      ssid: Keyword.get(opts, :ssid, 0),
      config: load_config(opts),
      stats: init_stats(),
      recent_packets: %{},
      viscous_queue: %{},
      aliases: load_aliases(opts)
    }

    # Start cleanup timer
    Process.send_after(self(), :cleanup, 60_000)

    {:ok, state}
  end

  defp load_config(opts) do
    %{
      enabled: Keyword.get(opts, :enabled, true),
      # ms
      viscous_delay: Keyword.get(opts, :viscous_delay, 5000),
      max_hops: Keyword.get(opts, :max_hops, 2),
      # 30 seconds
      duplicate_timeout: Keyword.get(opts, :duplicate_timeout, 30_000),
      # 15 seconds
      flooding_timeout: Keyword.get(opts, :flooding_timeout, 15_000),
      max_flood_rate: Keyword.get(opts, :max_flood_rate, 5),

      # Digipeat modes
      wide_mode: Keyword.get(opts, :wide_mode, true),
      trace_mode: Keyword.get(opts, :trace_mode, true),

      # Filters
      blacklist: Keyword.get(opts, :blacklist, []),
      whitelist: Keyword.get(opts, :whitelist, []),

      # aprx-style settings
      filter_wx: Keyword.get(opts, :filter_wx, false),
      filter_telemetry: Keyword.get(opts, :filter_telemetry, false),
      aprsis_digipeat: Keyword.get(opts, :aprsis_digipeat, false)
    }
  end

  defp load_aliases(opts) do
    default_aliases = [
      "WIDE1-1",
      "WIDE2-1",
      "WIDE2-2",
      "WIDE3-1",
      "WIDE3-2",
      "WIDE3-3"
    ]

    Keyword.get(opts, :aliases, default_aliases)
  end

  defp init_stats do
    %{
      packets_received: 0,
      packets_digipeated: 0,
      packets_dropped: 0,
      duplicates: 0,
      viscous_saved: 0,
      flooding_dropped: 0
    }
  end

  @doc """
  Process a packet for potential digipeating.
  Returns {:digipeat, modified_packet} or {:drop, reason}
  """
  def process_packet(packet, source_interface \\ nil) do
    GenServer.call(__MODULE__, {:process_packet, packet, source_interface})
  end

  @impl true
  def handle_call({:process_packet, packet, source_interface}, _from, state) do
    state = update_stats(state, :packets_received)

    # Check if digipeating is enabled
    if state.config.enabled do
      case check_packet(packet, state) do
        {:ok, :process} ->
          process_for_digipeat(packet, source_interface, state)

        {:drop, reason} = drop ->
          state = update_stats(state, :packets_dropped)
          Logger.debug("Dropping packet: #{reason}")
          {:reply, drop, state}
      end
    else
      {:reply, {:drop, :disabled}, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_call({:should_digipeat?, packet, _config}, _from, state) do
    # Quick check if this packet should be digipeated
    result =
      cond do
        not state.config.enabled -> false
        is_duplicate?(packet, state) -> false
        is_flooding?(packet, state) -> false
        is_blacklisted?(packet.source, state) -> false
        not is_whitelisted?(packet.source, state) -> false
        should_filter?(packet, state) -> false
        true -> find_digipeat_point(packet.path, state) != :no_digipeat
      end

    {:reply, result, state}
  end

  defp check_packet(packet, state) do
    cond do
      # Check for duplicate
      is_duplicate?(packet, state) ->
        {:drop, :duplicate}

      # Check flooding
      is_flooding?(packet, state) ->
        {:drop, :flooding}

      # Check blacklist
      is_blacklisted?(packet.source, state) ->
        {:drop, :blacklisted}

      # Check whitelist (if configured)
      not is_whitelisted?(packet.source, state) ->
        {:drop, :not_whitelisted}

      # Check filters
      should_filter?(packet, state) ->
        {:drop, :filtered}

      true ->
        {:ok, :process}
    end
  end

  defp process_for_digipeat(packet, source_interface, state) do
    case find_digipeat_point(packet.path, state) do
      {:digipeat, index, new_hop} ->
        # Check for viscous delay
        if state.config.viscous_delay > 0 and should_use_viscous?(packet) do
          handle_viscous_delay(packet, index, new_hop, source_interface, state)
        else
          perform_digipeat(packet, index, new_hop, state)
        end

      :no_digipeat ->
        {:reply, {:drop, :no_matching_alias}, state}
    end
  end

  defp find_digipeat_point([], _state), do: :no_digipeat

  defp find_digipeat_point(path, state) do
    path
    |> Enum.with_index()
    |> Enum.find_value(fn {hop, index} ->
      if not is_used?(hop) and matches_alias?(hop, state) do
        {:digipeat, index, process_hop(hop, state)}
      end
    end) || :no_digipeat
  end

  defp is_used?(hop) do
    String.ends_with?(hop, "*")
  end

  defp matches_alias?(hop, state) do
    clean_hop = String.replace(hop, "*", "")
    my_call = "#{state.callsign}-#{state.ssid}"

    # Check direct callsign match
    # Check configured aliases
    # Check WIDE/TRACE patterns
    clean_hop == state.callsign or
      clean_hop == my_call or
      Enum.any?(state.aliases, &matches_pattern?(&1, clean_hop)) or
      is_wide_pattern?(clean_hop) or
      is_trace_pattern?(clean_hop)
  end

  defp matches_pattern?(pattern, hop) do
    cond do
      # Exact match
      pattern == hop ->
        true

      # WIDEn-N pattern
      String.starts_with?(pattern, "WIDE") and String.starts_with?(hop, "WIDE") ->
        parse_wide_pattern(hop) != nil

      # TRACEn-N pattern  
      String.starts_with?(pattern, "TRACE") and String.starts_with?(hop, "TRACE") ->
        parse_trace_pattern(hop) != nil

      true ->
        false
    end
  end

  defp is_wide_pattern?(hop) do
    parse_wide_pattern(hop) != nil
  end

  defp is_trace_pattern?(hop) do
    parse_trace_pattern(hop) != nil
  end

  defp parse_wide_pattern(hop) do
    case Regex.run(~r/^WIDE(\d)-(\d)$/, hop) do
      [_, n, m] ->
        {String.to_integer(n), String.to_integer(m)}

      _ ->
        nil
    end
  end

  defp parse_trace_pattern(hop) do
    case Regex.run(~r/^TRACE(\d)-(\d)$/, hop) do
      [_, n, m] ->
        {String.to_integer(n), String.to_integer(m)}

      _ ->
        nil
    end
  end

  defp process_hop(hop, state) do
    clean_hop = String.replace(hop, "*", "")
    my_call = "#{state.callsign}-#{state.ssid}"

    cond do
      # Direct call - mark as used
      clean_hop == state.callsign or clean_hop == my_call ->
        my_call <> "*"

      # WIDE pattern
      is_wide_pattern?(clean_hop) ->
        process_wide_hop(clean_hop, state)

      # TRACE pattern
      is_trace_pattern?(clean_hop) ->
        process_trace_hop(clean_hop, state)

      # Alias - replace with mycall
      true ->
        my_call <> "*"
    end
  end

  defp process_wide_hop(hop, state) do
    case parse_wide_pattern(hop) do
      {n, m} when m > 1 ->
        # Decrement the count
        "WIDE#{n}-#{m - 1}"

      {_n, 1} ->
        # Last hop - mark with mycall
        "#{state.callsign}-#{state.ssid}*"

      _ ->
        hop <> "*"
    end
  end

  defp process_trace_hop(hop, state) do
    my_call = "#{state.callsign}-#{state.ssid}"

    case parse_trace_pattern(hop) do
      {n, m} when m > 1 ->
        # Insert mycall and decrement
        [my_call <> "*", "TRACE#{n}-#{m - 1}"]

      {_n, 1} ->
        # Last hop
        my_call <> "*"

      _ ->
        hop <> "*"
    end
  end

  defp should_use_viscous?(packet) do
    # Use viscous delay for packets that might benefit from it
    # (typically position reports from mobiles)
    packet.type in [:position, :position_with_timestamp, :mic_e]
  end

  defp handle_viscous_delay(packet, index, new_hop, source_interface, state) do
    packet_id = generate_packet_id(packet)

    case Map.get(state.viscous_queue, packet_id) do
      nil ->
        # First time seeing this packet - queue it
        Process.send_after(self(), {:viscous_timeout, packet_id}, state.config.viscous_delay)

        queued_packet = %{
          packet: packet,
          index: index,
          new_hop: new_hop,
          source_interface: source_interface,
          queued_at: System.monotonic_time(:millisecond)
        }

        new_queue = Map.put(state.viscous_queue, packet_id, queued_packet)
        state = %{state | viscous_queue: new_queue}
        state = update_stats(state, :viscous_saved)

        {:reply, {:viscous, state.config.viscous_delay}, state}

      _existing ->
        # Already in queue - this is a duplicate via different path
        # Cancel the viscous delay and digipeat immediately
        state = cancel_viscous(packet_id, state)
        perform_digipeat(packet, index, new_hop, state)
    end
  end

  @impl true
  def handle_info({:viscous_timeout, packet_id}, state) do
    case Map.get(state.viscous_queue, packet_id) do
      nil ->
        # Already processed
        {:noreply, state}

      queued ->
        # Time's up - digipeat the packet
        {:reply, result, new_state} =
          perform_digipeat(
            queued.packet,
            queued.index,
            queued.new_hop,
            state
          )

        # Remove from queue
        new_queue = Map.delete(new_state.viscous_queue, packet_id)

        # Send result to original caller if needed
        if queued[:from] do
          GenServer.reply(queued.from, result)
        end

        {:noreply, %{new_state | viscous_queue: new_queue}}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    # Clean old duplicate entries
    recent_packets =
      state.recent_packets
      |> Enum.filter(fn {_key, timestamp} ->
        now - timestamp < state.config.duplicate_timeout
      end)
      |> Map.new()

    # Clean old viscous queue entries
    viscous_queue =
      state.viscous_queue
      |> Enum.filter(fn {_key, entry} ->
        now - entry.queued_at < state.config.viscous_delay * 2
      end)
      |> Map.new()

    # Schedule next cleanup
    Process.send_after(self(), :cleanup, 60_000)

    {:noreply, %{state | recent_packets: recent_packets, viscous_queue: viscous_queue}}
  end

  defp cancel_viscous(packet_id, state) do
    %{state | viscous_queue: Map.delete(state.viscous_queue, packet_id)}
  end

  defp perform_digipeat(packet, index, new_hop, state) do
    # Build new path
    new_path = build_new_path(packet.path, index, new_hop)

    # Check max hops
    if count_hops(new_path) > state.config.max_hops do
      state = update_stats(state, :packets_dropped)
      {:reply, {:drop, :max_hops_exceeded}, state}
    else
      # Create digipeated packet
      digipeated_packet = %{packet | path: new_path}

      # Record as recent
      packet_id = generate_packet_id(packet)
      recent_packets = Map.put(state.recent_packets, packet_id, System.monotonic_time(:millisecond))

      state = %{state | recent_packets: recent_packets}
      state = update_stats(state, :packets_digipeated)

      {:reply, {:digipeat, digipeated_packet}, state}
    end
  end

  defp build_new_path(path, index, new_hop) when is_list(new_hop) do
    # TRACE mode - insert multiple hops
    {before, [_old | after_]} = Enum.split(path, index)
    before ++ new_hop ++ after_
  end

  defp build_new_path(path, index, new_hop) do
    # Normal replacement
    List.replace_at(path, index, new_hop)
  end

  defp count_hops(path) do
    Enum.count(path, &String.ends_with?(&1, "*"))
  end

  defp is_duplicate?(packet, state) do
    packet_id = generate_packet_id(packet)
    Map.has_key?(state.recent_packets, packet_id)
  end

  defp is_flooding?(packet, state) do
    # Check if source is flooding
    now = System.monotonic_time(:millisecond)
    cutoff = now - state.config.flooding_timeout

    recent_from_source =
      state.recent_packets
      |> Enum.filter(fn {key, timestamp} ->
        String.starts_with?(key, packet.source) and timestamp > cutoff
      end)
      |> length()

    recent_from_source > state.config.max_flood_rate
  end

  defp is_blacklisted?(callsign, state) do
    Enum.member?(state.config.blacklist, callsign)
  end

  defp is_whitelisted?(callsign, state) do
    if state.config.whitelist == [] do
      # No whitelist configured
      true
    else
      Enum.member?(state.config.whitelist, callsign)
    end
  end

  defp should_filter?(packet, state) do
    cond do
      state.config.filter_wx and is_wx?(packet) -> true
      state.config.filter_telemetry and is_telemetry?(packet) -> true
      true -> false
    end
  end

  defp is_wx?(packet) do
    # Weather packets start with specific characters
    String.match?(packet.data, ~r/^[!@=\/].*_/)
  end

  defp is_telemetry?(packet) do
    String.starts_with?(packet.data, "T#")
  end

  defp generate_packet_id(packet) do
    # Generate unique ID for duplicate detection
    data_hash = :md5 |> :crypto.hash(packet.data) |> Base.encode16(case: :lower)
    "#{packet.source}:#{data_hash}"
  end

  defp update_stats(state, stat) do
    new_stats = Map.update!(state.stats, stat, &(&1 + 1))
    %{state | stats: new_stats}
  end

  # Public API

  @doc """
  Get digipeater statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Update configuration.
  """
  def update_config(config) do
    GenServer.cast(__MODULE__, {:update_config, config})
  end

  @doc """
  Clear duplicate cache.
  """
  def clear_cache do
    GenServer.cast(__MODULE__, :clear_cache)
  end

  @doc """
  Check if a packet should be digipeated.
  """
  def should_digipeat?(packet, config) do
    GenServer.call(__MODULE__, {:should_digipeat?, packet, config})
  end

  @doc """
  Set digipeater enabled state.
  """
  def set_enabled(enabled) do
    GenServer.cast(__MODULE__, {:set_enabled, enabled})
  end

  @impl true
  def handle_cast({:update_config, config}, state) do
    new_config = Map.merge(state.config, config)
    {:noreply, %{state | config: new_config}}
  end

  @impl true
  def handle_cast(:clear_cache, state) do
    {:noreply, %{state | recent_packets: %{}, viscous_queue: %{}}}
  end

  @impl true
  def handle_cast({:set_enabled, enabled}, state) do
    new_config = %{state.config | enabled: enabled}
    {:noreply, %{state | config: new_config}}
  end
end
