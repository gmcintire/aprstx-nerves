defmodule Aprstx.ACL do
  @moduledoc """
  Access Control List management for APRS server.
  Controls client access, rate limiting, and permissions.
  """
  use GenServer

  require Logger

  defstruct [
    :rules,
    :blacklist,
    :whitelist,
    :rate_limits,
    :flood_protection
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      rules: load_rules(opts),
      blacklist: MapSet.new(),
      whitelist: MapSet.new(),
      rate_limits: %{},
      flood_protection: %{
        enabled: true,
        max_packets_per_minute: 60,
        max_bytes_per_minute: 100_000,
        # 5 minutes
        ban_duration: 300
      }
    }

    schedule_cleanup()
    {:ok, state}
  end

  @doc """
  Check if a client is allowed to connect.
  """
  def allowed_to_connect?(ip, callsign) do
    GenServer.call(__MODULE__, {:check_connect, ip, callsign})
  end

  @doc """
  Check if a client can send a packet.
  """
  def allowed_to_send?(client_info, packet) do
    GenServer.call(__MODULE__, {:check_send, client_info, packet})
  end

  @doc """
  Record a packet for rate limiting.
  """
  def record_packet(client_info, packet_size) do
    GenServer.cast(__MODULE__, {:record_packet, client_info, packet_size})
  end

  @doc """
  Add IP to blacklist.
  """
  def blacklist_ip(ip, reason \\ nil) do
    GenServer.cast(__MODULE__, {:blacklist_ip, ip, reason})
  end

  @doc """
  Add callsign to blacklist.
  """
  def blacklist_callsign(callsign, reason \\ nil) do
    GenServer.cast(__MODULE__, {:blacklist_callsign, callsign, reason})
  end

  @doc """
  Remove from blacklist.
  """
  def unblacklist(identifier) do
    GenServer.cast(__MODULE__, {:unblacklist, identifier})
  end

  @impl true
  def handle_call({:check_connect, ip, callsign}, _from, state) do
    allowed =
      not ip_blacklisted?(ip, state) and
        not callsign_blacklisted?(callsign, state) and
        (MapSet.size(state.whitelist) == 0 or
           ip_whitelisted?(ip, state) or
           callsign_whitelisted?(callsign, state))

    {:reply, allowed, state}
  end

  @impl true
  def handle_call({:check_send, client_info, _packet}, _from, state) do
    if state.flood_protection.enabled do
      case check_rate_limit(client_info, state) do
        :ok ->
          {:reply, true, state}

        {:exceeded, reason} ->
          Logger.warning("Rate limit exceeded for #{client_info.callsign}: #{reason}")
          {:reply, false, state}
      end
    else
      {:reply, true, state}
    end
  end

  @impl true
  def handle_cast({:record_packet, client_info, packet_size}, state) do
    key = rate_limit_key(client_info)
    now = System.monotonic_time(:second)

    entry =
      Map.get(state.rate_limits, key, %{
        packets: [],
        bytes: [],
        last_check: now
      })

    updated_entry = %{
      packets: [{now, 1} | entry.packets],
      bytes: [{now, packet_size} | entry.bytes],
      last_check: now
    }

    new_rate_limits = Map.put(state.rate_limits, key, updated_entry)

    # Check if should auto-ban
    state =
      case check_for_flood(updated_entry, state.flood_protection) do
        {:flood, reason} ->
          Logger.warning("Auto-banning #{client_info.callsign} for flooding: #{reason}")
          ban_client(state, client_info, state.flood_protection.ban_duration)

        :ok ->
          state
      end

    {:noreply, %{state | rate_limits: new_rate_limits}}
  end

  @impl true
  def handle_cast({:blacklist_ip, ip, reason}, state) do
    Logger.info("Blacklisting IP #{format_ip(ip)}: #{reason || "no reason"}")
    new_blacklist = MapSet.put(state.blacklist, {:ip, ip})
    {:noreply, %{state | blacklist: new_blacklist}}
  end

  @impl true
  def handle_cast({:blacklist_callsign, callsign, reason}, state) do
    Logger.info("Blacklisting callsign #{callsign}: #{reason || "no reason"}")
    new_blacklist = MapSet.put(state.blacklist, {:callsign, callsign})
    {:noreply, %{state | blacklist: new_blacklist}}
  end

  @impl true
  def handle_cast({:unblacklist, identifier}, state) do
    new_blacklist =
      state.blacklist
      |> MapSet.delete({:ip, identifier})
      |> MapSet.delete({:callsign, identifier})

    {:noreply, %{state | blacklist: new_blacklist}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:second)
    # Keep last minute of data
    cutoff = now - 60

    new_rate_limits =
      state.rate_limits
      |> Enum.map(fn {key, entry} ->
        cleaned_entry = %{
          packets: cleanup_old_entries(entry.packets, cutoff),
          bytes: cleanup_old_entries(entry.bytes, cutoff),
          last_check: entry.last_check
        }

        {key, cleaned_entry}
      end)
      |> Enum.filter(fn {_key, entry} ->
        length(entry.packets) > 0 or length(entry.bytes) > 0
      end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | rate_limits: new_rate_limits}}
  end

  defp load_rules(opts) do
    default_rules = %{
      allow_unverified: true,
      require_valid_callsign: true,
      max_path_length: 8,
      allowed_packet_types: :all,
      blocked_packet_types: [],
      # seconds
      min_position_interval: 30
    }

    Map.merge(default_rules, Map.new(Keyword.get(opts, :rules, [])))
  end

  defp ip_blacklisted?(ip, state) do
    MapSet.member?(state.blacklist, {:ip, ip})
  end

  defp callsign_blacklisted?(callsign, state) do
    MapSet.member?(state.blacklist, {:callsign, callsign})
  end

  defp ip_whitelisted?(ip, state) do
    MapSet.member?(state.whitelist, {:ip, ip})
  end

  defp callsign_whitelisted?(callsign, state) do
    MapSet.member?(state.whitelist, {:callsign, callsign})
  end

  defp rate_limit_key(client_info) do
    "#{client_info.callsign || "unknown"}:#{format_ip(client_info.ip)}"
  end

  defp check_rate_limit(client_info, state) do
    key = rate_limit_key(client_info)

    case Map.get(state.rate_limits, key) do
      nil ->
        :ok

      entry ->
        check_for_flood(entry, state.flood_protection)
    end
  end

  defp check_for_flood(entry, config) do
    now = System.monotonic_time(:second)
    cutoff = now - 60

    recent_packets =
      entry.packets
      |> Enum.filter(fn {time, _} -> time > cutoff end)
      |> Enum.map(fn {_, count} -> count end)
      |> Enum.sum()

    recent_bytes =
      entry.bytes
      |> Enum.filter(fn {time, _} -> time > cutoff end)
      |> Enum.map(fn {_, size} -> size end)
      |> Enum.sum()

    cond do
      recent_packets > config.max_packets_per_minute ->
        {:flood, "Too many packets: #{recent_packets}/min"}

      recent_bytes > config.max_bytes_per_minute ->
        {:flood, "Too many bytes: #{recent_bytes}/min"}

      true ->
        :ok
    end
  end

  defp ban_client(state, client_info, duration) do
    Process.send_after(self(), {:unban, client_info}, duration * 1000)

    new_blacklist =
      state.blacklist
      |> MapSet.put({:ip, client_info.ip})
      |> MapSet.put({:callsign, client_info.callsign})

    %{state | blacklist: new_blacklist}
  end

  @impl true
  def handle_info({:unban, client_info}, state) do
    new_blacklist =
      state.blacklist
      |> MapSet.delete({:ip, client_info.ip})
      |> MapSet.delete({:callsign, client_info.callsign})

    Logger.info("Unbanning #{client_info.callsign}")
    {:noreply, %{state | blacklist: new_blacklist}}
  end

  defp cleanup_old_entries(entries, cutoff) do
    Enum.filter(entries, fn {time, _} -> time > cutoff end)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: inspect(ip)

  defp schedule_cleanup do
    # Every minute
    Process.send_after(self(), :cleanup, 60_000)
  end

  @doc """
  Get current ACL statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      blacklisted_count: MapSet.size(state.blacklist),
      whitelisted_count: MapSet.size(state.whitelist),
      monitored_clients: map_size(state.rate_limits),
      flood_protection: state.flood_protection
    }

    {:reply, stats, state}
  end

  @doc """
  Update flood protection settings.
  """
  def update_flood_protection(settings) do
    GenServer.cast(__MODULE__, {:update_flood_protection, settings})
  end

  @impl true
  def handle_cast({:update_flood_protection, settings}, state) do
    new_flood_protection = Map.merge(state.flood_protection, settings)
    {:noreply, %{state | flood_protection: new_flood_protection}}
  end
end
