defmodule Aprstx.Config do
  @moduledoc """
  Configuration context for managing application settings in the database.
  """

  import Ecto.Query

  alias Aprstx.Configuration
  alias Aprstx.Repo

  @categories ["network", "station", "aprs", "digipeater", "igate", "beacon"]

  @doc """
  Get a configuration value by key.
  """
  def get(key) when is_binary(key) do
    case Repo.get_by(Configuration, key: key) do
      nil -> nil
      config -> config.value
    end
  end

  def get(key, default) when is_binary(key) do
    get(key) || default
  end

  @doc """
  Set a configuration value.
  """
  def set(key, value, category \\ "general") when is_binary(key) do
    case Repo.get_by(Configuration, key: key) do
      nil ->
        %Configuration{}
        |> Configuration.changeset(%{key: key, value: value, category: category})
        |> Repo.insert()

      config ->
        config
        |> Configuration.changeset(%{value: value, category: category})
        |> Repo.update()
    end
  end

  @doc """
  Get all configurations for a category.
  """
  def get_category(category) when category in @categories do
    Configuration
    |> where([c], c.category == ^category)
    |> Repo.all()
    |> Map.new(fn config -> {config.key, config.value} end)
  end

  @doc """
  Get all configurations.
  """
  def get_all do
    Configuration
    |> Repo.all()
    |> Map.new(fn config -> {config.key, config.value} end)
  end

  @doc """
  Check if the system is configured (has required settings).
  """
  def configured? do
    required_keys = ["callsign", "network_mode"]

    Enum.all?(required_keys, fn key -> get(key) != nil end)
  end

  @doc """
  Get the default configuration for initial setup.
  """
  def default_config do
    %{
      # Station settings
      "callsign" => %{"value" => "N0CALL", "ssid" => 0},
      "passcode" => %{"value" => "-1"},
      "location" => %{"latitude" => 0.0, "longitude" => 0.0, "altitude" => 0},
      "comment" => %{"value" => "Nerves APRS Station"},

      # Network settings
      "network_mode" => %{"value" => "dhcp"},
      "wifi_ssid" => %{"value" => ""},
      "wifi_password" => %{"value" => ""},
      "static_ip" => %{"value" => ""},
      "static_gateway" => %{"value" => ""},
      "static_dns" => %{"value" => "8.8.8.8"},

      # APRS settings
      "aprs_is_enabled" => %{"value" => true},
      "aprs_is_server" => %{"value" => "rotate.aprs2.net"},
      "aprs_is_port" => %{"value" => 14_580},
      "aprs_is_filter" => %{"value" => ""},

      # Digipeater settings
      "digipeater_enabled" => %{"value" => false},
      "digipeater_aliases" => %{"value" => ["WIDE1-1", "WIDE2-1"]},
      "digipeater_viscous_delay" => %{"value" => 5000},

      # iGate settings
      "igate_enabled" => %{"value" => true},
      "igate_gate_to_rf" => %{"value" => false},
      "igate_local_range" => %{"value" => 50},

      # Beacon settings
      "beacon_enabled" => %{"value" => true},
      "beacon_interval" => %{"value" => 1800},
      "beacon_symbol" => %{"value" => "/#"},
      "beacon_path" => %{"value" => ["WIDE1-1", "WIDE2-1"]},

      # RF settings
      "rf_enabled" => %{"value" => false},
      "kiss_tnc_type" => %{"value" => "serial"},
      "kiss_tnc_device" => %{"value" => "/dev/ttyUSB0"},
      "kiss_tnc_baud" => %{"value" => 9600}
    }
  end

  @doc """
  Load configuration from database and apply to running system.
  """
  def load_and_apply do
    if configured?() do
      config = get_all()

      # Apply network configuration if needed
      apply_network_config(config)

      # Apply APRS configuration
      apply_aprs_config(config)

      :ok
    else
      {:error, :not_configured}
    end
  end

  defp apply_network_config(config) do
    # Apply network settings through VintageNet
    case config["network_mode"]["value"] do
      "dhcp" ->
        VintageNet.configure("eth0", %{
          type: VintageNetEthernet,
          ipv4: %{method: :dhcp}
        })

      "static" ->
        VintageNet.configure("eth0", %{
          type: VintageNetEthernet,
          ipv4: %{
            method: :static,
            address: config["static_ip"]["value"],
            gateway: config["static_gateway"]["value"],
            name_servers: [config["static_dns"]["value"]]
          }
        })

      "wifi" ->
        VintageNet.configure("wlan0", %{
          type: VintageNetWiFi,
          vintage_net_wifi: %{
            networks: [
              %{
                key_mgmt: :wpa_psk,
                ssid: config["wifi_ssid"]["value"],
                psk: config["wifi_password"]["value"]
              }
            ]
          },
          ipv4: %{method: :dhcp}
        })
    end
  end

  defp apply_aprs_config(config) do
    # Update Aprx with new configuration
    aprx_config = %{
      callsign: config["callsign"]["value"],
      passcode: config["passcode"]["value"],
      location: config["location"],
      comment: config["comment"]["value"],
      aprs_is: %{
        enabled: config["aprs_is_enabled"]["value"],
        server: config["aprs_is_server"]["value"],
        port: config["aprs_is_port"]["value"],
        filter: config["aprs_is_filter"]["value"]
      },
      digipeater: %{
        enabled: config["digipeater_enabled"]["value"],
        aliases: config["digipeater_aliases"]["value"],
        viscous_delay: config["digipeater_viscous_delay"]["value"]
      },
      igate: %{
        enabled: config["igate_enabled"]["value"],
        gate_to_rf: config["igate_gate_to_rf"]["value"],
        local_range: config["igate_local_range"]["value"]
      },
      beacon: %{
        enabled: config["beacon_enabled"]["value"],
        interval: config["beacon_interval"]["value"],
        symbol: config["beacon_symbol"]["value"],
        path: config["beacon_path"]["value"]
      }
    }

    # Send configuration to Aprx process if it's running
    if Process.whereis(Aprstx.Aprx) do
      GenServer.cast(Aprstx.Aprx, {:update_config, aprx_config})
    end
  end

  @doc """
  Save wizard configuration from form data.
  """
  def save_wizard_config(params) do
    Repo.transaction(fn ->
      # Network settings
      set("network_mode", %{"value" => params["network_mode"]}, "network")

      if params["network_mode"] == "wifi" do
        set("wifi_ssid", %{"value" => params["wifi_ssid"]}, "network")
        set("wifi_password", %{"value" => params["wifi_password"]}, "network")
      end

      if params["network_mode"] == "static" do
        set("static_ip", %{"value" => params["static_ip"]}, "network")
        set("static_gateway", %{"value" => params["static_gateway"]}, "network")
        set("static_dns", %{"value" => params["static_dns"]}, "network")
      end

      # Station settings
      set("callsign", %{"value" => params["callsign"], "ssid" => params["ssid"] || 0}, "station")
      set("passcode", %{"value" => params["passcode"]}, "station")

      set(
        "location",
        %{
          "latitude" => String.to_float(params["latitude"] || "0"),
          "longitude" => String.to_float(params["longitude"] || "0"),
          "altitude" => String.to_integer(params["altitude"] || "0")
        },
        "station"
      )

      set("comment", %{"value" => params["comment"]}, "station")

      # APRS settings
      set("aprs_is_enabled", %{"value" => params["aprs_is_enabled"] == "true"}, "aprs")
      set("aprs_is_server", %{"value" => params["aprs_is_server"]}, "aprs")
      set("aprs_is_port", %{"value" => String.to_integer(params["aprs_is_port"] || "14580")}, "aprs")

      # Digipeater settings
      set("digipeater_enabled", %{"value" => params["digipeater_enabled"] == "true"}, "digipeater")

      # iGate settings  
      set("igate_enabled", %{"value" => params["igate_enabled"] == "true"}, "igate")
      set("igate_gate_to_rf", %{"value" => params["gate_to_rf"] == "true"}, "igate")

      # Beacon settings
      set("beacon_enabled", %{"value" => params["beacon_enabled"] == "true"}, "beacon")
      set("beacon_interval", %{"value" => String.to_integer(params["beacon_interval"] || "1800")}, "beacon")
      set("beacon_symbol", %{"value" => params["beacon_symbol"]}, "beacon")

      # RF settings
      set("rf_enabled", %{"value" => params["rf_enabled"] == "true"}, "rf")

      if params["rf_enabled"] == "true" do
        set("kiss_tnc_type", %{"value" => params["kiss_tnc_type"]}, "rf")
        set("kiss_tnc_device", %{"value" => params["kiss_tnc_device"]}, "rf")
        set("kiss_tnc_baud", %{"value" => String.to_integer(params["kiss_tnc_baud"] || "9600")}, "rf")
      end
    end)

    # Apply the new configuration
    load_and_apply()
  end
end
