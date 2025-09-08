defmodule Aprstx.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_all_env(:aprstx)

    children =
      [
        # Core services
        {Aprstx.Logger, config[:logger] || []},
        {Aprstx.Stats, []},
        {Aprstx.DuplicateFilter, []},
        {Aprstx.History, config[:history] || []},
        {Aprstx.ACL, config[:acl] || []},
        {Aprstx.MessageHandler, []},

        # Network servers
        {Aprstx.Server, config[:server] || []},
        {Aprstx.UdpListener, config[:udp] || []},

        # HTTP services
        {Plug.Cowboy, scheme: :http, plug: Aprstx.HttpApi, options: [port: 8080]},
        {Plug.Cowboy, scheme: :http, plug: Aprstx.StatusPage, options: [port: 8081]}
      ] ++
        uplink_children(config) ++
        ssl_children(config) ++
        kiss_children(config) ++
        peer_children(config) ++
        roaming_children(config) ++
        target_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Aprstx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp uplink_children(config) do
    case config[:uplink] do
      nil -> []
      uplink_config -> [{Aprstx.Uplink, uplink_config}]
    end
  end

  defp ssl_children(config) do
    case config[:ssl] do
      nil -> []
      ssl_config -> [{Aprstx.SslServer, ssl_config}]
    end
  end

  defp kiss_children(config) do
    case config[:kiss] do
      nil -> []
      kiss_config -> [{Aprstx.KissTnc, kiss_config}]
    end
  end

  defp peer_children(config) do
    case config[:peers] do
      nil -> []
      peer_config -> [{Aprstx.Peer, peer_config}]
    end
  end

  defp roaming_children(config) do
    # Start roaming iGate components if configured
    case config[:roaming_igate] do
      nil ->
        []

      roaming_config ->
        if roaming_config[:enabled] == true do
          # GPS, Digipeater, Beacon are managed by RoamingIgate
          # so we start the coordinator
          [
            {Aprstx.GPS, config[:gps] || []},
            {Aprstx.Digipeater, config[:digipeater] || []},
            {Aprstx.Beacon, config[:beacon] || []},
            {Aprstx.RoamingIgate, roaming_config}
          ]
        else
          []
        end
    end
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end
  else
    defp target_children do
      [
        # Children for all targets except host
        # Starts a worker by calling: Target.Worker.start_link(arg)
        # {Target.Worker, arg},
      ]
    end
  end
end
