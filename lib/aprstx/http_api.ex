defmodule Aprstx.HttpApi do
  @moduledoc """
  HTTP API for server status and control.
  """
  use Plug.Router

  require Logger

  plug(:match)
  plug(:dispatch)

  get "/status" do
    stats = Aprstx.Stats.get_stats()

    response = %{
      status: "online",
      stats: stats,
      version: "1.0.0",
      uptime: stats.uptime_seconds
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(response))
  end

  get "/clients" do
    clients = GenServer.call(Aprstx.Server, :get_clients)

    client_list =
      Enum.map(clients, fn {_id, client} ->
        %{
          callsign: client.callsign,
          ip: format_ip(client.ip),
          port: client.port,
          connected_at: client.connected_at,
          authenticated: client.authenticated
        }
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(client_list))
  end

  get "/health" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "OK")
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: inspect(ip)
end
