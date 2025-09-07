defmodule Aprstx.FilterTest do
  use ExUnit.Case
  alias Aprstx.Filter
  alias Aprstx.Packet

  describe "parse/1" do
    test "parses range filter" do
      filters = Filter.parse("r/35.5/-106.0/100")
      
      assert [filter] = filters
      assert filter.type == :range
      assert filter.params.latitude == 35.5
      assert filter.params.longitude == -106.0
      assert filter.params.range == 100.0
    end

    test "parses prefix filter" do
      filters = Filter.parse("p/N0/KC/W5")
      
      assert [filter] = filters
      assert filter.type == :prefix
      assert filter.params.prefixes == ["N0", "KC", "W5"]
    end

    test "parses budlist filter" do
      filters = Filter.parse("b/N0CALL/KC0ABC")
      
      assert [filter] = filters
      assert filter.type == :budlist
      assert filter.params.callsigns == ["N0CALL", "KC0ABC"]
    end

    test "parses type filter" do
      filters = Filter.parse("t/poimqstw")
      
      assert [filter] = filters
      assert filter.type == :type
      assert :position in filter.params.types
      assert :object in filter.params.types
      assert :message in filter.params.types
    end

    test "parses multiple filters" do
      filters = Filter.parse("r/35/-106/50 p/N0 t/pm")
      
      assert length(filters) == 3
      assert Enum.at(filters, 0).type == :range
      assert Enum.at(filters, 1).type == :prefix
      assert Enum.at(filters, 2).type == :type
    end

    test "handles nil input" do
      assert [] = Filter.parse(nil)
    end
  end

  describe "matches?/2" do
    test "matches range filter" do
      filter = %Filter{
        type: :range,
        params: %{latitude: 35.0, longitude: -106.0, range: 100.0}
      }
      
      packet = %Packet{
        type: :position_no_timestamp,
        data: "!3530.00N/10600.00W>Test"
      }
      
      assert Filter.matches?(packet, [filter])
    end

    test "matches prefix filter" do
      filter = %Filter{
        type: :prefix,
        params: %{prefixes: ["N0", "KC"]}
      }
      
      packet = %Packet{source: "N0CALL"}
      assert Filter.matches?(packet, [filter])
      
      packet2 = %Packet{source: "W5XYZ"}
      refute Filter.matches?(packet2, [filter])
    end

    test "matches budlist filter" do
      filter = %Filter{
        type: :budlist,
        params: %{callsigns: ["N0CALL", "KC0ABC"]}
      }
      
      packet = %Packet{
        source: "N0CALL",
        destination: "APRS",
        path: []
      }
      assert Filter.matches?(packet, [filter])
      
      packet2 = %Packet{
        source: "W5XYZ",
        destination: "KC0ABC",
        path: []
      }
      assert Filter.matches?(packet2, [filter])
      
      packet3 = %Packet{
        source: "OTHER",
        destination: "APRS",
        path: ["N0CALL"]
      }
      assert Filter.matches?(packet3, [filter])
    end

    test "matches type filter" do
      filter = %Filter{
        type: :type,
        params: %{types: [:position, :message]}
      }
      
      packet = %Packet{type: :position_no_timestamp}
      assert Filter.matches?(packet, [filter])
      
      packet2 = %Packet{type: :message}
      assert Filter.matches?(packet2, [filter])
      
      packet3 = %Packet{type: :status}
      refute Filter.matches?(packet3, [filter])
    end

    test "returns true for nil filters" do
      packet = %Packet{source: "N0CALL"}
      assert Filter.matches?(packet, nil)
    end

    test "matches any filter in list" do
      filters = [
        %Filter{type: :prefix, params: %{prefixes: ["W5"]}},
        %Filter{type: :prefix, params: %{prefixes: ["N0"]}}
      ]
      
      packet = %Packet{source: "N0CALL"}
      assert Filter.matches?(packet, filters)
    end
  end
end