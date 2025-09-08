defmodule Aprstx.KissTnc do
  @moduledoc """
  KISS TNC interface for serial and TCP KISS connections.
  Supports both serial ports and TCP KISS connections.
  """
  use GenServer

  import Bitwise

  require Logger

  @kiss_fend 0xC0
  @kiss_fesc 0xDB
  @kiss_tfend 0xDC
  @kiss_tfesc 0xDD

  defstruct [
    :type,
    :device,
    :port,
    :connection,
    :buffer,
    :stats
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    type = Keyword.get(opts, :type, :serial)

    state = %__MODULE__{
      type: type,
      device: Keyword.get(opts, :device),
      port: Keyword.get(opts, :port, 8001),
      buffer: <<>>,
      stats: init_stats()
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_tnc(state) do
      {:ok, connection} ->
        Logger.info("Connected to KISS TNC")
        {:noreply, %{state | connection: connection}}

      {:error, reason} ->
        Logger.error("Failed to connect to KISS TNC: #{inspect(reason)}")
        schedule_reconnect()
        {:noreply, state}
    end
  end

  defp connect_tnc(%{type: :serial} = state) do
    # Serial port connection using Circuits.UART
    case Circuits.UART.start_link() do
      {:ok, uart} ->
        opts = [
          speed: 9600,
          data_bits: 8,
          stop_bits: 1,
          parity: :none,
          flow_control: :none
        ]

        case Circuits.UART.open(uart, state.device, opts) do
          :ok ->
            {:ok, uart}

          error ->
            error
        end

      error ->
        error
    end
  rescue
    _ ->
      # Circuits.UART not available, try TCP fallback
      {:error, :serial_not_available}
  end

  defp connect_tnc(%{type: :tcp} = state) do
    case :gen_tcp.connect(~c"localhost", state.port, [:binary, packet: 0, active: true]) do
      {:ok, socket} ->
        {:ok, socket}

      error ->
        error
    end
  end

  @impl true
  def handle_info({:circuits_uart, _device, data}, state) do
    process_kiss_data(data, state)
  end

  @impl true
  def handle_info({:tcp, _socket, data}, state) do
    process_kiss_data(data, state)
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  defp process_kiss_data(data, state) do
    buffer = state.buffer <> data
    {frames, remaining} = extract_kiss_frames(buffer)

    Enum.each(frames, &process_kiss_frame(&1, state))

    {:noreply, %{state | buffer: remaining}}
  end

  defp extract_kiss_frames(data) do
    extract_frames(data, [])
  end

  defp extract_frames(<<@kiss_fend, rest::binary>>, frames) do
    case find_frame_end(rest) do
      {:ok, frame, remaining} ->
        extract_frames(remaining, [frame | frames])

      :incomplete ->
        {Enum.reverse(frames), <<@kiss_fend, rest::binary>>}
    end
  end

  defp extract_frames(<<_byte, rest::binary>>, frames) do
    # Skip bytes until we find FEND
    extract_frames(rest, frames)
  end

  defp extract_frames(<<>>, frames) do
    {Enum.reverse(frames), <<>>}
  end

  defp find_frame_end(data) do
    find_frame_end(data, <<>>)
  end

  defp find_frame_end(<<@kiss_fend, rest::binary>>, acc) do
    {:ok, acc, rest}
  end

  defp find_frame_end(<<@kiss_fesc, @kiss_tfend, rest::binary>>, acc) do
    find_frame_end(rest, acc <> <<@kiss_fend>>)
  end

  defp find_frame_end(<<@kiss_fesc, @kiss_tfesc, rest::binary>>, acc) do
    find_frame_end(rest, acc <> <<@kiss_fesc>>)
  end

  defp find_frame_end(<<byte, rest::binary>>, acc) do
    find_frame_end(rest, acc <> <<byte>>)
  end

  defp find_frame_end(<<>>, _acc) do
    :incomplete
  end

  defp process_kiss_frame(frame, state) do
    case decode_kiss_frame(frame) do
      {:ok, :data, ax25_frame} ->
        process_ax25_frame(ax25_frame, state)

      {:ok, command, _data} ->
        Logger.debug("Received KISS command: #{inspect(command)}")

      {:error, reason} ->
        Logger.warning("Invalid KISS frame: #{inspect(reason)}")
    end
  end

  defp decode_kiss_frame(<<>>) do
    {:error, :empty_frame}
  end

  defp decode_kiss_frame(<<type_byte, data::binary>>) do
    port = type_byte >>> 4
    command = type_byte &&& 0x0F

    command_type =
      case command do
        0x00 -> :data
        0x01 -> :txdelay
        0x02 -> :persistence
        0x03 -> :slottime
        0x04 -> :txtail
        0x05 -> :fullduplex
        0x06 -> :sethardware
        0xFF -> :return
        _ -> :unknown
      end

    if port == 0 do
      {:ok, command_type, data}
    else
      {:error, :invalid_port}
    end
  end

  defp process_ax25_frame(frame, _state) do
    case Aprstx.AX25.decode(frame) do
      {:ok, packet} ->
        # Convert AX.25 to APRS packet
        aprs_packet = ax25_to_aprs(packet)

        # Send to server for processing
        GenServer.cast(Aprstx.Server, {:broadcast, aprs_packet, :kiss_tnc})

      {:error, reason} ->
        Logger.warning("Failed to decode AX.25 frame: #{inspect(reason)}")
    end
  end

  @doc """
  Send a packet via KISS TNC.
  """
  def send_packet(packet) do
    GenServer.cast(__MODULE__, {:send_packet, packet})
  end

  def send_packet(pid, packet) when is_pid(pid) or is_atom(pid) do
    GenServer.cast(pid, {:send_packet, packet})
  end

  @impl true
  def handle_cast({:send_packet, packet}, state) do
    # Convert APRS packet to AX.25
    case aprs_to_ax25(packet) do
      {:ok, ax25_frame} ->
        kiss_frame = encode_kiss_frame(ax25_frame)
        send_to_tnc(state, kiss_frame)

        new_stats = Map.update!(state.stats, :packets_sent, &(&1 + 1))
        {:noreply, %{state | stats: new_stats}}

        # This clause is not needed since aprs_to_ax25 always returns {:ok, _}
        # Keeping for future error handling if needed
    end
  end

  defp encode_kiss_frame(data) do
    # Escape special characters
    escaped =
      data
      |> :binary.bin_to_list()
      |> Enum.flat_map(fn
        @kiss_fend -> [@kiss_fesc, @kiss_tfend]
        @kiss_fesc -> [@kiss_fesc, @kiss_tfesc]
        byte -> [byte]
      end)
      |> :binary.list_to_bin()

    # Add frame delimiters and data type byte (0x00 for data)
    <<@kiss_fend, 0x00, escaped::binary, @kiss_fend>>
  end

  defp send_to_tnc(%{type: :serial, connection: uart}, data) when not is_nil(uart) do
    Circuits.UART.write(uart, data)
  rescue
    _ -> :ok
  end

  defp send_to_tnc(%{type: :tcp, connection: socket}, data) when not is_nil(socket) do
    :gen_tcp.send(socket, data)
  end

  defp send_to_tnc(_, _), do: :ok

  defp ax25_to_aprs(ax25_packet) do
    %Aprstx.Packet{
      source: ax25_packet.source,
      destination: ax25_packet.destination,
      path: ax25_packet.digipeaters,
      data: ax25_packet.info,
      type: detect_packet_type(ax25_packet.info),
      timestamp: DateTime.utc_now()
    }
  end

  defp aprs_to_ax25(packet) do
    {:ok,
     %{
       source: packet.source,
       destination: packet.destination,
       digipeaters: packet.path,
       info: packet.data
     }}
  end

  defp detect_packet_type(data) when byte_size(data) > 0 do
    case String.at(data, 0) do
      "!" -> :position_no_timestamp
      "=" -> :position_with_timestamp
      "/" -> :position_with_timestamp_msg
      "@" -> :position_with_timestamp_compressed
      ">" -> :status
      ":" -> :message
      _ -> :unknown
    end
  end

  defp detect_packet_type(_), do: :unknown

  defp schedule_reconnect do
    Process.send_after(self(), :reconnect, 5000)
  end

  defp init_stats do
    %{
      packets_received: 0,
      packets_sent: 0,
      bytes_received: 0,
      bytes_sent: 0
    }
  end
end
