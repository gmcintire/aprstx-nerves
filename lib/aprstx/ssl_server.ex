defmodule Aprstx.SslServer do
  @moduledoc """
  SSL/TLS server for secure APRS-IS connections.
  """
  use GenServer

  require Logger

  defstruct [
    :port,
    :listen_socket,
    :ssl_opts,
    :clients
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 24_580)

    ssl_opts = [
      :binary,
      packet: :line,
      active: false,
      reuseaddr: true,
      certfile: Keyword.get(opts, :certfile, "priv/cert.pem"),
      keyfile: Keyword.get(opts, :keyfile, "priv/key.pem"),
      # Can be :verify_peer for client certs
      verify: :verify_none,
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]

    state = %__MODULE__{
      port: port,
      ssl_opts: ssl_opts,
      clients: %{}
    }

    {:ok, state, {:continue, :start_listening}}
  end

  @impl true
  def handle_continue(:start_listening, state) do
    case :ssl.listen(state.port, state.ssl_opts) do
      {:ok, listen_socket} ->
        Logger.info("SSL/TLS server listening on port #{state.port}")
        spawn_link(fn -> accept_loop(listen_socket, state.ssl_opts) end)
        {:noreply, %{state | listen_socket: listen_socket}}

      {:error, reason} ->
        Logger.error("Failed to start SSL server: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  defp accept_loop(listen_socket, ssl_opts) do
    case :ssl.transport_accept(listen_socket) do
      {:ok, transport_socket} ->
        case :ssl.handshake(transport_socket, ssl_opts, 5000) do
          {:ok, socket} ->
            send(__MODULE__, {:new_ssl_client, socket})

          {:error, reason} ->
            Logger.warning("SSL handshake failed: #{inspect(reason)}")
        end

        accept_loop(listen_socket, ssl_opts)

      {:error, reason} ->
        Logger.error("SSL accept error: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_info({:new_ssl_client, socket}, state) do
    {:ok, {ip, port}} = :ssl.peername(socket)
    client_id = generate_client_id()

    client = %{
      id: client_id,
      socket: socket,
      ip: ip,
      port: port,
      connected_at: DateTime.utc_now(),
      authenticated: false,
      ssl: true
    }

    Logger.info("New SSL client connected: #{format_ip(ip)}:#{port}")

    Task.start_link(fn -> handle_ssl_client(socket, client_id) end)

    new_state = put_in(state.clients[client_id], client)
    {:noreply, new_state}
  end

  defp handle_ssl_client(socket, client_id) do
    send_server_banner(socket)

    case :ssl.recv(socket, 0, 30_000) do
      {:ok, data} ->
        # Forward to main server for processing
        send(Aprstx.Server, {:client_data, client_id, data})
        handle_ssl_client(socket, client_id)

      {:error, :closed} ->
        send(Aprstx.Server, {:client_disconnected, client_id})

      {:error, reason} ->
        Logger.error("SSL client error: #{inspect(reason)}")
        send(Aprstx.Server, {:client_disconnected, client_id})
    end
  end

  defp send_server_banner(socket) do
    banner = "# aprsc-elixir 1.0.0 (SSL)\r\n"
    :ssl.send(socket, banner)
  end

  defp generate_client_id do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16()
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(ip), do: inspect(ip)

  @doc """
  Generate self-signed certificate for testing.
  """
  def generate_self_signed_cert do
    # Generate private key
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})

    # Certificate validity
    validity = {
      :utcTime,
      to_charlist("230101000000Z"),
      :utcTime,
      to_charlist("251231235959Z")
    }

    # Certificate subject
    subject = {
      :rdnSequence,
      [
        [{:AttributeTypeAndValue, {2, 5, 4, 6}, "US"}],
        [{:AttributeTypeAndValue, {2, 5, 4, 8}, "State"}],
        [{:AttributeTypeAndValue, {2, 5, 4, 7}, "City"}],
        [{:AttributeTypeAndValue, {2, 5, 4, 10}, "APRSTX"}],
        [{:AttributeTypeAndValue, {2, 5, 4, 3}, "localhost"}]
      ]
    }

    # Create certificate
    cert =
      :public_key.pkix_sign(
        {:OTPCertificate,
         {:OTPTBSCertificate, :v3, 1, {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 11}, :asn1_NOVALUE}, subject,
          validity, subject,
          {:OTPSubjectPublicKeyInfo, {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 1}, :asn1_NOVALUE}, private_key},
          :asn1_NOVALUE, :asn1_NOVALUE, []}, {:AlgorithmIdentifier, {1, 2, 840, 113_549, 1, 1, 11}, :asn1_NOVALUE},
         <<>>},
        private_key
      )

    # Save to files
    cert_pem = :public_key.pem_encode([{:Certificate, cert}])
    key_pem = :public_key.pem_encode([{:RSAPrivateKey, private_key}])

    File.mkdir_p!("priv")
    File.write!("priv/cert.pem", cert_pem)
    File.write!("priv/key.pem", key_pem)

    Logger.info("Generated self-signed certificate in priv/")
    :ok
  end
end
