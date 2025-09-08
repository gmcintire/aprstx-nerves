defmodule AprstxWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :aprstx

  # Serve at "/" the static files from "priv/static" directory.
  plug(Plug.Static,
    at: "/",
    from: :aprstx,
    gzip: false,
    only: ~w(assets fonts images favicon.ico robots.txt)
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  # Disabled for now as we don't have LiveReloader dependency
  # if code_reloading? do
  #   socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
  #   plug Phoenix.LiveReloader
  #   plug Phoenix.CodeReloader
  # end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)

  plug(Plug.Session,
    store: :cookie,
    key: "_aprstx_key",
    signing_salt: "xI3vV5RL"
  )

  plug(AprstxWeb.Router)
end
