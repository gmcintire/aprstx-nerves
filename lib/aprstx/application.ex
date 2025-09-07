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
        # Children for all targets
        {Aprstx.Stats, []},
        {Aprstx.Server, config[:server] || []},
        {Plug.Cowboy, scheme: :http, plug: Aprstx.HttpApi, options: [port: 8080]}
      ] ++ uplink_children(config) ++ target_children()

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

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end
  else
    defp target_children() do
      [
        # Children for all targets except host
        # Starts a worker by calling: Target.Worker.start_link(arg)
        # {Target.Worker, arg},
      ]
    end
  end
end
