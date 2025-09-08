defmodule Aprstx.WifiSetup do
  @moduledoc """
  Handles initial WiFi setup by creating an access point with captive portal.
  """
  use GenServer

  require Logger

  @ap_ssid "aprstx"
  # Default password for AP
  @ap_psk "aprstx123"
  @ap_ip "192.168.4.1"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Check if we need to enter setup mode
    state = %{
      setup_mode: should_enter_setup_mode?(),
      configured: false
    }

    if state.setup_mode do
      Logger.info("Entering WiFi setup mode - starting access point")
      start_access_point()
    end

    {:ok, state}
  end

  @doc """
  Check if we should enter WiFi setup mode.
  Returns true if:
  - No network configuration exists
  - Reset button was held during boot
  - WiFi credentials are invalid/can't connect
  """
  def should_enter_setup_mode? do
    cond do
      # Check if configuration exists
      not Aprstx.Config.configured?() ->
        true

      # Check for setup mode file (created by reset button handler)
      File.exists?("/data/wifi_setup_mode") ->
        File.rm("/data/wifi_setup_mode")
        true

      # Check if we've failed to connect multiple times
      check_connection_failures() ->
        true

      true ->
        false
    end
  end

  defp check_connection_failures do
    # Check if we've failed to connect to WiFi multiple times
    case File.read("/data/wifi_failures") do
      {:ok, content} ->
        failures = String.to_integer(String.trim(content))
        failures >= 3

      _ ->
        false
    end
  end

  @doc """
  Start WiFi access point for configuration.
  """
  def start_access_point do
    if Code.ensure_loaded?(VintageNet) do
      # Configure WiFi interface as access point
      config = %{
        type: VintageNetWiFi,
        vintage_net_wifi: %{
          networks: [
            %{
              mode: :ap,
              ssid: @ap_ssid,
              psk: @ap_psk,
              key_mgmt: :wpa_psk
            }
          ]
        },
        ipv4: %{
          method: :static,
          address: @ap_ip,
          netmask: "255.255.255.0"
        },
        dhcpd: %{
          # DHCP server configuration for AP mode
          start: "192.168.4.2",
          end: "192.168.4.100",
          options: %{
            dns: [@ap_ip],
            router: [@ap_ip]
          }
        }
      }

      apply(VintageNet, :configure, ["wlan0", config])

      # Start DNS server for captive portal
      start_captive_portal_dns()

      Logger.info("WiFi Access Point started: SSID=#{@ap_ssid}")
      Logger.info("Connect to http://#{@ap_ip} or http://setup.local")
    else
      Logger.warning("VintageNet not available - skipping AP setup")
    end
  end

  @doc """
  Start DNS server that redirects all requests to our IP (captive portal).
  """
  def start_captive_portal_dns do
    # Start a simple DNS server that responds with our IP to all queries
    Task.start(fn ->
      {:ok, socket} = :gen_udp.open(53, [:binary, active: true, reuseaddr: true])
      dns_loop(socket)
    end)
  end

  defp dns_loop(socket) do
    receive do
      {:udp, _socket, ip, port, packet} ->
        # Parse DNS query and respond with our IP
        response = build_dns_response(packet, @ap_ip)
        :gen_udp.send(socket, ip, port, response)
        dns_loop(socket)
    end
  end

  defp build_dns_response(query, ip_str) do
    # Basic DNS response builder
    # This is simplified - real implementation would parse the query properly
    <<
      # Copy transaction ID from query
      query::binary-size(2),
      # Flags: standard query response, no error
      0x81,
      0x80,
      # Questions: 1
      0x00,
      0x01,
      # Answer RRs: 1
      0x00,
      0x01,
      # Authority RRs: 0
      0x00,
      0x00,
      # Additional RRs: 0
      0x00,
      0x00,
      # Copy the question section (simplified)
      query::binary-size(byte_size(query) - 2),
      # Answer: Type A, Class IN, TTL 300
      # Pointer to domain name
      0xC0,
      0x0C,
      # Type A
      0x00,
      0x01,
      # Class IN
      0x00,
      0x01,
      # TTL: 300 seconds
      0x00,
      0x00,
      0x01,
      0x2C,
      # Data length: 4 bytes
      0x00,
      0x04,
      # IP address
      ip_to_bytes(ip_str)::binary
    >>
  end

  defp ip_to_bytes(ip_str) do
    ip_str
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> :binary.list_to_bin()
  end

  @doc """
  Apply network configuration and reboot to client mode.
  """
  def apply_config_and_reboot(params) do
    GenServer.call(__MODULE__, {:apply_config, params})
  end

  @impl true
  def handle_call({:apply_config, params}, _from, state) do
    Logger.info("Applying network configuration and preparing to reboot")

    # Save the configuration
    case Aprstx.Config.save_wizard_config(params) do
      {:ok, _} ->
        # Clear any failure counts
        File.rm("/data/wifi_failures")

        # Schedule reboot in 2 seconds
        Task.start(fn ->
          Process.sleep(2000)
          Logger.info("Rebooting to apply network configuration...")
          System.cmd("reboot", [])
        end)

        {:reply, :ok, %{state | configured: true}}

      error ->
        {:reply, error, state}
    end
  end

  @doc """
  Reset to setup mode (called when reset button is pressed).
  """
  def reset_to_setup_mode do
    # Create marker file
    File.write!("/data/wifi_setup_mode", "1")
    # Reboot
    System.cmd("reboot", [])
  end

  @doc """
  Increment WiFi connection failure counter.
  """
  def record_wifi_failure do
    current =
      case File.read("/data/wifi_failures") do
        {:ok, content} -> String.to_integer(String.trim(content))
        _ -> 0
      end

    File.write!("/data/wifi_failures", to_string(current + 1))

    if current + 1 >= 3 do
      Logger.warning("WiFi connection failed 3 times, entering setup mode on next boot")
    end
  end

  @doc """
  Clear WiFi failure counter (called on successful connection).
  """
  def clear_wifi_failures do
    File.rm("/data/wifi_failures")
  end
end
