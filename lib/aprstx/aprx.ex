defmodule Aprstx.Aprx do
  @moduledoc """
  Main aprx coordinator module for APRS iGate/digipeater functionality.
  Manages RF interfaces, APRS-IS connection, and gating logic.
  """
  use GenServer

  require Logger

  defstruct [
    :config,
    :aprs_is_client,
    :tnc_interfaces,
    :beacon_timer,
    :telemetry_timer,
    :stats,
    :last_heard,
    :mode
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    config = load_config(opts)

    state = %__MODULE__{
      config: config,
      tnc_interfaces: %{},
      stats: init_stats(),
      last_heard: %{},
      mode: config.mode
    }

    # Start components based on configuration
    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    # Initialize TNC interfaces
    state = init_tnc_interfaces(state)

    # Connect to APRS-IS if configured
    state =
      if state.config.aprs_is.enabled do
        connect_aprs_is(state)
      else
        state
      end

    # Start beaconing if configured
    state =
      if state.config.beacon.enabled do
        schedule_beacon(state)
      else
        state
      end

    # Start telemetry reporting if configured
    state =
      if state.config.telemetry.enabled do
        schedule_telemetry(state)
      else
        state
      end

    Logger.info("Aprx started in #{state.mode} mode")
    {:noreply, state}
  end

  # Handle packet from RF
  @impl true
  def handle_info({:rf_packet, interface_id, packet}, state) do
    Logger.debug("Received RF packet from #{interface_id}: #{inspect(packet)}")

    # Update stats
    state = update_stats(state, :rf_received)

    # Update last heard
    state = update_last_heard(state, packet.source)

    # Check if we should gate to APRS-IS
    state =
      if should_gate_to_is?(packet, state) do
        gate_to_aprs_is(packet, interface_id, state)
      else
        state
      end

    # Check if we should digipeat
    state =
      if should_digipeat?(packet, state) do
        digipeat_packet(packet, interface_id, state)
      else
        state
      end

    {:noreply, state}
  end

  # Handle packet from APRS-IS
  @impl true
  def handle_info({:aprs_is_packet, packet}, state) do
    Logger.debug("Received APRS-IS packet: #{inspect(packet)}")

    # Update stats
    state = update_stats(state, :is_received)

    # Check if we should gate to RF
    state =
      if should_gate_to_rf?(packet, state) do
        gate_to_rf(packet, state)
      else
        state
      end

    {:noreply, state}
  end

  # Handle beacon timer
  @impl true
  def handle_info(:beacon, state) do
    send_beacon(state)
    state = schedule_beacon(state)
    {:noreply, state}
  end

  # Handle telemetry timer
  @impl true
  def handle_info(:telemetry, state) do
    send_telemetry(state)
    state = schedule_telemetry(state)
    {:noreply, state}
  end

  # Handle APRS-IS connection status
  @impl true
  def handle_info({:aprs_is_status, status}, state) do
    Logger.info("APRS-IS connection status: #{status}")
    {:noreply, state}
  end

  # Handle TNC status
  @impl true
  def handle_info({:tnc_status, interface_id, status}, state) do
    Logger.info("TNC #{interface_id} status: #{status}")
    {:noreply, state}
  end

  defp load_config(opts) do
    %{
      # :igate, :digi, :igate_digi
      mode: Keyword.get(opts, :mode, :igate),
      callsign: Keyword.get(opts, :callsign, "N0CALL"),
      ssid: Keyword.get(opts, :ssid, 10),
      location: Keyword.get(opts, :location, %{lat: 0.0, lon: 0.0}),

      # TNC interfaces configuration
      interfaces: Keyword.get(opts, :interfaces, []),

      # APRS-IS configuration
      aprs_is: %{
        enabled: Keyword.get(opts, :aprs_is_enabled, true),
        server: Keyword.get(opts, :aprs_is_server, "rotate.aprs2.net"),
        port: Keyword.get(opts, :aprs_is_port, 14_580),
        passcode: Keyword.get(opts, :aprs_is_passcode, -1),
        filter: Keyword.get(opts, :aprs_is_filter, "")
      },

      # Beacon configuration
      beacon: %{
        enabled: Keyword.get(opts, :beacon_enabled, true),
        # 30 minutes
        interval: Keyword.get(opts, :beacon_interval, 1_800_000),
        comment: Keyword.get(opts, :beacon_comment, "Aprx on Elixir/Nerves"),
        # iGate symbol
        symbol: Keyword.get(opts, :beacon_symbol, "I&")
      },

      # Telemetry configuration
      telemetry: %{
        enabled: Keyword.get(opts, :telemetry_enabled, true),
        # 10 minutes
        interval: Keyword.get(opts, :telemetry_interval, 600_000)
      },

      # Gating configuration
      gating: %{
        rf_to_is: Keyword.get(opts, :gate_rf_to_is, true),
        is_to_rf: Keyword.get(opts, :gate_is_to_rf, true),
        message_only: Keyword.get(opts, :message_only, false),
        max_hops: Keyword.get(opts, :max_hops, 2)
      },

      # Digipeater configuration
      digi: %{
        enabled: Keyword.get(opts, :digi_enabled, true),
        aliases: Keyword.get(opts, :digi_aliases, ["WIDE1-1", "WIDE2-1"]),
        max_hops: Keyword.get(opts, :digi_max_hops, 2),
        viscous_delay: Keyword.get(opts, :viscous_delay, 0)
      }
    }
  end

  defp init_stats do
    %{
      rf_received: 0,
      rf_transmitted: 0,
      is_received: 0,
      is_transmitted: 0,
      digipeated: 0,
      gated_to_rf: 0,
      gated_to_is: 0,
      start_time: DateTime.utc_now()
    }
  end

  defp init_tnc_interfaces(state) do
    interfaces =
      state.config.interfaces
      |> Enum.map(fn interface_config ->
        case start_tnc_interface(interface_config) do
          {:ok, pid} ->
            {interface_config.id, pid}

          {:error, reason} ->
            Logger.error("Failed to start TNC interface #{interface_config.id}: #{reason}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    %{state | tnc_interfaces: interfaces}
  end

  defp start_tnc_interface(config) do
    # Start appropriate TNC interface based on type
    case config.type do
      :kiss_serial ->
        Aprstx.KissTnc.start_link(
          type: :serial,
          device: config.device,
          speed: config[:speed] || 9600,
          name: {:via, Registry, {Aprstx.TncRegistry, config.id}}
        )

      :kiss_tcp ->
        Aprstx.KissTnc.start_link(
          type: :tcp,
          host: config.host,
          port: config.port,
          name: {:via, Registry, {Aprstx.TncRegistry, config.id}}
        )

      _ ->
        {:error, :unsupported_interface_type}
    end
  end

  defp connect_aprs_is(state) do
    case Aprstx.AprsIsClient.start_link(
           server: state.config.aprs_is.server,
           port: state.config.aprs_is.port,
           callsign: "#{state.config.callsign}-#{state.config.ssid}",
           passcode: state.config.aprs_is.passcode,
           filter: state.config.aprs_is.filter
         ) do
      {:ok, client} ->
        %{state | aprs_is_client: client}

      {:error, reason} ->
        Logger.error("Failed to connect to APRS-IS: #{reason}")
        state
    end
  end

  defp should_gate_to_is?(packet, state) do
    state.config.gating.rf_to_is and
      state.aprs_is_client != nil and
      not is_third_party?(packet) and
      has_valid_path?(packet) and
      not from_internet?(packet)
  end

  defp should_gate_to_rf?(packet, state) do
    state.config.gating.is_to_rf and
      length(state.tnc_interfaces) > 0 and
      (not state.config.gating.message_only or is_message?(packet)) and
      is_local?(packet, state)
  end

  defp should_digipeat?(packet, state) do
    state.config.digi.enabled and
      state.mode in [:digi, :igate_digi] and
      needs_digipeat?(packet, state)
  end

  defp gate_to_aprs_is(packet, _interface_id, state) do
    # Add qAR construct
    gated_packet = add_qar_construct(packet, state.config.callsign)

    # Send to APRS-IS
    if state.aprs_is_client do
      Aprstx.AprsIsClient.send_packet(state.aprs_is_client, gated_packet)
    end

    update_stats(state, :gated_to_is)
  end

  defp gate_to_rf(packet, state) do
    # Remove q-constructs and prepare for RF
    rf_packet = prepare_for_rf(packet)

    # Send to all TNC interfaces
    Enum.each(state.tnc_interfaces, fn {_id, tnc} ->
      Aprstx.KissTnc.send_packet(tnc, rf_packet)
    end)

    update_stats(state, :gated_to_rf)
  end

  defp digipeat_packet(packet, source_interface, state) do
    # Process digipeat path
    digipeated = process_digipeat_path(packet, state)

    # Send to all interfaces except source
    state.tnc_interfaces
    |> Enum.reject(fn {id, _} -> id == source_interface end)
    |> Enum.each(fn {_id, tnc} ->
      Aprstx.KissTnc.send_packet(tnc, digipeated)
    end)

    update_stats(state, :digipeated)
  end

  defp send_beacon(state) do
    beacon = create_beacon_packet(state)

    # Send to RF
    Enum.each(state.tnc_interfaces, fn {_id, tnc} ->
      Aprstx.KissTnc.send_packet(tnc, beacon)
    end)

    # Send to APRS-IS if connected
    if state.aprs_is_client do
      Aprstx.AprsIsClient.send_packet(state.aprs_is_client, beacon)
    end

    Logger.debug("Sent beacon")
  end

  defp send_telemetry(state) do
    telemetry = create_telemetry_packet(state)

    # Send to APRS-IS if connected
    if state.aprs_is_client do
      Aprstx.AprsIsClient.send_packet(state.aprs_is_client, telemetry)
    end

    Logger.debug("Sent telemetry")
  end

  defp schedule_beacon(state) do
    if state.beacon_timer, do: Process.cancel_timer(state.beacon_timer)
    timer = Process.send_after(self(), :beacon, state.config.beacon.interval)
    %{state | beacon_timer: timer}
  end

  defp schedule_telemetry(state) do
    if state.telemetry_timer, do: Process.cancel_timer(state.telemetry_timer)
    timer = Process.send_after(self(), :telemetry, state.config.telemetry.interval)
    %{state | telemetry_timer: timer}
  end

  defp update_stats(state, stat) do
    new_stats = Map.update!(state.stats, stat, &(&1 + 1))
    %{state | stats: new_stats}
  end

  defp update_last_heard(state, callsign) do
    last_heard = Map.put(state.last_heard, callsign, DateTime.utc_now())
    %{state | last_heard: last_heard}
  end

  defp is_third_party?(packet) do
    String.starts_with?(packet.data, "}")
  end

  defp has_valid_path?(packet) do
    # Check if packet has a valid path for gating
    packet.path != nil and length(packet.path) <= 8
  end

  defp from_internet?(packet) do
    # Check if packet came from internet (has q-construct)
    Enum.any?(packet.path || [], &String.starts_with?(&1, "q"))
  end

  defp is_message?(packet) do
    String.starts_with?(packet.data, ":")
  end

  defp is_local?(_packet, _state) do
    # Check if packet is for local area (implement range check)
    # This is a simplified version
    true
  end

  defp needs_digipeat?(packet, state) do
    # Check if packet needs digipeating based on path
    Aprstx.Digipeater.should_digipeat?(packet, state.config.digi)
  end

  defp add_qar_construct(packet, gateway_call) do
    # Add qAR construct for RF->IS gating
    %{packet | path: packet.path ++ ["qAR", gateway_call]}
  end

  defp prepare_for_rf(packet) do
    # Remove q-constructs and TCPIP from path
    cleaned_path =
      packet.path
      |> Enum.reject(&String.starts_with?(&1, "q"))
      |> Enum.reject(&(&1 == "TCPIP*"))

    %{packet | path: cleaned_path}
  end

  defp process_digipeat_path(packet, state) do
    Aprstx.Digipeater.process_packet(packet, state.config.digi)
  end

  defp create_beacon_packet(state) do
    %Aprstx.Packet{
      source: "#{state.config.callsign}-#{state.config.ssid}",
      destination: "APRS",
      path: ["WIDE2-1"],
      data: create_position_beacon(state),
      timestamp: DateTime.utc_now()
    }
  end

  defp create_position_beacon(state) do
    lat = format_latitude(state.config.location.lat)
    lon = format_longitude(state.config.location.lon)
    symbol = state.config.beacon.symbol
    comment = state.config.beacon.comment

    "=#{lat}#{symbol}#{lon}#{comment}"
  end

  defp create_telemetry_packet(state) do
    %Aprstx.Packet{
      source: "#{state.config.callsign}-#{state.config.ssid}",
      destination: "APRS",
      path: ["TCPIP*"],
      data: create_telemetry_data(state),
      timestamp: DateTime.utc_now()
    }
  end

  defp create_telemetry_data(state) do
    # Format telemetry data
    ">#{DateTime.to_iso8601(DateTime.utc_now())},rxpkts:#{state.stats.rf_received},txpkts:#{state.stats.rf_transmitted}"
  end

  defp format_latitude(lat) do
    hemisphere = if lat >= 0, do: "N", else: "S"
    lat = abs(lat)
    degrees = trunc(lat)
    minutes = (lat - degrees) * 60

    "~2..0B~05.2f~s"
    |> :io_lib.format([degrees, minutes, hemisphere])
    |> IO.iodata_to_binary()
  end

  defp format_longitude(lon) do
    hemisphere = if lon >= 0, do: "E", else: "W"
    lon = abs(lon)
    degrees = trunc(lon)
    minutes = (lon - degrees) * 60

    "~3..0B~05.2f~s"
    |> :io_lib.format([degrees, minutes, hemisphere])
    |> IO.iodata_to_binary()
  end

  # Public API

  @doc """
  Get current statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc """
  Get last heard stations.
  """
  def get_last_heard do
    GenServer.call(__MODULE__, :get_last_heard)
  end

  @doc """
  Send a manual packet.
  """
  def send_packet(packet) do
    GenServer.cast(__MODULE__, {:send_packet, packet})
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_call(:get_last_heard, _from, state) do
    {:reply, state.last_heard, state}
  end

  @impl true
  def handle_cast({:send_packet, packet}, state) do
    # Send packet to RF
    Enum.each(state.tnc_interfaces, fn {_id, tnc} ->
      Aprstx.KissTnc.send_packet(tnc, packet)
    end)

    {:noreply, update_stats(state, :rf_transmitted)}
  end
end
