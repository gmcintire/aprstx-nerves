defmodule Aprstx.RoamingIgate do
  @moduledoc """
  Roaming iGate controller that coordinates GPS, digipeater, beacon, and iGate functions.
  Provides unified control for mobile APRS operations.
  """
  use GenServer

  require Logger

  defstruct [
    :mode,
    :callsign,
    :config,
    :services,
    :status,
    :stats
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    callsign = Keyword.get(opts, :callsign, "NOCALL")

    state = %__MODULE__{
      # :auto, :igate_only, :digi_only, :both, :tracker_only
      mode: Keyword.get(opts, :mode, :auto),
      callsign: callsign,
      config: init_config(opts),
      services: %{
        gps: nil,
        kiss: nil,
        digipeater: nil,
        beacon: nil,
        igate: nil
      },
      status: %{
        gps_fix: false,
        internet_connected: false,
        rf_connected: false,
        operating_mode: :initializing
      },
      stats: %{
        start_time: DateTime.utc_now(),
        packets_igated_rf_to_is: 0,
        packets_igated_is_to_rf: 0,
        packets_digipeated: 0,
        beacons_sent: 0
      }
    }

    # Start services based on configuration
    {:ok, state, {:continue, :start_services}}
  end

  defp init_config(opts) do
    %{
      # GPS Configuration
      gps: %{
        device: Keyword.get(opts, :gps_device, "/dev/ttyUSB0"),
        baud_rate: Keyword.get(opts, :gps_baud, 9600),
        enabled: Keyword.get(opts, :gps_enabled, true)
      },

      # KISS TNC Configuration
      kiss: %{
        type: Keyword.get(opts, :kiss_type, :serial),
        device: Keyword.get(opts, :kiss_device, "/dev/ttyUSB1"),
        tcp_port: Keyword.get(opts, :kiss_tcp_port, 8001),
        enabled: Keyword.get(opts, :kiss_enabled, true)
      },

      # Digipeater Configuration
      digi: %{
        enabled: Keyword.get(opts, :digi_enabled, true),
        ssid: Keyword.get(opts, :digi_ssid, 7),
        aliases: Keyword.get(opts, :digi_aliases, ["WIDE1-1", "WIDE2"]),
        max_hops: Keyword.get(opts, :digi_max_hops, 2),
        fill_in: Keyword.get(opts, :digi_fill_in, true)
      },

      # Beacon Configuration
      beacon: %{
        enabled: Keyword.get(opts, :beacon_enabled, true),
        ssid: Keyword.get(opts, :beacon_ssid, 9),
        # Digi symbol
        symbol: Keyword.get(opts, :beacon_symbol, "/#"),
        comment: Keyword.get(opts, :beacon_comment, "Roaming iGate/Digi"),
        path: Keyword.get(opts, :beacon_path, ["WIDE1-1", "WIDE2-1"]),
        smart_beaconing: Keyword.get(opts, :smart_beaconing, true)
      },

      # iGate Configuration
      igate: %{
        enabled: Keyword.get(opts, :igate_enabled, true),
        server: Keyword.get(opts, :aprs_server, "rotate.aprs2.net"),
        port: Keyword.get(opts, :aprs_port, 14_580),
        passcode: Keyword.get(opts, :aprs_passcode, "-1"),
        # Will be set dynamically based on GPS
        filter: Keyword.get(opts, :aprs_filter, nil),
        gate_to_rf: Keyword.get(opts, :gate_to_rf, true),
        gate_local_only: Keyword.get(opts, :gate_local_only, true),
        # km
        local_range: Keyword.get(opts, :local_range, 50)
      },

      # Operating modes
      auto_mode: %{
        # Automatically switch modes based on conditions
        require_internet_for_igate: true,
        require_gps_for_beacon: true,
        # If no internet, operate as digi-only
        fallback_to_digi: true
      }
    }
  end

  @impl true
  def handle_continue(:start_services, state) do
    Logger.info("Starting roaming iGate services for #{state.callsign}")

    # Start GPS if enabled
    state =
      if state.config.gps.enabled do
        start_gps_service(state)
      else
        state
      end

    # Start KISS TNC if enabled
    state =
      if state.config.kiss.enabled do
        start_kiss_service(state)
      else
        state
      end

    # Start other services
    state =
      state
      |> start_digipeater_service()
      |> start_beacon_service()
      |> start_igate_service()

    # Schedule status check
    schedule_status_check()

    {:noreply, state}
  end

  defp start_gps_service(state) do
    case Aprstx.GPS.start_link(
           device: state.config.gps.device,
           baud_rate: state.config.gps.baud_rate
         ) do
      {:ok, pid} ->
        Aprstx.GPS.subscribe()
        Logger.info("GPS service started")
        put_in(state.services.gps, pid)

      {:error, reason} ->
        Logger.error("Failed to start GPS: #{inspect(reason)}")
        state
    end
  end

  defp start_kiss_service(state) do
    opts =
      case state.config.kiss.type do
        :serial ->
          [
            type: :serial,
            device: state.config.kiss.device
          ]

        :tcp ->
          [
            type: :tcp,
            port: state.config.kiss.tcp_port
          ]
      end

    case Aprstx.KissTnc.start_link(opts) do
      {:ok, pid} ->
        Logger.info("KISS TNC service started")
        put_in(state.services.kiss, pid)

      {:error, reason} ->
        Logger.error("Failed to start KISS TNC: #{inspect(reason)}")
        state
    end
  end

  defp start_digipeater_service(state) do
    if state.config.digi.enabled do
      opts = [
        callsign: state.callsign,
        ssid: state.config.digi.ssid,
        aliases: state.config.digi.aliases,
        max_hops: state.config.digi.max_hops,
        fill_in: state.config.digi.fill_in,
        kiss_tnc: state.services.kiss,
        enabled: should_enable_digi?(state)
      ]

      case Aprstx.Digipeater.start_link(opts) do
        {:ok, pid} ->
          Logger.info("Digipeater service started")
          put_in(state.services.digipeater, pid)

        {:error, reason} ->
          Logger.error("Failed to start digipeater: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp start_beacon_service(state) do
    if state.config.beacon.enabled do
      opts = [
        callsign: state.callsign,
        ssid: state.config.beacon.ssid,
        symbol: state.config.beacon.symbol,
        comment: state.config.beacon.comment,
        path: state.config.beacon.path,
        smart_beaconing: state.config.beacon.smart_beaconing,
        kiss_tnc: state.services.kiss,
        enabled: should_enable_beacon?(state)
      ]

      case Aprstx.Beacon.start_link(opts) do
        {:ok, pid} ->
          Logger.info("Beacon service started")
          put_in(state.services.beacon, pid)

        {:error, reason} ->
          Logger.error("Failed to start beacon: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp start_igate_service(state) do
    if state.config.igate.enabled do
      # Start APRS-IS uplink
      opts = [
        host: state.config.igate.server,
        port: state.config.igate.port,
        callsign: "#{state.callsign}-#{state.config.beacon.ssid}",
        passcode: state.config.igate.passcode,
        filter: build_dynamic_filter(state)
      ]

      case Aprstx.AprsIsClient.start_link(opts) do
        {:ok, pid} ->
          Logger.info("iGate service started")
          put_in(state.services.igate, pid)

        {:error, reason} ->
          Logger.error("Failed to start iGate: #{inspect(reason)}")
          state
      end
    else
      state
    end
  end

  defp build_dynamic_filter(state) do
    # Build filter based on current GPS position if available
    case Aprstx.GPS.get_position() do
      nil ->
        state.config.igate.filter || ""

      position ->
        range = state.config.igate.local_range
        "r/#{position.latitude}/#{position.longitude}/#{range}"
    end
  end

  defp should_enable_digi?(state) do
    case state.mode do
      :auto ->
        # Enable digi if we have RF connectivity
        state.status.rf_connected

      :digi_only ->
        true

      :both ->
        true

      :igate_only ->
        false

      :tracker_only ->
        false

      _ ->
        false
    end
  end

  defp should_enable_beacon?(state) do
    case state.mode do
      :auto ->
        # Enable beacon if we have GPS fix
        state.status.gps_fix

      # Always beacon in manual modes
      _ ->
        true
    end
  end

  @impl true
  def handle_info({:gps, {:position_update, position}}, state) do
    # Update GPS status
    state = put_in(state.status.gps_fix, true)

    # Update iGate filter if position changed significantly
    state =
      if should_update_filter?(position, state) do
        update_igate_filter(position, state)
      else
        state
      end

    # Update operating mode if in auto
    state = update_operating_mode(state)

    {:noreply, state}
  end

  @impl true
  def handle_info(:check_status, state) do
    # Check internet connectivity
    internet_connected = check_internet_connection()

    # Check RF connectivity (KISS TNC)
    rf_connected = state.services.kiss != nil

    # Update status
    state =
      state
      |> put_in([:status, :internet_connected], internet_connected)
      |> put_in([:status, :rf_connected], rf_connected)

    # Update operating mode
    state = update_operating_mode(state)

    # Log status
    log_status(state)

    # Schedule next check
    schedule_status_check()

    {:noreply, state}
  end

  defp should_update_filter?(_position, state) do
    # Update filter if position changed by more than 10km
    case state.services.igate do
      nil ->
        false

      _ ->
        # This is simplified - would need to track last filter position
        true
    end
  end

  defp update_igate_filter(position, state) do
    if state.services.igate do
      range = state.config.igate.local_range
      filter = "r/#{position.latitude}/#{position.longitude}/#{range}"

      # Update uplink filter
      # This would need to be implemented in Uplink module
      Logger.info("Updated iGate filter: #{filter}")
    end

    state
  end

  defp update_operating_mode(state) do
    if state.mode == :auto do
      new_mode = determine_operating_mode(state)

      if new_mode == state.status.operating_mode do
        state
      else
        Logger.info("Operating mode changed: #{state.status.operating_mode} -> #{new_mode}")
        apply_operating_mode(new_mode, state)
      end
    else
      # Manual mode
      put_in(state.status.operating_mode, state.mode)
    end
  end

  defp determine_operating_mode(state) do
    cond do
      # Full iGate + Digi mode
      state.status.internet_connected and state.status.rf_connected ->
        :both

      # Digi only mode (no internet)
      not state.status.internet_connected and state.status.rf_connected ->
        :digi_only

      # iGate only mode (no RF)
      state.status.internet_connected and not state.status.rf_connected ->
        :igate_only

      # Tracker only mode (GPS but no RF gateway capability)
      state.status.gps_fix and not state.status.rf_connected ->
        :tracker_only

      true ->
        :limited
    end
  end

  defp apply_operating_mode(mode, state) do
    case mode do
      :both ->
        # Enable everything
        Aprstx.Digipeater.set_enabled(true)
        Aprstx.Beacon.set_enabled(true)
        put_in(state.status.operating_mode, :both)

      :digi_only ->
        # Enable digi and beacon, disable iGate functions
        Aprstx.Digipeater.set_enabled(true)
        Aprstx.Beacon.set_enabled(true)
        put_in(state.status.operating_mode, :digi_only)

      :igate_only ->
        # Disable digi, enable iGate
        Aprstx.Digipeater.set_enabled(false)
        Aprstx.Beacon.set_enabled(true)
        put_in(state.status.operating_mode, :igate_only)

      :tracker_only ->
        # Beacon only
        Aprstx.Digipeater.set_enabled(false)
        Aprstx.Beacon.set_enabled(true)
        put_in(state.status.operating_mode, :tracker_only)

      :limited ->
        # Minimal operation
        Aprstx.Digipeater.set_enabled(false)
        Aprstx.Beacon.set_enabled(false)
        put_in(state.status.operating_mode, :limited)
    end
  end

  defp check_internet_connection do
    # Simple connectivity check
    case :httpc.request(:get, {~c"http://www.google.com", []}, [{:timeout, 5000}], []) do
      {:ok, _} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp log_status(state) do
    Logger.info("""
    Roaming iGate Status:
      Mode: #{state.status.operating_mode}
      GPS: #{if state.status.gps_fix, do: "Fixed", else: "No Fix"}
      Internet: #{if state.status.internet_connected, do: "Connected", else: "Disconnected"}
      RF: #{if state.status.rf_connected, do: "Connected", else: "Disconnected"}
    """)
  end

  defp schedule_status_check do
    # Every 30 seconds
    Process.send_after(self(), :check_status, 30_000)
  end

  # Public API

  @doc """
  Get current status.
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      mode: state.mode,
      operating_mode: state.status.operating_mode,
      gps_fix: state.status.gps_fix,
      internet_connected: state.status.internet_connected,
      rf_connected: state.status.rf_connected,
      stats: state.stats,
      services: %{
        gps: state.services.gps != nil,
        kiss: state.services.kiss != nil,
        digipeater: state.services.digipeater != nil,
        beacon: state.services.beacon != nil,
        igate: state.services.igate != nil
      }
    }

    {:reply, status, state}
  end

  @doc """
  Set operating mode.
  """
  def set_mode(mode) do
    GenServer.cast(__MODULE__, {:set_mode, mode})
  end

  @impl true
  def handle_cast({:set_mode, mode}, state) do
    Logger.info("Setting mode to: #{mode}")

    state = update_operating_mode(%{state | mode: mode})

    {:noreply, state}
  end

  @doc """
  Force beacon transmission.
  """
  def beacon_now do
    Aprstx.Beacon.send_now()
  end

  @doc """
  Get GPS position.
  """
  def get_position do
    Aprstx.GPS.get_position()
  end
end
