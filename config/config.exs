# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

# Database configuration
config :aprstx, Aprstx.Repo,
  database: "/data/aprstx.db",
  pool_size: 5,
  log: false

# Phoenix configuration
config :aprstx, AprstxWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "HEcwc7F+BtJsMofE2CqLsJZfHQoMx6B5ivlG0E1L7BPuQzpfVVHXkxkbKNBPqPM+",
  render_errors: [view: AprstxWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: Aprstx.PubSub,
  live_view: [signing_salt: "xI3vV5RL"]

# Aprx configuration (APRS iGate/Digipeater)
config :aprstx,
  # Station identification
  callsign: System.get_env("APRX_CALLSIGN", "N0CALL"),

  # Main aprx configuration
  aprx: [
    # :igate, :digi, :igate_digi, :tracker
    mode: :igate_digi,
    callsign: System.get_env("APRX_CALLSIGN", "N0CALL"),
    ssid: String.to_integer(System.get_env("APRX_SSID", "10")),
    location: %{
      lat: String.to_float(System.get_env("APRX_LAT", "0.0")),
      lon: String.to_float(System.get_env("APRX_LON", "0.0"))
    },

    # TNC interfaces (configure based on your hardware)
    interfaces: [
      # Example KISS serial interface
      # %{
      #   id: :tnc1,
      #   type: :kiss_serial,
      #   device: "/dev/ttyUSB0",
      #   speed: 9600
      # },
      # Example KISS TCP interface (for direwolf, etc)
      # %{
      #   id: :tnc2,
      #   type: :kiss_tcp,
      #   host: "localhost",
      #   port: 8001
      # }
    ],

    # APRS-IS connection
    aprs_is_enabled: true,
    aprs_is_server: System.get_env("APRX_IS_SERVER", "rotate.aprs2.net"),
    aprs_is_port: 14_580,
    aprs_is_passcode: String.to_integer(System.get_env("APRX_PASSCODE", "-1")),
    aprs_is_filter: System.get_env("APRX_FILTER", ""),

    # Beaconing
    beacon_enabled: true,
    # 30 minutes
    beacon_interval: 30 * 60 * 1000,
    beacon_comment: "Aprx on Elixir/Nerves",
    # iGate symbol
    beacon_symbol: "I&",

    # Telemetry
    telemetry_enabled: true,
    # 10 minutes
    telemetry_interval: 10 * 60 * 1000,

    # Gating
    gate_rf_to_is: true,
    gate_is_to_rf: true,
    message_only: false,
    max_hops: 2
  ],

  # Digipeater configuration
  digipeater: [
    enabled: true,
    callsign: System.get_env("APRX_CALLSIGN", "N0CALL"),
    ssid: 0,
    # 5 seconds - aprx-style viscous delay
    viscous_delay: 5000,
    max_hops: 2,
    # 30 seconds
    duplicate_timeout: 30_000,
    # 15 seconds
    flooding_timeout: 15_000,
    max_flood_rate: 5,
    aliases: ["WIDE1-1", "WIDE2-1", "WIDE2-2"],
    wide_mode: true,
    trace_mode: true,
    blacklist: [],
    whitelist: [],
    filter_wx: false,
    filter_telemetry: false,
    aprsis_digipeat: false
  ],

  # RF gating configuration
  rf_gate: [
    rf_to_is: true,
    is_to_rf: true,
    # :all, :heard, :message_only
    is_to_rf_type: :heard,
    gate_local_only: false,
    # km
    local_range: 50,
    # packets per minute to RF
    max_rf_rate: 30,
    rate_limit_window: 60_000,
    max_hops_to_rf: 2,
    gate_messages: true,
    gate_positions: true,
    gate_weather: true,
    gate_telemetry: false,
    gate_objects: true,
    position: %{
      lat: String.to_float(System.get_env("APRX_LAT", "0.0")),
      lon: String.to_float(System.get_env("APRX_LON", "0.0"))
    }
  ],

  # Beacon configuration
  beacon: [
    enabled: true,
    # 30 minutes
    interval: 30 * 60 * 1000,
    callsign: System.get_env("APRX_CALLSIGN", "N0CALL"),
    ssid: 10,
    comment: "Aprx Elixir/Nerves iGate",
    symbol: "I&",
    path: ["WIDE2-1"],
    smart_beaconing: false,
    # Smart beaconing parameters (when enabled)
    sb_low_speed: 5,
    sb_high_speed: 90,
    sb_slow_rate: 1800,
    sb_fast_rate: 60,
    sb_min_turn_angle: 30,
    sb_min_turn_time: 15,
    sb_corner_pegging: true
  ],

  # GPS configuration (for mobile/roaming)
  gps: [
    enabled: false,
    device: "/dev/ttyUSB0",
    speed: 9600
  ],

  # Roaming iGate configuration
  roaming_igate: [
    enabled: false,
    # :auto, :igate, :digi, :tracker
    mode: :auto,
    # km/h - switch to tracker mode above this
    speed_threshold: 5,
    # Check internet every 30 seconds
    internet_check_interval: 30_000,
    digi_when_offline: true,
    beacon_when_offline: true,
    igate_when_online: true
  ],

  # KISS TNC configuration (legacy - interfaces are configured in aprx section)
  kiss: [
    enabled: false,
    # :serial or :tcp
    type: :serial,
    # For serial
    device: "/dev/ttyUSB0",
    speed: 9600
  ],

  # Logging configuration
  logger: [
    enabled: true,
    log_dir: "/data/logs",
    access_log: true,
    packet_log: true,
    error_log: true,
    # 10 MB
    rotate_size: 10_485_760,
    rotate_count: 5
  ],

  # History configuration
  history: [
    max_size: 10_000,
    replay_limit: 100
  ],

  # ACL configuration
  acl: [
    enabled: true,
    flood_protection: true,
    # per minute
    max_packet_rate: 100,
    # per minute
    max_byte_rate: 10_000,
    # 5 minutes
    ban_duration: 300_000
  ],

  # UDP listener (for UDP KISS, etc)
  udp: [
    enabled: false,
    port: 8093,
    # :kiss or :aprs
    mode: :kiss
  ]

config :aprstx, ecto_repos: [Aprstx.Repo]

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information
config :nerves, source_date_epoch: "1757282540"

config :phoenix, :json_library, Jason

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
