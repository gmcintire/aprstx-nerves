defmodule Aprstx.Beacon do
  @moduledoc """
  APRS beacon transmission with GPS position and smart beaconing.
  """
  use GenServer

  require Logger

  defstruct [
    :callsign,
    :ssid,
    :symbol,
    :comment,
    :path,
    :config,
    :last_beacon,
    :last_position,
    :stats,
    :smart_beacon,
    :kiss_tnc
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    callsign = Keyword.get(opts, :callsign, "NOCALL")
    ssid = Keyword.get(opts, :ssid, 9)

    state = %__MODULE__{
      callsign: callsign,
      ssid: ssid,
      # Default: Primary symbol table, digi
      symbol: Keyword.get(opts, :symbol, "/#"),
      comment: Keyword.get(opts, :comment, "APRSTX Roaming iGate/Digi"),
      path: Keyword.get(opts, :path, ["WIDE1-1", "WIDE2-1"]),
      config: %{
        enabled: Keyword.get(opts, :enabled, true),
        # 10 minutes default
        interval: Keyword.get(opts, :interval, 600_000),
        compressed: Keyword.get(opts, :compressed, false),
        altitude: Keyword.get(opts, :altitude, true),
        timestamp: Keyword.get(opts, :timestamp, false),
        smart_beaconing: Keyword.get(opts, :smart_beaconing, true)
      },
      smart_beacon: init_smart_beacon(opts),
      stats: %{
        beacons_sent: 0,
        last_beacon_time: nil
      },
      kiss_tnc: Keyword.get(opts, :kiss_tnc)
    }

    # Subscribe to GPS updates
    Aprstx.GPS.subscribe()

    # Schedule first beacon
    if state.config.enabled do
      schedule_next_beacon(state.config.interval)
    end

    Logger.info("Beacon started: #{callsign}-#{ssid}")
    {:ok, state}
  end

  defp init_smart_beacon(opts) do
    %{
      # Speed thresholds (km/h)
      low_speed: Keyword.get(opts, :sb_low_speed, 5),
      high_speed: Keyword.get(opts, :sb_high_speed, 90),

      # Beacon rates (seconds)
      # 30 min when stopped
      slow_rate: Keyword.get(opts, :sb_slow_rate, 1800),
      # 1 min at high speed
      fast_rate: Keyword.get(opts, :sb_fast_rate, 60),

      # Turn thresholds
      # degrees
      min_turn_angle: Keyword.get(opts, :sb_min_turn_angle, 30),
      # seconds
      min_turn_time: Keyword.get(opts, :sb_min_turn_time, 15),

      # Corner pegging
      corner_pegging: Keyword.get(opts, :sb_corner_pegging, true),

      # State
      last_heading: nil,
      last_turn_time: nil
    }
  end

  @impl true
  def handle_info({:gps, {:position_update, position}}, state) do
    if state.config.enabled and state.config.smart_beaconing do
      # Check if smart beaconing triggers a beacon
      case should_beacon_smart?(position, state) do
        {true, reason} ->
          Logger.debug("Smart beacon triggered: #{reason}")
          state = send_beacon(position, state)
          {:noreply, state}

        {false, _} ->
          {:noreply, %{state | last_position: position}}
      end
    else
      {:noreply, %{state | last_position: position}}
    end
  end

  @impl true
  def handle_info(:beacon_timer, state) do
    if state.config.enabled do
      # Get current position
      case Aprstx.GPS.get_position() do
        nil ->
          # No GPS fix, send status beacon
          state = send_status_beacon(state)
          schedule_next_beacon(state.config.interval)
          {:noreply, state}

        position ->
          # Send position beacon
          state = send_beacon(position, state)

          # Schedule next beacon based on smart beaconing
          interval = calculate_next_interval(position, state)
          schedule_next_beacon(interval)

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  defp should_beacon_smart?(position, state) do
    cond do
      # First beacon
      state.last_beacon == nil ->
        {true, :first_beacon}

      # Check time since last beacon
      time_since_beacon(state) > state.smart_beacon.slow_rate * 1000 ->
        {true, :max_time}

      # Check for significant course change (corner pegging)
      state.smart_beacon.corner_pegging and
          significant_turn?(position, state) ->
        {true, :corner_pegging}

      # Check speed-based beaconing
      speed_beacon_needed?(position, state) ->
        {true, :speed_based}

      true ->
        {false, :no_trigger}
    end
  end

  defp time_since_beacon(state) do
    if state.last_beacon do
      System.monotonic_time(:millisecond) - state.last_beacon
    else
      :infinity
    end
  end

  defp significant_turn?(position, state) do
    if position[:course] && state.smart_beacon.last_heading do
      angle_diff = abs(position.course - state.smart_beacon.last_heading)
      angle_diff = if angle_diff > 180, do: 360 - angle_diff, else: angle_diff

      if angle_diff >= state.smart_beacon.min_turn_angle do
        # Check minimum time since last turn
        now = System.monotonic_time(:second)

        case state.smart_beacon.last_turn_time do
          nil -> true
          last_turn -> now - last_turn >= state.smart_beacon.min_turn_time
        end
      else
        false
      end
    else
      false
    end
  end

  defp speed_beacon_needed?(position, state) do
    if position[:speed] && state.last_beacon do
      # Convert to seconds
      time_since = time_since_beacon(state) / 1000

      # Calculate beacon rate based on speed
      beacon_rate = calculate_beacon_rate(position.speed, state.smart_beacon)

      time_since >= beacon_rate
    else
      false
    end
  end

  defp calculate_beacon_rate(speed, smart_beacon) do
    cond do
      speed <= smart_beacon.low_speed ->
        smart_beacon.slow_rate

      speed >= smart_beacon.high_speed ->
        smart_beacon.fast_rate

      true ->
        # Linear interpolation between slow and fast rates
        speed_range = smart_beacon.high_speed - smart_beacon.low_speed
        rate_range = smart_beacon.slow_rate - smart_beacon.fast_rate
        speed_factor = (speed - smart_beacon.low_speed) / speed_range

        smart_beacon.slow_rate - rate_range * speed_factor
    end
  end

  defp calculate_next_interval(position, state) do
    if state.config.smart_beaconing && position[:speed] do
      rate = calculate_beacon_rate(position.speed, state.smart_beacon)
      # Convert to milliseconds
      trunc(rate * 1000)
    else
      state.config.interval
    end
  end

  defp send_beacon(position, state) do
    packet = build_position_packet(position, state)

    # Transmit via KISS TNC if available
    if state.kiss_tnc do
      Aprstx.KissTnc.send_packet(packet)
    end

    # Also send to APRS-IS
    GenServer.cast(Aprstx.Server, {:broadcast, packet, :beacon})
    Aprstx.Uplink.send_packet(packet)

    Logger.info("Beacon sent: #{Aprstx.Packet.encode(packet)}")

    # Update state
    %{
      state
      | last_beacon: System.monotonic_time(:millisecond),
        last_position: position,
        stats: %{
          state.stats
          | beacons_sent: state.stats.beacons_sent + 1,
            last_beacon_time: DateTime.utc_now()
        },
        smart_beacon: update_smart_beacon_state(position, state.smart_beacon)
    }
  end

  defp update_smart_beacon_state(position, smart_beacon) do
    smart_beacon =
      if position[:course] do
        %{smart_beacon | last_heading: position.course}
      else
        smart_beacon
      end

    # Update last turn time if we just turned
    if position[:course] && smart_beacon.last_heading do
      angle_diff = abs(position.course - smart_beacon.last_heading)
      angle_diff = if angle_diff > 180, do: 360 - angle_diff, else: angle_diff

      if angle_diff >= smart_beacon.min_turn_angle do
        %{smart_beacon | last_turn_time: System.monotonic_time(:second)}
      else
        smart_beacon
      end
    else
      smart_beacon
    end
  end

  defp send_status_beacon(state) do
    packet = build_status_packet(state)

    # Transmit via KISS TNC if available
    if state.kiss_tnc do
      Aprstx.KissTnc.send_packet(packet)
    end

    # Also send to APRS-IS
    GenServer.cast(Aprstx.Server, {:broadcast, packet, :beacon})

    Logger.info("Status beacon sent: #{Aprstx.Packet.encode(packet)}")

    %{
      state
      | last_beacon: System.monotonic_time(:millisecond),
        stats: %{
          state.stats
          | beacons_sent: state.stats.beacons_sent + 1,
            last_beacon_time: DateTime.utc_now()
        }
    }
  end

  defp build_position_packet(position, state) do
    source = "#{state.callsign}-#{state.ssid}"

    # Format position data
    pos_str = Aprstx.GPS.format_aprs_position(position)

    # Build data field
    data =
      if state.config.compressed do
        build_compressed_position(position, state)
      else
        build_uncompressed_position(pos_str, position, state)
      end

    %Aprstx.Packet{
      source: source,
      destination: "APRS",
      path: state.path,
      data: data,
      type: if(state.config.timestamp, do: :position_with_timestamp, else: :position_no_timestamp),
      timestamp: DateTime.utc_now()
    }
  end

  defp build_uncompressed_position(pos_str, position, state) do
    # Start with position indicator
    indicator =
      if state.config.timestamp do
        timestamp = format_aprs_timestamp(DateTime.utc_now())
        "/#{timestamp}z"
      else
        "!"
      end

    # Add position and symbol
    data = "#{indicator}#{pos_str}#{state.symbol}"

    # Add course/speed if available
    data =
      if position[:course] && position[:speed] do
        course = position.course |> trunc() |> Integer.to_string() |> String.pad_leading(3, "0")
        # km/h to knots
        speed = trunc(position.speed * 0.539957)
        speed_str = speed |> Integer.to_string() |> String.pad_leading(3, "0")
        "#{data}#{course}/#{speed_str}"
      else
        data
      end

    # Add altitude if available and enabled
    data =
      if state.config.altitude && position[:altitude] do
        alt_feet = trunc(position.altitude * 3.28084)
        "#{data}/A=#{String.pad_leading(Integer.to_string(alt_feet), 6, "0")}"
      else
        data
      end

    # Add comment
    "#{data} #{state.comment}"
  end

  defp build_compressed_position(position, state) do
    # Compressed position format (base-91)
    # This is a simplified version - full implementation would be more complex

    indicator =
      if state.config.timestamp do
        timestamp = format_aprs_timestamp(DateTime.utc_now())
        "@#{timestamp}z"
      else
        "="
      end

    # Compress lat/lon to base-91
    lat_compressed = compress_latitude(position.latitude)
    lon_compressed = compress_longitude(position.longitude)

    # Symbol table and code
    [table, code] = String.graphemes(state.symbol)

    # Build compressed position
    "#{indicator}#{lat_compressed}#{lon_compressed}#{code}#{table} #{state.comment}"
  end

  defp compress_latitude(lat) do
    # Convert to base-91 (simplified)
    y = 380_926 * (90 - lat)

    <<
      33 + div(trunc(y), 91 * 91 * 91),
      33 + rem(div(trunc(y), 91 * 91), 91),
      33 + rem(div(trunc(y), 91), 91),
      33 + rem(trunc(y), 91)
    >>
  end

  defp compress_longitude(lon) do
    # Convert to base-91 (simplified)
    x = 190_463 * (180 + lon)

    <<
      33 + div(trunc(x), 91 * 91 * 91),
      33 + rem(div(trunc(x), 91 * 91), 91),
      33 + rem(div(trunc(x), 91), 91),
      33 + rem(trunc(x), 91)
    >>
  end

  defp build_status_packet(state) do
    source = "#{state.callsign}-#{state.ssid}"

    status = ">#{format_aprs_timestamp(DateTime.utc_now())}z #{state.comment} [No GPS Fix]"

    %Aprstx.Packet{
      source: source,
      destination: "APRS",
      path: state.path,
      data: status,
      type: :status,
      timestamp: DateTime.utc_now()
    }
  end

  defp format_aprs_timestamp(datetime) do
    Calendar.strftime(datetime, "%d%H%M")
  end

  defp schedule_next_beacon(interval) do
    Process.send_after(self(), :beacon_timer, interval)
  end

  # Public API

  @doc """
  Send beacon immediately.
  """
  def send_now do
    GenServer.cast(__MODULE__, :send_now)
  end

  @impl true
  def handle_cast(:send_now, state) do
    case Aprstx.GPS.get_position() do
      nil ->
        {:noreply, send_status_beacon(state)}

      position ->
        {:noreply, send_beacon(position, state)}
    end
  end

  @impl true
  def handle_cast({:update_config, config}, state) do
    new_config = Map.merge(state.config, config)
    {:noreply, %{state | config: new_config}}
  end

  @impl true
  def handle_cast({:set_enabled, enabled}, state) do
    Logger.info("Beacon #{if enabled, do: "enabled", else: "disabled"}")

    if enabled and not state.config.enabled do
      # Start beaconing
      schedule_next_beacon(state.config.interval)
    end

    {:noreply, put_in(state.config.enabled, enabled)}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        enabled: state.config.enabled,
        smart_beaconing: state.config.smart_beaconing,
        last_position: state.last_position
      })

    {:reply, stats, state}
  end

  @doc """
  Get beacon statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Update beacon configuration.
  """
  def update_config(config) do
    GenServer.cast(__MODULE__, {:update_config, config})
  end

  @doc """
  Enable or disable beaconing.
  """
  def set_enabled(enabled) do
    GenServer.cast(__MODULE__, {:set_enabled, enabled})
  end
end
