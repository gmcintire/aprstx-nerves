defmodule AprstxWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", AprstxWeb do
    pipe_through(:browser)

    get("/", PageController, :index)
    live("/dashboard", DashboardLive)
  end

  # API routes
  scope "/api", AprstxWeb do
    pipe_through(:api)

    get("/status", ApiController, :status)
    get("/config", ApiController, :get_config)
    post("/config", ApiController, :update_config)
  end
end
