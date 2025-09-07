defmodule Aprstx.Stats do
  @moduledoc """
  Statistics collection and reporting for APRS server.
  """
  use GenServer
  require Logger

  defstruct [
    :packets_received,
    :packets_sent,
    :bytes_received,
    :bytes_sent,
    :clients_current,
    :clients_total,
    :uptime_start,
    :packet_types
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      packets_received: 0,
      packets_sent: 0,
      bytes_received: 0,
      bytes_sent: 0,
      clients_current: 0,
      clients_total: 0,
      uptime_start: System.monotonic_time(:second),
      packet_types: %{}
    }

    schedule_report()
    {:ok, state}
  end

  @impl true
  def handle_cast({:packet_received, packet}, state) do
    new_state = state
    |> Map.update!(:packets_received, &(&1 + 1))
    |> Map.update!(:bytes_received, &(&1 + byte_size(packet.raw)))
    |> update_packet_types(packet.type)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:packet_sent, _packet, bytes}, state) do
    new_state = state
    |> Map.update!(:packets_sent, &(&1 + 1))
    |> Map.update!(:bytes_sent, &(&1 + bytes))

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:client_connected, _client_id}, state) do
    new_state = state
    |> Map.update!(:clients_current, &(&1 + 1))
    |> Map.update!(:clients_total, &(&1 + 1))

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:client_disconnected, _client_id}, state) do
    new_state = Map.update!(state, :clients_current, &max(&1 - 1, 0))
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = format_stats(state)
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:report_stats, state) do
    stats = format_stats(state)
    Logger.info("Stats: #{inspect(stats)}")
    schedule_report()
    {:noreply, state}
  end

  defp update_packet_types(state, type) do
    Map.update!(state, :packet_types, fn types ->
      Map.update(types, type, 1, &(&1 + 1))
    end)
  end

  defp format_stats(state) do
    uptime = System.monotonic_time(:second) - state.uptime_start
    
    %{
      uptime_seconds: uptime,
      packets: %{
        received: state.packets_received,
        sent: state.packets_sent,
        rate_rx: calculate_rate(state.packets_received, uptime),
        rate_tx: calculate_rate(state.packets_sent, uptime)
      },
      bytes: %{
        received: state.bytes_received,
        sent: state.bytes_sent
      },
      clients: %{
        current: state.clients_current,
        total: state.clients_total
      },
      packet_types: state.packet_types
    }
  end

  defp calculate_rate(count, seconds) when seconds > 0 do
    Float.round(count / seconds, 2)
  end
  defp calculate_rate(_, _), do: 0.0

  defp schedule_report do
    Process.send_after(self(), :report_stats, 60_000)
  end

  def record_packet_received(packet) do
    GenServer.cast(__MODULE__, {:packet_received, packet})
  end

  def record_packet_sent(packet, bytes) do
    GenServer.cast(__MODULE__, {:packet_sent, packet, bytes})
  end

  def record_client_connected(client_id) do
    GenServer.cast(__MODULE__, {:client_connected, client_id})
  end

  def record_client_disconnected(client_id) do
    GenServer.cast(__MODULE__, {:client_disconnected, client_id})
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end
end