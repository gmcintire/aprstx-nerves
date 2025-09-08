defmodule Aprstx.Logger do
  @moduledoc """
  Custom logger with file rotation and packet logging.
  """
  use GenServer

  require Logger

  # 10 MB
  @max_file_size 10_485_760
  @max_files 10
  @log_dir "logs"

  defstruct [
    :access_log,
    :packet_log,
    :error_log,
    :current_sizes,
    :config
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    log_dir = Keyword.get(opts, :log_dir, @log_dir)
    File.mkdir_p!(log_dir)

    state = %__MODULE__{
      access_log: open_log_file(Path.join(log_dir, "access.log")),
      packet_log: open_log_file(Path.join(log_dir, "packets.log")),
      error_log: open_log_file(Path.join(log_dir, "error.log")),
      current_sizes: %{
        access: 0,
        packet: 0,
        error: 0
      },
      config: %{
        log_dir: log_dir,
        max_file_size: Keyword.get(opts, :max_file_size, @max_file_size),
        max_files: Keyword.get(opts, :max_files, @max_files),
        log_packets: Keyword.get(opts, :log_packets, true),
        log_access: Keyword.get(opts, :log_access, true)
      }
    }

    {:ok, state}
  end

  @doc """
  Log an access event (client connection/disconnection).
  """
  def log_access(event, details) do
    GenServer.cast(__MODULE__, {:log_access, event, details})
  end

  @doc """
  Log a packet.
  """
  def log_packet(packet, direction \\ :rx) do
    GenServer.cast(__MODULE__, {:log_packet, packet, direction})
  end

  @doc """
  Log an error.
  """
  def log_error(error, context) do
    GenServer.cast(__MODULE__, {:log_error, error, context})
  end

  @impl true
  def handle_cast({:log_access, event, details}, state) do
    if state.config.log_access do
      timestamp = format_timestamp(DateTime.utc_now())

      log_entry =
        case event do
          :connect ->
            "#{timestamp} CONNECT #{details.ip}:#{details.port} callsign=#{details.callsign || "none"}"

          :disconnect ->
            "#{timestamp} DISCONNECT #{details.ip}:#{details.port} callsign=#{details.callsign || "none"} duration=#{details.duration}s"

          :auth_success ->
            "#{timestamp} AUTH_SUCCESS #{details.ip}:#{details.port} callsign=#{details.callsign}"

          :auth_failure ->
            "#{timestamp} AUTH_FAILURE #{details.ip}:#{details.port} callsign=#{details.callsign} reason=#{details.reason}"

          _ ->
            "#{timestamp} #{event} #{inspect(details)}"
        end

      _new_state = write_log_entry(state, :access, log_entry)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:log_packet, packet, direction}, state) do
    if state.config.log_packets do
      timestamp = format_timestamp(DateTime.utc_now())
      dir_str = if direction == :rx, do: "RX", else: "TX"

      log_entry = "#{timestamp} #{dir_str} #{Aprstx.Packet.encode(packet)}"

      _new_state = write_log_entry(state, :packet, log_entry)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:log_error, error, context}, state) do
    timestamp = format_timestamp(DateTime.utc_now())

    log_entry = "#{timestamp} ERROR #{inspect(error)} context=#{inspect(context)}"

    state = write_log_entry(state, :error, log_entry)

    {:noreply, state}
  end

  defp write_log_entry(state, log_type, entry) do
    {file, size_key} =
      case log_type do
        :access -> {state.access_log, :access}
        :packet -> {state.packet_log, :packet}
        :error -> {state.error_log, :error}
      end

    IO.puts(file, entry)

    new_size = Map.get(state.current_sizes, size_key) + byte_size(entry) + 1

    if new_size > state.config.max_file_size do
      rotate_log(state, log_type)
    else
      put_in(state.current_sizes[size_key], new_size)
    end
  end

  defp rotate_log(state, log_type) do
    {file, base_name} =
      case log_type do
        :access -> {state.access_log, "access.log"}
        :packet -> {state.packet_log, "packets.log"}
        :error -> {state.error_log, "error.log"}
      end

    File.close(file)

    # Rotate existing files
    base_path = Path.join(state.config.log_dir, base_name)
    rotate_existing_files(base_path, state.config.max_files)

    # Open new file
    new_file = open_log_file(base_path)

    case log_type do
      :access ->
        state
        |> Map.put(:access_log, new_file)
        |> put_in([:current_sizes, :access], 0)

      :packet ->
        state
        |> Map.put(:packet_log, new_file)
        |> put_in([:current_sizes, :packet], 0)

      :error ->
        state
        |> Map.put(:error_log, new_file)
        |> put_in([:current_sizes, :error], 0)
    end
  end

  defp rotate_existing_files(base_path, max_files) do
    # Delete oldest file if it exists
    oldest = "#{base_path}.#{max_files}"
    if File.exists?(oldest), do: File.rm!(oldest)

    # Rotate files
    for i <- (max_files - 1)..1 do
      from = "#{base_path}.#{i}"
      to = "#{base_path}.#{i + 1}"
      if File.exists?(from), do: File.rename!(from, to)
    end

    # Move current to .1
    if File.exists?(base_path), do: File.rename!(base_path, "#{base_path}.1")
  end

  defp open_log_file(path) do
    File.open!(path, [:append, :utf8])
  end

  defp format_timestamp(datetime) do
    datetime
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S.%f")
    # Remove last 3 digits of microseconds
    |> String.slice(0..-4//1)
  end

  @doc """
  Get log statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      current_sizes: state.current_sizes,
      config: state.config,
      log_files: list_log_files(state.config.log_dir)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:export_logs, from, to, output_path}, _from, state) do
    # This would need more complex implementation to filter by timestamp
    # For now, just copy current logs

    result =
      try do
        File.open!(output_path, [:write, :utf8], fn output ->
          for log_file <- [state.access_log, state.packet_log, state.error_log] do
            log_file.path
            |> File.stream!()
            |> Stream.filter(fn line ->
              case extract_timestamp(line) do
                {:ok, timestamp} ->
                  timestamp >= from and timestamp <= to

                _ ->
                  false
              end
            end)
            |> Enum.each(&IO.write(output, &1))
          end
        end)

        {:ok, output_path}
      rescue
        e -> {:error, e}
      end

    {:reply, result, state}
  end

  defp list_log_files(log_dir) do
    case File.ls(log_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".log"))
        |> Enum.map(fn file ->
          path = Path.join(log_dir, file)
          stat = File.stat!(path)

          %{
            name: file,
            size: stat.size,
            modified: stat.mtime
          }
        end)

      _ ->
        []
    end
  end

  @doc """
  Export logs for a specific time range.
  """
  def export_logs(from_datetime, to_datetime, output_path) do
    GenServer.call(__MODULE__, {:export_logs, from_datetime, to_datetime, output_path})
  end

  defp extract_timestamp(line) do
    case Regex.run(~r/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})/, line) do
      [_, timestamp_str] ->
        case DateTime.from_iso8601(timestamp_str <> "Z") do
          {:ok, datetime, _} -> {:ok, datetime}
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
