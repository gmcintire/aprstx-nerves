defmodule AprstxWeb.PageController do
  use Phoenix.Controller

  def index(conn, _params) do
    html(conn, """
    <!DOCTYPE html>
    <html>
    <head>
      <title>APRSTX - Roaming iGate/Digi</title>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body { 
          font-family: system-ui, sans-serif; 
          max-width: 1200px; 
          margin: 0 auto; 
          padding: 20px;
          background: #f5f5f5;
        }
        h1 { color: #333; }
        .status { 
          background: white; 
          padding: 20px; 
          border-radius: 8px;
          box-shadow: 0 2px 4px rgba(0,0,0,0.1);
          margin: 20px 0;
        }
        .status-item {
          display: flex;
          justify-content: space-between;
          padding: 10px 0;
          border-bottom: 1px solid #eee;
        }
        .status-item:last-child {
          border-bottom: none;
        }
        .online { color: green; font-weight: bold; }
        .offline { color: red; font-weight: bold; }
      </style>
    </head>
    <body>
      <h1>APRSTX Roaming iGate/Digipeater</h1>
      
      <div class="status">
        <h2>System Status</h2>
        <div class="status-item">
          <span>System</span>
          <span class="online">Online</span>
        </div>
        <div class="status-item">
          <span>GPS</span>
          <span>Checking...</span>
        </div>
        <div class="status-item">
          <span>Internet</span>
          <span>Checking...</span>
        </div>
        <div class="status-item">
          <span>Mode</span>
          <span>Initializing...</span>
        </div>
      </div>
      
      <div class="status">
        <h2>Quick Links</h2>
        <ul>
          <li><a href="/dashboard">Live Dashboard</a></li>
          <li><a href="/api/status">API Status (JSON)</a></li>
          <li><a href="/api/config">Configuration API</a></li>
        </ul>
      </div>
      
      <p>Phoenix web interface is running! Database and full configuration UI coming soon.</p>
    </body>
    </html>
    """)
  end
end
