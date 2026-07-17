defmodule Ankole.AIGateway do
  @moduledoc """
  Control-plane owned AI provider gateway.

  AIGateway keeps provider credentials and provider differences in Elixir. It
  serves Principal-scoped OpenResponses/OpenRouter-shaped requests without
  depending on caller workflow lifecycle semantics.
  """

  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.HostedToolTelemetry
  alias Ankole.AIGateway.MapUtils
  alias Ankole.AIGateway.Models
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ModelSelectors
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.ResponsesPreparation
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.AIGateway.StatefulLifecycle
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.UniversalAIRequest
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Security.SSRFFilter

  @stateful_http_fields ~w(previous_response_id conversation store)

  @type gateway_response :: %{
          required(:status) => pos_integer(),
          required(:body) => map(),
          required(:model_ref) => map()
        }

  @doc """
  Creates one stateless OpenResponses response.

  The call resolves the agent-visible selector, prepares a provider-owned
  UniversalAIRequest spec, calls the UniversalAIClient, and normalizes the result back
  into the AIGateway response body.
  """
  @spec create_response(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_response(subject_uid, request, opts \\ [])

  def create_response(subject_uid, request, opts) when is_map(request) do
    request = normalize_request_keys(request)

    with :ok <- reject_http_stateful_fields(request),
         {:ok, %{runtime: runtime, spec: prepared_request}} <-
           ResponsesPreparation.prepare(subject_uid, request, stream?: false),
         {:ok, upstream_response} <-
           execute_response_request(runtime, prepared_request, opts) do
      persist_response(subject_uid, runtime, prepared_request, upstream_response)
    end
  end

  def create_response(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  defp execute_response_request(runtime, prepared_request, opts) do
    case execute_prepared_request(runtime, prepared_request, opts) do
      {:error, reason} when is_map_key(prepared_request, :hosted_tools) ->
        error = ImageGeneration.normalize_execution_error(reason)
        HostedToolTelemetry.emit_failure(prepared_request, error)
        {:error, error}

      result ->
        result
    end
  end

  defp persist_response(subject_uid, runtime, prepared_request, upstream_response) do
    case ImageGeneration.persist_response(
           subject_uid,
           Map.fetch!(upstream_response, :body)
         ) do
      {:ok, body} ->
        HostedToolTelemetry.emit(Map.get(upstream_response, :hosted_tool_metadata))
        {:ok, gateway_response(200, body, runtime)}

      {:error, error} ->
        emit_persistence_failure(prepared_request, upstream_response, error)
        {:error, error}
    end
  end

  defp emit_persistence_failure(prepared_request, upstream_response, error) do
    case Map.get(upstream_response, :hosted_tool_metadata) do
      %{} = metadata ->
        metadata
        |> Map.put("result", "failure")
        |> Map.put("failure_reason", error.code)
        |> HostedToolTelemetry.emit()

      _missing ->
        HostedToolTelemetry.emit_failure(prepared_request, error)
    end
  end

  @doc """
  Retrieves one stored stateful response owned by the authenticated subject.
  """
  @spec retrieve_response(String.t(), binary()) :: {:ok, %{body: map()}} | {:error, term()}
  def retrieve_response(subject_uid, response_id) do
    StatefulLifecycle.retrieve_response(subject_uid, response_id)
  end

  @doc """
  Creates one manual stateful compaction response.
  """
  @spec compact_response(String.t(), map()) :: {:ok, %{body: map()}} | {:error, term()}
  def compact_response(subject_uid, request) when is_map(request) do
    StatefulLifecycle.compact_response(subject_uid, request)
  end

  def compact_response(_subject_uid, _request), do: {:error, :invalid_request_body}

  @doc false
  @spec record_tool_results(String.t(), map()) :: {:ok, %{body: map()}} | {:error, term()}
  def record_tool_results(subject_uid, request) when is_map(request) do
    StatefulLifecycle.record_tool_results(subject_uid, request)
  end

  def record_tool_results(_subject_uid, _request), do: {:error, :invalid_request_body}

  @doc """
  Reads one stored Response scoped to its owning Principal subject.
  """
  @spec get_response(String.t(), binary()) ::
          {:ok, Ankole.AIGateway.Schemas.Message.t()} | {:error, :not_found}
  defdelegate get_response(subject_uid, response_id),
    to: StatefulResponses,
    as: :get_response_for_subject

  @doc """
  Lists an immutable Response chain final-first, capped at 500 rows.
  """
  @spec list_response_chain(String.t(), binary(), pos_integer()) ::
          {:ok, [Ankole.AIGateway.Schemas.Message.t()]} | {:error, :not_found}
  defdelegate list_response_chain(subject_uid, response_id, max_depth \\ 500),
    to: StatefulResponses

  @doc """
  Returns the exact caller-supplied opaque metadata map for a Response.
  """
  @spec response_metadata(Ankole.AIGateway.Schemas.Message.t()) :: map()
  defdelegate response_metadata(response), to: StatefulResponses

  @doc """
  Reads an active conversation scoped to its owning Principal subject.
  """
  @spec get_conversation(String.t(), binary()) ::
          {:ok, Ankole.AIGateway.Schemas.Conversation.t()} | {:error, :invalid_conversation}
  defdelegate get_conversation(subject_uid, conversation_id),
    to: StatefulResponses,
    as: :get_conversation_for_subject

  @doc false
  defdelegate ensure_conversation_in_tx(repo, subject_uid, conversation_key, metadata \\ %{}),
    to: Conversations

  @doc false
  defdelegate update_conversation_metadata_in_tx(repo, conversation, metadata), to: Conversations

  @doc false
  defdelegate active_conversation_for_update(repo, subject_uid, conversation_key),
    to: Conversations

  @doc false
  defdelegate lock_conversation(repo, conversation_id), to: Conversations

  @doc """
  Lists active conversations using generic subject/conversation filters.
  """
  @spec list_active_conversations(module(), keyword()) :: [
          Ankole.AIGateway.Schemas.Conversation.t()
        ]
  defdelegate list_active_conversations(repo, opts \\ []), to: Conversations

  @doc false
  defdelegate list_conversation_responses_in_tx(repo, subject_uid, conversation_id, opts \\ []),
    to: StatefulResponses

  @doc """
  Marks an explicitly identified generating Response failed.
  """
  @spec fail_generating_response(String.t(), binary(), map()) ::
          {:ok, Ankole.AIGateway.Schemas.Message.t() | :already_terminal} | {:error, term()}
  defdelegate fail_generating_response(subject_uid, response_id, error_details),
    to: StatefulResponses

  @doc false
  defdelegate fail_generating_response_in_tx(
                repo,
                subject_uid,
                response_id,
                error_details,
                now
              ),
              to: StatefulResponses

  @doc false
  defdelegate hard_delete_visible_suffix_in_tx(
                repo,
                subject_uid,
                conversation_id,
                response_ids,
                opts \\ []
              ),
              to: StatefulResponses

  @doc false
  defdelegate retract_visible_suffix_in_tx(
                repo,
                subject_uid,
                conversation_id,
                response_ids,
                opts \\ []
              ),
              to: StatefulResponses

  @doc """
  Subscribes to generic live events after validating conversation ownership.
  """
  @spec subscribe(String.t(), binary()) :: :ok | {:error, :invalid_conversation}
  defdelegate subscribe(subject_uid, conversation_id), to: Events

  @spec unsubscribe(String.t(), binary()) :: :ok | {:error, :invalid_conversation}
  defdelegate unsubscribe(subject_uid, conversation_id), to: Events

  @doc false
  defdelegate reconcile_orphaned_response(response_id, opts \\ []), to: StatefulResponses

  @doc false
  defdelegate publish_terminal_event(response, event_type, payload), to: StatefulResponses

  @doc false
  defdelegate runtime_event_snapshot(), to: StatefulResponses

  @doc false
  @spec open_sse_stream(String.t(), map(), keyword()) ::
          {:ok, ResponseStream.t(), map()} | {:error, term()}
  def open_sse_stream(subject_uid, request, opts \\ [])

  def open_sse_stream(subject_uid, request, opts) when is_map(request) do
    request = normalize_request_keys(request)

    with :ok <- reject_http_stateful_fields(request),
         {:ok, %{spec: prepared_request}} <-
           ResponsesPreparation.prepare(subject_uid, request, stream?: true),
         {:ok, stream, meta} <-
           ResponseStream.open(subject_uid, request, prepared_request, opts) do
      {:ok, stream, meta}
    else
      {:error, _reason} = error -> error
      reason -> {:error, reason}
    end
  end

  def open_sse_stream(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc false
  @spec open_websocket_stream(String.t(), map(), keyword()) ::
          {:ok, ResponseStream.t(), map()} | {:error, term()}
  def open_websocket_stream(subject_uid, request, opts \\ [])

  def open_websocket_stream(subject_uid, request, opts) when is_map(request) do
    with {:ok, prepared_request, stateful_context} <-
           prepare_websocket_stream_request(subject_uid, request) do
      result =
        ResponseStream.open(
          subject_uid,
          normalize_request_keys(request),
          prepared_request,
          Keyword.put(opts, :stateful, stateful_context)
        )

      case result do
        {:error, reason} = error ->
          StatefulLifecycle.commit_socket_open_error(stateful_context, reason)
          error

        {:ok, _stream, _meta} = opened ->
          opened
      end
    end
  end

  def open_websocket_stream(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc false
  @spec prepare_websocket_request(String.t(), map()) ::
          {:ok, UniversalAIRequest.t()} | {:error, term()}
  def prepare_websocket_request(subject_uid, request) when is_map(request) do
    with {:ok, prepared_request, _run_attrs} <-
           prepare_websocket_provider_request(subject_uid, request) do
      {:ok, prepared_request}
    end
  end

  def prepare_websocket_request(_subject_uid, _request), do: {:error, :invalid_request_body}

  defp prepare_websocket_stream_request(subject_uid, request) do
    StatefulLifecycle.prepare_and_start_websocket_provider_request(subject_uid, request)
  end

  defp prepare_websocket_provider_request(subject_uid, request) do
    StatefulLifecycle.prepare_websocket_provider_request(subject_uid, request)
  end

  @doc false
  @spec read_response_stream(ResponseStream.t(), non_neg_integer()) :: :ok | {:error, term()}
  def read_response_stream(stream, count \\ 1), do: ResponseStream.read(stream, count)

  @doc false
  @spec cancel_response_stream(ResponseStream.t(), String.t()) :: :ok | {:error, term()}
  def cancel_response_stream(stream, reason \\ "consumer_cancelled"),
    do: ResponseStream.cancel(stream, reason)

  defp execute_prepared_request(_runtime, prepared_request, opts),
    do: UniversalAIRequest.request(prepared_request, opts)

  defp execute_web_fetch(%{"provider_kind" => "jina_reader"} = runtime, request, opts) do
    request
    |> Map.fetch!("urls")
    |> Enum.reduce_while({:ok, []}, fn url, {:ok, results} ->
      single_url_request = Map.put(request, "urls", [url])

      with {:ok, prepared_request} <-
             Providers.build_web_fetch_request(runtime, single_url_request),
           {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
        {:cont, {:ok, results ++ web_fetch_results(Map.fetch!(upstream_response, :body))}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} ->
        {:ok, %{"success" => Enum.all?(results, &is_nil(&1["error"])), "results" => results}}

      {:error, _reason} = error ->
        error
    end
  end

  defp execute_web_fetch(runtime, request, opts) do
    with {:ok, prepared_request} <- Providers.build_web_fetch_request(runtime, request),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, Map.fetch!(upstream_response, :body)}
    end
  end

  defp web_fetch_results(%{"results" => results}) when is_list(results), do: results
  defp web_fetch_results(_body), do: []

  @doc """
  Creates embeddings with a normalized list response shape.

  Request validation happens before provider dispatch because invalid local
  shape should not become an upstream provider call or failover candidate.
  """
  @spec create_embeddings(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_embeddings(subject_uid, request, opts \\ [])

  def create_embeddings(subject_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(subject_uid, "embedding", request),
         :ok <- validate_embeddings_request(request),
         {:ok, prepared_request} <- Providers.build_embeddings_request(runtime, request),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_embeddings(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Creates a rerank result with an OpenRouter-compatible public shape.

  Rerank uses the same model resolver as LLM calls, but requires a provider that
  explicitly supports the `rerank` capability.
  """
  @spec create_rerank(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_rerank(subject_uid, request, opts \\ [])

  def create_rerank(subject_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(subject_uid, "rerank", request),
         :ok <- validate_rerank_request(request),
         {:ok, prepared_request} <- Providers.build_rerank_request(runtime, request),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_rerank(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Creates a normalized web search result through AIGateway.
  """
  @spec create_web_search(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_web_search(subject_uid, request, opts \\ [])

  def create_web_search(subject_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(subject_uid, "web_search", request),
         :ok <- validate_web_search_request(request),
         {:ok, prepared_request} <- Providers.build_web_search_request(runtime, request),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_web_search(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Creates normalized web fetch results through a provider-backed AIGateway path.
  """
  @spec create_web_fetch(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_web_fetch(subject_uid, request, opts \\ [])

  def create_web_fetch(subject_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(subject_uid, "web_fetch", request),
         {:ok, ssrf_filter?} <- SSRFFilter.enabled?(subject_uid),
         :ok <- validate_web_fetch_request(request, ssrf_filter?),
         request = normalize_request_keys(request),
         {:ok, body} <- execute_web_fetch(runtime, request, opts) do
      {:ok, gateway_response(200, body, runtime)}
    end
  end

  def create_web_fetch(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Returns provider-backed web tool availability for an agent runtime.
  """
  @spec web_tools(String.t()) :: {:ok, map()}
  def web_tools(subject_uid) when is_binary(subject_uid) do
    {:ok,
     %{
       "web_search" => web_tool(subject_uid, "web_search"),
       "web_fetch" => web_tool(subject_uid, "web_fetch")
     }}
  end

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

  defp reject_http_stateful_fields(request) do
    request = normalize_request_keys(request)

    case Enum.find(@stateful_http_fields, &Map.has_key?(request, &1)) do
      "store" ->
        if request["store"] == false do
          :ok
        else
          {:error, {:stateful_http_field_forbidden, "store"}}
        end

      field when is_binary(field) ->
        {:error, {:stateful_http_field_forbidden, field}}

      nil ->
        :ok
    end
  end

  defp validate_embeddings_request(request) do
    request = normalize_request_keys(request)

    cond do
      not Map.has_key?(request, "input") ->
        {:error, :missing_input}

      embedding_input?(Map.get(request, "input")) ->
        :ok

      true ->
        {:error, :invalid_embedding_input}
    end
  end

  defp validate_rerank_request(request) do
    request = normalize_request_keys(request)

    cond do
      not non_empty_string?(Map.get(request, "query")) ->
        {:error, :missing_query}

      not rerank_documents?(Map.get(request, "documents")) ->
        {:error, :invalid_documents}

      not valid_top_n?(Map.get(request, "top_n")) ->
        {:error, :invalid_top_n}

      true ->
        :ok
    end
  end

  defp validate_web_search_request(request) do
    request = normalize_request_keys(request)

    cond do
      not non_empty_string?(Map.get(request, "query")) ->
        {:error, :missing_query}

      String.length(String.trim(Map.get(request, "query"))) > 500 ->
        {:error, :invalid_query}

      not valid_web_limit?(Map.get(request, "limit")) ->
        {:error, :invalid_limit}

      true ->
        :ok
    end
  end

  defp validate_web_fetch_request(request, ssrf_filter?) do
    request = normalize_request_keys(request)

    cond do
      not Map.has_key?(request, "urls") ->
        {:error, :missing_urls}

      not valid_extract_urls?(Map.get(request, "urls"), ssrf_filter?) ->
        {:error, :invalid_urls}

      true ->
        :ok
    end
  end

  defp embedding_input?(input) when is_binary(input), do: String.trim(input) != ""

  defp embedding_input?(input) when is_list(input) and input != [] do
    Enum.all?(input, fn
      value when is_binary(value) -> true
      value when is_integer(value) -> true
      value when is_map(value) -> true
      value when is_list(value) -> Enum.all?(value, &is_integer/1)
      _value -> false
    end)
  end

  defp embedding_input?(_input), do: false

  defp rerank_documents?(documents) when is_list(documents) and documents != [] do
    Enum.all?(documents, fn
      document when is_binary(document) -> String.trim(document) != ""
      document when is_map(document) -> map_size(document) > 0
      _document -> false
    end)
  end

  defp rerank_documents?(_documents), do: false

  defp valid_top_n?(nil), do: true
  defp valid_top_n?(value) when is_integer(value), do: value > 0
  defp valid_top_n?(_value), do: false

  defp valid_web_limit?(nil), do: true
  defp valid_web_limit?(value) when is_integer(value), do: value >= 1 and value <= 100
  defp valid_web_limit?(_value), do: false

  defp valid_extract_urls?(urls, ssrf_filter?)
       when is_list(urls) and urls != [] and length(urls) <= 5,
       do: Enum.all?(urls, &safe_web_url?(&1, ssrf_filter?))

  defp valid_extract_urls?(_urls, _ssrf_filter?), do: false

  # The kernel owns URL parsing, host classification, and the SSRF toggle so
  # the provider path and the Agent Computer web/browser guards share one
  # policy; the gateway keeps only its HTTPS-only scheme rule. Cloud metadata
  # endpoints are rejected regardless of the `security.ssrf_filter` policy.
  defp safe_web_url?(url, ssrf_filter?) when is_binary(url),
    do: NativeKernel.validate_web_url(url, ["https"], ssrf_filter?) == :ok

  defp safe_web_url?(_url, _ssrf_filter?), do: false

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp normalize_request_keys(map) when is_map(map) do
    MapUtils.normalize_request_keys(map)
  end

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

  defp web_tool(subject_uid, capability) do
    profile = capability

    case ModelProfiles.resolve_runtime_profile(subject_uid, profile) do
      {:ok, runtime} ->
        %{
          "available" => true,
          "model" => ModelSelectors.public_selector(capability, profile),
          "provider_id" => runtime["provider_id"],
          "provider_kind" => runtime["provider_kind"]
        }

      {:error, reason} ->
        %{
          "available" => false,
          "reason" => unavailable_web_tool_reason(reason)
        }
    end
  end

  defp unavailable_web_tool_reason(:model_profile_not_configured),
    do: "model_profile_not_configured"

  defp unavailable_web_tool_reason(:invalid_model_profile), do: "invalid_model_profile"
  defp unavailable_web_tool_reason(:agent_not_found), do: "agent_not_found"
  defp unavailable_web_tool_reason(:provider_disabled), do: "provider_disabled"
  defp unavailable_web_tool_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp unavailable_web_tool_reason(reason), do: inspect(reason)
end
