import Config

# Database configuration for host development
config :aprstx, Aprstx.Repo,
  database: "priv/repo/aprstx_dev.db",
  pool_size: 5,
  show_sensitive_data_on_connection_error: true

# Phoenix endpoint for development
config :aprstx, AprstxWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  secret_key_base: "HEcwc7F+BtJsMofE2CqLsJZfHQoMx6B5ivlG0E1L7BPuQzpfVVHXkxkbKNBPqPM+",
  render_errors: [view: AprstxWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: Aprstx.PubSub,
  live_view: [signing_salt: "xI3vV5RL"],
  server: true,
  debug_errors: true,
  code_reloader: true,
  check_origin: false

config :aprstx, ecto_repos: [Aprstx.Repo]

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://hexdocs.pm/nerves_runtime/readme.html#using-nerves_runtime-in-tests
       # https://hexdocs.pm/nerves_runtime/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}

# Add configuration that is only needed when running on the host here.

# Phoenix configuration for host development
config :phoenix, :json_library, Jason
