defmodule Aprstx.GPS do
  @moduledoc """
  GPS module for USB-serial GPS devices.
  Supports NMEA parsing and position tracking for roaming igate/digi.
  """
  use GenServer

  require Logger

  defstruct [
    :device,
    :uart,
    :current_position,
    :last_valid_position,
    :fix_status,
    :satellites,
    :speed,
    :course,
    :altitude,
    :buffer,
    :stats,
    :subscribers
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    device = Keyword.get(opts, :device, "/dev/ttyUSB0")
    baud = Keyword.get(opts, :baud_rate, 9600)

    state = %__MODULE__{
      device: device,
      buffer: "",
      fix_status: :no_fix,
      satellites: 0,
      stats: %{
        sentences_received: 0,
        valid_fixes: 0,
        last_fix_time: nil
      },
      subscribers: []
    }

    # Try to open GPS device
    case open_gps_device(device, baud) do
      {:ok, uart} ->
        Logger.info("GPS device opened: #{device}")
        {:ok, %{state | uart: uart}}

      {:error, reason} ->
        Logger.error("Failed to open GPS device #{device}: #{inspect(reason)}")
        # Retry connection periodically
        Process.send_after(self(), :retry_connect, 5000)
        {:ok, state}
    end
  end

  defp open_gps_device(device, baud) do
    case Circuits.UART.start_link() do
      {:ok, uart} ->
        opts = [
          speed: baud,
          data_bits: 8,
          stop_bits: 1,
          parity: :none,
          flow_control: :none,
          active: true
        ]

        case Circuits.UART.open(uart, device, opts) do
          :ok ->
            # Configure GPS if needed (some GPS modules accept commands)
            configure_gps(uart)
            {:ok, uart}

          error ->
            Circuits.UART.stop(uart)
            error
        end

      error ->
        error
    end
  rescue
    _ ->
      # Circuits.UART not available, try alternative
      {:error, :uart_not_available}
  end

  defp configure_gps(_uart) do
    # Send initialization commands if needed
    # For example, for u-blox GPS modules:
    # Circuits.UART.write(uart, "$PUBX,40,RMC,0,1,0,0*47\r\n")  # Enable RMC
    # Circuits.UART.write(uart, "$PUBX,40,GGA,0,1,0,0*5A\r\n")  # Enable GGA
    :ok
  end

  @impl true
  def handle_info(:retry_connect, state) do
    case open_gps_device(state.device, 9600) do
      {:ok, uart} ->
        Logger.info("GPS device reconnected")
        {:noreply, %{state | uart: uart}}

      {:error, _reason} ->
        Process.send_after(self(), :retry_connect, 5000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:circuits_uart, _device, data}, state) do
    # Append data to buffer and process complete sentences
    buffer = state.buffer <> data
    {sentences, remaining} = extract_nmea_sentences(buffer)

    new_state =
      sentences
      |> Enum.reduce(state, &process_nmea_sentence/2)
      |> Map.put(:buffer, remaining)

    {:noreply, new_state}
  end

  defp extract_nmea_sentences(buffer) do
    lines = String.split(buffer, "\n")

    case List.pop_at(lines, -1) do
      {incomplete, complete} ->
        sentences =
          complete
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&String.starts_with?(&1, "$"))

        {sentences, incomplete || ""}
    end
  end

  defp process_nmea_sentence(sentence, state) do
    state = update_stats(state, :sentences_received)

    case parse_nmea(sentence) do
      {:ok, :gga, data} ->
        process_gga(state, data)

      {:ok, :rmc, data} ->
        process_rmc(state, data)

      {:ok, :gsa, data} ->
        process_gsa(state, data)

      {:ok, :vtg, data} ->
        process_vtg(state, data)

      _ ->
        state
    end
  end

  defp parse_nmea(sentence) do
    # Verify checksum
    case verify_nmea_checksum(sentence) do
      :ok ->
        parse_nmea_type(sentence)

      :error ->
        {:error, :invalid_checksum}
    end
  end

  defp verify_nmea_checksum(sentence) do
    case String.split(sentence, "*") do
      [data, checksum] ->
        # Calculate checksum (XOR of all bytes between $ and *)
        calculated =
          data
          |> String.slice(1..-1//1)
          |> String.to_charlist()
          |> Enum.reduce(0, &Bitwise.bxor/2)
          |> Integer.to_string(16)
          |> String.upcase()
          |> String.pad_leading(2, "0")

        if calculated == String.upcase(checksum), do: :ok, else: :error

      _ ->
        :error
    end
  end

  defp parse_nmea_type(sentence) do
    parts = String.split(sentence, ",")

    case hd(parts) do
      "$GPGGA" -> parse_gga(parts)
      "$GNGGA" -> parse_gga(parts)
      "$GPRMC" -> parse_rmc(parts)
      "$GNRMC" -> parse_rmc(parts)
      "$GPGSA" -> parse_gsa(parts)
      "$GNGSA" -> parse_gsa(parts)
      "$GPVTG" -> parse_vtg(parts)
      "$GNVTG" -> parse_vtg(parts)
      _ -> {:error, :unknown_sentence}
    end
  end

  defp parse_gga(parts) when length(parts) >= 14 do
    [_, time, lat, lat_dir, lon, lon_dir, fix, sats, hdop, alt, alt_unit | _] = parts

    data = %{
      time: parse_time(time),
      latitude: parse_coordinate(lat, lat_dir),
      longitude: parse_coordinate(lon, lon_dir),
      fix_quality: parse_int(fix),
      satellites: parse_int(sats),
      hdop: parse_float(hdop),
      altitude: parse_float(alt)
    }

    {:ok, :gga, data}
  rescue
    _ -> {:error, :parse_error}
  end

  defp parse_gga(_), do: {:error, :invalid_gga}

  defp parse_rmc(parts) when length(parts) >= 12 do
    [_, time, status, lat, lat_dir, lon, lon_dir, speed, course, date | _] = parts

    data = %{
      time: parse_time(time),
      status: status == "A",
      latitude: parse_coordinate(lat, lat_dir),
      longitude: parse_coordinate(lon, lon_dir),
      # knots
      speed: parse_float(speed),
      course: parse_float(course),
      date: parse_date(date)
    }

    {:ok, :rmc, data}
  rescue
    _ -> {:error, :parse_error}
  end

  defp parse_rmc(_), do: {:error, :invalid_rmc}

  defp parse_gsa(parts) when length(parts) >= 17 do
    [_, mode, fix_type | rest] = parts

    data = %{
      mode: mode,
      fix_type: parse_int(fix_type),
      pdop: parse_float(Enum.at(rest, 12)),
      hdop: parse_float(Enum.at(rest, 13)),
      vdop: parse_float(Enum.at(rest, 14))
    }

    {:ok, :gsa, data}
  rescue
    _ -> {:error, :parse_error}
  end

  defp parse_gsa(_), do: {:error, :invalid_gsa}

  defp parse_vtg(parts) when length(parts) >= 9 do
    [_, course_true, _, course_mag, _, speed_knots, _, speed_kmh | _] = parts

    data = %{
      course_true: parse_float(course_true),
      course_magnetic: parse_float(course_mag),
      speed_knots: parse_float(speed_knots),
      speed_kmh: parse_float(speed_kmh)
    }

    {:ok, :vtg, data}
  rescue
    _ -> {:error, :parse_error}
  end

  defp parse_vtg(_), do: {:error, :invalid_vtg}

  defp parse_coordinate("", _), do: nil

  defp parse_coordinate(coord, dir) do
    # Format: DDMM.MMMM or DDDMM.MMMM
    {degrees, minutes} =
      if String.length(coord) > 10 do
        # Longitude: DDDMM.MMMM
        {String.slice(coord, 0..2), String.slice(coord, 3..-1//1)}
      else
        # Latitude: DDMM.MMMM
        {String.slice(coord, 0..1), String.slice(coord, 2..-1//1)}
      end

    deg = String.to_integer(degrees)
    min = String.to_float(minutes)
    decimal = deg + min / 60.0

    case dir do
      "S" -> -decimal
      "W" -> -decimal
      _ -> decimal
    end
  rescue
    _ -> nil
  end

  defp parse_time(time) when byte_size(time) >= 6 do
    hour = String.slice(time, 0..1)
    minute = String.slice(time, 2..3)
    second = String.slice(time, 4..5)
    "#{hour}:#{minute}:#{second}"
  rescue
    _ -> nil
  end

  defp parse_time(_), do: nil

  defp parse_date(date) when byte_size(date) == 6 do
    day = String.slice(date, 0..1)
    month = String.slice(date, 2..3)
    year = "20" <> String.slice(date, 4..5)
    "#{year}-#{month}-#{day}"
  rescue
    _ -> nil
  end

  defp parse_date(_), do: nil

  defp parse_int(""), do: nil

  defp parse_int(str) do
    String.to_integer(str)
  rescue
    _ -> nil
  end

  defp parse_float(""), do: nil

  defp parse_float(str) do
    String.to_float(str)
  rescue
    _ -> nil
  end

  defp process_gga(state, data) do
    if data.fix_quality > 0 and data.latitude and data.longitude do
      position = %{
        latitude: data.latitude,
        longitude: data.longitude,
        altitude: data.altitude,
        timestamp: DateTime.utc_now()
      }

      new_state = %{
        state
        | current_position: position,
          last_valid_position: position,
          satellites: data.satellites,
          altitude: data.altitude,
          fix_status: fix_status_from_quality(data.fix_quality)
      }

      notify_subscribers(new_state, {:position_update, position})
      update_stats(new_state, :valid_fixes)
    else
      %{state | fix_status: :no_fix, satellites: data.satellites}
    end
  end

  defp process_rmc(state, data) do
    if data.status and data.latitude and data.longitude do
      position = %{
        latitude: data.latitude,
        longitude: data.longitude,
        speed: knots_to_kmh(data.speed),
        course: data.course,
        timestamp: DateTime.utc_now()
      }

      new_state = %{
        state
        | current_position: Map.merge(state.current_position || %{}, position),
          last_valid_position: Map.merge(state.last_valid_position || %{}, position),
          speed: knots_to_kmh(data.speed),
          course: data.course
      }

      notify_subscribers(new_state, {:position_update, position})
      new_state
    else
      state
    end
  end

  defp process_gsa(state, data) do
    %{state | fix_status: fix_status_from_type(data.fix_type)}
  end

  defp process_vtg(state, data) do
    %{state | speed: data.speed_kmh, course: data.course_true}
  end

  defp fix_status_from_quality(quality) do
    case quality do
      0 -> :no_fix
      1 -> :gps_fix
      2 -> :dgps_fix
      4 -> :rtk_fixed
      5 -> :rtk_float
      _ -> :unknown
    end
  end

  defp fix_status_from_type(type) do
    case type do
      1 -> :no_fix
      2 -> :fix_2d
      3 -> :fix_3d
      _ -> :unknown
    end
  end

  defp knots_to_kmh(nil), do: nil
  defp knots_to_kmh(knots), do: knots * 1.852

  defp update_stats(state, :sentences_received) do
    put_in(state.stats.sentences_received, state.stats.sentences_received + 1)
  end

  defp update_stats(state, :valid_fixes) do
    state
    |> put_in([:stats, :valid_fixes], state.stats.valid_fixes + 1)
    |> put_in([:stats, :last_fix_time], DateTime.utc_now())
  end

  defp notify_subscribers(state, message) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:gps, message})
    end)

    state
  end

  # Public API

  @doc """
  Get current GPS position.
  """
  def get_position do
    GenServer.call(__MODULE__, :get_position)
  end

  @impl true
  def handle_call(:get_position, _from, state) do
    {:reply, state.current_position, state}
  end

  @doc """
  Get GPS status.
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      fix: state.fix_status,
      satellites: state.satellites,
      position: state.current_position,
      speed: state.speed,
      course: state.course,
      altitude: state.altitude,
      stats: state.stats
    }

    {:reply, status, state}
  end

  @doc """
  Subscribe to GPS updates.
  """
  def subscribe do
    GenServer.cast(__MODULE__, {:subscribe, self()})
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  @doc """
  Format position for APRS.
  """
  def format_aprs_position(position) when not is_nil(position) do
    lat = format_aprs_lat(position.latitude)
    lon = format_aprs_lon(position.longitude)
    "#{lat}/#{lon}"
  end

  def format_aprs_position(_), do: nil

  defp format_aprs_lat(lat) do
    {degrees, minutes} = decimal_to_dm(abs(lat))
    dir = if lat >= 0, do: "N", else: "S"

    deg_str = degrees |> Integer.to_string() |> String.pad_leading(2, "0")
    min_str = "~05.2f" |> :io_lib.format([minutes]) |> to_string() |> String.trim()

    "#{deg_str}#{min_str}#{dir}"
  end

  defp format_aprs_lon(lon) do
    {degrees, minutes} = decimal_to_dm(abs(lon))
    dir = if lon >= 0, do: "E", else: "W"

    deg_str = degrees |> Integer.to_string() |> String.pad_leading(3, "0")
    min_str = "~05.2f" |> :io_lib.format([minutes]) |> to_string() |> String.trim()

    "#{deg_str}#{min_str}#{dir}"
  end

  defp decimal_to_dm(decimal) do
    degrees = trunc(decimal)
    minutes = (decimal - degrees) * 60
    {degrees, minutes}
  end
end
