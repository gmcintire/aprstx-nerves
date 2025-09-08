import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.
# Load local SSH keys
local_keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()

# Load GitHub keys for gmcintire
github_keys_file = Path.join(__DIR__, "authorized_keys")

github_keys =
  if File.exists?(github_keys_file) do
    [github_keys_file]
  else
    []
  end

# Combine all keys
keys = local_keys ++ github_keys

# Configure Ecto to use SQLite in the persistent /data partition
# The /data partition in Nerves persists across firmware updates
config :aprstx, Aprstx.Repo,
  database: "/data/aprstx.db",
  pool_size: 5,
  show_sensitive_data_on_connection_error: true

config :aprstx, ecto_repos: [Aprstx.Repo]

config :logger, backends: [RingLogger]

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

config :nerves, :erlinit, update_clock: true

# Advance the system clock on devices without real-time clocks.

# Use Jason for JSON parsing in Phoenix
# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://hexdocs.pm/nerves_ssh/readme.html for general SSH configuration
# * See https://hexdocs.pm/ssh_subsystem_fwup/readme.html for firmware updates

config :phoenix, :json_library, Jason

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

if keys == [] and !File.exists?(github_keys_file),
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh or config/authorized_keys. 
    An ssh authorized key is needed to log into the Nerves device 
    and update firmware on it using ssh.
    """)

# Read all SSH keys
all_ssh_keys =
  Enum.flat_map(keys, fn key_file ->
    content = File.read!(key_file)
    # Split the file content into individual keys (one per line)
    content
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, ["ssh-"]))
  end)

# Phoenix configuration for web interface on port 80
config :aprstx, AprstxWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: 80],
  secret_key_base: "HEcwc7F+BtJsMofE2CqLsJZfHQoMx6B5ivlG0E1L7BPuQzpfVVHXkxkbKNBPqPM+",
  render_errors: [view: AprstxWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: Aprstx.PubSub,
  live_view: [signing_salt: "xI3vV5RL"],
  server: true,
  check_origin: false

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "nerves"],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "epmd",
      transport: "tcp",
      port: 4369
    }
  ]

config :nerves_ssh,
  authorized_keys: all_ssh_keys

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    # Import target specific config. This must remain at the bottom
    # of this file so it overrides the configuration defined above.
    # import_config "#{Mix.target()}.exs"

    # Uncomment to use target specific configurations
    {"wlan0", %{type: VintageNetWiFi}}
  ]
