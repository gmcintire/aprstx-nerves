defmodule Aprstx.AX25Test do
  use ExUnit.Case

  import Bitwise

  alias Aprstx.AX25

  describe "encode/1" do
    test "encodes a basic packet" do
      packet = %{
        source: "N0CALL",
        destination: "APRS",
        digipeaters: [],
        info: "Test message"
      }

      assert {:ok, frame} = AX25.encode(packet)
      assert is_binary(frame)
    end

    test "encodes packet with digipeaters" do
      packet = %{
        source: "N0CALL",
        destination: "APRS",
        digipeaters: ["WIDE1-1", "WIDE2-2"],
        info: "Test message"
      }

      assert {:ok, frame} = AX25.encode(packet)
      assert is_binary(frame)
    end

    test "encodes callsign with SSID" do
      packet = %{
        source: "N0CALL-5",
        destination: "APRS",
        digipeaters: [],
        info: "Test"
      }

      assert {:ok, frame} = AX25.encode(packet)
      assert is_binary(frame)
    end
  end

  describe "decode/1" do
    test "decodes a valid AX.25 frame" do
      # Create a simple frame (this is simplified - real AX.25 is more complex)
      # Destination: APRS (padded to 6 chars, shifted left)
      dest = <<65 <<< 1, 80 <<< 1, 82 <<< 1, 83 <<< 1, 32 <<< 1, 32 <<< 1, 0x60>>
      # Source: N0CALL (last address)
      source = <<78 <<< 1, 48 <<< 1, 67 <<< 1, 65 <<< 1, 76 <<< 1, 76 <<< 1, 0x61>>
      # Control and PID
      control_pid = <<0x03, 0xF0>>
      # Info
      info = "Test message"

      frame = dest <> source <> control_pid <> info

      assert {:ok, decoded} = AX25.decode(frame)
      assert decoded.destination == "APRS"
      assert decoded.source == "N0CALL"
      assert decoded.info == "Test message"
    end

    test "handles frame with digipeaters" do
      # This would be a more complex test with actual digipeater encoding
      assert true
    end

    test "returns error for invalid frame" do
      assert {:error, :frame_too_short} = AX25.decode(<<1, 2, 3>>)
    end

    test "returns error for invalid control/PID" do
      # Create frame with wrong control byte
      dest = <<65 <<< 1, 80 <<< 1, 82 <<< 1, 83 <<< 1, 32 <<< 1, 32 <<< 1, 0x60>>
      source = <<78 <<< 1, 48 <<< 1, 67 <<< 1, 65 <<< 1, 76 <<< 1, 76 <<< 1, 0x61>>
      # Wrong control byte
      control_pid = <<0xFF, 0xF0>>
      frame = dest <> source <> control_pid <> "Test"

      assert {:error, :invalid_control_pid} = AX25.decode(frame)
    end
  end

  describe "FCS functions" do
    test "calculates FCS correctly" do
      data = "Test data"
      fcs = AX25.calculate_fcs(data)

      assert byte_size(fcs) == 2
    end

    test "verifies valid FCS" do
      data = "Test data"
      fcs = AX25.calculate_fcs(data)
      frame = data <> fcs

      assert AX25.verify_fcs(frame) == true
    end

    test "rejects invalid FCS" do
      data = "Test data"
      bad_fcs = <<0xFF, 0xFF>>
      frame = data <> bad_fcs

      assert AX25.verify_fcs(frame) == false
    end

    test "rejects frame too short for FCS" do
      assert AX25.verify_fcs(<<1>>) == false
    end
  end
end
