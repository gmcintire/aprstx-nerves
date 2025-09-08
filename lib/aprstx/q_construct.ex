defmodule Aprstx.QConstruct do
  @moduledoc """
  Q-construct processing for APRS-IS packets.
  Handles qAC, qAX, qAU, qAo, qAO, qAS, qAr, qAR, qAZ constructs.
  """

  @doc """
  Process Q-construct in packet path.
  """
  def process(packet, client_info) do
    cond do
      has_q_construct?(packet) ->
        # Already has Q-construct, validate and possibly modify
        validate_existing_q(packet, client_info)

      client_info.verified ->
        # Add appropriate Q-construct for verified client
        add_q_construct(packet, client_info, :verified)

      true ->
        # Unverified client
        add_q_construct(packet, client_info, :unverified)
    end
  end

  @doc """
  Check if packet already has a Q-construct.
  """
  def has_q_construct?(%{path: path}) do
    Enum.any?(path, &String.starts_with?(&1, "q"))
  end

  @doc """
  Add Q-construct to packet path.
  """
  def add_q_construct(packet, client_info, :verified) do
    q_element = build_q_element("qAC", client_info.server_call)
    %{packet | path: packet.path ++ [q_element]}
  end

  def add_q_construct(packet, client_info, :unverified) do
    q_element = build_q_element("qAX", client_info.server_call)
    %{packet | path: packet.path ++ [q_element]}
  end

  @doc """
  Validate existing Q-construct.
  """
  def validate_existing_q(packet, _client_info) do
    case find_q_construct(packet.path) do
      {index, q_element} ->
        if valid_q_construct?(q_element) do
          packet
        else
          # Remove invalid Q-construct
          new_path = List.delete_at(packet.path, index)
          %{packet | path: new_path}
        end

      nil ->
        packet
    end
  end

  @doc """
  Build a Q-construct element.
  """
  def build_q_element(q_type, server_call) do
    "#{q_type},#{server_call}"
  end

  @doc """
  Parse Q-construct from path element.
  """
  def parse_q_element(element) do
    case Regex.run(~r/^(q[A-Z]{2}),(.+)$/, element) do
      [_, q_type, server_call] ->
        {:ok, q_type, server_call}

      _ ->
        :error
    end
  end

  defp find_q_construct(path) do
    path
    |> Enum.with_index()
    |> Enum.find(fn {element, _index} ->
      String.starts_with?(element, "q")
    end)
  end

  defp valid_q_construct?(element) do
    case parse_q_element(element) do
      {:ok, q_type, _server_call} ->
        q_type in ["qAC", "qAX", "qAU", "qAo", "qAO", "qAS", "qAr", "qAR", "qAZ"]

      _ ->
        false
    end
  end

  @doc """
  Process packet for I-gate path.
  qAR = packet received directly via radio from the packet originator
  qAo = packet received via a client-only port
  qAO = packet received from client login that is not verified
  """
  def process_igate_path(packet, receive_type) do
    q_element =
      case receive_type do
        :radio -> build_q_element("qAR", get_server_call())
        :client_only -> build_q_element("qAo", get_server_call())
        :unverified -> build_q_element("qAO", get_server_call())
        _ -> nil
      end

    if q_element do
      %{packet | path: packet.path ++ [q_element]}
    else
      packet
    end
  end

  defp get_server_call do
    Application.get_env(:aprstx, :server_call, "APRSTX")
  end

  @doc """
  Strip Q-constructs from path for RF transmission.
  """
  def strip_q_constructs(packet) do
    new_path = Enum.reject(packet.path, &String.starts_with?(&1, "q"))
    %{packet | path: new_path}
  end

  @doc """
  Check if packet should be gated to RF based on Q-construct.
  """
  def gate_to_rf?(packet) do
    case find_q_construct(packet.path) do
      {_index, element} ->
        case parse_q_element(element) do
          # Verified client
          {:ok, "qAC", _} -> true
          # From server
          {:ok, "qAS", _} -> true
          # Already from RF
          {:ok, "qAR", _} -> false
          # Unverified
          {:ok, "qAX", _} -> false
          # Unverified client-only
          {:ok, "qAO", _} -> false
          _ -> false
        end

      nil ->
        # No Q-construct, don't gate
        false
    end
  end
end
