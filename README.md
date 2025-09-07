# APRSTX - APRS Server for Elixir/Nerves

An APRS-IS (Automatic Packet Reporting System - Internet Service) server implementation in Elixir, designed to run on Nerves-powered embedded devices or standard Elixir applications.

## Features

- **APRS-IS Server**: Full APRS-IS server implementation on port 14580
- **Packet Parsing**: Complete APRS packet parsing and encoding
- **Client Management**: Handle multiple simultaneous client connections
- **Packet Filtering**: Support for standard APRS-IS filter strings
- **APRS-IS Uplink**: Connect to upstream APRS-IS servers
- **Statistics**: Real-time statistics tracking and reporting
- **HTTP API**: REST API for monitoring and control on port 8080
- **Nerves Support**: Run on Raspberry Pi and other embedded platforms

## Architecture

The server consists of several GenServer modules:

- `Aprstx.Server` - Main TCP server handling client connections
- `Aprstx.Packet` - APRS packet parsing and encoding
- `Aprstx.Filter` - Packet filtering implementation  
- `Aprstx.Uplink` - APRS-IS upstream connectivity
- `Aprstx.Stats` - Statistics collection and reporting
- `Aprstx.HttpApi` - HTTP API for monitoring

## Configuration

Edit `config/config.exs` to configure the server:

```elixir
# Server configuration
config :aprstx,
  server: [
    port: 14580,
    max_clients: 1000
  ]

# Optional APRS-IS uplink
config :aprstx,
  uplink: [
    host: "rotate.aprs2.net",
    port: 14580,
    callsign: "N0CALL",
    passcode: "12345",
    filter: "r/40.0/-105.0/100"
  ]
```

## Filter Syntax

The server supports standard APRS-IS filter syntax:

- `r/lat/lon/dist` - Range filter (km)
- `p/prefix` - Callsign prefix filter
- `b/callsign` - Budlist filter
- `t/types` - Packet type filter
- `o/object` - Object name filter
- `s/symbol` - Symbol filter

Example: `r/40.0/-105.0/100 p/K t/pm`

## HTTP API Endpoints

- `GET /status` - Server status and statistics
- `GET /clients` - List connected clients
- `GET /health` - Health check endpoint

## Building for Nerves

To build and deploy on a Nerves device (e.g., Raspberry Pi):

```bash
# Set target
export MIX_TARGET=rpi4

# Get dependencies
mix deps.get

# Build firmware
mix firmware

# Burn to SD card
mix burn

# Or upload to running device
mix upload 192.168.1.10
```

## Running Locally

For development and testing on your host machine:

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Start the server
iex -S mix
```

## Client Connection

Clients connect using standard APRS-IS protocol:

```
telnet localhost 14580
user N0CALL pass 12345 vers test 1.0 filter r/40/-105/100
```

## Targets

Nerves applications produce images for hardware targets based on the
`MIX_TARGET` environment variable. If `MIX_TARGET` is unset, `mix` builds an
image that runs on the host (e.g., your laptop). This is useful for executing
logic tests, running utilities, and debugging. Other targets are represented by
a short name like `rpi3` that maps to a Nerves system image for that platform.
All of this logic is in the generated `mix.exs` and may be customized. For more
information about targets see:

https://hexdocs.pm/nerves/supported-targets.html

## Getting Started

To start your Nerves app:
  * `export MIX_TARGET=my_target` or prefix every command with
    `MIX_TARGET=my_target`. For example, `MIX_TARGET=rpi3`
  * Install dependencies with `mix deps.get`
  * Create firmware with `mix firmware`
  * Burn to an SD card with `mix burn`

## Learn more

  * Official docs: https://hexdocs.pm/nerves/getting-started.html
  * Official website: https://nerves-project.org/
  * Forum: https://elixirforum.com/c/nerves-forum
  * Elixir Slack #nerves channel: https://elixir-slack.community/
  * Elixir Discord #nerves channel: https://discord.gg/elixir
  * Source: https://github.com/nerves-project/nerves
