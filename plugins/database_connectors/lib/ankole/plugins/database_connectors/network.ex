defmodule Ankole.Plugins.DatabaseConnectors.Network do
  @moduledoc """
  Resolves a connection's database endpoint under the tenant's
  `security.ssrf_filter` policy, the same check that `Ankole.Files.HTTP`
  applies to URL fetches.

  Every resolved address must pass `Ankole.Kernel.validate_ip_addresses/2`
  before a connect, and the driver connects to that validated address, so a
  DNS answer that changes between the check and the connect cannot redirect
  the session. TLS keeps the configured host name for SNI and certificate
  verification.

  The PostgreSQL and MySQL connection pools exit without the reason when a TLS
  handshake fails. A session therefore creates a failure table with
  `tls_failures/0` and passes it to `ssl_options/2`. In `verify` mode, the
  certificate check writes its failure into that table before it rejects the
  handshake, and `tls_failure/2` turns the session exit into a
  `database_unavailable` error that names the failed check. The write finishes
  before the handshake fails, so the session always finds it.
  """

  @tls_modes ~w(verify require disable)

  def tls_modes, do: @tls_modes

  @doc "Builds the driver endpoint from the connection's public metadata and secret."
  def endpoint(config, secret, default_port) do
    metadata = Map.merge(config.public_metadata || %{}, secret)
    host = String.trim(to_string(metadata["host"] || ""))

    with {:ok, port} <- port(metadata["port"], default_port),
         {:ok, address} <- resolve(host, port) do
      {:ok,
       %{
         host: host,
         address: address,
         port: port,
         database: blank(metadata["database"]),
         username: to_string(metadata["username"] || ""),
         password: to_string(metadata["password"] || ""),
         tls: if(metadata["tls_mode"] in @tls_modes, do: metadata["tls_mode"], else: "verify"),
         ca_certificate: blank(metadata["ca_certificate"])
       }}
    end
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: to_string(value)

  defp port(nil, default), do: {:ok, default}
  defp port("", default), do: {:ok, default}
  defp port(port, _default) when is_integer(port) and port in 1..65_535, do: {:ok, port}

  defp port(port, default) when is_binary(port) do
    case Integer.parse(String.trim(port)) do
      {value, ""} -> port(value, default)
      _ -> {:error, invalid("The port must be a number from 1 to 65535.")}
    end
  end

  defp port(_, _), do: {:error, invalid("The port must be a number from 1 to 65535.")}

  @doc "Resolves `host` and returns one address that the SSRF policy allows."
  def resolve("", _port), do: {:error, invalid("The connection has no host.")}

  def resolve(host, port) do
    {:ok, filter} = Ankole.Security.SSRFFilter.enabled?()
    url_host = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host

    addresses =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, address} ->
          [address]

        _ ->
          Enum.flat_map([:inet, :inet6], fn family ->
            case :inet.getaddrs(String.to_charlist(host), family) do
              {:ok, addresses} -> addresses
              _ -> []
            end
          end)
      end

    with :ok <-
           Ankole.Kernel.validate_web_url("http://#{url_host}:#{port}/", ["http"], filter),
         [first | _] <- addresses,
         :ok <-
           Ankole.Kernel.validate_ip_addresses(
             Enum.map(addresses, &to_string(:inet.ntoa(&1))),
             filter
           ) do
      {:ok, to_string(:inet.ntoa(first))}
    else
      [] ->
        {:error,
         %{
           code: "database_host_unresolved",
           message: "The host name did not resolve.",
           retryable: true
         }}

      {:error, reason} ->
        {:error,
         %{
           code: "database_host_blocked",
           message: "The network policy rejects this database address.",
           reason: inspect(reason),
           retryable: false
         }}
    end
  end

  @doc """
  TLS client options that verify the configured host name, not the resolved
  address. With a `failures` table from `tls_failures/0`, the certificate check
  records why it rejected the server.
  """
  def ssl_options(endpoint, failures \\ nil)
  def ssl_options(%{tls: "disable"}, _failures), do: false
  def ssl_options(%{tls: "require"}, _failures), do: [verify: :verify_none]

  def ssl_options(%{tls: "verify"} = endpoint, failures) do
    [
      verify: :verify_peer,
      cacerts: cacerts(endpoint.ca_certificate),
      # OTP checks the certificate against this name, or against the address
      # when the host is an IP literal; `:disable` would skip that check.
      server_name_indication: String.to_charlist(endpoint.host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ] ++ if(failures, do: [verify_fun: {&__MODULE__.verify/3, failures}], else: [])
  end

  @doc "Creates the table in which a session's certificate check records its failure."
  def tls_failures, do: :ets.new(__MODULE__, [:set, :public])

  # OTP passes every certificate check result here, including the host name check.
  @doc false
  def verify(_cert, event, failures) when event in [:valid, :valid_peer], do: {:valid, failures}
  def verify(_cert, {:extension, _}, failures), do: {:unknown, failures}

  def verify(_cert, failure, failures) do
    :ets.insert(failures, {:failure, failure})
    {:fail, failure}
  end

  @doc "Returns the failed certificate check behind a session exit, or exits again with `reason`."
  def tls_failure(reason, failures) do
    case :ets.lookup(failures, :failure) do
      [{:failure, failure}] ->
        {:error,
         %{
           code: "database_unavailable",
           message:
             "The database certificate failed verification. Check the CA certificate and that the certificate names the configured host.",
           reason: inspect(failure),
           retryable: true
         }}

      [] ->
        exit(reason)
    end
  end

  defp cacerts(nil), do: :public_key.cacerts_get()

  defp cacerts(pem) do
    for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der
  end

  defp invalid(message),
    do: %{code: "invalid_database_connection", message: message, retryable: false}
end
