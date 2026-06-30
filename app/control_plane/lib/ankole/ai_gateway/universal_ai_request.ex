defmodule Ankole.AIGateway.UniversalAIRequest do
  @moduledoc """
  Thin execution adapter from AIGateway to the kernel UniversalAIClient.

  Provider modules prepare the UniversalAIClient spec. This module only executes
  it and preserves the HTTP/SSE ready boundary expected by Phoenix callers.
  """

  alias Ankole.Kernel.UniversalAIClient

  @default_timeout_ms 60_000
  @non_stream_model_timeout_ms 300_000
  @receive_grace_ms 1_000
  @raw_timeout_ms 15_000

  @enforce_keys [:ctx, :path, :api_resolver]
  defstruct [
    :ctx,
    :path,
    :api_resolver,
    method: "POST",
    upstream: nil,
    headers: [],
    provider_options: nil,
    include_model: true
  ]

  @typedoc """
  Downstream chunk format selected by the caller after the native stream is ready.
  """
  @type downstream_kind :: :sse | :websocket_text

  @typedoc """
  Provider-owned builder that can be converted into a UniversalAIClient spec.
  """
  @type t :: %__MODULE__{
          ctx: map(),
          path: binary(),
          api_resolver: atom(),
          method: binary(),
          upstream: atom() | nil,
          headers: [{binary(), binary()}],
          provider_options: map() | nil,
          include_model: boolean()
        }

  @doc """
  Builds a provider-owned request builder for one upstream endpoint.

  Provider modules use this helper to state only the endpoint, upstream shape,
  headers, and Rust API resolver. The provider does not build a provider body
  here; UniversalAIClient derives the upstream payload from the original public
  request and selected resolver.
  """
  @spec new(map(), binary(), atom(), keyword()) :: t()
  def new(ctx, path, api_resolver, opts \\ [])
      when is_map(ctx) and is_binary(path) and is_atom(api_resolver) do
    %__MODULE__{
      ctx: ctx,
      path: path,
      api_resolver: api_resolver,
      method: Keyword.get(opts, :method, "POST"),
      upstream: Keyword.get(opts, :upstream, capability_upstream(ctx)),
      headers: setting(ctx, :headers) |> normalize_headers(),
      include_model: Keyword.get(opts, :include_model, true)
    }
  end

  @doc """
  Converts the builder into the spec consumed by `UniversalAIClient`.

  The resulting spec is intentionally a prepared upstream request. Rust receives
  URL, method, headers, timeouts, transport preferences, and response context;
  it does not look back into provider DSL or construct provider-specific auth.
  """
  @spec to_spec(t()) :: {:ok, map()} | {:error, term()}
  def to_spec(%__MODULE__{} = request) do
    with {:ok, url} <- request_url(request.ctx, request.path, request.upstream) do
      upstream =
        %{
          kind: kernel_upstream_kind(request.upstream),
          method: request.method,
          url: url,
          headers: request.headers,
          timeout: timeout(request.ctx),
          transport: setting(request.ctx, :transport) || %{}
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)

      {:ok,
       %{
         api_resolver: request.api_resolver,
         upstream: upstream,
         response_context:
           response_context(request.ctx, request.include_model, request.provider_options)
       }}
    end
  end

  @doc """
  Overrides request-scoped provider options sent to UniversalAIClient.

  Provider modules use this after translating public options into the exact
  provider-native fields that Rust should merge into the upstream body.
  """
  @spec put_provider_options(t(), map()) :: t()
  def put_provider_options(%__MODULE__{} = request, provider_options)
      when is_map(provider_options) do
    %{request | provider_options: provider_options}
  end

  @doc """
  Adds or replaces a header while preserving ordered header output.

  `nil` and blank values are no-ops so provider prepare code can compose auth
  and optional headers without repeating guard code for every optional setting.
  Provider modules still own semantic validation for required options.
  """
  @spec put_header(t() | [{binary(), binary()}], binary(), term()) ::
          t() | [{binary(), binary()}]
  def put_header(%__MODULE__{} = request, name, value) do
    %{request | headers: put_header(request.headers, name, value)}
  end

  def put_header(headers, _name, nil) when is_list(headers), do: headers
  def put_header(headers, _name, "") when is_list(headers), do: headers

  def put_header(headers, name, value) when is_list(headers) and is_binary(name) do
    normalized = String.downcase(name)

    headers =
      Enum.reject(headers, fn {header, _value} -> String.downcase(header) == normalized end)

    headers ++ [{name, to_string(value)}]
  end

  @doc """
  Adds a header only when one with the same case-insensitive name is absent.

  This is useful for provider defaults such as attribution headers: operator or
  runtime headers can intentionally override them before the provider helper is
  applied.
  """
  @spec put_new_header(t() | [{binary(), binary()}], binary(), term()) ::
          t() | [{binary(), binary()}]
  def put_new_header(%__MODULE__{} = request, name, value) do
    %{request | headers: put_new_header(request.headers, name, value)}
  end

  def put_new_header(headers, _name, nil) when is_list(headers), do: headers
  def put_new_header(headers, _name, "") when is_list(headers), do: headers

  def put_new_header(headers, name, value) when is_list(headers) and is_binary(name) do
    normalized = String.downcase(name)

    case Enum.any?(headers, fn {header, _value} -> String.downcase(header) == normalized end) do
      true -> headers
      false -> headers ++ [{name, to_string(value)}]
    end
  end

  @doc """
  Adds or replaces a header from a prepared context setting.
  """
  @spec put_setting_header(t(), binary(), atom()) :: t()
  def put_setting_header(%__MODULE__{} = request, name, key),
    do: put_header(request, name, setting(request.ctx, key))

  @doc """
  Adds a header from a setting only when that header is not already present.
  """
  @spec put_new_setting_header(t(), binary(), atom()) :: t()
  def put_new_setting_header(%__MODULE__{} = request, name, key),
    do: put_new_header(request, name, setting(request.ctx, key))

  @doc """
  Adds a standard bearer `Authorization` header.

  Passing an atom reads that setting from the context. Passing a binary lets
  live-check and metadata helpers reuse the same header helper after they have
  already selected a credential value.
  """
  @spec bearer_auth(t() | [{binary(), binary()}], atom() | binary() | nil) ::
          t() | [{binary(), binary()}]
  def bearer_auth(request_or_headers, credential_or_key \\ :api_key)

  def bearer_auth(%__MODULE__{} = request, key) when is_atom(key),
    do: bearer_auth(request, setting(request.ctx, key))

  def bearer_auth(%__MODULE__{} = request, credential),
    do: put_header(request, "authorization", bearer_value(credential))

  def bearer_auth(headers, credential) when is_list(headers),
    do: put_header(headers, "authorization", bearer_value(credential))

  @doc """
  Adds a provider-specific API-key header.

  This covers providers such as Anthropic and Azure OpenAI where the credential
  is not represented as a bearer token.
  """
  @spec api_key_header(t() | [{binary(), binary()}], binary(), atom() | binary() | nil) ::
          t() | [{binary(), binary()}]
  def api_key_header(request_or_headers, name, credential_or_key \\ :api_key)

  def api_key_header(%__MODULE__{} = request, name, key) when is_atom(key),
    do: api_key_header(request, name, setting(request.ctx, key))

  def api_key_header(%__MODULE__{} = request, name, credential),
    do: put_header(request, name, credential)

  def api_key_header(headers, name, credential) when is_list(headers),
    do: put_header(headers, name, credential)

  @doc """
  Reads a provider setting from a `%PrepareContext{}` or map-like live-check context.
  """
  @spec setting(map(), atom(), term()) :: term()
  def setting(ctx, key, default \\ nil) when is_atom(key) do
    settings = ctx_settings(ctx)
    Map.get(settings, key, default)
  end

  @doc """
  Returns normalized headers for raw provider helper calls.

  Raw calls, such as metadata catalog endpoints, are still executed through the native
  UniversalAIClient HTTP path. This helper only applies the same operator
  headers that a model request would see.
  """
  @spec raw_headers(map()) :: [{binary(), binary()}]
  def raw_headers(ctx) when is_map(ctx) do
    ctx
    |> raw_connection()
    |> Map.get("headers", %{})
    |> normalize_headers()
  end

  @doc """
  Performs a raw GET through UniversalAIClient for provider-owned helper APIs.

  The main use is metadata catalog calls and live checks. Tests may inject an `http_client`
  function so they can validate provider URL/header construction without
  opening real network connections.
  """
  @spec raw_get(map(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def raw_get(ctx, path_or_url, opts \\ []) when is_map(ctx) and is_binary(path_or_url) do
    with {:ok, url} <- raw_url(ctx, path_or_url) do
      request = %{
        url: url,
        headers: Keyword.get(opts, :headers, raw_headers(ctx)),
        timeout: raw_timeout(ctx),
        transport: raw_transport(ctx)
      }

      case Keyword.get(opts, :http_client) || map_get(ctx, :http_client) do
        http_client when is_function(http_client, 1) ->
          http_client.(Map.put(request, :timeout_ms, raw_timeout_ms(ctx)))

        http_client when is_function(http_client, 3) ->
          http_client.(request.url, request.headers, raw_timeout_ms(ctx))

        nil ->
          UniversalAIClient.raw_get(request)
      end
    end
  end

  @doc """
  Executes a non-streaming model request through the native UniversalAIClient.

  This keeps streaming and non-streaming calls on the same prepared request
  contract, connection pool, compression handling, and Rust API resolvers.
  """
  @spec request(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(spec, opts \\ [])

  def request(%__MODULE__{} = request, opts) do
    with {:ok, spec} <- to_spec(request) do
      request(spec, opts)
    end
  end

  def request(spec, _opts) when is_map(spec) do
    with {:ok, response} <- UniversalAIClient.model_request(spec) do
      normalize_response(response)
    else
      {:error, reason} -> {:error, normalize_error_reason(reason)}
    end
  end

  def request(_spec, _opts), do: {:error, :invalid_universal_ai_request}

  @doc """
  Opens a native stream and waits for the `:ready` message before returning.

  Phoenix callers must not commit SSE or WebSocket responses before Rust has
  connected upstream and selected the downstream chunk mode. Waiting here keeps
  pre-ready failures representable as ordinary HTTP errors.
  """
  @spec open_stream(map(), downstream_kind(), keyword()) ::
          {:ok, UniversalAIClient.stream(), map()} | {:error, term()}
  def open_stream(spec, downstream, opts \\ [])

  def open_stream(%__MODULE__{} = request, downstream, opts) do
    with {:ok, spec} <- to_spec(request) do
      open_stream(spec, downstream, opts)
    end
  end

  def open_stream(spec, downstream, _opts)
      when is_map(spec) and downstream in [:sse, :websocket_text] do
    stream_spec = Map.put(spec, :downstream, downstream)

    case UniversalAIClient.open(stream_spec, receiver: self()) do
      {:ok, stream} ->
        case wait_ready(stream, receive_timeout_ms(stream_spec)) do
          {:ok, meta} -> {:ok, stream, meta}
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, normalize_error_reason(reason)}
    end
  end

  def open_stream(_spec, _downstream, _opts), do: {:error, :invalid_universal_ai_stream_request}

  # Stream requests use the same logical endpoint as HTTP requests, but
  # WebSocket upstreams need the URL scheme converted after base URL and query
  # parameters are resolved.
  defp request_url(ctx, path, upstream) do
    with {:ok, url} <- raw_url(ctx, path) do
      {:ok, websocket_url(url, upstream)}
    end
  end

  defp raw_url(_ctx, "https://" <> _rest = url), do: {:ok, url}
  defp raw_url(_ctx, "http://" <> _rest = url), do: {:ok, url}

  # Absolute URLs let providers call native helper APIs outside their
  # OpenAI-compatible base URL, such as Google AI Studio's native embeddings and
  # metadata catalog endpoints.
  defp raw_url(ctx, path) do
    case setting(ctx, :base_url) || Map.get(raw_connection(ctx), "base_url") do
      base_url when is_binary(base_url) and base_url != "" ->
        url =
          "#{String.trim_trailing(base_url, "/")}/#{String.trim_leading(path, "/")}"
          |> append_query_params(setting(ctx, :query_params))

        {:ok, url}

      _base_url ->
        {:error, :missing_base_url}
    end
  end

  # Rust uses response context only to fill normalized Responses fields. It is
  # not allowed to mutate the upstream request from this data.
  defp response_context(ctx, include_model?, provider_options_override) do
    %{
      model: map_get(ctx, :model) || "",
      request: map_get(ctx, :request) || %{},
      provider_options: provider_options_override || map_get(ctx, :provider_options) || %{},
      stream: map_get(ctx, :stream?) || false,
      include_model: include_model?
    }
  end

  defp ctx_settings(%{settings: settings}) when is_map(settings), do: settings
  defp ctx_settings(%{"settings" => settings}) when is_map(settings), do: atomize_keys(settings)

  defp ctx_settings(ctx) when is_map(ctx) do
    ctx
    |> raw_connection()
    |> atomize_keys()
  end

  defp capability_upstream(%{capability: %{upstream: upstream}}), do: upstream
  defp capability_upstream(%{"capability" => %{"upstream" => upstream}}), do: upstream
  defp capability_upstream(_ctx), do: nil

  defp timeout(ctx) do
    case capability_timeout_ms(ctx) do
      nil -> default_timeout(ctx)
      timeout_ms -> capability_timeout(ctx, timeout_ms)
    end
  end

  defp default_timeout(ctx) do
    case map_get(ctx, :stream?) do
      true ->
        %{
          connect_ms: @default_timeout_ms,
          first_byte_ms: @default_timeout_ms,
          idle_ms: @default_timeout_ms,
          total_ms: nil
        }

      _stream? ->
        %{
          connect_ms: @default_timeout_ms,
          first_byte_ms: @non_stream_model_timeout_ms,
          idle_ms: @non_stream_model_timeout_ms,
          total_ms: @non_stream_model_timeout_ms
        }
    end
  end

  defp capability_timeout(ctx, timeout_ms) do
    %{
      connect_ms: timeout_ms,
      first_byte_ms: timeout_ms,
      idle_ms: timeout_ms,
      total_ms: total_timeout_ms(ctx, timeout_ms)
    }
  end

  defp capability_timeout_ms(%{capability: %{timeout_ms: timeout_ms}}), do: timeout_ms
  defp capability_timeout_ms(%{"capability" => %{"timeout_ms" => timeout_ms}}), do: timeout_ms
  defp capability_timeout_ms(_ctx), do: nil

  # Model streams intentionally have no total timeout. Non-streaming calls have
  # wider first-byte, idle, and total caps for high-thinking models, while still
  # bounding slow-drip upstream bodies.
  defp total_timeout_ms(ctx, timeout_ms) do
    case map_get(ctx, :stream?) do
      true -> nil
      _stream? -> timeout_ms
    end
  end

  # Raw helper calls are bounded by a total timeout because they are operator
  # checks or catalog calls, not long-running model streams.
  defp raw_timeout(ctx) do
    timeout_ms = raw_timeout_ms(ctx)

    %{
      connect_ms: timeout_ms,
      first_byte_ms: timeout_ms,
      idle_ms: timeout_ms,
      total_ms: timeout_ms
    }
  end

  defp raw_timeout_ms(ctx), do: map_get(ctx, :timeout_ms) || @raw_timeout_ms

  defp raw_transport(ctx), do: Map.get(raw_connection(ctx), "transport", %{})
  defp raw_connection(ctx), do: map_get(ctx, :connection) || %{}

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp normalize_headers(_headers), do: []

  # Non-streaming JSON requests omit the stream wire kind. The native
  # `model_request` still uses the API resolver, but it does not need
  # SSE/EventStream/WebSocket framing metadata.
  defp kernel_upstream_kind(:sse), do: :http_sse
  defp kernel_upstream_kind(:eventstream), do: :http_eventstream
  defp kernel_upstream_kind(:websocket_text), do: :websocket_text
  defp kernel_upstream_kind(:json), do: nil
  defp kernel_upstream_kind(nil), do: nil

  # OpenAI websocket mode is configured as an upstream transport choice; provider
  # code should not have to duplicate ws/wss URL construction.
  defp websocket_url("https://" <> rest, :websocket_text), do: "wss://" <> rest
  defp websocket_url("http://" <> rest, :websocket_text), do: "ws://" <> rest
  defp websocket_url(url, _upstream), do: url

  defp append_query_params(url, params) when is_map(params) and map_size(params) > 0 do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> URI.encode_query(params)
  end

  defp append_query_params(url, _params), do: url

  defp bearer_value(nil), do: nil
  defp bearer_value(""), do: nil

  defp bearer_value(credential) when is_binary(credential) do
    "Bearer #{String.replace_prefix(credential, "Bearer ", "")}"
  end

  defp bearer_value(_credential), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp atomize_keys(_value), do: %{}

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_value, _key), do: nil

  # The native task monitors the receiver after open, but this caller still
  # cancels on ready timeout so an upstream socket is not left alive when the
  # Phoenix side has already given up.
  defp wait_ready(stream, receive_timeout_ms) do
    receive do
      {:universal_ai_client, ref, :ready, meta} when ref == stream.ref ->
        {:ok, meta}

      {:universal_ai_client, ref, :error, error} when ref == stream.ref ->
        {:error, normalize_error_reason(error)}

      {:universal_ai_client, ref, :aborted} when ref == stream.ref ->
        {:error, :stream_aborted}
    after
      receive_timeout_ms ->
        _ = UniversalAIClient.cancel(stream)
        {:error, :universal_ai_stream_ready_timeout}
    end
  end

  defp normalize_response(%{"status" => status, "body" => body} = response)
       when is_integer(status) do
    {:ok,
     %{
       status: status,
       body: body,
       headers: Map.get(response, "headers", []),
       http_version: Map.get(response, "http_version"),
       http_negotiation: Map.get(response, "http_negotiation")
     }}
  end

  defp normalize_response(response), do: {:error, {:invalid_universal_ai_response, response}}

  # Ready waits add a small BEAM delivery grace period on top of upstream
  # timeouts. Without this, a slow scheduler could make a healthy native ready
  # message look like a transport timeout.
  defp receive_timeout_ms(spec) do
    spec
    |> get_in_any([:upstream, :timeout])
    |> timeout_ms()
    |> Kernel.+(@receive_grace_ms)
  end

  defp timeout_ms(timeout) when is_map(timeout) do
    timeout
    |> Enum.flat_map(fn
      {key, value}
      when key in [:connect_ms, :first_byte_ms, :idle_ms, :total_ms] or
             key in ["connect_ms", "first_byte_ms", "idle_ms", "total_ms"] ->
        if is_integer(value) and value > 0, do: [value], else: []

      _entry ->
        []
    end)
    |> case do
      [] -> @default_timeout_ms
      values -> Enum.max(values)
    end
  end

  defp timeout_ms(_timeout), do: @default_timeout_ms

  defp get_in_any(map, []), do: map

  defp get_in_any(map, [key | rest]) when is_map(map) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))
    get_in_any(value, rest)
  end

  defp get_in_any(_value, _path), do: nil

  # Controllers still speak the older AIGateway error vocabulary. This function
  # maps structured native errors back to that shape while preserving provider
  # status and body excerpts for callers that already handle them.
  defp normalize_error_reason(%{"code" => code, "provider_status" => status} = error)
       when code in ["provider_status_rejected", "websocket_status_rejected"] and
              is_integer(status) do
    {:upstream_response_failed, status, decoded_provider_excerpt(error)}
  end

  defp normalize_error_reason(
         %{"code" => "invalid_upstream_response", "provider_status" => status} = error
       )
       when is_integer(status) do
    {:invalid_upstream_response, status, decoded_provider_body(error)}
  end

  defp normalize_error_reason(error) when is_map(error), do: {:universal_ai_request_failed, error}
  defp normalize_error_reason(error), do: {:universal_ai_request_failed, error}

  # Provider body excerpts may already be JSON. Decoding them here keeps
  # controller errors useful without teaching controllers about native error
  # fields.
  defp decoded_provider_body(%{"provider_body_excerpt" => excerpt}) when is_binary(excerpt) do
    case Ankole.JSON.decode(excerpt) do
      {:ok, body} -> body
      {:error, _reason} -> excerpt
    end
  end

  defp decoded_provider_body(_error), do: nil

  # Status-rejected errors historically returned a map-like response body.
  # Wrapping non-object JSON keeps that contract stable for callers.
  defp decoded_provider_excerpt(%{"provider_body_excerpt" => excerpt}) when is_binary(excerpt) do
    case Ankole.JSON.decode(excerpt) do
      {:ok, body} when is_map(body) -> body
      {:ok, body} -> %{"body" => body}
      {:error, _reason} -> %{"raw_body" => excerpt}
    end
  end

  defp decoded_provider_excerpt(_error), do: %{}
end
