defmodule AprstxWeb.ApiController do
  use Phoenix.Controller

  def status(conn, _params) do
    # Get status from various services if they're running
    status = %{
      system: "online",
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      services: %{
        gps: check_service(Aprstx.GPS),
        digipeater: check_service(Aprstx.Digipeater),
        beacon: check_service(Aprstx.Beacon),
        server: check_service(Aprstx.Server)
      },
      stats: %{
        uptime: :wall_clock |> :erlang.statistics() |> elem(0) |> div(1000)
      }
    }

    json(conn, status)
  end

  def get_config(conn, _params) do
    # For now, return current configuration from Application env
    config = %{
      gps: Application.get_env(:aprstx, :gps, %{}),
      digipeater: Application.get_env(:aprstx, :digipeater, %{}),
      beacon: Application.get_env(:aprstx, :beacon, %{}),
      roaming_igate: Application.get_env(:aprstx, :roaming_igate, %{})
    }

    json(conn, config)
  end

  def update_config(conn, _params) do
    # Placeholder for config update - will use database later
    json(conn, %{status: "ok", message: "Configuration update not yet implemented"})
  end

  def reboot(conn, _params) do
    # Schedule reboot in 1 second
    if Mix.target() == :host do
      json(conn, %{status: "error", message: "Cannot reboot in development mode"})
    else
      Task.start(fn ->
        Process.sleep(1000)
        System.cmd("reboot", [])
      end)

      json(conn, %{status: "ok", message: "Rebooting..."})
    end
  end

  defp check_service(module) do
    case Process.whereis(module) do
      nil ->
        "offline"

      pid when is_pid(pid) ->
        if Process.alive?(pid), do: "online", else: "offline"
    end
  end
end
