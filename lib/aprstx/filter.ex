defmodule Aprstx.Filter do
  @moduledoc """
  APRS packet filtering implementation.
  """

  defstruct [
    :type,
    :params
  ]

  @type t :: %__MODULE__{
    type: atom(),
    params: map()
  }

  @doc """
  Parse a filter string into filter structures.
  """
  def parse(filter_string) when is_binary(filter_string) do
    filter_string
    |> String.split(" ")
    |> Enum.map(&parse_filter_part/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse(nil), do: []

  defp parse_filter_part(part) do
    case String.split(part, "/", parts: 2) do
      [type, params] ->
        parse_filter_type(type, params)
      _ ->
        nil
    end
  end

  defp parse_filter_type("r", params) do
    case parse_range_params(params) do
      {:ok, lat, lon, range} ->
        %__MODULE__{
          type: :range,
          params: %{latitude: lat, longitude: lon, range: range}
        }
      _ ->
        nil
    end
  end

  defp parse_filter_type("p", params) do
    prefixes = String.split(params, "/")
    %__MODULE__{
      type: :prefix,
      params: %{prefixes: prefixes}
    }
  end

  defp parse_filter_type("b", params) do
    callsigns = String.split(params, "/")
    %__MODULE__{
      type: :budlist,
      params: %{callsigns: callsigns}
    }
  end

  defp parse_filter_type("o", params) do
    objects = String.split(params, "/")
    %__MODULE__{
      type: :object,
      params: %{objects: objects}
    }
  end

  defp parse_filter_type("t", params) do
    types = parse_type_params(params)
    %__MODULE__{
      type: :type,
      params: %{types: types}
    }
  end

  defp parse_filter_type("s", params) do
    symbols = String.split(params, "/")
    %__MODULE__{
      type: :symbol,
      params: %{symbols: symbols}
    }
  end

  defp parse_filter_type(_, _), do: nil

  defp parse_range_params(params) do
    case String.split(params, "/") do
      [lat_str, lon_str, range_str] ->
        with {lat, _} <- Float.parse(lat_str),
             {lon, _} <- Float.parse(lon_str),
             {range, _} <- Float.parse(range_str) do
          {:ok, lat, lon, range}
        else
          _ -> :error
        end
      _ ->
        :error
    end
  end

  defp parse_type_params(params) do
    params
    |> String.graphemes()
    |> Enum.map(&type_char_to_atom/1)
    |> Enum.reject(&is_nil/1)
  end

  defp type_char_to_atom("p"), do: :position
  defp type_char_to_atom("o"), do: :object
  defp type_char_to_atom("i"), do: :item
  defp type_char_to_atom("m"), do: :message
  defp type_char_to_atom("q"), do: :query
  defp type_char_to_atom("s"), do: :status
  defp type_char_to_atom("t"), do: :telemetry
  defp type_char_to_atom("u"), do: :user_defined
  defp type_char_to_atom("n"), do: :nws
  defp type_char_to_atom("w"), do: :weather
  defp type_char_to_atom(_), do: nil

  @doc """
  Check if a packet matches the given filters.
  """
  def matches?(packet, filters) when is_list(filters) do
    Enum.any?(filters, &matches_filter?(packet, &1))
  end

  def matches?(_packet, nil), do: true

  defp matches_filter?(packet, %__MODULE__{type: :range} = filter) do
    case Aprstx.Packet.extract_position(packet) do
      {:ok, %{latitude: lat, longitude: lon}} ->
        distance = calculate_distance(
          filter.params.latitude,
          filter.params.longitude,
          lat,
          lon
        )
        distance <= filter.params.range
      _ ->
        false
    end
  end

  defp matches_filter?(packet, %__MODULE__{type: :prefix} = filter) do
    Enum.any?(filter.params.prefixes, fn prefix ->
      String.starts_with?(packet.source, prefix)
    end)
  end

  defp matches_filter?(packet, %__MODULE__{type: :budlist} = filter) do
    Enum.any?(filter.params.callsigns, fn callsign ->
      packet.source == callsign or
      packet.destination == callsign or
      callsign in packet.path
    end)
  end

  defp matches_filter?(packet, %__MODULE__{type: :type} = filter) do
    packet_type = map_packet_type(packet.type)
    packet_type in filter.params.types
  end

  defp matches_filter?(_packet, _filter), do: false

  defp map_packet_type(type) do
    case type do
      t when t in [:position_no_timestamp, :position_with_timestamp,
                   :position_with_timestamp_msg, :position_with_timestamp_compressed] ->
        :position
      :message -> :message
      :object -> :object
      :item -> :item
      :status -> :status
      :query -> :query
      :telemetry -> :telemetry
      :weather -> :weather
      :user_defined -> :user_defined
      _ -> nil
    end
  end

  defp calculate_distance(lat1, lon1, lat2, lon2) do
    # Haversine formula
    r = 6371.0  # Earth radius in km
    
    dlat = (lat2 - lat1) * :math.pi() / 180.0
    dlon = (lon2 - lon1) * :math.pi() / 180.0
    
    a = :math.sin(dlat/2) * :math.sin(dlat/2) +
        :math.cos(lat1 * :math.pi() / 180.0) * 
        :math.cos(lat2 * :math.pi() / 180.0) *
        :math.sin(dlon/2) * :math.sin(dlon/2)
    
    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1-a))
    r * c
  end
end