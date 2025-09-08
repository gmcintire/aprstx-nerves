defmodule Aprstx.Packet do
  @moduledoc """
  APRS packet parsing and encoding functionality.
  """

  defstruct [
    :source,
    :destination,
    :path,
    :data,
    :raw,
    :timestamp,
    :type
  ]

  @type t :: %__MODULE__{
          source: String.t(),
          destination: String.t(),
          path: [String.t()],
          data: String.t(),
          raw: String.t(),
          timestamp: DateTime.t(),
          type: atom()
        }

  @doc """
  Parse an APRS packet from raw string format.
  """
  def parse(raw) when is_binary(raw) do
    raw = String.trim(raw)

    with {:ok, header, data} <- split_header_data(raw),
         {:ok, source, destination, path} <- parse_header(header) do
      type = detect_packet_type(data)

      {:ok,
       %__MODULE__{
         source: source,
         destination: destination,
         path: path,
         data: data,
         raw: raw,
         timestamp: DateTime.utc_now(),
         type: type
       }}
    end
  end

  defp split_header_data(raw) do
    case String.split(raw, ":", parts: 2) do
      [header, data] -> {:ok, header, data}
      _ -> {:error, :invalid_format}
    end
  end

  defp parse_header(header) do
    case String.split(header, ">", parts: 2) do
      [source, rest] ->
        case String.split(rest, ",") do
          [destination | path] ->
            {:ok, source, destination, path}

          _ ->
            {:error, :invalid_header}
        end

      _ ->
        {:error, :invalid_header}
    end
  end

  defp detect_packet_type(data) when byte_size(data) > 0 do
    case String.at(data, 0) do
      "!" -> :position_no_timestamp
      "=" -> :position_with_timestamp
      "/" -> :position_with_timestamp_msg
      "@" -> :position_with_timestamp_compressed
      ">" -> :status
      "?" -> :query
      ":" -> :message
      ";" -> :object
      ")" -> :item
      "`" -> :mic_e
      "'" -> :old_mic_e
      "$" -> :raw_gps
      "%" -> :agrelo
      "T" -> :telemetry
      "[" -> :maidenhead_beacon
      "_" -> :weather
      "{" -> :user_defined
      "}" -> :third_party
      _ -> :unknown
    end
  end

  defp detect_packet_type(_), do: :unknown

  @doc """
  Decode an APRS packet from raw string format.
  Alias for parse/1 for compatibility.
  """
  def decode(raw), do: parse(raw)

  @doc """
  Encode a packet structure back to APRS format.
  """
  def encode(%__MODULE__{} = packet) do
    header = encode_header(packet)
    "#{header}:#{packet.data}"
  end

  defp encode_header(%__MODULE__{source: source, destination: dest, path: path}) do
    path_str =
      case path do
        [] -> ""
        _ -> "," <> Enum.join(path, ",")
      end

    "#{source}>#{dest}#{path_str}"
  end

  @doc """
  Validate an APRS callsign.
  """
  def valid_callsign?(callsign) when is_binary(callsign) do
    case String.split(String.upcase(callsign), "-") do
      [call] ->
        # Must have at least one letter and be 1-6 characters
        String.match?(call, ~r/^[A-Z0-9]{1,6}$/) and
          String.match?(call, ~r/[A-Z]/)

      [call, ssid] ->
        # Must have at least one letter, 1-6 characters, and SSID 0-15
        String.match?(call, ~r/^[A-Z0-9]{1,6}$/) and
          String.match?(call, ~r/[A-Z]/) and
          String.match?(ssid, ~r/^[0-9]{1,2}$/) and
          String.to_integer(ssid) <= 15

      _ ->
        false
    end
  end

  @doc """
  Extract position data from a packet if available.
  """
  def extract_position(%__MODULE__{type: type, data: data})
      when type in [:position_no_timestamp, :position_with_timestamp] do
    parse_position_data(data)
  end

  def extract_position(_), do: nil

  defp parse_position_data(data) do
    case Regex.run(~r/(\d{2})(\d{2}\.\d{2})([NS]).(\d{3})(\d{2}\.\d{2})([EW])/, data) do
      [_, lat_deg, lat_min, lat_dir, lon_deg, lon_min, lon_dir] ->
        lat = parse_coordinate(lat_deg, lat_min, lat_dir, :latitude)
        lon = parse_coordinate(lon_deg, lon_min, lon_dir, :longitude)
        {:ok, %{latitude: lat, longitude: lon}}

      _ ->
        {:error, :invalid_position}
    end
  end

  defp parse_coordinate(deg, min, dir, type) do
    degrees = String.to_integer(deg)
    minutes = String.to_float(min)
    decimal = degrees + minutes / 60.0

    case {type, dir} do
      {:latitude, "S"} -> -decimal
      {:latitude, "N"} -> decimal
      {:longitude, "W"} -> -decimal
      {:longitude, "E"} -> decimal
    end
  end
end
