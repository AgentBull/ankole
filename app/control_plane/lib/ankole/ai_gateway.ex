defmodule Ankole.AIGateway do
  @moduledoc """
  Control-plane owned AI provider gateway.

  AIGateway keeps provider credentials and provider differences in Elixir. Worker
  callers authenticate as an agent and send OpenResponses/OpenRouter-shaped
  requests to this module through the Phoenix API.
  """

  alias Ankole.AIGateway.Models
  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ModelSelectors
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.UniversalAIRequest
  alias Ankole.AIGateway.Schemas.Message

  @stateful_http_fields ~w(previous_response_id conversation store)
  @websocket_continuation_fields ~w(previous_response_id conversation)
  @input_message_roles ~w(system developer user)
  @stateful_request_metadata_fields ~w(
    instructions tools tool_choice truncation parallel_tool_calls text top_p
    presence_penalty frequency_penalty top_logprobs temperature reasoning
    max_output_tokens max_tool_calls service_tier prompt_cache_key
    safety_identifier user
  )

  @internal_response_metadata_keys ~w(
    actor_event_id auto_compaction auto_truncation error usage model request_model
    provider_model model_ref provider provider_id provider_kind instructions tools
    tool_choice truncation parallel_tool_calls text top_p presence_penalty
    frequency_penalty top_logprobs temperature reasoning max_output_tokens
    max_tool_calls service_tier prompt_cache_key safety_identifier user
    max_tool_calls_used max_tool_calls_exhausted provider_metadata tool_results
    stop_reason response incomplete_details tool_result_journal tool_result_idempotency_key
  )

  @tool_result_record_db_retry_delays_ms [50, 100, 200, 400, 800, 1_600]

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
  def create_response(agent_uid, request, opts \\ [])

  def create_response(agent_uid, request, opts) when is_map(request) do
    request = normalize_request_keys(request)

    with :ok <- reject_http_stateful_fields(request),
         {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "llm", request),
         {:ok, prepared_request} <-
           Providers.build_response_request(runtime, strip_noop_provider_fields(request),
             stream?: false
           ),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_response(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Retrieves one stored stateful response owned by the authenticated agent.
  """
  @spec retrieve_response(String.t(), binary()) :: {:ok, %{body: map()}} | {:error, term()}
  def retrieve_response(agent_uid, response_id) do
    with :ok <- validate_external_response_id(response_id),
         {:ok, %Message{} = message} <-
           StatefulResponses.get_message_for_agent(agent_uid, response_id) do
      {:ok, %{body: response_resource(message)}}
    else
      _not_found_or_invalid ->
        {:error, :not_found}
    end
  end

  @doc """
  Creates one manual stateful compaction response.
  """
  @spec compact_response(String.t(), map()) :: {:ok, %{body: map()}} | {:error, term()}
  def compact_response(agent_uid, request) when is_map(request) do
    request = normalize_request_keys(request)

    with {:ok, previous_response_id} <- compact_previous_response_id(request),
         {:ok, compaction_item} <- compact_item(request),
         {:ok, %Message{} = message} <-
           StatefulResponses.compact_response(
             agent_uid,
             previous_response_id,
             compaction_item,
             compact_metadata(request)
           ) do
      {:ok, %{body: response_resource(message)}}
    end
  end

  def compact_response(_agent_uid, _request), do: {:error, :invalid_request_body}

  @doc false
  @spec record_tool_results(String.t(), map()) :: {:ok, %{body: map()}} | {:error, term()}
  def record_tool_results(agent_uid, request) when is_map(request) do
    request = normalize_request_keys(request)
    previous_response_id = request["previous_response_id"]
    actor_event_id = get_in(request, ["metadata", "actor_event_id"])

    with :ok <- validate_tool_results_record_shape(request),
         {:ok, current_input} <- normalize_stateful_input(Map.get(request, "input")),
         {:ok, %Message{} = message} <-
           record_tool_results_with_transient_db_retry(%{
             agent_uid: agent_uid,
             actor_event_id: actor_event_id,
             previous_response_id: previous_response_id,
             request_items: current_input,
             metadata: stateful_run_metadata(request, %{})
           }) do
      {:ok, %{body: response_resource(message)}}
    end
  end

  def record_tool_results(_agent_uid, _request), do: {:error, :invalid_request_body}

  defp record_tool_results_with_transient_db_retry(attrs) do
    with_transient_db_checkout_retry(@tool_result_record_db_retry_delays_ms, fn ->
      StatefulResponses.record_tool_results(attrs)
    end)
  end

  defp with_transient_db_checkout_retry(delays_ms, fun) do
    fun.()
  rescue
    error in DBConnection.ConnectionError ->
      if transient_db_checkout_error?(error) do
        retry_transient_db_checkout(delays_ms, Exception.message(error), fun)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp retry_transient_db_checkout([delay_ms | rest], _message, fun) do
    Process.sleep(delay_ms)
    with_transient_db_checkout_retry(rest, fun)
  end

  defp retry_transient_db_checkout([], message, _fun) do
    {:error,
     {:tool_results_record_unavailable,
      %{
        "stage" => "tool_results_record",
        "retryable" => true,
        "message" => message
      }}}
  end

  defp transient_db_checkout_error?(%DBConnection.ConnectionError{} = error) do
    message = Exception.message(error)

    String.contains?(message, "could not checkout the connection") and
      String.contains?(message, "connection not available")
  end

  @doc false
  @spec open_sse_stream(String.t(), map(), keyword()) ::
          {:ok, Ankole.Kernel.UniversalAIClient.stream(), map()} | {:error, term()}
  def open_sse_stream(agent_uid, request, opts \\ [])

  def open_sse_stream(agent_uid, request, opts) when is_map(request) do
    request = normalize_request_keys(request)

    with :ok <- reject_http_stateful_fields(request),
         {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "llm", request),
         {:ok, prepared_request} <-
           Providers.build_response_request(runtime, strip_noop_provider_fields(request),
             stream?: true
           ) do
      UniversalAIRequest.open_stream(prepared_request, :sse, opts)
    else
      {:error, _reason} = error -> error
      reason -> {:error, reason}
    end
  end

  def open_sse_stream(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc false
  @spec open_websocket_stream(String.t(), map(), keyword()) ::
          {:ok, Ankole.Kernel.UniversalAIClient.stream(), map()} | {:error, term()}
  def open_websocket_stream(agent_uid, request, opts \\ [])

  def open_websocket_stream(agent_uid, request, opts) when is_map(request) do
    with {:ok, prepared_request, stateful_context} <-
           prepare_websocket_stream_request(agent_uid, request) do
      case UniversalAIRequest.open_stream(prepared_request, :websocket_text, opts) do
        {:ok, stream, meta} ->
          {:ok, stream, put_stateful_stream_meta(meta, stateful_context)}

        {:error, reason} ->
          commit_stateful_open_error(stateful_context, reason)
          {:error, reason}
      end
    end
  end

  def open_websocket_stream(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc false
  @spec prepare_websocket_request(String.t(), map()) ::
          {:ok, UniversalAIRequest.t()} | {:error, term()}
  def prepare_websocket_request(agent_uid, request) when is_map(request) do
    with {:ok, prepared_request, _run_attrs} <-
           prepare_websocket_provider_request(agent_uid, request) do
      {:ok, prepared_request}
    end
  end

  def prepare_websocket_request(_agent_uid, _request), do: {:error, :invalid_request_body}

  defp prepare_websocket_stream_request(agent_uid, request) do
    with {:ok, prepared_request, run_attrs} <-
           prepare_websocket_provider_request(agent_uid, request),
         {:ok, stateful_context} <- maybe_start_websocket_stateful_run(run_attrs) do
      {:ok, prepared_request, stateful_context}
    end
  end

  defp prepare_websocket_provider_request(agent_uid, request) do
    with :ok <- validate_websocket_stateful_shape(request),
         {:ok, runtime} <-
           Resolver.resolve_request_model(agent_uid, "llm", normalize_request_keys(request)),
         {:ok, request_for_provider, run_attrs} <-
           provider_websocket_request(agent_uid, request, runtime),
         {:ok, prepared_request} <-
           Providers.build_response_request(runtime, request_for_provider, stream?: true) do
      {:ok, prepared_request, run_attrs}
    end
  end

  # Step 1: Expands the message chain for a stateful run and injects the
  # expanded history into the provider-facing request input.
  #
  # This replaces the old worker-side history resolution path: the gateway now
  # owns history expansion (plan §3.9 step 3).
  #
  # After expansion, stateful fields are stripped from the request so they
  # are not sent to the upstream provider (plan §3.9 step 6):
  #   - previous_response_id (Ankole UUID, would 404 on OpenAI)
  #   - store (Ankole stateful switch; provider dispatch disables upstream storage)
  #   - conversation (internal correlation)
  #   - metadata.actor_event_id (internal correlation)
  defp provider_websocket_request(agent_uid, request, runtime) do
    request = normalize_request_keys(request)

    if request["store"] == true do
      expand_and_inject_history(agent_uid, request, runtime)
    else
      {:ok, strip_stateful_provider_fields(request), nil}
    end
  end

  defp expand_and_inject_history(agent_uid, request, runtime) do
    conversation_id = request["conversation"]
    actor_event_id = get_in(request, ["metadata", "actor_event_id"])
    previous_response_id = request["previous_response_id"]

    with :ok <- validate_external_optional_response_id(previous_response_id),
         {:ok, conversation} <-
           resolve_stateful_request_conversation(agent_uid, conversation_id, previous_response_id),
         :ok <- StatefulResponses.validate_response_anchor(conversation.id, previous_response_id),
         effective_previous_response_id <-
           effective_previous_response_id(conversation.id, previous_response_id),
         {:ok, current_input} <- normalize_stateful_input(Map.get(request, "input")),
         history <-
           StatefulResponses.expand_history(conversation.id,
             previous_response_id: effective_previous_response_id,
             protected_tail_items: current_input
           ),
         request <-
           request_with_effective_previous_response_id(request, effective_previous_response_id),
         {:ok, compaction} <-
           Compaction.maybe_compact_history(
             agent_uid,
             conversation.id,
             history,
             current_input,
             request,
             runtime
           ) do
      # Determine the anchor: explicit previous_response_id or latest visible leaf.
      history = compaction.history
      previous_response_id = compaction.previous_response_id

      current_input =
        Compaction.maybe_inject_memory_pre_compaction_nudge(
          current_input,
          compaction.run_metadata
        )

      history_items = messages_to_response_items(history, runtime_input_modalities(runtime))

      # The request's own "input" is the current-round delta (user input or
      # function_call_output from the worker). We prepend expanded history items.
      expanded_input = history_items ++ current_input

      {provider_request, max_tool_calls_metadata} =
        request
        |> Map.put("input", expanded_input)
        |> apply_max_tool_calls_strategy(conversation.id, previous_response_id, actor_event_id)

      # Strip stateful fields before sending to the provider.
      provider_request = strip_stateful_provider_fields(provider_request)

      {:ok, provider_request,
       %{
         agent_uid: agent_uid,
         conversation_id: conversation.id,
         # Source table: metadata.actor_event_id is actor_events.id supplied by
         # the actor turn; it is stored only as AIGateway correlation metadata.
         actor_event_id: actor_event_id,
         previous_response_id: previous_response_id,
         request_items: current_input,
         metadata:
           stateful_run_metadata(
             request,
             Map.merge(compaction.run_metadata, max_tool_calls_metadata)
           )
       }}
    end
  end

  defp apply_max_tool_calls_strategy(
         request,
         conversation_id,
         previous_response_id,
         actor_event_id
       ) do
    case Map.get(request, "max_tool_calls") do
      limit when is_integer(limit) and limit >= 0 ->
        used =
          StatefulResponses.count_function_calls_for_actor_event(
            conversation_id,
            previous_response_id,
            actor_event_id
          )

        metadata = %{"max_tool_calls_used" => used}

        if used >= limit do
          {
            disable_provider_tools(request),
            Map.put(metadata, "max_tool_calls_exhausted", true)
          }
        else
          {request, metadata}
        end

      _missing ->
        {request, %{}}
    end
  end

  defp disable_provider_tools(request) do
    request
    |> Map.delete("tools")
    |> Map.delete("tool_choice")
    |> Map.delete("parallel_tool_calls")
  end

  defp stateful_run_metadata(request, compaction_metadata) do
    request
    |> public_request_metadata()
    |> Map.merge(Map.take(request, @stateful_request_metadata_fields))
    |> maybe_put("request_model", Map.get(request, "model"), true)
    |> Map.merge(compaction_metadata)
  end

  defp public_request_metadata(%{"metadata" => %{} = metadata}) do
    Map.delete(metadata, "actor_event_id")
  end

  defp public_request_metadata(_request), do: %{}

  defp resolve_stateful_request_conversation(agent_uid, conversation_id, _previous_response_id)
       when not is_nil(conversation_id) do
    with :ok <- validate_external_conversation_id(conversation_id) do
      StatefulResponses.get_conversation_for_agent(agent_uid, decode_conv_id(conversation_id))
    end
  end

  defp resolve_stateful_request_conversation(_agent_uid, nil, nil),
    do: {:error, :invalid_conversation}

  defp resolve_stateful_request_conversation(agent_uid, nil, previous_response_id) do
    case StatefulResponses.get_message(previous_response_id) do
      %{status: "complete", conversation_id: conversation_id} ->
        case StatefulResponses.get_conversation_for_agent(agent_uid, conversation_id) do
          {:ok, conversation} -> {:ok, conversation}
          {:error, :invalid_conversation} -> {:error, :invalid_anchor}
        end

      _missing_or_not_complete ->
        {:error, :invalid_anchor}
    end
  end

  # Consume internal AIGateway state fields before provider dispatch. These are
  # Ankole continuation controls, not upstream provider request parameters.
  defp strip_stateful_provider_fields(request) do
    request
    |> Map.delete("previous_response_id")
    |> Map.delete("store")
    |> Map.delete("conversation")
    |> Map.delete("max_tool_calls")
    |> strip_noop_provider_fields()
    |> strip_internal_metadata()
  end

  defp strip_noop_provider_fields(request) do
    request
    |> Map.delete("service_tier")
  end

  defp strip_internal_metadata(request) do
    case Map.get(request, "metadata") do
      %{} = metadata ->
        cleaned = metadata |> Map.delete("actor_event_id")
        Map.put(request, "metadata", cleaned)

      _ ->
        request
    end
  end

  defp decode_conv_id("conv_" <> uuid), do: uuid

  defp effective_previous_response_id(_conversation_id, previous_response_id)
       when is_binary(previous_response_id),
       do: previous_response_id

  defp effective_previous_response_id(conversation_id, _missing_previous_response_id) do
    case StatefulResponses.latest_visible_leaf(conversation_id) do
      nil -> nil
      message_id -> "resp_#{message_id}"
    end
  end

  defp request_with_effective_previous_response_id(request, nil), do: request

  defp request_with_effective_previous_response_id(request, previous_response_id),
    do: Map.put(request, "previous_response_id", previous_response_id)

  defp maybe_start_websocket_stateful_run(nil), do: {:ok, nil}

  defp maybe_start_websocket_stateful_run(%{} = run_attrs) do
    attrs =
      %{
        agent_uid: run_attrs.agent_uid,
        # Source table: run_attrs.actor_event_id comes from request metadata and
        # must remain an actor_events.id correlation key.
        actor_event_id: run_attrs.actor_event_id,
        previous_response_id: run_attrs.previous_response_id,
        request_items: run_attrs.request_items,
        metadata: run_attrs.metadata
      }
      |> maybe_put(
        :conversation_id,
        run_attrs.conversation_id,
        is_nil(run_attrs.previous_response_id)
      )

    case StatefulResponses.start_response_run(attrs) do
      {:ok, %Message{} = message} ->
        {:ok,
         %{
           message_id: message.id,
           actor_event_id: run_attrs.actor_event_id,
           conversation_id: message.conversation_id
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, _key, nil, true), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp put_stateful_stream_meta(meta, nil), do: meta

  defp put_stateful_stream_meta(meta, stateful_context),
    do: Map.put(meta, :stateful, stateful_context)

  defp commit_stateful_open_error(nil, _reason), do: :ok

  defp commit_stateful_open_error(%{message_id: message_id}, reason) do
    StatefulResponses.commit_error(message_id, [], socket_open_error_details(reason),
      complete_actor_event?: false
    )

    :ok
  end

  defp socket_open_error_details({:upstream_response_failed, status, body}) do
    %{
      "code" => "upstream_response_failed",
      "message" => upstream_error_message(status, body),
      "reason" => "provider_call_failed: upstream_response_failed",
      "stage" => "socket_open",
      "status" => status,
      "body" => body,
      "retryable" => retryable_upstream_status?(status)
    }
  end

  defp socket_open_error_details({:invalid_upstream_response, status, body}) do
    %{
      "code" => "invalid_upstream_response",
      "message" => "Provider returned an invalid upstream response.",
      "reason" => "provider_call_failed: invalid_upstream_response",
      "stage" => "socket_open",
      "status" => status,
      "body" => body,
      "retryable" => false
    }
  end

  defp socket_open_error_details({:universal_ai_request_failed, %{} = details}) do
    status = upstream_status_from_universal_error(details)

    %{
      "code" => universal_socket_open_code(status),
      "message" => universal_socket_open_message(status, details),
      "reason" => "provider_call_failed: universal_ai_request_failed",
      "stage" => "socket_open",
      "status" => status,
      "body" => details,
      "retryable" => retryable_upstream_status?(status)
    }
  end

  defp socket_open_error_details(reason) do
    %{
      "code" => "provider_call_failed",
      "message" => inspect(reason),
      "reason" => "provider_call_failed: #{inspect(reason)}",
      "stage" => "socket_open",
      "retryable" => false
    }
  end

  defp upstream_error_message(_status, %{"error" => %{"message" => message}})
       when is_binary(message),
       do: message

  defp upstream_error_message(_status, %{"message" => message}) when is_binary(message),
    do: message

  defp upstream_error_message(status, _body), do: "Provider request failed with status #{status}."

  defp upstream_status_from_universal_error(%{"status" => status}) when is_integer(status),
    do: status

  defp upstream_status_from_universal_error(%{"message" => message}) when is_binary(message) do
    case Regex.run(~r/HTTP error:\s*(\d{3})/, message) do
      [_match, status] -> String.to_integer(status)
      _no_match -> nil
    end
  end

  defp upstream_status_from_universal_error(_details), do: nil

  defp universal_socket_open_code(status) when is_integer(status), do: "upstream_response_failed"
  defp universal_socket_open_code(_status), do: "provider_call_failed"

  defp universal_socket_open_message(_status, %{"message" => message}) when is_binary(message),
    do: message

  defp universal_socket_open_message(status, _details) when is_integer(status),
    do: upstream_error_message(status, %{})

  defp universal_socket_open_message(_status, _details), do: "Provider request failed."

  defp retryable_upstream_status?(status) when status in [408, 409, 425, 429], do: true
  defp retryable_upstream_status?(status) when is_integer(status) and status >= 500, do: true
  defp retryable_upstream_status?(_status), do: false

  # The message log stores durable Response items directly. Do not re-derive
  # history from the legacy row-level role hint. Provider-facing replay strips
  # opaque upstream item ids because this gateway uses store=false upstream and
  # owns continuation through its local `resp_*` chain.
  defp messages_to_response_items(messages, input_modalities) do
    supports_image? = "image" in input_modalities

    Enum.flat_map(messages, fn
      %{content: content} when is_list(content) ->
        Enum.map(content, &provider_replay_item(&1, supports_image?))

      _message ->
        []
    end)
  end

  defp provider_replay_item(%{} = item, true), do: Map.delete(item, "id")

  defp provider_replay_item(%{} = item, false) do
    item
    |> Map.delete("id")
    |> replace_image_parts_for_text_model()
  end

  defp provider_replay_item(item, _supports_image?), do: item

  defp replace_image_parts_for_text_model(%{"type" => type})
       when type in ["input_image", "image_url", "image"] do
    %{"type" => "input_text", "text" => "[image removed: current model has no image input]"}
  end

  defp replace_image_parts_for_text_model(%{"content" => content} = item) when is_list(content) do
    Map.put(item, "content", Enum.map(content, &replace_image_parts_for_text_model/1))
  end

  defp replace_image_parts_for_text_model(item), do: item

  defp runtime_input_modalities(%{"provider" => provider, "model" => model})
       when is_binary(model) do
    case ModelMetadata.model_metadata(provider, model) do
      {:ok, %{"architecture" => %{"input_modalities" => modalities}}} when is_list(modalities) ->
        Enum.map(modalities, &to_string/1)

      _metadata ->
        ["text"]
    end
  end

  defp runtime_input_modalities(_runtime), do: ["text"]

  defp response_resource(%Message{} = message) do
    metadata = if is_map(message.metadata), do: message.metadata, else: %{}
    content = if is_list(message.content), do: message.content, else: []

    %{
      "id" => "resp_#{message.id}",
      "object" => "response",
      "created_at" => unix_timestamp(message.inserted_at),
      "completed_at" => response_completed_at(message),
      "status" => response_status(message.status, metadata),
      "incomplete_details" => response_incomplete_details(message.status, metadata),
      "model" => response_model(metadata),
      "previous_response_id" => prefixed_id("resp_", message.previous_message_id),
      "instructions" => Map.get(metadata, "instructions"),
      "input" => Enum.filter(content, &input_item?/1),
      "output" => response_output(message.status, content),
      "error" => response_error(message.status, metadata),
      "tools" => list_or_empty(Map.get(metadata, "tools")),
      "tool_choice" => Map.get(metadata, "tool_choice", "auto"),
      "truncation" => Map.get(metadata, "truncation", "disabled"),
      "parallel_tool_calls" => Map.get(metadata, "parallel_tool_calls", true),
      "text" => Map.get(metadata, "text", %{"format" => %{"type" => "text"}}),
      "top_p" => Map.get(metadata, "top_p", 1),
      "presence_penalty" => Map.get(metadata, "presence_penalty", 0),
      "frequency_penalty" => Map.get(metadata, "frequency_penalty", 0),
      "top_logprobs" => Map.get(metadata, "top_logprobs", 0),
      "temperature" => Map.get(metadata, "temperature", 1),
      "reasoning" => Map.get(metadata, "reasoning", %{"effort" => nil, "summary" => nil}),
      "usage" => response_usage(Map.get(metadata, "usage")),
      "provider_metadata" => map_or_empty(Map.get(metadata, "provider_metadata")),
      "tool_results" => list_or_empty(Map.get(metadata, "tool_results")),
      "stop_reason" => Map.get(metadata, "stop_reason"),
      "max_output_tokens" => Map.get(metadata, "max_output_tokens"),
      "max_tool_calls" => Map.get(metadata, "max_tool_calls"),
      "store" => true,
      "background" => false,
      "service_tier" => Map.get(metadata, "service_tier"),
      "metadata" => public_response_metadata(metadata),
      "safety_identifier" => Map.get(metadata, "safety_identifier"),
      "prompt_cache_key" => Map.get(metadata, "prompt_cache_key"),
      "user" => Map.get(metadata, "user"),
      "next_response_ids" => [],
      "context_edits" => [],
      "prompt_cache_retention" => nil,
      "conversation" => %{"id" => "conv_#{message.conversation_id}"}
    }
  end

  defp input_item?(%{"type" => "function_call_output"}), do: true

  defp input_item?(%{"type" => "message", "role" => role}) when role in @input_message_roles,
    do: true

  defp input_item?(%{"role" => role}) when role in @input_message_roles,
    do: true

  defp input_item?(_item), do: false

  defp output_item?(item), do: not input_item?(item)

  defp response_output("generating", _content), do: []
  defp response_output(_status, content), do: Enum.filter(content, &output_item?/1)

  defp response_completed_at(%Message{status: status, updated_at: updated_at})
       when status in ["complete", "error", "retracted"],
       do: unix_timestamp(updated_at)

  defp response_completed_at(_message), do: nil

  defp response_status("generating", _metadata), do: "in_progress"

  defp response_status("complete", %{"incomplete_details" => %{} = _details}),
    do: "incomplete"

  defp response_status("complete", _metadata), do: "completed"
  defp response_status("error", _metadata), do: "failed"
  defp response_status("retracted", _metadata), do: "failed"
  defp response_status(_status, _metadata), do: "failed"

  defp response_incomplete_details("complete", %{"incomplete_details" => details})
       when not is_nil(details),
       do: details

  defp response_incomplete_details(_status, _metadata), do: nil

  defp response_model(%{"provider_model" => model}) when is_binary(model) and model != "",
    do: model

  defp response_model(%{"model_ref" => %{"model" => model}})
       when is_binary(model) and model != "", do: model

  defp response_model(%{"request_model" => model}) when is_binary(model) and model != "",
    do: model

  defp response_model(%{"model" => model}) when is_binary(model) and model != "", do: model

  defp response_model(_metadata), do: "unknown"

  defp response_error("error", %{"error" => %{} = error}), do: error

  defp response_error("error", %{"error" => error}),
    do: %{"code" => "error", "message" => inspect(error)}

  defp response_error("error", _metadata),
    do: %{"code" => "error", "message" => "response failed"}

  defp response_error("retracted", _metadata),
    do: %{"code" => "retracted", "message" => "response was retracted"}

  defp response_error(_status, _metadata), do: nil

  defp response_usage(%{} = usage) do
    input_tokens = usage_integer(usage, ["input_tokens", "prompt_tokens", "inputTokens"])
    output_tokens = usage_integer(usage, ["output_tokens", "completion_tokens", "outputTokens"])

    total_tokens =
      usage_integer(usage, ["total_tokens", "totalTokens"], input_tokens + output_tokens)

    %{
      "input_tokens" => input_tokens,
      "output_tokens" => output_tokens,
      "total_tokens" => total_tokens,
      "input_tokens_details" => %{
        "cached_tokens" =>
          usage_integer(
            map_or_empty(
              Map.get(usage, "input_tokens_details") || Map.get(usage, "prompt_tokens_details")
            ),
            ["cached_tokens", "cached", "cachedInputTokens"]
          )
      },
      "output_tokens_details" => %{
        "reasoning_tokens" =>
          usage_integer(
            map_or_empty(
              Map.get(usage, "output_tokens_details") ||
                Map.get(usage, "completion_tokens_details")
            ),
            ["reasoning_tokens", "reasoning", "reasoningTokens"]
          )
      }
    }
  end

  defp response_usage(_usage) do
    %{
      "input_tokens" => 0,
      "output_tokens" => 0,
      "total_tokens" => 0,
      "input_tokens_details" => %{"cached_tokens" => 0},
      "output_tokens_details" => %{"reasoning_tokens" => 0}
    }
  end

  defp public_response_metadata(metadata) do
    Map.drop(metadata, @internal_response_metadata_keys)
  end

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_value), do: []

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp usage_integer(map, keys, default \\ 0)

  defp usage_integer(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _value -> false
      end
    end)
  end

  defp usage_integer(_map, _keys, default), do: default

  defp prefixed_id(_prefix, nil), do: nil
  defp prefixed_id(prefix, id) when is_binary(id), do: prefix <> id

  defp unix_timestamp(%DateTime{} = datetime), do: DateTime.to_unix(datetime)
  defp unix_timestamp(_datetime), do: nil

  defp validate_external_optional_response_id(nil), do: :ok
  defp validate_external_optional_response_id(value), do: validate_external_response_id(value)

  defp validate_external_response_id("resp_" <> uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_anchor}
    end
  end

  defp validate_external_response_id(_value), do: {:error, :invalid_anchor}

  defp validate_external_conversation_id("conv_" <> uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_conversation}
    end
  end

  defp validate_external_conversation_id(_value), do: {:error, :invalid_conversation}

  defp compact_previous_response_id(%{"previous_response_id" => value})
       when is_binary(value) and value != "" do
    with :ok <- validate_external_response_id(value) do
      {:ok, value}
    else
      {:error, _reason} -> {:error, :invalid_anchor}
    end
  end

  defp compact_previous_response_id(_request), do: {:error, :unsupported_stateless_compact}

  defp compact_item(%{"input" => [%{"type" => "compaction"} = item]}), do: {:ok, item}
  defp compact_item(%{"input" => %{"type" => "compaction"} = item}), do: {:ok, item}
  defp compact_item(%{"compaction" => %{"type" => "compaction"} = item}), do: {:ok, item}
  defp compact_item(_request), do: {:error, :invalid_compaction_item}

  defp compact_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp compact_metadata(_request), do: %{}

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
  def create_embeddings(agent_uid, request, opts \\ [])

  def create_embeddings(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "embedding", request),
         :ok <- validate_embeddings_request(request),
         {:ok, prepared_request} <- Providers.build_embeddings_request(runtime, request),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
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
         :ok <- validate_rerank_request(request),
         {:ok, prepared_request} <- Providers.build_rerank_request(runtime, request),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_rerank(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Creates a normalized web search result through AIGateway.
  """
  @spec create_web_search(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_web_search(agent_uid, request, opts \\ [])

  def create_web_search(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "web_search", request),
         :ok <- validate_web_search_request(request),
         {:ok, prepared_request} <- Providers.build_web_search_request(runtime, request),
         {:ok, upstream_response} <- execute_prepared_request(runtime, prepared_request, opts) do
      {:ok, gateway_response(200, Map.fetch!(upstream_response, :body), runtime)}
    end
  end

  def create_web_search(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Creates normalized web fetch results through a provider-backed AIGateway path.
  """
  @spec create_web_fetch(String.t(), map(), keyword()) ::
          {:ok, gateway_response()} | {:error, term()}
  def create_web_fetch(agent_uid, request, opts \\ [])

  def create_web_fetch(agent_uid, request, opts) when is_map(request) do
    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "web_fetch", request),
         :ok <- validate_web_fetch_request(request),
         request = normalize_request_keys(request),
         {:ok, body} <- execute_web_fetch(runtime, request, opts) do
      {:ok, gateway_response(200, body, runtime)}
    end
  end

  def create_web_fetch(_agent_uid, _request, _opts), do: {:error, :invalid_request_body}

  @doc """
  Returns provider-backed web tool availability for an agent runtime.
  """
  @spec web_tools(String.t()) :: {:ok, map()}
  def web_tools(agent_uid) when is_binary(agent_uid) do
    {:ok,
     %{
       "web_search" => web_tool(agent_uid, "web_search"),
       "web_fetch" => web_tool(agent_uid, "web_fetch")
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

  defp validate_websocket_stateful_shape(request) do
    request = normalize_request_keys(request)
    continuation_field = Enum.find(@websocket_continuation_fields, &Map.has_key?(request, &1))
    previous_response_id = Map.get(request, "previous_response_id")
    conversation_id = Map.get(request, "conversation")

    cond do
      Map.has_key?(request, "previous_response_id") and Map.has_key?(request, "conversation") ->
        {:error, :stateful_anchor_conflict}

      not is_nil(previous_response_id) &&
          validate_external_response_id(previous_response_id) != :ok ->
        {:error, :invalid_anchor}

      not is_nil(conversation_id) && validate_external_conversation_id(conversation_id) != :ok ->
        {:error, :invalid_conversation}

      continuation_field && request["store"] != true ->
        {:error, :stateful_store_required}

      request["store"] == true && is_nil(continuation_field) ->
        {:error, :missing_stateful_anchor}

      request["store"] == true && missing_stateful_actor_event_id?(request) ->
        {:error, :missing_actor_event_id}

      not valid_max_tool_calls?(Map.get(request, "max_tool_calls")) ->
        {:error, :invalid_max_tool_calls}

      not valid_stateful_input?(Map.get(request, "input")) ->
        {:error, :invalid_input}

      true ->
        :ok
    end
  end

  defp validate_tool_results_record_shape(request) do
    request = normalize_request_keys(request)
    previous_response_id = Map.get(request, "previous_response_id")

    cond do
      is_nil(previous_response_id) ->
        {:error, :missing_stateful_anchor}

      validate_external_response_id(previous_response_id) != :ok ->
        {:error, :invalid_anchor}

      missing_stateful_actor_event_id?(request) ->
        {:error, :missing_actor_event_id}

      not valid_stateful_input?(Map.get(request, "input")) ->
        {:error, :invalid_input}

      true ->
        :ok
    end
  end

  defp valid_max_tool_calls?(nil), do: true
  defp valid_max_tool_calls?(value) when is_integer(value), do: value >= 0
  defp valid_max_tool_calls?(_value), do: false

  defp valid_stateful_input?(nil), do: true
  defp valid_stateful_input?(value) when is_binary(value), do: true
  defp valid_stateful_input?(value) when is_list(value), do: true
  defp valid_stateful_input?(_value), do: false

  defp normalize_stateful_input(nil), do: {:ok, []}
  defp normalize_stateful_input(input) when is_list(input), do: {:ok, input}

  defp normalize_stateful_input(input) when is_binary(input) do
    {:ok,
     [
       %{
         "type" => "message",
         "role" => "user",
         "content" => [%{"type" => "input_text", "text" => input}]
       }
     ]}
  end

  defp normalize_stateful_input(_input), do: {:error, :invalid_input}

  defp missing_stateful_actor_event_id?(request) do
    case get_in(request, ["metadata", "actor_event_id"]) do
      actor_event_id when is_binary(actor_event_id) -> String.trim(actor_event_id) == ""
      _missing_or_invalid -> true
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

  defp validate_web_fetch_request(request) do
    request = normalize_request_keys(request)

    cond do
      not Map.has_key?(request, "urls") ->
        {:error, :missing_urls}

      not valid_extract_urls?(Map.get(request, "urls")) ->
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

  defp valid_extract_urls?(urls) when is_list(urls) and urls != [] and length(urls) <= 5,
    do: Enum.all?(urls, &safe_web_url?/1)

  defp valid_extract_urls?(_urls), do: false

  defp safe_web_url?(url) when is_binary(url) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
        safe_web_host?(String.downcase(host))

      _uri ->
        false
    end
  end

  defp safe_web_url?(_url), do: false

  defp safe_web_host?(host) do
    cond do
      host in ["localhost", "metadata", "metadata.google.internal"] -> false
      String.ends_with?(host, ".localhost") -> false
      ip_address?(host) -> public_ip_address?(host)
      true -> true
    end
  end

  defp ip_address?(host), do: match?({:ok, _address}, :inet.parse_address(to_charlist(host)))

  defp public_ip_address?(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, address} -> public_ip_tuple?(address)
      {:error, _reason} -> false
    end
  end

  defp public_ip_tuple?({10, _, _, _}), do: false
  defp public_ip_tuple?({127, _, _, _}), do: false
  defp public_ip_tuple?({169, 254, _, _}), do: false
  defp public_ip_tuple?({172, second, _, _}) when second >= 16 and second <= 31, do: false
  defp public_ip_tuple?({192, 168, _, _}), do: false
  defp public_ip_tuple?({0, _, _, _}), do: false
  defp public_ip_tuple?({100, second, _, _}) when second >= 64 and second <= 127, do: false
  defp public_ip_tuple?({_, _, _, _}), do: true
  defp public_ip_tuple?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  defp public_ip_tuple?({first, _, _, _, _, _, _, _}) when first >= 0xFC00 and first <= 0xFDFF,
    do: false

  defp public_ip_tuple?({first, _, _, _, _, _, _, _}) when first >= 0xFE80 and first <= 0xFEBF,
    do: false

  defp public_ip_tuple?({_a, _b, _c, _d, _e, _f, _g, _h}), do: true

  defp non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_string?(_value), do: false

  defp normalize_request_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
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

  defp web_tool(agent_uid, capability) do
    profile = capability

    case ModelProfiles.resolve_runtime_profile(agent_uid, profile) do
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
