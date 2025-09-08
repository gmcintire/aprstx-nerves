defmodule Aprstx.Application do
  @moduledoc """
  Main application supervisor for aprx functionality.
  """
  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_all_env(:aprstx)

    # Load configuration from database after Repo starts
    # This will be done via a task after the supervisor starts

    # Main aprx coordinator - starts last
    children =
      [
        # Database (for persistent configuration)
        Aprstx.Repo,

        # Phoenix web interface
        {Phoenix.PubSub, name: Aprstx.PubSub},
        AprstxWeb.Endpoint,

        # Core services
        {Registry, keys: :unique, name: Aprstx.TncRegistry},
        {Aprstx.Logger, config[:logger] || []},
        {Aprstx.Stats, []},
        {Aprstx.DuplicateFilter, []},
        {Aprstx.History, config[:history] || []},
        {Aprstx.ACL, config[:acl] || []},
        {Aprstx.MessageHandler, []},

        # Digipeater with viscous delay
        {Aprstx.Digipeater, config[:digipeater] || []},

        # RF gating logic
        {Aprstx.RfGate, config[:rf_gate] || []},

        # Beaconing
        {Aprstx.Beacon, config[:beacon] || []},

        # UDP listener (for UDP kiss, etc)
        {Aprstx.UdpListener, config[:udp] || []}
      ] ++
        wifi_setup_children() ++
        gps_children(config) ++
        roaming_children(config) ++
        kiss_children(config) ++
        [{Aprstx.Aprx, config[:aprx] || []}] ++
        target_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Aprstx.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Load and apply configuration from database after everything starts
        Task.start(fn ->
          # Give services a moment to initialize
          Process.sleep(1000)

          # Try to load configuration from database
          case Aprstx.Config.load_and_apply() do
            :ok ->
              IO.puts("Configuration loaded from database")

            {:error, :not_configured} ->
              IO.puts("No configuration found - please complete setup wizard")

            {:error, reason} ->
              IO.puts("Failed to load configuration: #{inspect(reason)}")
          end
        end)

        {:ok, pid}

      error ->
        error
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AprstxWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp wifi_setup_children do
    # Only start WiFi setup on target devices with WiFi capability
    if Mix.target() != :host and has_wifi?() do
      [{Aprstx.WifiSetup, []}]
    else
      []
    end
  end

  defp has_wifi? do
    # Check if the target has WiFi capability
    # Pi 3 has built-in WiFi, Pi Zero W has WiFi, etc.
    Mix.target() in [:rpi3, :rpi3a, :rpi4, :rpi0_w, :rpi5]
  end

  defp gps_children(config) do
    case config[:gps] do
      nil ->
        []

      gps_config when is_list(gps_config) ->
        if Keyword.get(gps_config, :enabled, false) do
          [{Aprstx.GPS, gps_config}]
        else
          []
        end
    end
  end

  defp roaming_children(config) do
    case config[:roaming_igate] do
      nil ->
        []

      roaming_config when is_list(roaming_config) ->
        if Keyword.get(roaming_config, :enabled, false) do
          [{Aprstx.RoamingIgate, roaming_config}]
        else
          []
        end
    end
  end

  defp kiss_children(config) do
    case config[:kiss] do
      nil ->
        []

      kiss_config when is_list(kiss_config) ->
        if Keyword.get(kiss_config, :enabled, false) do
          [{Aprstx.KissTnc, kiss_config}]
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
      ]
    end
  else
    defp target_children do
      [
        # Children for all targets except host
        # For Nerves targets
      ]
    end
  end
end
