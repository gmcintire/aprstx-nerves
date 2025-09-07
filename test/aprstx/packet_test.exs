defmodule Aprstx.PacketTest do
  use ExUnit.Case
  alias Aprstx.Packet

  describe "parse/1" do
    test "parses a basic position packet" do
      raw = "N0CALL>APRS,TCPIP*:!3553.50N/10602.50W>Test packet"
      
      assert {:ok, packet} = Packet.parse(raw)
      assert packet.source == "N0CALL"
      assert packet.destination == "APRS"
      assert packet.path == ["TCPIP*"]
      assert packet.data == "!3553.50N/10602.50W>Test packet"
      assert packet.type == :position_no_timestamp
    end

    test "parses a message packet" do
      raw = "N0CALL>APRS::N1CALL   :Hello World{001"
      
      assert {:ok, packet} = Packet.parse(raw)
      assert packet.source == "N0CALL"
      assert packet.destination == "APRS"
      assert packet.data == ":N1CALL   :Hello World{001"
      assert packet.type == :message
    end

    test "parses a weather packet" do
      raw = "N0CALL>APRS:_10090556c220s004g005t077r000p000P000h50b09900"
      
      assert {:ok, packet} = Packet.parse(raw)
      assert packet.type == :weather
    end

    test "returns error for invalid format" do
      assert {:error, :invalid_format} = Packet.parse("invalid packet")
    end

    test "returns error for packet without header separator" do
      assert {:error, :invalid_header} = Packet.parse("N0CALL:data")
    end
  end

  describe "encode/1" do
    test "encodes a packet structure" do
      packet = %Packet{
        source: "N0CALL",
        destination: "APRS",
        path: ["TCPIP*"],
        data: "!3553.50N/10602.50W>Test"
      }
      
      encoded = Packet.encode(packet)
      assert encoded == "N0CALL>APRS,TCPIP*:!3553.50N/10602.50W>Test"
    end

    test "encodes packet without path" do
      packet = %Packet{
        source: "N0CALL",
        destination: "APRS",
        path: [],
        data: ">Status"
      }
      
      encoded = Packet.encode(packet)
      assert encoded == "N0CALL>APRS:>Status"
    end
  end

  describe "valid_callsign?/1" do
    test "validates correct callsigns" do
      assert Packet.valid_callsign?("N0CALL")
      assert Packet.valid_callsign?("KC0ABC")
      assert Packet.valid_callsign?("W5XYZ")
      assert Packet.valid_callsign?("N0CALL-5")
      assert Packet.valid_callsign?("KB0ABC-15")
    end

    test "rejects invalid callsigns" do
      refute Packet.valid_callsign?("")
      refute Packet.valid_callsign?("TOOLONGCALL")
      refute Packet.valid_callsign?("N0CALL-")
      refute Packet.valid_callsign?("N0CALL-16")
      refute Packet.valid_callsign?("123456")
    end
  end

  describe "extract_position/1" do
    test "extracts position from position packet" do
      packet = %Packet{
        type: :position_no_timestamp,
        data: "!3553.50N/10602.50W>Test"
      }
      
      assert {:ok, pos} = Packet.extract_position(packet)
      assert_in_delta pos.latitude, 35.891666, 0.001
      assert_in_delta pos.longitude, -106.041666, 0.001
    end

    test "returns nil for non-position packets" do
      packet = %Packet{
        type: :message,
        data: ":N1CALL   :Hello"
      }
      
      assert nil == Packet.extract_position(packet)
    end

    test "handles different position formats" do
      packet = %Packet{
        type: :position_with_timestamp,
        data: "/092345z4903.50N/07201.75W>Test"
      }
      
      assert {:ok, pos} = Packet.extract_position(packet)
      assert_in_delta pos.latitude, 49.058333, 0.001
      assert_in_delta pos.longitude, -72.029166, 0.001
    end
  end
end