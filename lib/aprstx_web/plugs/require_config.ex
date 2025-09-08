defmodule AprstxWeb.Plugs.RequireConfig do
  @moduledoc """
  Plug to ensure the system is configured before accessing certain pages.
  Redirects to setup wizard if not configured.
  """

  import Phoenix.Controller
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Skip for setup page and static assets
    if conn.request_path == "/setup" or String.starts_with?(conn.request_path, "/assets") do
      conn
    else
      # Check if configured
      if Aprstx.Config.configured?() do
        conn
      else
        conn
        |> put_flash(:info, "Please complete the initial setup.")
        |> redirect(to: "/setup")
        |> halt()
      end
    end
  end
end
