defmodule AprstxWeb.DashboardLive do
  @moduledoc false
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(1000, self(), :tick)
    end

    socket =
      assign(socket,
        time: DateTime.utc_now(),
        gps_status: "Unknown",
        packets_received: 0,
        packets_sent: 0
      )

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    socket =
      assign(socket,
        time: DateTime.utc_now(),
        gps_status: check_gps_status()
      )

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="font-family: system-ui, sans-serif; max-width: 1200px; margin: 0 auto; padding: 20px;">
      <h1>APRSTX Live Dashboard</h1>
      
      <div style="background: white; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h2>Real-time Status</h2>
        <p>Current Time: <%= @time |> DateTime.to_string() %></p>
        <p>GPS Status: <%= @gps_status %></p>
        <p>Packets Received: <%= @packets_received %></p>
        <p>Packets Sent: <%= @packets_sent %></p>
      </div>
      
      <div style="background: white; padding: 20px; border-radius: 8px; margin: 20px 0;">
        <h2>System Info</h2>
        <p>Uptime: <%= format_uptime(:erlang.statistics(:wall_clock) |> elem(0) |> div(1000)) %></p>
        <p>Memory: <%= format_memory(Process.info(self(), :memory)) %></p>
      </div>
      
      <p><a href="/">Back to Home</a></p>
    </div>
    """
  end

  defp check_gps_status do
    case Process.whereis(Aprstx.GPS) do
      nil -> "Not Running"
      _pid -> "Running"
    end
  end

  defp format_uptime(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    seconds = rem(seconds, 60)
    "#{hours}h #{minutes}m #{seconds}s"
  end

  defp format_memory({:memory, bytes}) do
    mb = bytes / 1_048_576
    "#{Float.round(mb, 2)} MB"
  end

  defp format_memory(_), do: "Unknown"
end
