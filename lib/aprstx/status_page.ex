defmodule Aprstx.StatusPage do
  @moduledoc """
  HTML status page and extended statistics for APRS server.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    html = generate_status_page()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  get "/json" do
    stats = gather_all_stats()

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(stats))
  end

  get "/metrics" do
    # Prometheus-style metrics
    metrics = generate_metrics()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp generate_status_page do
    stats = gather_all_stats()
    uptime = format_uptime(stats.server.uptime_seconds)

    """
    <!DOCTYPE html>
    <html>
    <head>
      <title>APRSTX Status</title>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body { font-family: Arial, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; }
        .card { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; }
        h2 { color: #666; border-bottom: 2px solid #eee; padding-bottom: 10px; }
        .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; }
        .stat-item { background: #f9f9f9; padding: 15px; border-radius: 5px; }
        .stat-value { font-size: 24px; font-weight: bold; color: #2196F3; }
        .stat-label { color: #666; margin-top: 5px; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 10px; text-align: left; border-bottom: 1px solid #eee; }
        th { background: #f5f5f5; font-weight: bold; }
        .status-ok { color: #4CAF50; }
        .status-warning { color: #FF9800; }
        .status-error { color: #F44336; }
        .refresh { float: right; color: #666; font-size: 14px; }
      </style>
      <script>
        setTimeout(function() { location.reload(); }, 30000);
      </script>
    </head>
    <body>
      <div class="container">
        <div class="card">
          <span class="refresh">Auto-refresh in 30s</span>
          <h1>APRSTX Server Status</h1>
          <p>Version: 1.0.0 | Uptime: #{uptime}</p>
        </div>
        
        <div class="card">
          <h2>Server Statistics</h2>
          <div class="stats-grid">
            <div class="stat-item">
              <div class="stat-value">#{stats.server.packets.received}</div>
              <div class="stat-label">Packets Received</div>
            </div>
            <div class="stat-item">
              <div class="stat-value">#{stats.server.packets.sent}</div>
              <div class="stat-label">Packets Sent</div>
            </div>
            <div class="stat-item">
              <div class="stat-value">#{stats.server.clients.current}</div>
              <div class="stat-label">Connected Clients</div>
            </div>
            <div class="stat-item">
              <div class="stat-value">#{stats.server.clients.total}</div>
              <div class="stat-label">Total Clients</div>
            </div>
            <div class="stat-item">
              <div class="stat-value">#{format_rate(stats.server.packets.rate_rx)}/s</div>
              <div class="stat-label">RX Rate</div>
            </div>
            <div class="stat-item">
              <div class="stat-value">#{format_rate(stats.server.packets.rate_tx)}/s</div>
              <div class="stat-label">TX Rate</div>
            </div>
          </div>
        </div>
        
        <div class="card">
          <h2>Connected Clients</h2>
          #{generate_clients_table(stats.clients)}
        </div>
        
        <div class="card">
          <h2>Packet Types</h2>
          #{generate_packet_types_table(stats.server.packet_types)}
        </div>
        
        <div class="card">
          <h2>System Health</h2>
          <div class="stats-grid">
            <div class="stat-item">
              <div class="stat-value">#{stats.duplicate_filter.duplicates_filtered}</div>
              <div class="stat-label">Duplicates Filtered</div>
            </div>
            <div class="stat-item">
              <div class="stat-value">#{stats.history.current_size}</div>
              <div class="stat-label">History Buffer</div>
            </div>
            <div class="stat-item">
              <div class="stat-value">#{stats.acl.blacklisted_count}</div>
              <div class="stat-label">Blacklisted</div>
            </div>
            <div class="stat-item">
              <div class="stat-value">#{stats.peers.connected_peers}</div>
              <div class="stat-label">Connected Peers</div>
            </div>
          </div>
        </div>
        
        #{generate_interfaces_section(stats)}
      </div>
    </body>
    </html>
    """
  end

  defp generate_clients_table([]), do: "<p>No clients connected</p>"

  defp generate_clients_table(clients) do
    rows =
      Enum.map_join(clients, fn client ->
        """
        <tr>
          <td>#{client.callsign || "Unknown"}</td>
          <td>#{client.ip}</td>
          <td>#{client.port}</td>
          <td class="#{if client.authenticated, do: "status-ok", else: "status-warning"}">
            #{if client.authenticated, do: "✓", else: "✗"}
          </td>
          <td>#{format_datetime(client.connected_at)}</td>
        </tr>
        """
      end)

    """
    <table>
      <thead>
        <tr>
          <th>Callsign</th>
          <th>IP Address</th>
          <th>Port</th>
          <th>Auth</th>
          <th>Connected</th>
        </tr>
      </thead>
      <tbody>
        #{rows}
      </tbody>
    </table>
    """
  end

  defp generate_packet_types_table(types) when map_size(types) == 0 do
    "<p>No packets processed yet</p>"
  end

  defp generate_packet_types_table(types) do
    rows =
      types
      |> Enum.sort_by(fn {_type, count} -> -count end)
      |> Enum.map_join(fn {type, count} ->
        """
        <tr>
          <td>#{type}</td>
          <td>#{count}</td>
        </tr>
        """
      end)

    """
    <table>
      <thead>
        <tr>
          <th>Packet Type</th>
          <th>Count</th>
        </tr>
      </thead>
      <tbody>
        #{rows}
      </tbody>
    </table>
    """
  end

  defp generate_interfaces_section(stats) do
    """
    <div class="card">
      <h2>Network Interfaces</h2>
      <table>
        <thead>
          <tr>
            <th>Interface</th>
            <th>Port</th>
            <th>Status</th>
            <th>Statistics</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>TCP Server</td>
            <td>14580</td>
            <td class="status-ok">Active</td>
            <td>#{stats.server.clients.current} clients</td>
          </tr>
          <tr>
            <td>SSL/TLS Server</td>
            <td>24580</td>
            <td class="#{if stats.ssl_enabled, do: "status-ok", else: "status-warning"}">
              #{if stats.ssl_enabled, do: "Active", else: "Disabled"}
            </td>
            <td>-</td>
          </tr>
          <tr>
            <td>UDP Listener</td>
            <td>#{stats.udp.port}</td>
            <td class="status-ok">Active</td>
            <td>#{stats.udp.active_clients} clients</td>
          </tr>
          <tr>
            <td>HTTP API</td>
            <td>8080</td>
            <td class="status-ok">Active</td>
            <td>-</td>
          </tr>
          <tr>
            <td>Peer Network</td>
            <td>10152</td>
            <td class="status-ok">Active</td>
            <td>#{stats.peers.connected_peers} peers</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp gather_all_stats do
    %{
      server: Aprstx.Stats.get_stats(),
      clients: get_clients_info(),
      duplicate_filter: Aprstx.DuplicateFilter.get_stats(),
      history: Aprstx.History.get_stats(),
      acl: Aprstx.ACL.get_stats(),
      peers: Aprstx.Peer.get_stats(),
      udp: Aprstx.UdpListener.get_stats(),
      ssl_enabled: ssl_enabled?(),
      timestamp: DateTime.utc_now()
    }
  end

  defp get_clients_info do
    Aprstx.Server
    |> GenServer.call(:get_clients)
    |> Enum.map(fn {_id, client} ->
      %{
        callsign: client.callsign,
        ip: format_ip(client.ip),
        port: client.port,
        authenticated: client.authenticated,
        connected_at: client.connected_at
      }
    end)
  end

  defp ssl_enabled? do
    case Process.whereis(Aprstx.SslServer) do
      nil -> false
      _pid -> true
    end
  end

  defp generate_metrics do
    stats = gather_all_stats()

    """
    # HELP aprstx_packets_received_total Total packets received
    # TYPE aprstx_packets_received_total counter
    aprstx_packets_received_total #{stats.server.packets.received}

    # HELP aprstx_packets_sent_total Total packets sent  
    # TYPE aprstx_packets_sent_total counter
    aprstx_packets_sent_total #{stats.server.packets.sent}

    # HELP aprstx_clients_connected Current connected clients
    # TYPE aprstx_clients_connected gauge
    aprstx_clients_connected #{stats.server.clients.current}

    # HELP aprstx_duplicates_filtered_total Total duplicate packets filtered
    # TYPE aprstx_duplicates_filtered_total counter
    aprstx_duplicates_filtered_total #{stats.duplicate_filter.duplicates_filtered}

    # HELP aprstx_history_buffer_size Current history buffer size
    # TYPE aprstx_history_buffer_size gauge
    aprstx_history_buffer_size #{stats.history.current_size}

    # HELP aprstx_peers_connected Connected peer servers
    # TYPE aprstx_peers_connected gauge
    aprstx_peers_connected #{stats.peers.connected_peers}

    # HELP aprstx_uptime_seconds Server uptime in seconds
    # TYPE aprstx_uptime_seconds counter
    aprstx_uptime_seconds #{stats.server.uptime_seconds}
    """
  end

  defp format_uptime(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    minutes = div(rem(seconds, 3600), 60)

    parts = []
    parts = if days > 0, do: ["#{days}d" | parts], else: parts
    parts = if hours > 0, do: ["#{hours}h" | parts], else: parts
    parts = if minutes > 0, do: ["#{minutes}m" | parts], else: parts

    if Enum.empty?(parts), do: "< 1m", else: Enum.join(Enum.reverse(parts), " ")
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_rate(rate) when is_float(rate), do: Float.round(rate, 2)
  defp format_rate(rate), do: rate

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: inspect(ip)
end
