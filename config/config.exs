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

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1757282540"

# APRS Server Configuration
config :aprstx,
  server: [
    port: 14580,
    max_clients: 1000
  ]

# Uncomment to enable APRS-IS uplink
# config :aprstx,
#   uplink: [
#     host: "rotate.aprs2.net",
#     port: 14580,
#     callsign: "N0CALL",
#     passcode: "-1",
#     filter: "r/40.0/-105.0/100"
#   ]

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
