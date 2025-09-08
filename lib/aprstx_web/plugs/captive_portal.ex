defmodule AprstxWeb.Plugs.CaptivePortal do
  @moduledoc """
  Plug that implements captive portal behavior.
  When the device is unconfigured, ALL requests get redirected to the setup page.
  This causes devices to automatically open the setup page when connecting to the AP.
  """

  import Phoenix.Controller
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Check if we're in setup mode AND this isn't already the setup page
    if in_setup_mode?() and not is_setup_request?(conn) do
      # Redirect ANY request to the setup page
      # This triggers captive portal detection on most devices
      conn
      |> put_status(302)
      |> put_resp_header("location", build_setup_url(conn))
      |> html(redirect_html())
      |> halt()
    else
      conn
    end
  end

  defp in_setup_mode? do
    not Aprstx.Config.configured?()
  end

  defp is_setup_request?(conn) do
    # Don't redirect if we're already on the setup page or related assets
    String.starts_with?(conn.request_path, "/setup") or
      String.starts_with?(conn.request_path, "/assets") or
      String.starts_with?(conn.request_path, "/live") or
      conn.request_path == "/phoenix"
  end

  defp build_setup_url(conn) do
    # Use the actual host from the request or default to AP IP
    host = conn |> get_req_header("host") |> List.first() || "192.168.4.1"
    "http://#{host}/setup"
  end

  defp redirect_html do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>APRS Station Setup</title>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
          display: flex;
          justify-content: center;
          align-items: center;
          min-height: 100vh;
          margin: 0;
          background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
          color: white;
        }
        .container {
          text-align: center;
          padding: 2rem;
        }
        h1 {
          font-size: 2.5rem;
          margin-bottom: 1rem;
        }
        p {
          font-size: 1.2rem;
          margin-bottom: 2rem;
        }
        .button {
          display: inline-block;
          padding: 1rem 2rem;
          background: white;
          color: #667eea;
          text-decoration: none;
          border-radius: 0.5rem;
          font-weight: bold;
          transition: transform 0.2s;
        }
        .button:hover {
          transform: scale(1.05);
        }
        .spinner {
          border: 3px solid rgba(255,255,255,0.3);
          border-radius: 50%;
          border-top: 3px solid white;
          width: 40px;
          height: 40px;
          animation: spin 1s linear infinite;
          margin: 2rem auto;
        }
        @keyframes spin {
          0% { transform: rotate(0deg); }
          100% { transform: rotate(360deg); }
        }
      </style>
      <script>
        // Auto-redirect after a moment
        setTimeout(function() {
          window.location.href = '/setup';
        }, 1000);
      </script>
    </head>
    <body>
      <div class="container">
        <h1>Welcome to APRS Station</h1>
        <p>Setting up your device...</p>
        <div class="spinner"></div>
        <a href="/setup" class="button">Continue to Setup</a>
      </div>
    </body>
    </html>
    """
  end
end
