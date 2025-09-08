defmodule AprstxWeb.SetupWizardLive do
  @moduledoc false
  use AprstxWeb, :live_view

  alias Aprstx.Config

  @impl true
  def mount(_params, _session, socket) do
    # Check if already configured
    if Config.configured?() do
      {:ok, push_navigate(socket, to: "/")}
    else
      {:ok,
       socket
       |> assign(:step, 1)
       |> assign(:max_steps, 5)
       |> assign(:form_data, %{})
       |> assign(:errors, %{})
       |> assign_form()}
    end
  end

  defp assign_form(socket) do
    form =
      to_form(%{
        # Network
        "network_mode" => "dhcp",
        "wifi_ssid" => "",
        "wifi_password" => "",
        "static_ip" => "",
        "static_gateway" => "",
        "static_dns" => "8.8.8.8",

        # Station
        "callsign" => "",
        "ssid" => "0",
        "passcode" => "-1",
        "latitude" => "",
        "longitude" => "",
        "altitude" => "0",
        "comment" => "Nerves APRS Station",

        # APRS-IS
        "aprs_is_enabled" => "true",
        "aprs_is_server" => "rotate.aprs2.net",
        "aprs_is_port" => "14580",

        # Features
        "digipeater_enabled" => "false",
        "igate_enabled" => "true",
        "gate_to_rf" => "false",
        "beacon_enabled" => "true",
        "beacon_interval" => "1800",
        "beacon_symbol" => "/#",

        # RF
        "rf_enabled" => "false",
        "kiss_tnc_type" => "serial",
        "kiss_tnc_device" => "/dev/ttyUSB0",
        "kiss_tnc_baud" => "9600"
      })

    assign(socket, :form, form)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-100 py-12 px-4 sm:px-6 lg:px-8">
      <div class="max-w-3xl mx-auto">
        <div class="bg-white shadow-xl rounded-lg">
          <div class="px-6 py-4 border-b border-gray-200">
            <h1 class="text-2xl font-bold text-gray-900">APRS Station Setup Wizard</h1>
            <div class="mt-4">
              <div class="flex items-center">
                <%= for step_num <- 1..@max_steps do %>
                  <div class={[
                    "flex items-center",
                    if(step_num > 1, do: "ml-4", else: "")
                  ]}>
                    <div class={[
                      "rounded-full h-8 w-8 flex items-center justify-center text-sm",
                      if(step_num < @step, do: "bg-green-500 text-white", 
                        else: if(step_num == @step, do: "bg-blue-500 text-white", 
                        else: "bg-gray-300 text-gray-600"))
                    ]}>
                      <%= if step_num < @step do %>
                        ✓
                      <% else %>
                        <%= step_num %>
                      <% end %>
                    </div>
                    <%= if step_num < @max_steps do %>
                      <div class="w-12 h-0.5 bg-gray-300 ml-2"></div>
                    <% end %>
                  </div>
                <% end %>
              </div>
              <div class="mt-2 text-sm text-gray-600">
                Step <%= @step %> of <%= @max_steps %>: <%= step_title(@step) %>
              </div>
            </div>
          </div>
          
          <.form for={@form} phx-change="validate" phx-submit="next_step" class="px-6 py-4">
            <%= case @step do %>
              <% 1 -> %>
                <.network_step form={@form} />
              <% 2 -> %>
                <.station_step form={@form} errors={@errors} />
              <% 3 -> %>
                <.aprs_step form={@form} />
              <% 4 -> %>
                <.features_step form={@form} />
              <% 5 -> %>
                <.review_step form={@form} />
            <% end %>
            
            <div class="mt-6 flex justify-between">
              <%= if @step > 1 do %>
                <button type="button" phx-click="prev_step" 
                  class="px-4 py-2 border border-gray-300 rounded-md text-gray-700 bg-white hover:bg-gray-50">
                  Previous
                </button>
              <% else %>
                <div></div>
              <% end %>
              
              <%= if @step < @max_steps do %>
                <button type="submit" 
                  class="px-4 py-2 border border-transparent rounded-md shadow-sm text-white bg-blue-600 hover:bg-blue-700">
                  Next
                </button>
              <% else %>
                <button type="button" phx-click="finish" 
                  class="px-4 py-2 border border-transparent rounded-md shadow-sm text-white bg-green-600 hover:bg-green-700">
                  Complete Setup
                </button>
              <% end %>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  defp network_step(assigns) do
    ~H"""
    <div class="space-y-4">
      <h2 class="text-lg font-medium text-gray-900">Network Configuration</h2>
      
      <div>
        <label class="block text-sm font-medium text-gray-700">Network Mode</label>
        <select name="network_mode" value={@form.params["network_mode"]} 
          class="mt-1 block w-full rounded-md border-gray-300 shadow-sm">
          <option value="dhcp">DHCP (Automatic)</option>
          <option value="static">Static IP</option>
          <option value="wifi">WiFi</option>
        </select>
      </div>
      
      <%= if @form.params["network_mode"] == "wifi" do %>
        <div>
          <label class="block text-sm font-medium text-gray-700">WiFi SSID</label>
          <input type="text" name="wifi_ssid" value={@form.params["wifi_ssid"]}
            class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
        </div>
        
        <div>
          <label class="block text-sm font-medium text-gray-700">WiFi Password</label>
          <input type="password" name="wifi_password" value={@form.params["wifi_password"]}
            class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
        </div>
      <% end %>
      
      <%= if @form.params["network_mode"] == "static" do %>
        <div>
          <label class="block text-sm font-medium text-gray-700">IP Address</label>
          <input type="text" name="static_ip" value={@form.params["static_ip"]}
            placeholder="192.168.1.100"
            class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
        </div>
        
        <div>
          <label class="block text-sm font-medium text-gray-700">Gateway</label>
          <input type="text" name="static_gateway" value={@form.params["static_gateway"]}
            placeholder="192.168.1.1"
            class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
        </div>
        
        <div>
          <label class="block text-sm font-medium text-gray-700">DNS Server</label>
          <input type="text" name="static_dns" value={@form.params["static_dns"]}
            placeholder="8.8.8.8"
            class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
        </div>
      <% end %>
    </div>
    """
  end

  defp station_step(assigns) do
    ~H"""
    <div class="space-y-4">
      <h2 class="text-lg font-medium text-gray-900">Station Information</h2>
      
      <div>
        <label class="block text-sm font-medium text-gray-700">Callsign *</label>
        <input type="text" name="callsign" value={@form.params["callsign"]}
          placeholder="N0CALL"
          class="mt-1 block w-full rounded-md border-gray-300 shadow-sm uppercase" />
        <%= if @errors[:callsign] do %>
          <p class="mt-1 text-sm text-red-600"><%= @errors[:callsign] %></p>
        <% end %>
      </div>
      
      <div>
        <label class="block text-sm font-medium text-gray-700">SSID</label>
        <select name="ssid" value={@form.params["ssid"]}
          class="mt-1 block w-full rounded-md border-gray-300 shadow-sm">
          <%= for i <- 0..15 do %>
            <option value={i}><%= i %> <%= ssid_description(i) %></option>
          <% end %>
        </select>
      </div>
      
      <div>
        <label class="block text-sm font-medium text-gray-700">APRS-IS Passcode</label>
        <input type="text" name="passcode" value={@form.params["passcode"]}
          placeholder="-1"
          class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
        <p class="mt-1 text-sm text-gray-500">Leave as -1 for receive-only</p>
      </div>
      
      <div class="grid grid-cols-2 gap-4">
        <div>
          <label class="block text-sm font-medium text-gray-700">Latitude</label>
          <input type="text" name="latitude" value={@form.params["latitude"]}
            placeholder="40.7128"
            class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
        </div>
        
        <div>
          <label class="block text-sm font-medium text-gray-700">Longitude</label>
          <input type="text" name="longitude" value={@form.params["longitude"]}
            placeholder="-74.0060"
            class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
        </div>
      </div>
      
      <div>
        <label class="block text-sm font-medium text-gray-700">Altitude (meters)</label>
        <input type="text" name="altitude" value={@form.params["altitude"]}
          placeholder="0"
          class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
      </div>
      
      <div>
        <label class="block text-sm font-medium text-gray-700">Station Comment</label>
        <input type="text" name="comment" value={@form.params["comment"]}
          placeholder="Nerves APRS Station"
          class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
      </div>
    </div>
    """
  end

  defp aprs_step(assigns) do
    ~H"""
    <div class="space-y-4">
      <h2 class="text-lg font-medium text-gray-900">APRS-IS Connection</h2>
      
      <div>
        <label class="flex items-center">
          <input type="checkbox" name="aprs_is_enabled" value="true"
            checked={@form.params["aprs_is_enabled"] == "true"}
            class="rounded border-gray-300 text-blue-600 shadow-sm" />
          <span class="ml-2">Connect to APRS-IS Internet Service</span>
        </label>
      </div>
      
      <%= if @form.params["aprs_is_enabled"] == "true" do %>
        <div>
          <label class="block text-sm font-medium text-gray-700">APRS-IS Server</label>
          <select name="aprs_is_server" value={@form.params["aprs_is_server"]}
            class="mt-1 block w-full rounded-md border-gray-300 shadow-sm">
            <option value="rotate.aprs2.net">rotate.aprs2.net (Worldwide)</option>
            <option value="noam.aprs2.net">noam.aprs2.net (North America)</option>
            <option value="euro.aprs2.net">euro.aprs2.net (Europe)</option>
            <option value="asia.aprs2.net">asia.aprs2.net (Asia)</option>
            <option value="aunz.aprs2.net">aunz.aprs2.net (Oceania)</option>
            <option value="soam.aprs2.net">soam.aprs2.net (South America)</option>
          </select>
        </div>
        
        <div>
          <label class="block text-sm font-medium text-gray-700">Port</label>
          <input type="text" name="aprs_is_port" value={@form.params["aprs_is_port"]}
            class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
        </div>
      <% end %>
      
      <div class="mt-6">
        <h3 class="text-md font-medium text-gray-900">RF Configuration</h3>
        
        <div class="mt-2">
          <label class="flex items-center">
            <input type="checkbox" name="rf_enabled" value="true"
              checked={@form.params["rf_enabled"] == "true"}
              class="rounded border-gray-300 text-blue-600 shadow-sm" />
            <span class="ml-2">Enable RF (Radio) Support</span>
          </label>
        </div>
        
        <%= if @form.params["rf_enabled"] == "true" do %>
          <div class="mt-4 space-y-4 ml-6">
            <div>
              <label class="block text-sm font-medium text-gray-700">KISS TNC Type</label>
              <select name="kiss_tnc_type" value={@form.params["kiss_tnc_type"]}
                class="mt-1 block w-full rounded-md border-gray-300 shadow-sm">
                <option value="serial">Serial (USB)</option>
                <option value="tcp">TCP/IP</option>
              </select>
            </div>
            
            <%= if @form.params["kiss_tnc_type"] == "serial" do %>
              <div>
                <label class="block text-sm font-medium text-gray-700">Device</label>
                <input type="text" name="kiss_tnc_device" value={@form.params["kiss_tnc_device"]}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
              </div>
              
              <div>
                <label class="block text-sm font-medium text-gray-700">Baud Rate</label>
                <select name="kiss_tnc_baud" value={@form.params["kiss_tnc_baud"]}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm">
                  <option value="1200">1200</option>
                  <option value="9600">9600</option>
                  <option value="19200">19200</option>
                  <option value="38400">38400</option>
                  <option value="57600">57600</option>
                  <option value="115200">115200</option>
                </select>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp features_step(assigns) do
    ~H"""
    <div class="space-y-4">
      <h2 class="text-lg font-medium text-gray-900">Station Features</h2>
      
      <div class="space-y-4">
        <div class="border rounded-lg p-4">
          <label class="flex items-center">
            <input type="checkbox" name="igate_enabled" value="true"
              checked={@form.params["igate_enabled"] == "true"}
              class="rounded border-gray-300 text-blue-600 shadow-sm" />
            <span class="ml-2 font-medium">Enable iGate</span>
          </label>
          <p class="mt-1 ml-6 text-sm text-gray-500">
            Gateway RF packets to APRS-IS Internet service
          </p>
          
          <%= if @form.params["igate_enabled"] == "true" && @form.params["rf_enabled"] == "true" do %>
            <div class="mt-3 ml-6">
              <label class="flex items-center">
                <input type="checkbox" name="gate_to_rf" value="true"
                  checked={@form.params["gate_to_rf"] == "true"}
                  class="rounded border-gray-300 text-blue-600 shadow-sm" />
                <span class="ml-2 text-sm">Gate messages from Internet to RF</span>
              </label>
              <p class="mt-1 ml-6 text-xs text-orange-600">
                ⚠ Only enable if you understand the implications
              </p>
            </div>
          <% end %>
        </div>
        
        <div class="border rounded-lg p-4">
          <label class="flex items-center">
            <input type="checkbox" name="digipeater_enabled" value="true"
              checked={@form.params["digipeater_enabled"] == "true"}
              disabled={@form.params["rf_enabled"] != "true"}
              class="rounded border-gray-300 text-blue-600 shadow-sm disabled:opacity-50" />
            <span class="ml-2 font-medium">Enable Digipeater</span>
          </label>
          <p class="mt-1 ml-6 text-sm text-gray-500">
            Repeat packets on RF for other stations (requires RF)
          </p>
        </div>
        
        <div class="border rounded-lg p-4">
          <label class="flex items-center">
            <input type="checkbox" name="beacon_enabled" value="true"
              checked={@form.params["beacon_enabled"] == "true"}
              class="rounded border-gray-300 text-blue-600 shadow-sm" />
            <span class="ml-2 font-medium">Enable Beaconing</span>
          </label>
          <p class="mt-1 ml-6 text-sm text-gray-500">
            Periodically transmit your station's position
          </p>
          
          <%= if @form.params["beacon_enabled"] == "true" do %>
            <div class="mt-3 ml-6 space-y-3">
              <div>
                <label class="block text-sm font-medium text-gray-700">Interval (seconds)</label>
                <input type="text" name="beacon_interval" value={@form.params["beacon_interval"]}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm" />
              </div>
              
              <div>
                <label class="block text-sm font-medium text-gray-700">Symbol</label>
                <select name="beacon_symbol" value={@form.params["beacon_symbol"]}
                  class="mt-1 block w-full rounded-md border-gray-300 shadow-sm">
                  <option value="/#">Digi (#)</option>
                  <option value="/&">Gateway (&)</option>
                  <option value="/-">House (-)</option>
                  <option value="/r">Repeater (r)</option>
                  <option value="/i">Internet (i)</option>
                </select>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp review_step(assigns) do
    ~H"""
    <div class="space-y-4">
      <h2 class="text-lg font-medium text-gray-900">Review Configuration</h2>
      
      <div class="bg-gray-50 rounded-lg p-4 space-y-3">
        <div>
          <h3 class="font-medium text-gray-900">Network</h3>
          <p class="text-sm text-gray-600">
            Mode: <%= String.capitalize(@form.params["network_mode"]) %>
            <%= if @form.params["network_mode"] == "wifi" do %>
              (SSID: <%= @form.params["wifi_ssid"] %>)
            <% end %>
          </p>
        </div>
        
        <div>
          <h3 class="font-medium text-gray-900">Station</h3>
          <p class="text-sm text-gray-600">
            Callsign: <%= @form.params["callsign"] %>-<%= @form.params["ssid"] %><br/>
            Location: <%= @form.params["latitude"] %>, <%= @form.params["longitude"] %>
          </p>
        </div>
        
        <div>
          <h3 class="font-medium text-gray-900">Services</h3>
          <ul class="text-sm text-gray-600">
            <%= if @form.params["aprs_is_enabled"] == "true" do %>
              <li>✓ APRS-IS Connection</li>
            <% end %>
            <%= if @form.params["rf_enabled"] == "true" do %>
              <li>✓ RF Support</li>
            <% end %>
            <%= if @form.params["igate_enabled"] == "true" do %>
              <li>✓ iGate</li>
            <% end %>
            <%= if @form.params["digipeater_enabled"] == "true" do %>
              <li>✓ Digipeater</li>
            <% end %>
            <%= if @form.params["beacon_enabled"] == "true" do %>
              <li>✓ Beaconing</li>
            <% end %>
          </ul>
        </div>
      </div>
      
      <div class="bg-blue-50 border border-blue-200 rounded-lg p-4">
        <p class="text-sm text-blue-800">
          Click "Complete Setup" to save this configuration and restart services.
        </p>
      </div>
      
      <script>
        window.addEventListener("phx:reboot_countdown", (e) => {
          let seconds = e.detail.seconds;
          const countdown = setInterval(() => {
            seconds--;
            if (seconds <= 0) {
              clearInterval(countdown);
              // Trigger reboot via API
              fetch('/api/reboot', {method: 'POST'});
            }
          }, 1000);
        });
      </script>
    </div>
    """
  end

  @impl true
  def handle_event("validate", params, socket) do
    socket =
      socket
      |> assign(:form, to_form(params))
      |> validate_step(params)

    {:noreply, socket}
  end

  @impl true
  def handle_event("next_step", params, socket) do
    socket = assign(socket, :form, to_form(params))

    if valid_step?(socket.assigns.step, params) do
      {:noreply, assign(socket, :step, socket.assigns.step + 1)}
    else
      {:noreply, socket |> validate_step(params) |> put_flash(:error, "Please fix the errors below")}
    end
  end

  @impl true
  def handle_event("prev_step", _params, socket) do
    {:noreply, assign(socket, :step, socket.assigns.step - 1)}
  end

  @impl true
  def handle_event("finish", _params, socket) do
    params = socket.assigns.form.params

    case Config.save_wizard_config(params) do
      {:ok, _} ->
        # If we're in WiFi setup mode, trigger a reboot to apply network config
        if Process.whereis(Aprstx.WifiSetup) && Mix.target() != :host do
          {:noreply,
           socket
           |> put_flash(:info, "Configuration saved! Device will reboot in 5 seconds...")
           |> push_event("reboot_countdown", %{seconds: 5})}
        else
          # Just restart Aprx with new configuration
          if Process.whereis(Aprstx.Aprx) do
            GenServer.stop(Aprstx.Aprx)
            # Supervisor will restart it with new config
          end

          {:noreply,
           socket
           |> put_flash(:info, "Configuration saved successfully!")
           |> push_navigate(to: "/")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save configuration: #{inspect(reason)}")}
    end
  end

  defp validate_step(socket, params) do
    errors =
      case socket.assigns.step do
        2 -> validate_station(params)
        _ -> %{}
      end

    assign(socket, :errors, errors)
  end

  defp valid_step?(step, params) do
    case step do
      2 -> validate_station(params) == %{}
      _ -> true
    end
  end

  defp validate_station(params) do
    errors = %{}

    errors =
      if params["callsign"] == "" or not Regex.match?(~r/^[A-Z0-9]{3,}$/, String.upcase(params["callsign"] || "")) do
        Map.put(errors, :callsign, "Invalid callsign format")
      else
        errors
      end

    errors
  end

  defp step_title(step) do
    case step do
      1 -> "Network Setup"
      2 -> "Station Information"
      3 -> "APRS Connection"
      4 -> "Features"
      5 -> "Review"
    end
  end

  defp ssid_description(ssid) do
    case ssid do
      0 -> "(Primary station)"
      1 -> "(Generic additional station)"
      2 -> "(Generic additional station)"
      3 -> "(Generic additional station)"
      4 -> "(Generic additional station)"
      5 -> "(Other network)"
      6 -> "(Special activity)"
      7 -> "(Walkie-talkie/HT)"
      8 -> "(Boats/Maritime mobile)"
      9 -> "(Primary mobile)"
      10 -> "(Internet, iGate, echolink)"
      11 -> "(Balloon, aircraft)"
      12 -> "(APRStt, DTMF, RFID)"
      13 -> "(Weather station)"
      14 -> "(Truckers)"
      15 -> "(Generic additional station)"
      _ -> ""
    end
  end
end
