defmodule Aprstx.AprsIsClient do
  @moduledoc """
  APRS-IS client for connecting to APRS-IS servers.
  Handles authentication, filtering, and bidirectional packet flow.
  """
  use GenServer

  require Logger

  @reconnect_interval 30_000
  @keepalive_interval 60_000

  defstruct [
    :config,
    :socket,
    :state,
    :buffer,
    :keepalive_timer,
    :reconnect_timer,
    :stats
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      config: %{
        server: Keyword.get(opts, :server, "rotate.aprs2.net"),
        port: Keyword.get(opts, :port, 14_580),
        callsign: Keyword.fetch!(opts, :callsign),
        passcode: Keyword.fetch!(opts, :passcode),
        filter: Keyword.get(opts, :filter, ""),
        software: Keyword.get(opts, :software, "APRXel"),
        version: Keyword.get(opts, :version, "1.0")
      },
      state: :disconnected,
      buffer: "",
      stats: init_stats()
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_to_server(state) do
      {:ok, socket} ->
        Logger.info("Connected to APRS-IS server #{state.config.server}:#{state.config.port}")

        # Send login
        login_string = build_login_string(state.config)
        :gen_tcp.send(socket, login_string)

        # Start keepalive timer
        keepalive_timer = Process.send_after(self(), :keepalive, @keepalive_interval)

        new_state = %{state | socket: socket, state: :connected, keepalive_timer: keepalive_timer}

        # Notify parent
        send(Aprstx.Aprx, {:aprs_is_status, :connected})

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to connect to APRS-IS: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  defp connect_to_server(state) do
    opts = [:binary, {:packet, :line}, {:active, true}, {:keepalive, true}]

    case resolve_server(state.config.server) do
      {:ok, address} ->
        :gen_tcp.connect(address, state.config.port, opts, 10_000)

      error ->
        error
    end
  end

  defp resolve_server(hostname) when is_binary(hostname) do
    case :inet.getaddr(String.to_charlist(hostname), :inet) do
      {:ok, address} -> {:ok, address}
      error -> error
    end
  end

  defp build_login_string(config) do
    filter_part = if config.filter == "", do: "", else: " filter #{config.filter}"

    "user #{config.callsign} pass #{config.passcode} vers #{config.software} #{config.version}#{filter_part}\r\n"
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    # Handle incoming data from APRS-IS
    lines = String.split(state.buffer <> data, "\n")
    {complete, [incomplete]} = Enum.split(lines, -1)

    new_state =
      Enum.reduce(complete, state, fn line, acc_state ->
        process_line(String.trim(line), acc_state)
      end)

    {:noreply, %{new_state | buffer: incomplete}}
  end

  @impl true
  def handle_info({:tcp_closed, _socket}, state) do
    Logger.warning("APRS-IS connection closed")
    handle_disconnect(state)
  end

  @impl true
  def handle_info({:tcp_error, _socket, reason}, state) do
    Logger.error("APRS-IS TCP error: #{inspect(reason)}")
    handle_disconnect(state)
  end

  @impl true
  def handle_info(:keepalive, %{state: :connected} = state) do
    # Send keepalive comment
    :gen_tcp.send(state.socket, "# aprx-el keepalive\r\n")

    # Schedule next keepalive
    keepalive_timer = Process.send_after(self(), :keepalive, @keepalive_interval)
    {:noreply, %{state | keepalive_timer: keepalive_timer}}
  end

  @impl true
  def handle_info(:keepalive, state) do
    # Not connected, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    Logger.info("Attempting to reconnect to APRS-IS...")
    {:noreply, state, {:continue, :connect}}
  end

  defp process_line("", state), do: state

  defp process_line("#" <> comment, state) do
    # Server comment/status line
    Logger.debug("APRS-IS: #{comment}")

    if String.contains?(comment, "logresp") do
      handle_login_response(comment, state)
    else
      state
    end
  end

  defp process_line(line, state) do
    # APRS packet
    case Aprstx.Packet.decode(line) do
      {:ok, packet} ->
        # Send to Aprx module for processing
        send(Aprstx.Aprx, {:aprs_is_packet, packet})

        # Update stats
        update_stats(state, :packets_received)

      {:error, reason} ->
        Logger.warning("Failed to decode APRS-IS packet: #{inspect(reason)}")
        state
    end
  end

  defp handle_login_response(response, state) do
    cond do
      String.contains?(response, "verified") ->
        Logger.info("APRS-IS login verified")
        state

      String.contains?(response, "unverified") ->
        Logger.warning("APRS-IS login unverified - check passcode")
        state

      true ->
        Logger.info("APRS-IS login response: #{response}")
        state
    end
  end

  defp handle_disconnect(state) do
    # Cancel timers
    if state.keepalive_timer, do: Process.cancel_timer(state.keepalive_timer)

    # Close socket if still open
    if state.socket, do: :gen_tcp.close(state.socket)

    # Notify parent
    send(Aprstx.Aprx, {:aprs_is_status, :disconnected})

    # Schedule reconnect
    schedule_reconnect(%{state | socket: nil, state: :disconnected, keepalive_timer: nil})
  end

  defp schedule_reconnect(state) do
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)

    reconnect_timer = Process.send_after(self(), :reconnect, @reconnect_interval)
    {:noreply, %{state | reconnect_timer: reconnect_timer}}
  end

  defp init_stats do
    %{
      packets_sent: 0,
      packets_received: 0,
      bytes_sent: 0,
      bytes_received: 0,
      connect_time: nil,
      last_packet_time: nil
    }
  end

  defp update_stats(state, :packets_received) do
    new_stats =
      state.stats
      |> Map.update!(:packets_received, &(&1 + 1))
      |> Map.put(:last_packet_time, DateTime.utc_now())

    %{state | stats: new_stats}
  end

  defp update_stats(state, :packets_sent) do
    new_stats = Map.update!(state.stats, :packets_sent, &(&1 + 1))
    %{state | stats: new_stats}
  end

  # Public API

  @doc """
  Send a packet to APRS-IS.
  """
  def send_packet(pid \\ __MODULE__, packet) do
    GenServer.cast(pid, {:send_packet, packet})
  end

  @doc """
  Get connection status.
  """
  def get_status(pid \\ __MODULE__) do
    GenServer.call(pid, :get_status)
  end

  @doc """
  Get statistics.
  """
  def get_stats(pid \\ __MODULE__) do
    GenServer.call(pid, :get_stats)
  end

  @impl true
  def handle_cast({:send_packet, packet}, %{state: :connected} = state) do
    # Encode and send packet
    encoded = Aprstx.Packet.encode(packet)
    :gen_tcp.send(state.socket, encoded <> "\r\n")

    {:noreply, update_stats(state, :packets_sent)}
  end

  @impl true
  def handle_cast({:send_packet, _packet}, state) do
    # Not connected, drop packet
    Logger.warning("Cannot send packet - not connected to APRS-IS")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      state: state.state,
      server: state.config.server,
      port: state.config.port,
      callsign: state.config.callsign,
      filter: state.config.filter
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end
end
