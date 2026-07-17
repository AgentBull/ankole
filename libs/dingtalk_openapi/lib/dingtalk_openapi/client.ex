defmodule DingTalkOpenAPI.Client do
  @moduledoc """
  Holds DingTalk enterprise-internal application credentials and transport
  configuration.

  DingTalk exposes two API domains that share one app access token:

    * new domain `https://api.dingtalk.com` (`/v1.0/*`) — token in the
      `x-acs-dingtalk-access-token` header, errors as HTTP status + `{code,
      message}`.
    * old domain `https://oapi.dingtalk.com` (`topapi/*`, media upload) — token
      in the `access_token` query parameter, errors as HTTP 200 + `{errcode,
      errmsg}`.

  `client_secret` is stored as a zero-arity closure so it never appears in
  `inspect/1`, stacktraces, or `:sys.get_state/1`. `new/1` accepts either a
  string (auto-wrapped) or a closure.

  `client_id` is the enterprise-internal application AppKey; `client_secret` is
  its AppSecret. These double as the Stream `clientId` / `clientSecret`.
  """

  @default_api_base_url "https://api.dingtalk.com"
  @default_oapi_base_url "https://oapi.dingtalk.com"

  @type secret_fn :: (-> String.t())
  @type cache_namespace :: String.t()

  @type t :: %__MODULE__{
          client_id: String.t(),
          client_secret_fn: secret_fn(),
          api_base_url: String.t(),
          oapi_base_url: String.t(),
          token_cache_ns: cache_namespace(),
          req_options: keyword(),
          headers: list()
        }

  # Only non-sensitive fields are inspectable. Combined with `client_secret_fn`
  # being a closure, this keeps credentials out of logs and crash dumps.
  @derive {Inspect, only: [:client_id, :api_base_url, :oapi_base_url]}
  defstruct client_id: nil,
            client_secret_fn: nil,
            api_base_url: @default_api_base_url,
            oapi_base_url: @default_oapi_base_url,
            token_cache_ns: nil,
            req_options: [],
            headers: []

  @opts [:client_id, :client_secret, :api_base_url, :oapi_base_url, :req_options, :headers]

  @doc """
  Build a new `%Client{}`. Options:

    * `:client_id` (required) — enterprise-internal AppKey.
    * `:client_secret` (required) — AppSecret, as a `String.t()` (auto-wrapped in
      a closure) or a `(-> String.t())` function evaluated lazily.
    * `:api_base_url` — overrides the new-domain base (`#{@default_api_base_url}`).
    * `:oapi_base_url` — overrides the old-domain base (`#{@default_oapi_base_url}`).
    * `:req_options` — extra options merged into every `Req.request/1`.
    * `:headers` — additional headers attached to every request.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @opts)

    client_id = fetch_non_empty!(opts, :client_id)
    client_secret = Keyword.fetch!(opts, :client_secret)
    validate_secret!(client_secret)

    api_base_url = normalize_base_url(Keyword.get(opts, :api_base_url, @default_api_base_url))
    oapi_base_url = normalize_base_url(Keyword.get(opts, :oapi_base_url, @default_oapi_base_url))
    headers = Keyword.get(opts, :headers, [])
    req_options = Keyword.get(opts, :req_options, [])

    %__MODULE__{
      client_id: client_id,
      client_secret_fn: wrap_secret(client_secret),
      api_base_url: api_base_url,
      oapi_base_url: oapi_base_url,
      token_cache_ns:
        build_cache_namespace(client_id, client_secret, api_base_url, oapi_base_url, headers),
      req_options: req_options,
      headers: headers
    }
  end

  @doc "Resolve the client secret closure. Used by token and OAuth flows."
  @spec client_secret(t()) :: String.t()
  def client_secret(%__MODULE__{client_secret_fn: fun}) when is_function(fun, 0), do: fun.()

  @doc false
  @spec cache_namespace(t()) :: cache_namespace()
  def cache_namespace(%__MODULE__{token_cache_ns: ns}), do: ns

  @doc "Base URL for the given domain."
  @spec base_url(t(), :new | :old) :: String.t()
  def base_url(%__MODULE__{api_base_url: url}, :new), do: url
  def base_url(%__MODULE__{oapi_base_url: url}, :old), do: url

  defp wrap_secret(secret) when is_binary(secret), do: fn -> secret end
  defp wrap_secret(fun) when is_function(fun, 0), do: fun

  defp fetch_non_empty!(opts, key) do
    case Keyword.fetch!(opts, key) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: raise(ArgumentError, "#{key} must be a non-empty string"),
          else: value

      other ->
        raise ArgumentError, "#{key} must be a string, got: #{inspect(other)}"
    end
  end

  defp validate_secret!(secret) when is_binary(secret) do
    if String.trim(secret) == "",
      do: raise(ArgumentError, "client_secret must be a non-empty string"),
      else: :ok
  end

  defp validate_secret!(fun) when is_function(fun, 0), do: :ok

  defp validate_secret!(_other) do
    raise ArgumentError, "client_secret must be a string or a zero-arity function"
  end

  defp normalize_base_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      String.trim_trailing(url, "/")
    else
      raise ArgumentError, "base_url must be an absolute http(s) URL, got: #{inspect(url)}"
    end
  end

  # Token caches are keyed by this namespace, so two clients share a cached token
  # iff they authenticate identically. The secret contributes only its hash,
  # never plaintext.
  defp build_cache_namespace(client_id, client_secret, api_base_url, oapi_base_url, headers) do
    %{
      client_id: client_id,
      client_secret: secret_fingerprint(client_secret),
      api_base_url: api_base_url,
      oapi_base_url: oapi_base_url,
      headers: headers
    }
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp secret_fingerprint(secret) when is_binary(secret),
    do: {:binary, :crypto.hash(:sha256, secret)}

  defp secret_fingerprint(fun) when is_function(fun, 0), do: {:fun, :erlang.phash2(fun)}
end
