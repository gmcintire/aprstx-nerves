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

# APRS Server Configuration
# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :aprstx,
  server_call: "APRSTX",
  server_id: "APRSTX-001",
  server: [
    port: 14_580,
    max_clients: 1000
  ],

  # UDP listener
  udp: [
    port: 8080,
    # or :unidirectional
    mode: :bidirectional
  ],

  # History buffer
  history: [
    max_size: 10_000,
    replay_limit: 100
  ],

  # Access control
  acl: [
    rules: %{
      allow_unverified: true,
      require_valid_callsign: true,
      max_path_length: 8
    }
  ],

  # Logging
  logger: [
    log_dir: "logs",
    # 10MB
    max_file_size: 10_485_760,
    max_files: 10,
    log_packets: true,
    log_access: true
  ],

  # GPS Configuration for roaming iGate/digi
  gps: [
    device: "/dev/ttyUSB0",
    baud_rate: 9600
  ],

  # Digipeater Configuration
  digipeater: [
    enabled: true,
    callsign: "NOCALL",
    ssid: 0,
    aliases: ["WIDE1-1", "WIDE2", "TRACE"],
    max_hops: 7,
    dupe_window: 30,
    fill_in: true,
    new_paradigm: true,
    preemptive: true,
    viscous_delay: 0,
    limit_hops: true,
    direct_only: false
  ],

  # Beacon Configuration
  beacon: [
    enabled: true,
    callsign: "NOCALL",
    ssid: 9,
    symbol: "/#",
    comment: "APRSTX Roaming iGate/Digi",
    path: ["WIDE1-1", "WIDE2-1"],
    interval: 600_000,
    compressed: false,
    altitude: true,
    timestamp: false,
    smart_beaconing: true,
    # Smart beaconing parameters
    sb_low_speed: 5,
    sb_high_speed: 90,
    sb_slow_rate: 1800,
    sb_fast_rate: 60,
    sb_min_turn_angle: 30,
    sb_min_turn_time: 15,
    sb_corner_pegging: true
  ],

  # Roaming iGate Configuration
  roaming_igate: [
    enabled: true,
    mode: :auto,
    internet_check_interval: 30_000,
    uplink_filter: "r/40.0/-105.0/100",
    digi_when_offline: true,
    beacon_when_offline: true,
    igate_when_online: true
  ]

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
config :nerves, source_date_epoch: "1757282540"

# Uncomment to enable APRS-IS uplink
# config :aprstx,
#   uplink: [
#     host: "rotate.aprs2.net",
#     port: 14580,
#     callsign: "N0CALL",
#     passcode: "-1",
#     filter: "r/40.0/-105.0/100"
#   ]

# Uncomment to enable SSL/TLS
# config :aprstx,
#   ssl: [
#     port: 24580,
#     certfile: "priv/cert.pem",
#     keyfile: "priv/key.pem"
#   ]

# Uncomment to enable KISS TNC
# config :aprstx,
#   kiss: [
#     type: :serial,  # or :tcp
#     device: "/dev/ttyUSB0",  # for serial
#     # port: 8001  # for TCP
#   ]

# Uncomment to enable peer connections
# config :aprstx,
#   peers: [
#     port: 10152,
#     auth_key: "secret",
#     peers: [
#       %{
#         id: "peer1",
#         host: "peer1.example.com",
#         port: 10152,
#         auth_key: "secret"
#       }
#     ]
#   ]

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
