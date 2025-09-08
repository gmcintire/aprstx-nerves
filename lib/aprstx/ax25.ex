defmodule Aprstx.AX25 do
  @moduledoc """
  AX.25 packet encoding and decoding for amateur radio.
  """
  import Bitwise

  @ax25_ui 0x03
  @ax25_pid_no_layer3 0xF0

  @doc """
  Decode an AX.25 frame to extract APRS data.
  """
  def decode(frame) when byte_size(frame) >= 16 do
    # Extract destination (7 bytes)
    <<dest_bytes::binary-size(7), rest::binary>> = frame
    destination = decode_callsign(dest_bytes)

    # Extract source (7 bytes)
    <<source_bytes::binary-size(7), rest::binary>> = rest
    {source, has_more} = decode_callsign_with_flag(source_bytes)

    # Extract digipeaters
    {digipeaters, rest} = extract_digipeaters(rest, has_more, [])

    # Extract control and PID
    case rest do
      <<@ax25_ui, @ax25_pid_no_layer3, info::binary>> ->
        {:ok,
         %{
           destination: destination,
           source: source,
           digipeaters: digipeaters,
           info: info
         }}

      _ ->
        {:error, :invalid_control_pid}
    end
  rescue
    _ -> {:error, :decode_error}
  end

  def decode(_), do: {:error, :frame_too_short}

  @doc """
  Encode an APRS packet into AX.25 frame.
  """
  def encode(packet) do
    # Encode destination
    dest_bytes = encode_callsign(packet.destination, false)

    # Encode source
    has_digis = length(packet.digipeaters) > 0
    source_bytes = encode_callsign(packet.source, not has_digis)

    # Encode digipeaters
    digi_bytes = encode_digipeaters(packet.digipeaters)

    # Build frame
    frame = <<
      dest_bytes::binary,
      source_bytes::binary,
      digi_bytes::binary,
      @ax25_ui,
      @ax25_pid_no_layer3,
      packet.info::binary
    >>

    {:ok, frame}
  rescue
    _ -> {:error, :encode_error}
  end

  defp decode_callsign(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.take(6)
    |> Enum.map(&(&1 >>> 1))
    |> decode_callsign_chars()
  end

  defp decode_callsign_with_flag(bytes) do
    <<b1, b2, b3, b4, b5, b6, ssid_byte>> = bytes

    callsign =
      [b1, b2, b3, b4, b5, b6]
      |> Enum.map(&(&1 >>> 1))
      |> decode_callsign_chars()

    ssid = ssid_byte >>> 1 &&& 0x0F
    has_more = (ssid_byte &&& 0x01) == 0

    call_with_ssid =
      if ssid > 0 do
        "#{callsign}-#{ssid}"
      else
        callsign
      end

    {call_with_ssid, has_more}
  end

  defp decode_callsign_chars(chars) do
    chars
    |> Enum.map(fn
      # Space
      32 -> nil
      c -> <<c>>
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp extract_digipeaters(data, false, digis) do
    {Enum.reverse(digis), data}
  end

  defp extract_digipeaters(<<digi_bytes::binary-size(7), rest::binary>>, true, digis) do
    {digi, has_more} = decode_callsign_with_flag(digi_bytes)
    extract_digipeaters(rest, has_more, [digi | digis])
  end

  defp extract_digipeaters(data, _, digis) do
    {Enum.reverse(digis), data}
  end

  defp encode_callsign(callsign, is_last) do
    {call, ssid} = parse_callsign_ssid(callsign)

    # Pad to 6 characters
    padded = String.pad_trailing(call, 6)

    # Encode characters (shift left by 1)
    call_bytes =
      padded
      |> String.to_charlist()
      |> Enum.take(6)
      |> Enum.map(&(&1 <<< 1))

    # Encode SSID byte
    ssid_byte =
      ssid <<< 1 ||| 0x60 ||| if is_last, do: 0x01, else: 0x00

    :binary.list_to_bin(call_bytes ++ [ssid_byte])
  end

  defp encode_digipeaters([]) do
    <<>>
  end

  defp encode_digipeaters(digis) do
    {last, rest} = List.pop_at(digis, -1)

    rest_bytes = Enum.map_join(rest, &encode_callsign(&1, false))

    last_bytes = encode_callsign(last, true)

    rest_bytes <> last_bytes
  end

  defp parse_callsign_ssid(callsign) do
    case String.split(callsign, "-") do
      [call, ssid_str] ->
        ssid = String.to_integer(ssid_str)
        {call, ssid}

      [call] ->
        {call, 0}
    end
  end

  @doc """
  Calculate FCS (Frame Check Sequence) for AX.25.
  """
  def calculate_fcs(data) do
    crc = :erlang.crc32(data)
    <<crc::little-16>>
  end

  @doc """
  Verify FCS of an AX.25 frame.
  """
  def verify_fcs(frame) when byte_size(frame) >= 2 do
    frame_size = byte_size(frame)
    data_size = frame_size - 2

    <<data::binary-size(data_size), fcs::little-16>> = frame
    calculated_fcs = :erlang.crc32(data) &&& 0xFFFF

    fcs == calculated_fcs
  end

  def verify_fcs(_), do: false
end
