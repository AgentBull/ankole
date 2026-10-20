defmodule WeComOpenAPI.Corp.Client do
  @moduledoc """
  Holds one WeCom corp REST credential set and transport configuration.

  All corp server APIs live on one domain (`https://qyapi.weixin.qq.com`) with
  the access token in the `access_token` query parameter and failures reported
  as HTTP 200 + non-zero `errcode`.

  One corp usually yields several clients with different secrets: the self-built
  app secret (login `getuserinfo`) and the contacts-sync secret (directory
  read). Each secret gets its own access token, so the token cache namespace is
  derived from the full credential set.

  `secret` is stored as a zero-arity closure so it never appears in
  `inspect/1`, stacktraces, or `:sys.get_state/1`. `new/1` accepts either a
  string (auto-wrapped) or a closure.
  """

  @default_base_url "https://qyapi.weixin.qq.com"

  @type secret_fn :: (-> String.t())
  @type cache_namespace :: String.t()

  @type t :: %__MODULE__{
          corp_id: String.t(),
          secret_fn: secret_fn(),
          base_url: String.t(),
          token_cache_ns: cache_namespace(),
          req_options: keyword(),
          headers: list()
        }

  # Only non-sensitive fields are inspectable. Combined with `secret_fn` being a
  # closure, this keeps credentials out of logs and crash dumps.
  @derive {Inspect, only: [:corp_id, :base_url]}
  defstruct corp_id: nil,
            secret_fn: nil,
            base_url: @default_base_url,
            token_cache_ns: nil,
            req_options: [],
            headers: []

  @opts [:corp_id, :secret, :base_url, :req_options, :headers]

  @doc """
  Build a new `%Corp.Client{}`. Options:

    * `:corp_id` (required) — the enterprise CorpID.
    * `:secret` (required) — an app secret or the contacts-sync secret, as a
      `String.t()` (auto-wrapped in a closure) or a `(-> String.t())` function
      evaluated lazily.
    * `:base_url` — overrides `#{@default_base_url}` (local fakes only).
    * `:req_options` — extra options merged into every `Req.request/1`.
    * `:headers` — additional headers attached to every request.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts = Keyword.validate!(opts, @opts)

    corp_id = fetch_non_empty!(opts, :corp_id)
    secret = Keyword.fetch!(opts, :secret)
    validate_secret!(secret)

    base_url = normalize_base_url(Keyword.get(opts, :base_url, @default_base_url))
    headers = Keyword.get(opts, :headers, [])
    req_options = Keyword.get(opts, :req_options, [])

    %__MODULE__{
      corp_id: corp_id,
      secret_fn: wrap_secret(secret),
      base_url: base_url,
      token_cache_ns: build_cache_namespace(corp_id, secret, base_url, headers),
      req_options: req_options,
      headers: headers
    }
  end

  @doc "Resolve the secret closure. Used by the token fetch."
  @spec secret(t()) :: String.t()
  def secret(%__MODULE__{secret_fn: fun}) when is_function(fun, 0), do: fun.()

  @doc false
  @spec cache_namespace(t()) :: cache_namespace()
  def cache_namespace(%__MODULE__{token_cache_ns: ns}), do: ns

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
      do: raise(ArgumentError, "secret must be a non-empty string"),
      else: :ok
  end

  defp validate_secret!(fun) when is_function(fun, 0), do: :ok

  defp validate_secret!(_other) do
    raise ArgumentError, "secret must be a string or a zero-arity function"
  end

  defp normalize_base_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      String.trim_trailing(url, "/")
    else
      raise ArgumentError, "base_url must be an absolute http(s) URL, got: #{inspect(url)}"
    end
  end

  # Token caches are keyed by this namespace, so two clients share a cached
  # token iff they authenticate identically. The secret contributes only its
  # hash, never plaintext.
  defp build_cache_namespace(corp_id, secret, base_url, headers) do
    %{
      corp_id: corp_id,
      secret: secret_fingerprint(secret),
      base_url: base_url,
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
