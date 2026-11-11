defmodule Ankole.AIGateway.GoogleServiceAccount do
  @moduledoc """
  Exchanges a Google Cloud service-account key for short-lived access tokens.

  Google Cloud APIs such as Vertex AI accept only OAuth access tokens, and a
  token lives for about one hour. The operator stores the long-lived JSON key
  in the credential pool; this module signs a JWT with the key, exchanges it
  at the key's token endpoint, and keeps the token in a node-local ETS table
  until shortly before it expires. The table is a rebuildable cache: a restart
  or another node only costs one more exchange.
  """

  use GenServer

  alias Ankole.EgressProxy
  alias Ankole.Logging

  @table __MODULE__
  @scope "https://www.googleapis.com/auth/cloud-platform"
  @default_token_uri "https://oauth2.googleapis.com/token"
  @assertion_lifetime_s 3600
  # A request that starts with a token this close to expiry could outlive it.
  @refresh_skew_s 300

  @type key :: %{
          client_email: String.t(),
          project_id: String.t(),
          token_uri: String.t(),
          private_key: term()
        }

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    _table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Parses the JSON key file that Google Cloud issues for a service account.

  The error names the first thing that makes the key unusable, so the operator
  who pasted it can tell a wrong file from a damaged one.
  """
  @spec parse(term()) ::
          {:ok, key()}
          | {:error,
             :invalid_json
             | :not_a_service_account_key
             | :missing_client_email
             | :missing_project_id
             | :invalid_private_key}
  def parse(json) when is_binary(json) do
    with {:ok, %{} = fields} <- decode(json),
         :ok <- require_service_account(fields),
         {:ok, client_email} <- text_field(fields, "client_email", :missing_client_email),
         {:ok, project_id} <- text_field(fields, "project_id", :missing_project_id),
         {:ok, private_key} <- private_key(fields["private_key"]) do
      {:ok,
       %{
         client_email: client_email,
         project_id: project_id,
         token_uri: text(fields["token_uri"]) || @default_token_uri,
         private_key: private_key
       }}
    end
  end

  def parse(_json), do: {:error, :invalid_json}

  @doc """
  Returns an access token for the key, exchanging the key only when the cached
  token is missing or about to expire.

  `proxy_url` names the proxy of the provider row, which the exchange uses the
  way the row's model requests do. A `:google_token_rejected` error means the
  token endpoint refused the signed assertion: the key was deleted, its
  service account was disabled, or this node's clock is far enough off that
  Google refuses the assertion's timestamps. A `:google_token_transient` error
  leaves the key's standing unknown.
  """
  @spec access_token(String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, {:google_token_rejected, String.t()} | {:google_token_transient, term()}}
  def access_token(json, opts \\ []) when is_binary(json) and is_list(opts) do
    cache_key = :crypto.hash(:sha256, json)
    now = System.os_time(:second)

    case :ets.lookup(@table, cache_key) do
      [{^cache_key, token, expires_at}] when expires_at - @refresh_skew_s > now ->
        {:ok, token}

      _missing_or_expiring ->
        with {:ok, key} <- parse_stored(json),
             {:ok, token, expires_in} <- exchange(key, now, opts) do
          true = :ets.insert(@table, {cache_key, token, now + expires_in})
          {:ok, token}
        end
    end
  end

  if Mix.env() == :test do
    @doc false
    def clear_for_test do
      true = :ets.delete_all_objects(@table)
      :ok
    end
  end

  # The pool validates a key when the operator saves it, so a stored key that
  # no longer parses is as unusable as one that Google rejects.
  defp parse_stored(json) do
    with {:error, reason} <- parse(json) do
      {:error, {:google_token_rejected, Atom.to_string(reason)}}
    end
  end

  defp exchange(key, now, opts) do
    options =
      [
        method: :post,
        url: key.token_uri,
        form: [
          grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
          assertion: assertion(key, now)
        ],
        retry: false,
        receive_timeout: 15_000
      ] ++ EgressProxy.req_options(key.token_uri, Keyword.take(opts, [:proxy_url]))

    case Req.request(options) do
      {:ok, %Req.Response{status: 200, body: %{"access_token" => token} = body}}
      when is_binary(token) and token != "" ->
        {:ok, token, expires_in(body)}

      # Google answers 400 `invalid_grant` for a deleted key, a disabled
      # account, or assertion timestamps it does not accept, and 401
      # `invalid_client` for an unknown account.
      {:ok, %Req.Response{status: status, body: body}} when status in [400, 401] ->
        code = error_code(body, status)
        log_failure(key, "rejected", status, code)
        {:error, {:google_token_rejected, code}}

      {:ok, %Req.Response{status: status, body: body}} ->
        code = error_code(body, status)
        log_failure(key, "transient", status, code)
        {:error, {:google_token_transient, code}}

      {:error, exception} ->
        reason = Exception.message(exception)
        log_failure(key, "transient", nil, reason)
        {:error, {:google_token_transient, reason}}
    end
  end

  # The caller's error becomes a generic upstream failure, so this line is
  # where an operator learns that the token endpoint is the part that failed.
  defp log_failure(key, class, status, reason) do
    Logging.warning(
      "ai_gateway.google_service_account.exchange_failed",
      "Google service-account token exchange failed",
      %{
        token_host: URI.parse(key.token_uri).host,
        class: class,
        upstream_status: status,
        reason: reason
      }
    )
  end

  defp assertion(key, now) do
    header = encode_part(%{"alg" => "RS256", "typ" => "JWT"})

    claims =
      encode_part(%{
        "iss" => key.client_email,
        "scope" => @scope,
        "aud" => key.token_uri,
        "iat" => now,
        "exp" => now + @assertion_lifetime_s
      })

    signing_input = header <> "." <> claims
    signature = :public_key.sign(signing_input, :sha256, key.private_key)
    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp encode_part(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp expires_in(%{"expires_in" => seconds}) when is_integer(seconds) and seconds > 0,
    do: seconds

  defp expires_in(_body), do: @assertion_lifetime_s

  defp error_code(%{"error" => code}, _status) when is_binary(code), do: code
  defp error_code(_body, status), do: Integer.to_string(status)

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = fields} -> {:ok, fields}
      _other -> {:error, :invalid_json}
    end
  end

  defp require_service_account(%{"type" => "service_account"}), do: :ok
  defp require_service_account(_fields), do: {:error, :not_a_service_account_key}

  defp text_field(fields, name, error) do
    case text(fields[name]) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil

  defp private_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [entry] ->
        case :public_key.pem_entry_decode(entry) do
          key when elem(key, 0) == :RSAPrivateKey -> {:ok, key}
          _other -> {:error, :invalid_private_key}
        end

      _entries ->
        {:error, :invalid_private_key}
    end
  rescue
    _error -> {:error, :invalid_private_key}
  end

  defp private_key(_pem), do: {:error, :invalid_private_key}
end
