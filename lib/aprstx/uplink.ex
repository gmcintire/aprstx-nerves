defmodule Aprstx.Uplink do
  @moduledoc """
  APRS-IS uplink connection management.
  """
  use GenServer
  require Logger

  defstruct [
    :host,
    :port,
    :callsign,
    :passcode,
    :filter,
    :socket,
    :connected,
    :reconnect_timer
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      host: Keyword.get(opts, :host, "rotate.aprs2.net"),
      port: Keyword.get(opts, :port, 14580),
      callsign: Keyword.fetch!(opts, :callsign),
      passcode: Keyword.fetch!(opts, :passcode),
      filter: Keyword.get(opts, :filter, ""),
      connected: false
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_to_server(state) do
      {:ok, socket} ->
        Logger.info("Connected to APRS-IS server #{state.host}:#{state.port}")
        {:noreply, %{state | socket: socket, connected: true}}
      
      {:error, reason} ->
        Logger.error("Failed to connect to APRS-IS: #{inspect(reason)}")
        schedule_reconnect()
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    process_uplink_data(data)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.warn("APRS-IS connection closed")
    schedule_reconnect()
    {:noreply, %{state | connected: false, socket: nil}}
  end

  @impl true
  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("APRS-IS connection error: #{inspect(reason)}")
    :gen_tcp.close(socket)
    schedule_reconnect()
    {:noreply, %{state | connected: false, socket: nil}}
  end

  @impl true
  def handle_cast({:send_packet, packet}, state) do
    if state.connected do
      encoded = Aprstx.Packet.encode(packet)
      :gen_tcp.send(state.socket, encoded <> "\r\n")
    end
    {:noreply, state}
  end

  defp connect_to_server(state) do
    with {:ok, socket} <- :gen_tcp.connect(
           String.to_charlist(state.host),
           state.port,
           [:binary, packet: :line, active: true, keepalive: true],
           5000
         ),
         :ok <- authenticate(socket, state) do
      {:ok, socket}
    end
  end

  defp authenticate(socket, state) do
    login = "user #{state.callsign} pass #{state.passcode} vers aprstx-elixir 1.0"
    login = if state.filter != "", do: login <> " filter #{state.filter}", else: login
    
    :gen_tcp.send(socket, login <> "\r\n")
  end

  defp process_uplink_data(data) do
    data = String.trim(data)
    
    unless String.starts_with?(data, "#") do
      case Aprstx.Packet.parse(data) do
        {:ok, packet} ->
          GenServer.cast(Aprstx.Server, {:broadcast, packet, :uplink})
        
        {:error, _reason} ->
          :ok
      end
    end
  end

  defp schedule_reconnect do
    Process.send_after(self(), :reconnect, 5000)
  end

  def send_packet(packet) do
    GenServer.cast(__MODULE__, {:send_packet, packet})
  end
end