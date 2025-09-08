defmodule Aprstx.RfGate do
  @moduledoc """
  RF gating logic for aprx - handles intelligent gating between RF and APRS-IS
  with duplicate detection, path validation, and rate limiting.
  """
  use GenServer

  require Logger

  # 30 seconds
  @duplicate_timeout 30_000
  # 10 minutes for heard list
  @heard_timeout 600_000
  # 1 minute
  @cleanup_interval 60_000

  defstruct [
    :config,
    :recent_packets,
    :heard_direct,
    :heard_indirect,
    :gated_to_rf,
    :stats
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      config: load_config(opts),
      recent_packets: %{},
      heard_direct: %{},
      heard_indirect: %{},
      gated_to_rf: %{},
      stats: init_stats()
    }

    # Start cleanup timer
    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:ok, state}
  end

  defp load_config(opts) do
    %{
      # RF to IS gating
      rf_to_is: Keyword.get(opts, :rf_to_is, true),
      gate_local_only: Keyword.get(opts, :gate_local_only, false),
      # km
      local_range: Keyword.get(opts, :local_range, 50),

      # IS to RF gating
      is_to_rf: Keyword.get(opts, :is_to_rf, true),
      # :all, :heard, :message_only
      is_to_rf_type: Keyword.get(opts, :is_to_rf_type, :heard),

      # Message gating
      gate_messages: Keyword.get(opts, :gate_messages, true),
      gate_positions: Keyword.get(opts, :gate_positions, true),
      gate_weather: Keyword.get(opts, :gate_weather, true),
      gate_telemetry: Keyword.get(opts, :gate_telemetry, false),
      gate_objects: Keyword.get(opts, :gate_objects, true),

      # Rate limiting
      # packets per minute
      max_rf_rate: Keyword.get(opts, :max_rf_rate, 30),
      rate_limit_window: Keyword.get(opts, :rate_limit_window, 60_000),

      # Path limits
      max_hops_to_rf: Keyword.get(opts, :max_hops_to_rf, 2),

      # Station position (for range calculations)
      position: Keyword.get(opts, :position, %{lat: 0.0, lon: 0.0})
    }
  end

  defp init_stats do
    %{
      rf_to_is_gated: 0,
      is_to_rf_gated: 0,
      duplicates_blocked: 0,
      rate_limited: 0,
      out_of_range: 0,
      invalid_path: 0
    }
  end

  @doc """
  Check if a packet from RF should be gated to APRS-IS.
  """
  def should_gate_rf_to_is?(packet, interface_id) do
    GenServer.call(__MODULE__, {:check_rf_to_is, packet, interface_id})
  end

  @doc """
  Check if a packet from APRS-IS should be gated to RF.
  """
  def should_gate_is_to_rf?(packet) do
    GenServer.call(__MODULE__, {:check_is_to_rf, packet})
  end

  @doc """
  Record that a packet was heard on RF (for IS->RF gating decisions).
  """
  def heard_on_rf(callsign, direct?) do
    GenServer.cast(__MODULE__, {:heard_on_rf, callsign, direct?})
  end

  @doc """
  Record that a packet was gated.
  """
  def record_gated(packet, direction) do
    GenServer.cast(__MODULE__, {:record_gated, packet, direction})
  end

  @impl true
  def handle_call({:check_rf_to_is, packet, _interface_id}, _from, state) do
    result =
      cond do
        not state.config.rf_to_is ->
          {:no, :rf_to_is_disabled}

        is_duplicate_rf?(packet, state) ->
          _ = update_stats(state, :duplicates_blocked)
          {:no, :duplicate}

        has_invalid_rf_path?(packet) ->
          _ = update_stats(state, :invalid_path)
          {:no, :invalid_path}

        is_third_party?(packet) ->
          {:no, :third_party}

        state.config.gate_local_only and not is_local?(packet, state) ->
          _ = update_stats(state, :out_of_range)
          {:no, :out_of_range}

        not should_gate_type?(packet, state.config) ->
          {:no, :filtered_type}

        true ->
          {:yes, add_qar_construct(packet)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:check_is_to_rf, packet}, _from, state) do
    result =
      cond do
        not state.config.is_to_rf ->
          {:no, :is_to_rf_disabled}

        is_duplicate_is?(packet, state) ->
          _ = update_stats(state, :duplicates_blocked)
          {:no, :duplicate}

        is_rate_limited?(state) ->
          _ = update_stats(state, :rate_limited)
          {:no, :rate_limited}

        not should_gate_to_heard?(packet, state) ->
          {:no, :not_heard}

        not should_gate_type?(packet, state.config) ->
          {:no, :filtered_type}

        too_many_hops?(packet, state.config.max_hops_to_rf) ->
          {:no, :too_many_hops}

        true ->
          {:yes, prepare_for_rf(packet)}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_call(:get_heard_list, _from, state) do
    heard = %{
      direct: Map.keys(state.heard_direct),
      indirect: Map.keys(state.heard_indirect)
    }

    {:reply, heard, state}
  end

  @impl true
  def handle_cast({:heard_on_rf, callsign, direct?}, state) do
    now = System.monotonic_time(:millisecond)

    state =
      if direct? do
        %{state | heard_direct: Map.put(state.heard_direct, callsign, now)}
      else
        %{state | heard_indirect: Map.put(state.heard_indirect, callsign, now)}
      end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:record_gated, packet, direction}, state) do
    packet_id = generate_packet_id(packet)
    now = System.monotonic_time(:millisecond)

    state =
      case direction do
        :rf_to_is ->
          recent = Map.put(state.recent_packets, packet_id, now)
          state = update_stats(state, :rf_to_is_gated)
          %{state | recent_packets: recent}

        :is_to_rf ->
          gated = Map.put(state.gated_to_rf, packet_id, now)
          state = update_stats(state, :is_to_rf_gated)
          %{state | gated_to_rf: gated}
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)

    # Clean old entries
    recent = clean_old_entries(state.recent_packets, now - @duplicate_timeout)
    heard_direct = clean_old_entries(state.heard_direct, now - @heard_timeout)
    heard_indirect = clean_old_entries(state.heard_indirect, now - @heard_timeout)
    gated = clean_old_entries(state.gated_to_rf, now - @duplicate_timeout)

    state = %{
      state
      | recent_packets: recent,
        heard_direct: heard_direct,
        heard_indirect: heard_indirect,
        gated_to_rf: gated
    }

    # Schedule next cleanup
    Process.send_after(self(), :cleanup, @cleanup_interval)

    {:noreply, state}
  end

  defp clean_old_entries(map, cutoff) do
    map
    |> Enum.filter(fn {_key, timestamp} -> timestamp > cutoff end)
    |> Map.new()
  end

  defp is_duplicate_rf?(packet, state) do
    packet_id = generate_packet_id(packet)
    Map.has_key?(state.recent_packets, packet_id)
  end

  defp is_duplicate_is?(packet, state) do
    packet_id = generate_packet_id(packet)
    Map.has_key?(state.gated_to_rf, packet_id)
  end

  defp has_invalid_rf_path?(packet) do
    # Check for invalid RF paths
    Enum.any?(packet.path || [], fn hop ->
      # No q-constructs should be on RF
      # No TCPIP should be on RF
      # No NOGATE
      # No RFONLY from RF (it's already RF!)
      String.starts_with?(hop, "q") or
        hop == "TCPIP*" or
        hop == "NOGATE" or
        hop == "RFONLY"
    end)
  end

  defp is_third_party?(packet) do
    # Third-party packets start with }
    String.starts_with?(packet.data || "", "}")
  end

  defp is_local?(packet, state) do
    # Check if packet is within local range
    case extract_position(packet) do
      {:ok, lat, lon} ->
        distance =
          calculate_distance(
            state.config.position.lat,
            state.config.position.lon,
            lat,
            lon
          )

        distance <= state.config.local_range

      _ ->
        # No position or can't determine - consider it local
        true
    end
  end

  defp should_gate_type?(packet, config) do
    cond do
      is_message?(packet) -> config.gate_messages
      is_position?(packet) -> config.gate_positions
      is_weather?(packet) -> config.gate_weather
      is_telemetry?(packet) -> config.gate_telemetry
      is_object?(packet) -> config.gate_objects
      # Gate other types by default
      true -> true
    end
  end

  defp should_gate_to_heard?(packet, state) do
    case state.config.is_to_rf_type do
      :all ->
        true

      :message_only ->
        is_message?(packet) or is_addressed_to_heard?(packet, state)

      :heard ->
        # Gate if we've heard the station recently
        is_heard?(packet.destination, state) or
          is_heard?(packet.source, state) or
          is_addressed_to_heard?(packet, state)
    end
  end

  defp is_heard?(callsign, state) do
    Map.has_key?(state.heard_direct, callsign) or
      Map.has_key?(state.heard_indirect, callsign)
  end

  defp is_addressed_to_heard?(packet, state) do
    # Check if packet is addressed to a heard station
    if is_message?(packet) do
      case parse_message_addressee(packet.data) do
        {:ok, addressee} ->
          is_heard?(addressee, state)

        _ ->
          false
      end
    else
      false
    end
  end

  defp is_rate_limited?(state) do
    # Count recent packets gated to RF
    now = System.monotonic_time(:millisecond)
    cutoff = now - state.config.rate_limit_window

    recent_count = Enum.count(state.gated_to_rf, fn {_id, timestamp} -> timestamp > cutoff end)

    recent_count >= state.config.max_rf_rate
  end

  defp too_many_hops?(packet, max_hops) do
    # Count remaining hops in path
    remaining_hops =
      packet.path
      |> Enum.filter(&(not String.ends_with?(&1, "*")))
      |> Enum.map(&count_path_hops/1)
      |> Enum.sum()

    remaining_hops > max_hops
  end

  defp count_path_hops(hop) do
    case Regex.run(~r/^WIDE(\d)-(\d)$/, hop) do
      [_, _n, m] -> String.to_integer(m)
      _ -> 1
    end
  end

  defp add_qar_construct(packet) do
    # Add qAR construct for RF->IS gating
    # qAR = packet heard directly (no digipeating)
    gateway_call = Application.get_env(:aprstx, :callsign, "N0CALL")

    %{packet | path: (packet.path || []) ++ ["qAR", gateway_call]}
  end

  defp prepare_for_rf(packet) do
    # Remove q-constructs and prepare for RF transmission
    cleaned_path =
      packet.path
      |> Enum.reject(&String.starts_with?(&1, "q"))
      |> Enum.reject(&(&1 == "TCPIP*"))

    %{packet | path: cleaned_path}
  end

  defp is_message?(packet) do
    String.starts_with?(packet.data || "", ":")
  end

  defp is_position?(packet) do
    data = packet.data || ""
    String.match?(data, ~r/^[!@=\/]/)
  end

  defp is_weather?(packet) do
    data = packet.data || ""

    String.match?(data, ~r/^[!@=\/].*_/) or
      String.starts_with?(data, "_")
  end

  defp is_telemetry?(packet) do
    data = packet.data || ""
    String.starts_with?(data, "T#")
  end

  defp is_object?(packet) do
    data = packet.data || ""
    String.starts_with?(data, ";")
  end

  defp parse_message_addressee(data) do
    case Regex.run(~r/^:([A-Z0-9\- ]{9}):/, data) do
      [_, addressee] ->
        {:ok, String.trim(addressee)}

      _ ->
        :error
    end
  end

  defp extract_position(packet) do
    # Extract position from packet data
    # This is simplified - real implementation would handle all APRS position formats
    # Use sigil_r to avoid escaping issues
    pattern = ~r/^[!@=\/](\d{4}\.\d{2})([NS])[\/\\](\d{5}\.\d{2})([EW])/

    case Regex.run(pattern, packet.data || "") do
      [_, lat_str, lat_h, lon_str, lon_h] ->
        lat = parse_aprs_coordinate(lat_str, lat_h)
        lon = parse_aprs_coordinate(lon_str, lon_h)
        {:ok, lat, lon}

      _ ->
        :error
    end
  end

  defp parse_aprs_coordinate(coord_str, hemisphere) do
    {degrees, minutes} =
      case String.length(coord_str) do
        # Latitude
        7 ->
          {String.slice(coord_str, 0..1), String.slice(coord_str, 2..6)}

        # Longitude
        8 ->
          {String.slice(coord_str, 0..2), String.slice(coord_str, 3..7)}

        _ ->
          {"0", "0.00"}
      end

    deg = String.to_integer(degrees)
    min = String.to_float(minutes)
    decimal = deg + min / 60.0

    case hemisphere do
      h when h in ["S", "W"] -> -decimal
      _ -> decimal
    end
  end

  defp calculate_distance(lat1, lon1, lat2, lon2) do
    # Haversine formula for distance calculation
    # Earth radius in km
    r = 6371

    dlat = (lat2 - lat1) * :math.pi() / 180
    dlon = (lon2 - lon1) * :math.pi() / 180

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(lat1 * :math.pi() / 180) * :math.cos(lat2 * :math.pi() / 180) *
          :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    r * c
  end

  defp generate_packet_id(packet) do
    # Generate unique ID for duplicate detection
    data_hash = :md5 |> :crypto.hash(packet.data || "") |> Base.encode16(case: :lower)
    "#{packet.source}:#{data_hash}"
  end

  defp update_stats(state, stat) do
    new_stats = Map.update!(state.stats, stat, &(&1 + 1))
    %{state | stats: new_stats}
  end

  # Public API

  @doc """
  Get gating statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Get heard stations list.
  """
  def get_heard_list do
    GenServer.call(__MODULE__, :get_heard_list)
  end
end
