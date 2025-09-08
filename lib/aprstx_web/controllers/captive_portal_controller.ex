defmodule AprstxWeb.CaptivePortalController do
  use AprstxWeb, :controller

  @doc """
  Handle all captive portal detection requests.
  When in setup mode, redirect to our setup page.
  When configured, return appropriate response to indicate no captive portal.
  """
  def detect(conn, _params) do
    if in_setup_mode?() do
      # We're in setup mode - redirect to setup wizard
      # This triggers the captive portal popup on most devices
      conn
      |> put_status(302)
      |> put_resp_header("location", "http://192.168.4.1/setup")
      |> html("""
      <html>
      <head>
        <title>APRS Station Setup</title>
        <meta http-equiv="refresh" content="0; url=http://192.168.4.1/setup">
      </head>
      <body>
        <p>Redirecting to setup page...</p>
        <p><a href="http://192.168.4.1/setup">Click here if not redirected</a></p>
      </body>
      </html>
      """)
    else
      # Not in setup mode - return appropriate response for the request path
      case conn.request_path do
        "/generate_204" -> send_resp(conn, 204, "")
        "/gen_204" -> send_resp(conn, 204, "")
        "/ncsi.txt" -> text(conn, "Microsoft NCSI")
        "/connecttest.txt" -> text(conn, "Microsoft Connect Test")
        "/hotspot-detect.html" -> html(conn, "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>")
        _ -> text(conn, "success")
      end
    end
  end

  defp in_setup_mode? do
    # Check if we're in WiFi setup mode
    not Aprstx.Config.configured?()
  end
end
