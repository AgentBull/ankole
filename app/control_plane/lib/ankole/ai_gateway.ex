defmodule Ankole.AIGateway do
  @moduledoc """
  Control-plane owned AI provider gateway.

  AIGateway keeps provider credentials and provider differences in Elixir. Worker
  callers authenticate as an agent and send OpenResponses/OpenRouter-shaped
  requests to this module through the Phoenix API.
  """

  alias Ankole.AIGateway.HttpClient
  alias Ankole.AIGateway.Models
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.AIGateway.StreamEvents

  @type gateway_response :: %{
          required(:status) => pos_integer(),
          required(:body) => map(),
          required(:model_ref) => map()
        }

  @doc """
  Creates one stateless OpenResponses response.

  The call resolves the agent-visible selector, builds a provider-owned upstream
  request, calls the configured HTTP client, and normalizes the result back into
  the AIGateway response body.
  """
  @spec create_response(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_response(agent_uid, request, opts \\ [])

  def create_response(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "llm", request),
         {:ok, upstream_request} <-
           Providers.build_response_request(runtime, request, stream?: false),
         {:ok, upstream_response} <- HttpClient.client(opts).(upstream_request),
         {:ok, body} <-
           Providers.normalize_response_body(runtime, upstream_request, upstream_response) do
      {:ok, gateway_response(200, body, runtime)}
    end
  end

  def create_response(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Streams one OpenResponses turn from an upstream SSE-capable provider.

  This arity is for callers that only need each event. It delegates to the
  state-threading arity so HTTP SSE and WebSocket transports share one stream
  normalization path.
  """
  @spec stream_response(String.t(), map(), (map() -> :ok | {:error, term()}), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def stream_response(agent_uid, request, emit_event, opts \\ [])

  def stream_response(agent_uid, request, emit_event, opts)
      when is_map(request) and is_function(emit_event, 1) do
    case stream_response(
           agent_uid,
           request,
           nil,
           fn event, nil ->
             case emit_event.(event) do
               :ok -> {:ok, nil}
               {:error, reason} -> {:error, reason}
             end
           end,
           opts
         ) do
      {:ok, response, nil} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  def stream_response(_agent_uid, _request, _emit_event, _opts),
    do: {:error, :invalid_request_body}

  @doc """
  Streams one response while threading caller-owned emitter state.

  The gateway never writes directly to a socket here. The caller owns emission
  state, while AIGateway owns provider stream parsing and terminal response
  validation.
  """
  @spec stream_response(
          String.t(),
          map(),
          term(),
          (map(), term() -> {:ok, term()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, gateway_response(), term()} | {:error, term()}
  def stream_response(agent_uid, request, emit_state, emit_event, opts)

  def stream_response(agent_uid, request, emit_state, emit_event, opts)
      when is_map(request) and is_function(emit_event, 2) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "llm", request),
         {:ok, upstream_request} <-
           Providers.build_response_request(runtime, request, stream?: true),
         {:ok, response_stream_state} <- ResponseStream.init(runtime, upstream_request),
         stream_state <- %{response: response_stream_state, emit: emit_state},
         {:ok, stream_state} <-
           HttpClient.stream_client(opts).(
             upstream_request,
             stream_state,
             stream_chunk_handler(runtime, upstream_request, emit_event)
           ),
         {:ok, events, response_stream_state} <-
           ResponseStream.finish(runtime, upstream_request, stream_state.response),
         {:ok, emit_state} <- emit_events(events, stream_state.emit, emit_event),
         body when is_map(body) <- ResponseStream.response_body(response_stream_state) do
      {:ok, gateway_response(200, body, runtime), emit_state}
    else
      nil -> {:error, :missing_stream_response_body}
      {:error, _reason} = error -> error
      reason -> {:error, reason}
    end
  end

  def stream_response(_agent_uid, _request, _emit_state, _emit_event, _opts),
    do: {:error, :invalid_request_body}

  @doc """
  Collects upstream streaming events into memory for WebSocket transports.

  WebSocket response creation needs the normalized event list for tests and for
  connection-local bookkeeping, but it still goes through the same streaming
  provider path as HTTP SSE.
  """
  @spec response_events(String.t(), map(), keyword()) ::
          {:ok, [map()], gateway_response()} | {:error, term()}
  def response_events(agent_uid, request, opts \\ []) do
    case stream_response(
           agent_uid,
           request,
           [],
           fn event, events -> {:ok, [event | events]} end,
           opts
         ) do
      {:ok, response, events} -> {:ok, Enum.reverse(events), response}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates embeddings with an OpenRouter/OpenAI-compatible public shape.

  Request validation happens before provider dispatch because invalid local
  shape should not become an upstream provider call or failover candidate.
  """
  @spec create_embeddings(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_embeddings(agent_uid, request, opts \\ [])

  def create_embeddings(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "embedding", request),
         :ok <- Ankole.AIGateway.Request.validate_embeddings_request(request),
         {:ok, upstream_request} <- Providers.build_embeddings_request(runtime, request),
         {:ok, upstream_response} <- HttpClient.client(opts).(upstream_request),
         {:ok, body} <-
           Providers.normalize_embeddings_body(runtime, upstream_request, upstream_response) do
      {:ok, gateway_response(200, body, runtime)}
    end
  end

  def create_embeddings(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Creates a rerank result with an OpenRouter-compatible public shape.

  Rerank uses the same model resolver as LLM calls, but requires a provider that
  explicitly supports the `rerank` capability.
  """
  @spec create_rerank(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_rerank(agent_uid, request, opts \\ [])

  def create_rerank(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "rerank", request),
         :ok <- Ankole.AIGateway.Request.validate_rerank_request(request),
         {:ok, upstream_request} <- Providers.build_rerank_request(runtime, request),
         {:ok, upstream_response} <- HttpClient.client(opts).(upstream_request),
         {:ok, body} <-
           Providers.normalize_rerank_body(runtime, upstream_request, upstream_response) do
      {:ok, gateway_response(200, body, runtime)}
    end
  end

  def create_rerank(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Lists OpenRouter-shaped model selectors available through AIGateway.
  """
  @spec list_models(String.t(), String.t(), map()) :: {:ok, map()}
  defdelegate list_models(subject_uid, subject_type, params \\ %{}), to: Models

  @doc """
  Returns whether a request asked for an SSE response.
  """
  @spec stream_requested?(map()) :: boolean()
  def stream_requested?(%{"stream" => true}), do: true
  def stream_requested?(%{stream: true}), do: true
  def stream_requested?(_request), do: false

  @doc """
  Builds the stateless OpenResponses SSE event sequence for a completed body.
  """
  @spec response_stream_events(map()) :: [map()]
  defdelegate response_stream_events(body), to: StreamEvents

  @doc false
  defdelegate default_http_client(request), to: HttpClient

  # Keeps transport response data separate from model resolution facts. The body
  # must stay provider-contract compatible; internal trace facts belong in
  # `model_ref`, telemetry, or durable turn metadata.
  defp gateway_response(status, body, runtime) do
    %{
      status: status,
      body: body,
      model_ref: %{
        "provider_id" => runtime["provider_id"],
        "provider_kind" => runtime["provider_kind"],
        "model" => runtime["model"],
        "selector" => runtime["selector"],
        "capability" => runtime["capability"]
      }
    }
  end

  # Adapts the HTTP client's raw chunk callback to provider stream decoding.
  # Errors halt the upstream stream immediately so callers do not receive partial
  # success after a malformed provider event.
  defp stream_chunk_handler(runtime, upstream_request, emit_event) do
    fn chunk, %{response: response_state, emit: emit_state} ->
      with {:ok, events, response_state} <-
             ResponseStream.decode_chunk(runtime, upstream_request, response_state, chunk),
           {:ok, emit_state} <- emit_events(events, emit_state, emit_event) do
        {:cont, %{response: response_state, emit: emit_state}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end
  end

  defp emit_events(events, emit_state, emit_event) do
    Enum.reduce_while(events, {:ok, emit_state}, fn event, {:ok, emit_state} ->
      case emit_event.(event, emit_state) do
        {:ok, emit_state} -> {:cont, {:ok, emit_state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
