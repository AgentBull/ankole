defmodule Ankole.AIGateway do
  @moduledoc """
  Control-plane owned AI provider gateway.

  AIGateway keeps provider credentials and provider differences in Elixir. It
  serves Principal-scoped OpenResponses/OpenRouter-shaped requests without
  depending on caller workflow lifecycle semantics.

  This module is also the Ash domain of the gateway resources. Other domains
  read the rows through its defines. The response, provider, and artifact
  writes go through the functions below and their owner modules.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  alias Ankole.AIGateway.CodexVision
  alias Ankole.AIGateway.CompactionRequests
  alias Ankole.AIGateway.Audio
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.Decisions
  alias Ankole.AIGateway.ImageRequests
  alias Ankole.AIGateway.MediaJobs
  alias Ankole.AIGateway.Models
  alias Ankole.AIGateway.OCR
  alias Ankole.AIGateway.Observability
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.RequestExecution
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.ResponsesPreparation
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.StatefulLifecycle
  alias Ankole.AIGateway.UsageLedger
  alias Ankole.AIGateway.WebSearch
  alias Ankole.Attrs
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Security.SSRFFilter

  resources do
    resource(Ankole.AIGateway.Schemas.Artifact)
    resource(Ankole.AIGateway.Schemas.CompactionArtifact)
    resource(Ankole.AIGateway.Schemas.MediaJob)
    resource(Ankole.AIGateway.Schemas.UsageRecord)
    resource(Ankole.AIGateway.UsageConsole)

    resource Ankole.AIGateway.Schemas.Conversation do
      # `get_conversation/3` reads a conversation of one subject.
      define(:get_conversation_by_id, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_conversations, action: :read)
    end

    resource Ankole.AIGateway.Schemas.Message do
      define(:get_message, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_messages, action: :read)
    end
  end

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/ai-gateway/conversations", Ankole.AIGateway.Schemas.Conversation do
        index(:console_list, name: "list_ai_gateway_conversations", derive_sort?: false)
        get(:read, name: "get_ai_gateway_conversation")
      end

      base_route "/ai-gateway/conversations/:conversation_id/messages",
                 Ankole.AIGateway.Schemas.Message do
        index(:console_list, name: "list_ai_gateway_messages", derive_sort?: false)
      end

      route(Ankole.AIGateway.UsageConsole, :get, "/ai-gateway/usage", :summary,
        name: "get_ai_gateway_usage"
      )
    end
  end

  @stateful_http_fields ~w(previous_response_id conversation store)

  @type gateway_response :: %{
          required(:status) => pos_integer(),
          required(:body) => map(),
          required(:model_ref) => map()
        }

  @type compaction_response :: %{required(:body) => map()}

  @doc """
  Creates one stateless OpenResponses response.

  The call resolves the agent-visible selector, prepares a provider-owned
  UniversalAIRequest spec, calls the UniversalAIClient, and normalizes the result back
  into the AIGateway response body. A compaction trigger returns only its
  response body; it does not select a model response or expose a model reference.
  """
  @spec create_response(String.t(), map(), keyword()) ::
          {:ok, gateway_response() | compaction_response()} | {:error, term()}
  def create_response(subject_uid, request, opts \\ [])

  def create_response(subject_uid, request, opts) when is_map(request) do
    request = Attrs.normalize_external_attrs(request)

    # The trigger is a request item, not a transport event, so every transport
    # answers it the same way. AIGateway owns it on all of them, which is also
    # why it never reaches a Provider adapter by itself.
    if CompactionRequests.compaction_trigger?(request) do
      with :ok <- ensure_stateless_request(request),
           {:ok, body} <-
             CompactionRequests.compact_from_trigger(
               subject_uid,
               request,
               Keyword.take(opts, [:subject_type, :request_context])
             ),
           do: {:ok, %{body: body}}
    else
      create_model_response(subject_uid, request, opts)
    end
  end

  def create_response(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  defp create_model_response(subject_uid, request, opts) do
    with :ok <- reject_http_stateful_fields(request),
         {:ok, %{runtime: runtime, spec: prepared_request, driver: driver}} <-
           ResponsesPreparation.prepare(
             subject_uid,
             request,
             Keyword.put(opts, :stream?, false)
           ),
         {:ok, response} <-
           execute_response_driver(
             driver,
             subject_uid,
             request,
             runtime,
             prepared_request,
             opts
           ) do
      {:ok, response}
    end
  end

  @doc """
  Returns the full output text of a completed response body, or an error.

  Machine callers that parse response text must use this instead of reading
  `output` directly, because only the gateway knows when a body is whole: a
  response that ended on `max_output_tokens` still carries valid-looking
  partial text, and reasoning can consume the whole output budget and leave
  a completed-looking body with no text at all.
  """
  @spec completed_output_text(map()) :: {:ok, String.t()} | {:error, term()}
  def completed_output_text(%{"status" => "completed"} = body) do
    case output_text(body) do
      "" -> {:error, :missing_response_text}
      text -> {:ok, text}
    end
  end

  def completed_output_text(body) when is_map(body) do
    {:error,
     {:incomplete_response, Map.take(body, ["status", "incomplete_details", "error", "usage"])}}
  end

  defp output_text(%{"output_text" => text}) when is_binary(text), do: String.trim(text)

  defp output_text(%{"output" => output}) when is_list(output) do
    output
    |> ResponseItems.message_content_parts()
    |> ResponseItems.text_parts()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp output_text(_body), do: ""

  defp execute_response_driver(
         :single_request,
         subject_uid,
         request,
         runtime,
         prepared_request,
         opts
       ) do
    observation =
      subject_uid
      |> Observability.start_response(request, opts)
      |> Observability.start_round(%{runtime: runtime}, prepared_request)

    execute_opts =
      Keyword.put(opts, :credential_retry_observer, fn reason, delay_ms ->
        Observability.record_credential_retry(observation, reason, delay_ms)
      end)

    case execute_response_request(runtime, prepared_request, execute_opts) do
      {:ok, upstream_response} ->
        observation = Observability.finish_round(observation, upstream_response)

        :ok =
          UsageLedger.record(
            runtime,
            Keyword.get(opts, :subject_type),
            Map.fetch!(upstream_response, :body),
            caller: Keyword.get(opts, :caller),
            aggregate_includes_tool_usage?: Map.has_key?(prepared_request, :hosted_tools)
          )

        result =
          prepared_request
          |> ResponseStream.project_non_streaming_response(upstream_response)
          |> then(&persist_response(subject_uid, runtime, prepared_request, &1, opts))

        _observation = Observability.finish_response(observation, result)
        result

      {:error, reason} = error ->
        _observation = Observability.fail(observation, reason)
        error
    end
  end

  defp execute_response_driver(
         :response_stream,
         subject_uid,
         request,
         runtime,
         prepared_request,
         opts
       ) do
    case ResponseStream.collect(subject_uid, request, prepared_request, opts) do
      {:ok, %{terminal_response: %{} = body}, _meta} ->
        {:ok, RequestExecution.gateway_response(200, body, runtime)}

      {:ok, _outcome, _meta} ->
        {:error, :response_stream_missing_terminal_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_response_request(runtime, prepared_request, opts) do
    {hosted_attempt, prepared_request} =
      ImageGeneration.pop_credential_attempt(prepared_request)

    do_execute_response_request(runtime, prepared_request, hosted_attempt, opts)
  end

  defp do_execute_response_request(runtime, prepared_request, hosted_attempt, opts) do
    case RequestExecution.execute_prepared_request(runtime, prepared_request, opts) do
      {:error, {:credential_pool_exhausted, _details} = exhausted} ->
        {:error, exhausted}

      {:error, reason}
      when is_map(hosted_attempt) ->
        handle_hosted_response_failure(hosted_attempt, reason)

      {:error, reason} when is_map_key(prepared_request, :hosted_tools) ->
        normalize_hosted_execution_error(reason)

      {:ok, upstream_response} = result when is_map(hosted_attempt) ->
        :ok = ImageGeneration.record_credential_usage(hosted_attempt, upstream_response)
        :ok = ImageGeneration.record_usage(hosted_attempt, runtime, upstream_response, opts)
        result

      result ->
        result
    end
  end

  defp handle_hosted_response_failure(hosted_attempt, reason) do
    cond do
      ImageGeneration.credential_failure?(reason) ->
        :ok = ImageGeneration.record_credential_failure(hosted_attempt, reason)
        normalize_hosted_execution_error(reason)

      ImageGeneration.hosted_execution_failure?(reason) ->
        normalize_hosted_execution_error(reason)

      true ->
        {:error, reason}
    end
  end

  defp normalize_hosted_execution_error(reason) do
    error = ImageGeneration.normalize_execution_error(reason)
    {:error, error}
  end

  defp persist_response(subject_uid, runtime, prepared_request, upstream_response, opts) do
    case ImageGeneration.persist_response(
           subject_uid,
           Map.fetch!(upstream_response, :body),
           persist_artifacts?: Keyword.get(opts, :persist_artifacts?, true)
         ) do
      {:ok, body} ->
        body = Map.put(body, "id", "tmp_resp_#{Ankole.Ecto.UUIDv7.autogenerate()}")
        {:ok, RequestExecution.gateway_response(200, body, runtime)}

      {:error, error} ->
        emit_persistence_failure(runtime, prepared_request, upstream_response, error)
        {:error, error}
    end
  end

  defp emit_persistence_failure(runtime, prepared_request, upstream_response, error) do
    metadata = Map.get(upstream_response, :hosted_tool_metadata) || %{}

    reason = %{
      "code" => error.code,
      "status" => error.status,
      "stage" => "artifact_persistence",
      "hosted_tool_metadata" => Map.put(metadata, "failure_reason", error.code)
    }

    context =
      Map.merge(ImageGeneration.failure_log_fields(prepared_request, reason), %{
        capability: runtime["capability"],
        provider_id: runtime["provider_id"],
        provider_kind: runtime["provider_kind"],
        model: runtime["model"],
        api_resolver: prepared_request.api_resolver,
        upstream_host: RequestExecution.request_upstream_host(prepared_request)
      })

    FailureDiagnostics.log(
      "ai_gateway.response_failed",
      "AIGateway response persistence failed",
      context,
      error
    )
  end

  @doc """
  Retrieves one stored stateful response owned by the authenticated subject.
  """
  @spec retrieve_response(String.t(), binary()) :: {:ok, %{body: map()}} | {:error, term()}
  def retrieve_response(subject_uid, response_id) do
    StatefulLifecycle.retrieve_response(subject_uid, response_id)
  end

  @doc """
  Reads one stored Response scoped to its owning Principal subject.
  """
  @spec get_response(String.t(), binary()) ::
          {:ok, Ankole.AIGateway.Schemas.Message.t()} | {:error, :not_found}
  defdelegate get_response(subject_uid, response_id),
    to: Ankole.AIGateway.ResponseChain,
    as: :get_response_for_subject

  @doc """
  Lists an immutable Response chain final-first, capped at 500 rows.
  """
  @spec list_response_chain(String.t(), binary(), pos_integer()) ::
          {:ok, [Ankole.AIGateway.Schemas.Message.t()]} | {:error, :not_found}
  defdelegate list_response_chain(subject_uid, response_id, max_depth \\ 500),
    to: Ankole.AIGateway.ResponseChain

  @doc """
  Returns the exact caller-supplied opaque metadata map for a Response.
  """
  @spec response_metadata(Ankole.AIGateway.Schemas.Message.t()) :: map()
  defdelegate response_metadata(response), to: Ankole.AIGateway.ResponseChain

  @doc "Sums the counted model rounds of one Signal's work for its execution record."
  defdelegate turn_usage(signal_id), to: UsageLedger

  @doc """
  Reads a conversation scoped to its owning Principal subject.
  `include_ended: true` permits reading retained history after the conversation ends.
  """
  @spec get_conversation(String.t(), binary()) ::
          {:ok, Ankole.AIGateway.Schemas.Conversation.t()} | {:error, :invalid_conversation}
  defdelegate get_conversation(subject_uid, conversation_id, opts \\ []),
    to: Ankole.AIGateway.ResponseChain,
    as: :get_conversation_for_subject

  @doc "Records caller-supplied tool results in the current transaction."
  defdelegate record_tool_results_in_tx(subject_uid, request, metadata),
    to: StatefulLifecycle

  @doc false
  defdelegate ensure_conversation_in_tx(subject_uid, conversation_key, metadata \\ %{}),
    to: Conversations

  @doc false
  defdelegate active_conversation_for_update(subject_uid, conversation_key),
    to: Conversations

  @doc false
  defdelegate end_active_conversation_in_tx(subject_uid, conversation_key, now),
    to: Conversations

  @doc false
  defdelegate lock_conversation(conversation_id), to: Conversations

  @doc """
  Lists active conversations using generic subject/conversation filters.
  """
  @spec list_active_conversations(keyword()) :: [
          Ankole.AIGateway.Schemas.Conversation.t()
        ]
  defdelegate list_active_conversations(opts \\ []), to: Conversations

  @doc false
  defdelegate conversation_exists_by_key?(subject_uid, conversation_key), to: Conversations

  @doc false
  defdelegate list_conversation_responses_in_tx(subject_uid, conversation_id, opts \\ []),
    to: Ankole.AIGateway.ResponseChain

  @doc """
  Marks an explicitly identified generating Response failed.
  """
  @spec fail_generating_response(String.t(), binary(), map()) ::
          {:ok, Ankole.AIGateway.Schemas.Message.t() | :already_terminal} | {:error, term()}
  defdelegate fail_generating_response(subject_uid, response_id, error_details),
    to: Ankole.AIGateway.ResponseCommit

  @doc false
  defdelegate fail_generating_response_in_tx(
                subject_uid,
                response_id,
                error_details,
                now
              ),
              to: Ankole.AIGateway.ResponseCommit

  @doc false
  defdelegate retract_generating_response_in_tx(
                subject_uid,
                response_id,
                reason,
                now
              ),
              to: Ankole.AIGateway.ResponseCommit

  @doc false
  defdelegate hard_delete_visible_suffix_in_tx(
                subject_uid,
                conversation_id,
                response_ids,
                opts \\ []
              ),
              to: Ankole.AIGateway.ResponseChain

  @doc false
  defdelegate retract_visible_suffix_in_tx(
                subject_uid,
                conversation_id,
                response_ids,
                opts \\ []
              ),
              to: Ankole.AIGateway.ResponseChain

  @doc false
  defdelegate reconcile_orphaned_response(response_id, opts \\ []),
    to: Ankole.AIGateway.ResponseCommit

  defdelegate reconcile_orphaned_response_in_tx(response_id, opts),
    to: Ankole.AIGateway.ResponseCommit

  @doc false
  defdelegate publish_terminal_event(response, event_type, payload),
    to: Ankole.AIGateway.ResponseCommit

  @doc false
  @spec open_sse_stream(String.t(), map(), keyword()) ::
          {:ok, ResponseStream.t(), map()} | {:error, term()}
  def open_sse_stream(subject_uid, request, opts \\ [])

  def open_sse_stream(subject_uid, request, opts) when is_map(request) do
    request = Attrs.normalize_external_attrs(request)

    with :ok <- reject_http_stateful_fields(request),
         {:ok, %{spec: prepared_request}} <-
           ResponsesPreparation.prepare(
             subject_uid,
             request,
             Keyword.put(opts, :stream?, true)
           ),
         {:ok, stream, meta} <-
           ResponseStream.open(subject_uid, request, prepared_request, opts) do
      {:ok, stream, meta}
    else
      {:error, _reason} = error -> error
      reason -> {:error, reason}
    end
  end

  def open_sse_stream(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Applies the model's image rule to input items that enter stateful history
  without a model request, such as images that follow tool results. A model
  with image input keeps them. For a text-only model, the frozen vision
  fallback describes them, or a marker states that they are unavailable.
  """
  @spec adapt_images(String.t(), [map()], map(), keyword()) :: [map()]
  def adapt_images(subject_uid, items, vision, opts) do
    {:ok, %{"input" => items}} =
      CodexVision.adapt(subject_uid, %{"input" => items, "__ankole_codex_vision" => vision}, opts)

    items
  end

  @doc false
  @spec open_websocket_stream(String.t(), map(), keyword()) ::
          {:ok, ResponseStream.t(), map()} | {:error, term()}
  def open_websocket_stream(subject_uid, request, opts \\ [])

  def open_websocket_stream(subject_uid, request, opts) when is_map(request) do
    with {:ok, prepared_request, stateful_context} <-
           StatefulLifecycle.prepare_websocket_request(subject_uid, request, opts) do
      result =
        ResponseStream.open(
          subject_uid,
          Attrs.normalize_external_attrs(request),
          prepared_request,
          opts |> Keyword.delete(:oidc_client_id) |> Keyword.put(:stateful, stateful_context)
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
  @spec read_response_stream(ResponseStream.t(), non_neg_integer()) :: :ok | {:error, term()}
  def read_response_stream(stream, count \\ 1), do: ResponseStream.read(stream, count)

  @doc "Reads the visible complete Response ancestry of an owned model conversation."
  defdelegate visible_response_chain(subject_uid, conversation_id, opts \\ []),
    to: Ankole.AIGateway.ResponseChain

  @doc "Reads caller metadata from complete ordinary rows across the visible ancestry."
  defdelegate visible_response_metadata(subject_uid, conversation_id),
    to: Ankole.AIGateway.ResponseChain

  @doc "Reads the visible Response suffix for one opaque caller-metadata string selector."
  defdelegate visible_response_suffix(subject_uid, conversation_id, selector),
    to: Ankole.AIGateway.ResponseChain

  @doc false
  @spec cancel_response_stream(ResponseStream.t(), String.t()) :: :ok | {:error, term()}
  def cancel_response_stream(stream, reason \\ "consumer_cancelled"),
    do: ResponseStream.cancel(stream, reason)

  defp execute_web_fetch(%{"provider_kind" => "jina_reader"} = runtime, request, opts) do
    request
    |> Map.fetch!("urls")
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {url, index}, {:ok, results} ->
      single_url_request = Map.put(request, "urls", [url])

      with {:ok, request_runtime} <- web_fetch_runtime(runtime, index),
           {:ok, prepared_request} <-
             Providers.build_web_fetch_request(request_runtime, single_url_request),
           {:ok, upstream_response} <-
             RequestExecution.execute_prepared_request(request_runtime, prepared_request, opts) do
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
         {:ok, upstream_response} <-
           RequestExecution.execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, Map.fetch!(upstream_response, :body)}
    end
  end

  defp web_fetch_runtime(runtime, 0), do: {:ok, runtime}
  defp web_fetch_runtime(runtime, _index), do: Resolver.reselect_credential(runtime)

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
         {:ok, upstream_response} <-
           RequestExecution.execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, RequestExecution.gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
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
         {:ok, upstream_response} <-
           RequestExecution.execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, RequestExecution.gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_rerank(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Creates one generated or edited image through the image provider that the
  request's `model` selects. With `respect_provider_hosted?: true`, the
  Principal's `provider_hosted.image_generate` toggle chooses the executor.
  """
  @spec create_image(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_image(subject_uid, request, opts \\ []) do
    ImageRequests.create_image(subject_uid, request, opts, &create_response/3)
  end

  @doc """
  Creates a normalized web search result through AIGateway.
  """
  @spec create_web_search(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_web_search(subject_uid, request, opts \\ []) do
    WebSearch.create_web_search(subject_uid, request, opts, &create_response/3)
  end

  @doc """
  Answers typed questions about a state with probabilities, through the
  `decision` profile or, when it is not configured, the `light` language model.
  """
  @spec create_decision(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_decision(subject_uid, request, opts \\ []) do
    Decisions.create_decision(subject_uid, request, opts, &create_response/3)
  end

  @doc """
  Turns text into audio through the `speech` profile. The response body holds
  the audio bytes under `"audio"` and their media type under `"content_type"`.
  """
  @spec create_speech(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_speech(subject_uid, request, opts \\ []),
    do: Audio.create_speech(subject_uid, request, opts)

  @doc "Turns audio into text through the `transcription` profile."
  @spec create_transcription(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_transcription(subject_uid, request, opts \\ []),
    do: Audio.create_transcription(subject_uid, request, opts)

  @doc """
  Creates a media job that generates a video through the `video` profile or
  music through the `music` profile. The response body is the job, which the
  caller reads with `fetch_media_job/3` until it is `completed` or `failed`.
  """
  @spec create_media_job(String.t(), String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_media_job(subject_uid, capability, request, opts \\ []),
    do: MediaJobs.create(subject_uid, capability, request, opts)

  @doc "Returns the caller's `video` or `music` media job."
  @spec fetch_media_job(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate fetch_media_job(subject_uid, capability, id), to: MediaJobs, as: :fetch

  @doc "Returns the stored object and media type of the caller's completed media job."
  @spec media_job_content(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate media_job_content(subject_uid, capability, id), to: MediaJobs, as: :content

  @doc """
  Reads the text of a PDF or a document image as Markdown, through the `ocr`
  profile or, when it is not configured, a language model that accepts
  images.
  """
  @spec create_ocr(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_ocr(subject_uid, request, opts \\ []) do
    OCR.create_ocr(subject_uid, request, opts, &create_response/3)
  end

  @doc """
  Names why one web fetch page has no usable content, or returns nil.

  `script_shell` is a page that serves a script-loading shell instead of its
  text, and `empty_text` is a fetch that extracted no text. A provider can set
  `render_warning` itself. An error page has no warning.
  """
  @spec web_fetch_render_warning(map()) :: String.t() | nil
  def web_fetch_render_warning(%{"error" => error}) when error not in [nil, false, ""], do: nil

  def web_fetch_render_warning(%{"render_warning" => warning}) when is_binary(warning),
    do: warning

  def web_fetch_render_warning(page) do
    text = page["text"] || ""

    cond do
      String.trim(text) == "" ->
        "empty_text"

      byte_size(text) <= 4_000 and
          Regex.match?(
            ~r/enable\s+javascript|javascript\s+is\s+(?:required|disabled|not enabled)/i,
            text
          ) ->
        "script_shell"

      true ->
        nil
    end
  end

  @doc """
  Creates normalized web fetch results through a provider-backed AIGateway path.
  """
  @spec create_web_fetch(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_web_fetch(subject_uid, request, opts \\ [])

  def create_web_fetch(subject_uid, request, opts) when is_map(request) do
    agent_uid =
      case Ankole.Principals.get_agent(subject_uid) do
        {:ok, %{agent: _agent}} -> subject_uid
        {:error, _reason} -> nil
      end

    with {:ok, runtime} <- Resolver.resolve_request_model(subject_uid, "web_fetch", request),
         {:ok, ssrf_filter?} <- SSRFFilter.enabled?(agent_uid),
         :ok <- validate_web_fetch_request(request, ssrf_filter?),
         request = Attrs.normalize_external_attrs(request),
         {:ok, body} <- execute_web_fetch(runtime, request, opts) do
      {:ok, RequestExecution.gateway_response(200, body, runtime)}
    end
  end

  def create_web_fetch(_subject_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Lists OpenRouter-shaped model selectors available through AIGateway.
  """
  @spec list_models(String.t(), String.t(), map()) :: {:ok, map()}
  defdelegate list_models(subject_uid, subject_type, params \\ %{}), to: Models

  @doc "Lists OpenRouter-shaped model aliases configured for one OIDC Client."
  @spec list_model_aliases(map(), map()) :: {:ok, map()}
  defdelegate list_model_aliases(model_aliases, params \\ %{}), to: Models

  @doc """
  Returns whether a request asked for an SSE response.
  """
  @spec stream_requested?(map()) :: boolean()
  def stream_requested?(%{"stream" => true}), do: true
  def stream_requested?(%{stream: true}), do: true
  def stream_requested?(_request), do: false

  @doc """
  Rejects the stateful selectors on a stateless entrypoint.

  Every HTTP Responses entrypoint is stateless, including the compaction
  trigger. A caller that names stored history there would otherwise have that
  history silently dropped, because only the WebSocket resolves an anchor.
  """
  @spec ensure_stateless_request(map()) ::
          :ok | {:error, {:stateful_http_field_forbidden, String.t()}}
  def ensure_stateless_request(request) when is_map(request),
    do: reject_http_stateful_fields(request)

  defp reject_http_stateful_fields(request) do
    request = Attrs.normalize_external_attrs(request)

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
    request = Attrs.normalize_external_attrs(request)

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
    request = Attrs.normalize_external_attrs(request)

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

  defp validate_web_fetch_request(request, ssrf_filter?) do
    request = Attrs.normalize_external_attrs(request)

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
end
