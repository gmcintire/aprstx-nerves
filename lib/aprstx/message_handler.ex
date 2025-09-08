defmodule Aprstx.MessageHandler do
  @moduledoc """
  APRS message handling, acknowledgments, and bulletins.
  """
  use GenServer

  require Logger

  defstruct [
    :pending_acks,
    :recent_messages,
    :bulletins
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    state = %__MODULE__{
      pending_acks: %{},
      recent_messages: [],
      bulletins: %{}
    }

    schedule_cleanup()
    {:ok, state}
  end

  @doc """
  Process an APRS message packet.
  """
  def process_message(packet) do
    GenServer.call(__MODULE__, {:process_message, packet})
  end

  @impl true
  def handle_call({:process_message, packet}, _from, state) do
    case parse_message(packet.data) do
      {:message, to, text, msg_id} ->
        state = handle_message(state, packet, to, text, msg_id)
        {:reply, :ok, state}

      {:ack, to, msg_id} ->
        state = handle_ack(state, packet, to, msg_id)
        {:reply, :ok, state}

      {:rej, to, msg_id} ->
        state = handle_reject(state, packet, to, msg_id)
        {:reply, :ok, state}

      {:bulletin, bulletin_id, text} ->
        state = handle_bulletin(state, packet, bulletin_id, text)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :invalid_message}, state}
    end
  end

  @impl true
  def handle_call({:get_recent_messages, limit}, _from, state) do
    messages = Enum.take(state.recent_messages, limit)
    {:reply, messages, state}
  end

  @impl true
  def handle_call(:get_bulletins, _from, state) do
    {:reply, state.bulletins, state}
  end

  defp parse_message(data) when is_binary(data) do
    cond do
      # Standard message format ":ADDRESSEE:Message text{msgid"
      String.match?(data, ~r/^:[A-Z0-9\- ]{9}:/) ->
        parse_standard_message(data)

      # Bulletin format ":BLNn:Message text"
      String.match?(data, ~r/^:BLN[0-9A-Z]:/) ->
        parse_bulletin(data)

      true ->
        {:error, :invalid_format}
    end
  end

  defp parse_standard_message(data) do
    case Regex.run(~r/^:([A-Z0-9\- ]{9}):(.+)$/, data) do
      [_, addressee, content] ->
        addressee = String.trim(addressee)

        cond do
          # Acknowledgment
          String.starts_with?(content, "ack") ->
            msg_id = String.slice(content, 3..-1//1)
            {:ack, addressee, msg_id}

          # Reject
          String.starts_with?(content, "rej") ->
            msg_id = String.slice(content, 3..-1//1)
            {:rej, addressee, msg_id}

          # Regular message
          true ->
            case Regex.run(~r/^(.+)\{([0-9]{1,5})$/, content) do
              [_, text, msg_id] ->
                {:message, addressee, text, msg_id}

              _ ->
                {:message, addressee, content, nil}
            end
        end

      _ ->
        {:error, :invalid_format}
    end
  end

  defp parse_bulletin(data) do
    case Regex.run(~r/^:BLN([0-9A-Z]):(.+)$/, data) do
      [_, bulletin_id, text] ->
        {:bulletin, bulletin_id, text}

      _ ->
        {:error, :invalid_format}
    end
  end

  defp handle_message(state, packet, to, text, msg_id) do
    Logger.info("Message from #{packet.source} to #{to}: #{text}")

    # Store message
    message = %{
      from: packet.source,
      to: to,
      text: text,
      msg_id: msg_id,
      timestamp: DateTime.utc_now()
    }

    state = %{state | recent_messages: [message | state.recent_messages]}

    # Send acknowledgment if msg_id present
    if msg_id do
      send_ack(packet.source, to, msg_id)

      # Track pending ack
      ack_key = "#{to}:#{msg_id}"
      pending = Map.put(state.pending_acks, ack_key, DateTime.utc_now())
      %{state | pending_acks: pending}
    else
      state
    end
  end

  defp handle_ack(state, packet, to, msg_id) do
    Logger.info("ACK from #{packet.source} for message #{msg_id} to #{to}")

    # Remove from pending acks
    ack_key = "#{packet.source}:#{msg_id}"
    pending = Map.delete(state.pending_acks, ack_key)
    %{state | pending_acks: pending}
  end

  defp handle_reject(state, packet, to, msg_id) do
    Logger.info("REJ from #{packet.source} for message #{msg_id} to #{to}")

    # Remove from pending acks
    ack_key = "#{packet.source}:#{msg_id}"
    pending = Map.delete(state.pending_acks, ack_key)
    %{state | pending_acks: pending}
  end

  defp handle_bulletin(state, packet, bulletin_id, text) do
    Logger.info("Bulletin #{bulletin_id} from #{packet.source}: #{text}")

    bulletin = %{
      from: packet.source,
      id: bulletin_id,
      text: text,
      timestamp: DateTime.utc_now()
    }

    bulletins = Map.put(state.bulletins, bulletin_id, bulletin)
    %{state | bulletins: bulletins}
  end

  defp send_ack(to, from, msg_id) do
    ack_packet = %Aprstx.Packet{
      source: from,
      destination: "APRS",
      path: [],
      data: ":#{String.pad_trailing(to, 9)}:ack#{msg_id}",
      type: :message,
      timestamp: DateTime.utc_now()
    }

    GenServer.cast(Aprstx.Server, {:broadcast, ack_packet, :message_handler})
  end

  @doc """
  Send an APRS message.
  """
  def send_message(from, to, text, msg_id \\ nil) do
    msg_id = msg_id || generate_msg_id()

    # Format addressee to 9 characters
    formatted_to = String.pad_trailing(to, 9)

    data =
      if msg_id do
        ":#{formatted_to}:#{text}{#{msg_id}"
      else
        ":#{formatted_to}:#{text}"
      end

    packet = %Aprstx.Packet{
      source: from,
      destination: "APRS",
      path: [],
      data: data,
      type: :message,
      timestamp: DateTime.utc_now()
    }

    GenServer.cast(Aprstx.Server, {:broadcast, packet, :message_handler})
  end

  defp generate_msg_id do
    99_999 |> :rand.uniform() |> Integer.to_string() |> String.pad_leading(5, "0")
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Clean old messages (keep last 1000)
    messages = Enum.take(state.recent_messages, 1000)

    # Clean old pending acks (older than 1 hour)
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    pending =
      state.pending_acks
      |> Enum.filter(fn {_key, timestamp} ->
        DateTime.after?(timestamp, cutoff)
      end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | recent_messages: messages, pending_acks: pending}}
  end

  defp schedule_cleanup do
    # 5 minutes
    Process.send_after(self(), :cleanup, 300_000)
  end

  @doc """
  Get recent messages.
  """
  def get_recent_messages(limit \\ 100) do
    GenServer.call(__MODULE__, {:get_recent_messages, limit})
  end

  @doc """
  Get active bulletins.
  """
  def get_bulletins do
    GenServer.call(__MODULE__, :get_bulletins)
  end
end
