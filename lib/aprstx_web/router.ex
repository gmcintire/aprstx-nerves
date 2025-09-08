defmodule AprstxWeb.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    # Captive portal redirect
    plug(AprstxWeb.Plugs.CaptivePortal)
    # Normal config check
    plug(AprstxWeb.Plugs.RequireConfig)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :captive_portal do
    plug(:accepts, ["html", "text"])
  end

  # Captive portal detection endpoints (bypass config check)
  scope "/", AprstxWeb do
    pipe_through(:captive_portal)

    # Common captive portal detection URLs
    # iOS
    get("/hotspot-detect.html", CaptivePortalController, :detect)
    # iOS
    get("/library/test/success.html", CaptivePortalController, :detect)
    # Android
    get("/generate_204", CaptivePortalController, :detect)
    # Android
    get("/gen_204", CaptivePortalController, :detect)
    # Windows
    get("/ncsi.txt", CaptivePortalController, :detect)
    # Windows
    get("/connecttest.txt", CaptivePortalController, :detect)
    # Various
    get("/success.txt", CaptivePortalController, :detect)
  end

  scope "/", AprstxWeb do
    pipe_through(:browser)

    get("/", PageController, :index)
    live("/setup", SetupWizardLive)
    live("/dashboard", DashboardLive)
  end

  # API routes
  scope "/api", AprstxWeb do
    pipe_through(:api)

    get("/status", ApiController, :status)
    get("/config", ApiController, :get_config)
    post("/config", ApiController, :update_config)
    post("/reboot", ApiController, :reboot)
  end
end
