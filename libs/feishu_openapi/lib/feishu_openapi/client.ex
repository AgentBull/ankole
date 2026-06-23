defmodule FeishuOpenAPI.Client do
  @moduledoc """
  Holds Feishu/Lark application credentials and transport options.

  `app_secret` is stored as a zero-arity closure so it does not appear in
  `inspect/1`, stacktraces, or `:sys.get_state/1`. `Client.new/3` accepts
  either a string (auto-wrapped) or a closure.

  ## Application config

  If `:app_id` / `:app_secret` are present in `Application.get_env(:feishu_openapi, :default_client)`,
  they can be read via `Client.from_env/1` (no args) or used as defaults. Typical
  `config/runtime.exs`:

      config :feishu_openapi, :default_client,
        app_id: System.fetch_env!("FEISHU_APP_ID"),
        app_secret: System.fetch_env!("FEISHU_APP_SECRET"),
        domain: :feishu
  """

  @feishu_base_url "https://open.feishu.cn"
  @lark_base_url "https://open.larksuite.com"

  @type app_type :: :self_built | :marketplace
  @type domain :: :feishu | :lark | String.t()
  @type cache_namespace :: String.t()
  @type secret_fn :: (-> String.t())

  @type t :: %__MODULE__{
          app_id: String.t(),
          app_secret_fn: secret_fn(),
          app_type: app_type(),
          domain: domain(),
          token_cache_ns: cache_namespace(),
          base_url: String.t(),
          req_options: keyword(),
          headers: list()
        }

  @derive {Inspect, only: [:app_id, :app_type, :domain, :base_url]}
  defstruct app_id: nil,
            app_secret_fn: nil,
            app_type: :self_built,
            domain: :feishu,
            token_cache_ns: nil,
            base_url: @feishu_base_url,
            req_options: [],
            headers: []

  @client_opts [:domain, :app_type, :base_url, :req_options, :headers]
  @valid_app_types [:self_built, :marketplace]
  @valid_domains [:feishu, :lark]

  # Req's default retry predicate retries on 429 too, which duplicates our
  # Retry-After handling in `FeishuOpenAPI.handle_rate_limited/6`. Exclude 429
  # so only the SDK layer retries it.
  @retry_statuses [408, 500, 502, 503, 504]

  defp default_retry_fun do
    fn
      _req, %Req.Response{status: 429} -> false
      _req, %Req.Response{status: status} when status in @retry_statuses -> true
      _req, %{__exception__: true} -> true
      _req, _other -> false
    end
  end

  defp default_timeout_options do
    [
      receive_timeout: :timer.seconds(15),
      pool_timeout: :timer.seconds(5),
      connect_options: [timeout: :timer.seconds(5)],
      retry: default_retry_fun()
    ]
  end

  @doc """
  Build a new `%Client{}`. Options:

  * `:domain` — `:feishu` (default) or `:lark`
  * `:app_type` — `:self_built` (default) or `:marketplace`
  * `:base_url` — overrides the URL derived from `:domain`
  * `:req_options` — extra options passed through to `Req.request/1`; merged on
    top of the SDK's transport-timeout defaults (`receive_timeout: :timer.seconds(15)`,
    `pool_timeout: :timer.seconds(5)`, `connect_options[:timeout]: :timer.seconds(5)`)
  * `:headers` — additional headers to attach to every request

  `app_secret` may be a `String.t()` (auto-wrapped in a closure) or a
  `(-> String.t())` function (evaluated lazily each time the secret is read).
  """
  @spec new(String.t(), String.t() | secret_fn(), keyword()) :: t()
  def new(app_id, app_secret, opts \\ []) when is_binary(app_id) do
    opts = validate_opts!(opts)
    validate_app_id!(app_id)
    validate_app_secret!(app_secret)

    domain = validate_domain!(Keyword.get(opts, :domain, :feishu))
    app_type = validate_app_type!(Keyword.get(opts, :app_type, :self_built))
    headers = validate_headers!(Keyword.get(opts, :headers, []))
    raw_req_options = validate_req_options!(Keyword.get(opts, :req_options, []))

    base_url =
      opts
      |> Keyword.get_lazy(:base_url, fn -> base_url_for(domain) end)
      |> validate_base_url!()
      |> normalize_base_url()

    req_options =
      default_timeout_options()
      |> deep_merge_req_options(raw_req_options)

    %__MODULE__{
      app_id: app_id,
      app_secret_fn: wrap_secret(app_secret),
      app_type: app_type,
      domain: domain,
      token_cache_ns:
        build_cache_namespace(
          app_id,
          app_secret,
          app_type,
          domain,
          base_url,
          headers,
          raw_req_options
        ),
      base_url: base_url,
      req_options: req_options,
      headers: headers
    }
  end

  @doc """
  Build a `%Client{}` from `Application.get_env(:feishu_openapi, :default_client, [])`.

  Extra `opts` are merged on top of the env config.
  """
  @spec from_env(keyword()) :: t()
  def from_env(opts \\ []) do
    base = Application.get_env(:feishu_openapi, :default_client, [])
    merged = Keyword.merge(base, opts)

    app_id = Keyword.fetch!(merged, :app_id)
    app_secret = Keyword.fetch!(merged, :app_secret)

    new(app_id, app_secret, Keyword.drop(merged, [:app_id, :app_secret]))
  end

  @doc "Resolve the app secret closure. Used by `FeishuOpenAPI.Auth` and the WS client."
  @spec app_secret(t()) :: String.t()
  def app_secret(%__MODULE__{app_secret_fn: fun}) when is_function(fun, 0), do: fun.()

  @doc false
  @spec cache_namespace(t()) :: cache_namespace()
  def cache_namespace(%__MODULE__{token_cache_ns: ns}), do: ns

  @spec base_url_for(domain()) :: String.t()
  def base_url_for(:feishu), do: @feishu_base_url
  def base_url_for(:lark), do: @lark_base_url

  def base_url_for(domain) when is_binary(domain),
    do: validate_base_url!(domain) |> normalize_base_url()

  defp wrap_secret(secret) when is_binary(secret), do: fn -> secret end
  defp wrap_secret(fun) when is_function(fun, 0), do: fun

  defp normalize_base_url(base_url) when is_binary(base_url) do
    String.trim_trailing(base_url, "/")
  end

  defp deep_merge_req_options(defaults, overrides) do
    Keyword.merge(defaults, overrides, fn
      :connect_options, d, o when is_list(d) and is_list(o) -> Keyword.merge(d, o)
      _, _, o -> o
    end)
  end

  defp validate_opts!(opts) when is_list(opts), do: Keyword.validate!(opts, @client_opts)

  defp validate_opts!(_opts) do
    raise ArgumentError, "client options must be a keyword list"
  end

  defp validate_app_id!(app_id) do
    if String.trim(app_id) == "" do
      raise ArgumentError, "app_id must be a non-empty string"
    end
  end

  defp validate_app_secret!(secret) when is_binary(secret) do
    if String.trim(secret) == "" do
      raise ArgumentError, "app_secret must be a non-empty string"
    end
  end

  defp validate_app_secret!(fun) when is_function(fun, 0), do: :ok

  defp validate_app_secret!(_secret) do
    raise ArgumentError, "app_secret must be a string or a zero-arity function"
  end

  defp validate_domain!(domain) when domain in @valid_domains, do: domain
  defp validate_domain!(domain) when is_binary(domain), do: validate_base_url!(domain)

  defp validate_domain!(domain) do
    raise ArgumentError,
          "domain must be :feishu, :lark, or an absolute http(s) base URL, got: #{inspect(domain)}"
  end

  defp validate_app_type!(app_type) when app_type in @valid_app_types, do: app_type

  defp validate_app_type!(app_type) do
    raise ArgumentError,
          "app_type must be one of #{@valid_app_types |> Enum.map_join(", ", &inspect/1)}, got: #{inspect(app_type)}"
  end

  defp validate_base_url!(base_url) when is_binary(base_url) do
    uri = URI.parse(base_url)

    cond do
      String.trim(base_url) == "" ->
        raise ArgumentError, "base_url must be a non-empty absolute http(s) URL"

      uri.scheme not in ["http", "https"] or is_nil(uri.host) ->
        raise ArgumentError, "base_url must be an absolute http(s) URL, got: #{inspect(base_url)}"

      true ->
        base_url
    end
  end

  defp validate_base_url!(base_url) do
    raise ArgumentError, "base_url must be a string, got: #{inspect(base_url)}"
  end

  defp validate_headers!(headers) when is_list(headers) do
    Enum.each(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        :ok

      other ->
        raise ArgumentError,
              "headers must be a list of {binary_name, binary_value} tuples, got: #{inspect(other)}"
    end)

    headers
  end

  defp validate_headers!(headers) do
    raise ArgumentError, "headers must be a list, got: #{inspect(headers)}"
  end

  defp validate_req_options!(req_options) when is_list(req_options) do
    if Keyword.keyword?(req_options) do
      req_options
    else
      raise ArgumentError, "req_options must be a keyword list"
    end
  end

  defp validate_req_options!(req_options) do
    raise ArgumentError, "req_options must be a keyword list, got: #{inspect(req_options)}"
  end

  defp build_cache_namespace(app_id, app_secret, app_type, domain, base_url, headers, req_options) do
    fingerprint =
      :erlang.term_to_binary(%{
        app_id: app_id,
        app_secret: secret_fingerprint(app_secret),
        app_type: app_type,
        domain: domain,
        base_url: base_url,
        headers: headers,
        req_options: req_options
      })

    fingerprint
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp secret_fingerprint(secret) when is_binary(secret),
    do: {:binary, :crypto.hash(:sha256, secret)}

  defp secret_fingerprint(fun) when is_function(fun, 0),
    do: {:fun, :erlang.phash2(fun)}
end
