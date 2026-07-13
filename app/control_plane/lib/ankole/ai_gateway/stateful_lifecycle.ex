defmodule Ankole.AIGateway.StatefulLifecycle do
  @moduledoc """
  Owns the control-plane lifecycle for locally stored Responses.

  AIGateway stays the public facade. This module owns the stateful continuation
  rules that need durable history, compaction, response projection, and recovery
  semantics to remain in one place.
  """

  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.MapUtils
  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.UniversalAIRequest

  @websocket_continuation_fields ~w(previous_response_id conversation)
  @input_message_roles ~w(system developer user)
  @stateful_request_metadata_fields ~w(
    instructions tools tool_choice truncation parallel_tool_calls text top_p
    presence_penalty frequency_penalty top_logprobs temperature reasoning
    max_output_tokens max_tool_calls service_tier prompt_cache_key
    safety_identifier user
  )

  @tool_result_record_db_retry_delays_ms [50, 100, 200, 400, 800, 1_600]

  @doc false
  @spec retrieve_response(String.t(), binary()) :: {:ok, %{body: map()}} | {:error, term()}
  def retrieve_response(subject_uid, response_id) do
    with :ok <- validate_external_response_id(response_id),
         {:ok, %Message{} = message} <-
           StatefulResponses.get_response_for_subject(subject_uid, response_id) do
      {:ok, %{body: response_resource(message)}}
    else
      _not_found_or_invalid ->
        {:error, :not_found}
    end
  end

  @doc false
  @spec compact_response(String.t(), map()) :: {:ok, %{body: map()}} | {:error, term()}
  def compact_response(subject_uid, request) when is_map(request) do
    request = normalize_request_keys(request)

    with {:ok, body} <- Compaction.compact_response(subject_uid, request) do
      {:ok, %{body: body}}
    end
  end

  def compact_response(_subject_uid, _request), do: {:error, :invalid_request_body}

  @doc false
  @spec record_tool_results(String.t(), map()) :: {:ok, %{body: map()}} | {:error, term()}
  def record_tool_results(subject_uid, request) when is_map(request) do
    request = normalize_request_keys(request)
    previous_response_id = request["previous_response_id"]

    with :ok <- validate_tool_results_record_shape(request),
         {:ok, current_input} <- normalize_stateful_input(Map.get(request, "input")),
         {:ok, %Message{} = message} <-
           record_tool_results_with_transient_db_retry(%{
             subject_uid: subject_uid,
             previous_response_id: previous_response_id,
             request_items: current_input,
             metadata: stateful_run_metadata(request, %{})
           }) do
      {:ok, %{body: response_resource(message)}}
    end
  end

  def record_tool_results(_subject_uid, _request), do: {:error, :invalid_request_body}

  @doc false
  @spec prepare_websocket_provider_request(String.t(), map()) ::
          {:ok, UniversalAIRequest.t(), map() | nil} | {:error, term()}
  def prepare_websocket_provider_request(subject_uid, request) do
    with :ok <- validate_websocket_stateful_shape(request),
         {:ok, runtime} <-
           Resolver.resolve_request_model(subject_uid, "llm", normalize_request_keys(request)),
         {:ok, request_for_provider, run_attrs} <-
           provider_websocket_request(subject_uid, request, runtime),
         {:ok, prepared_request} <-
           Providers.build_response_request(runtime, request_for_provider, stream?: true) do
      {:ok, prepared_request, run_attrs}
    end
  end

  @doc false
  def start_websocket_run(nil), do: {:ok, nil}

  def start_websocket_run(%{} = run_attrs) do
    attrs =
      %{
        subject_uid: run_attrs.subject_uid,
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
           message: message,
           subject_uid: message.subject_uid,
           conversation_id: message.conversation_id
         }}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  def commit_socket_open_error(nil, _reason), do: :ok

  def commit_socket_open_error(%{message_id: message_id}, reason) do
    StatefulResponses.commit_error(message_id, [], socket_open_error_details(reason))

    :ok
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
  defp provider_websocket_request(subject_uid, request, runtime) do
    request = normalize_request_keys(request)

    if request["store"] == true do
      expand_and_inject_history(subject_uid, request, runtime)
    else
      with {:ok, request} <-
             CompactionArtifacts.resolve_request_input_handles(subject_uid, request) do
        {:ok, strip_stateful_provider_fields(request), nil}
      end
    end
  end

  defp expand_and_inject_history(subject_uid, request, runtime) do
    conversation_id = request["conversation"]
    previous_response_id = request["previous_response_id"]

    with :ok <- validate_external_optional_response_id(previous_response_id),
         {:ok, conversation} <-
           resolve_stateful_request_conversation(
             subject_uid,
             conversation_id,
             previous_response_id,
             public_request_metadata(request)
           ),
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
             subject_uid,
             conversation.id,
             history,
             current_input,
             request,
             runtime
           ) do
      history = compaction.history
      previous_response_id = compaction.previous_response_id

      current_input =
        Compaction.maybe_inject_brain_pre_compaction_nudge(
          current_input,
          compaction.run_metadata
        )

      with {:ok, history_items} <-
             messages_to_response_items(subject_uid, history, runtime_input_modalities(runtime)),
           {:ok, expanded_input} <-
             CompactionArtifacts.resolve_input_handles(
               subject_uid,
               history_items ++ current_input
             ) do
        provider_request =
          request
          |> Map.put("input", expanded_input)
          |> strip_stateful_provider_fields()

        {:ok, provider_request,
         %{
           subject_uid: subject_uid,
           conversation_id: conversation.id,
           previous_response_id: previous_response_id,
           request_items: current_input,
           metadata:
             stateful_run_metadata(
               request,
               compaction.run_metadata
             )
         }}
      end
    end
  end

  defp stateful_run_metadata(request, compaction_metadata) do
    %{"request_metadata" => public_request_metadata(request)}
    |> Map.merge(Map.take(request, @stateful_request_metadata_fields))
    |> maybe_put("request_model", Map.get(request, "model"), true)
    |> Map.merge(compaction_metadata)
  end

  defp public_request_metadata(%{"metadata" => %{} = metadata}), do: metadata

  defp public_request_metadata(_request), do: %{}

  defp resolve_stateful_request_conversation(
         subject_uid,
         conversation_id,
         _previous_response_id,
         _metadata
       )
       when not is_nil(conversation_id) do
    with :ok <- validate_external_conversation_id(conversation_id) do
      StatefulResponses.get_conversation_for_subject(subject_uid, decode_conv_id(conversation_id))
    end
  end

  defp resolve_stateful_request_conversation(subject_uid, nil, nil, metadata),
    do:
      StatefulResponses.create_managed_stateful_responses_conversation(subject_uid,
        metadata: metadata
      )

  defp resolve_stateful_request_conversation(
         subject_uid,
         nil,
         previous_response_id,
         _metadata
       ) do
    case StatefulResponses.get_message(previous_response_id) do
      %{status: "complete", conversation_id: conversation_id} ->
        case StatefulResponses.get_conversation_for_subject(subject_uid, conversation_id) do
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
    |> Map.delete("service_tier")
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

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, _key, nil, true), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

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
  defp messages_to_response_items(subject_uid, messages, input_modalities) do
    supports_image? = "image" in input_modalities

    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, acc} ->
      case message_response_items(subject_uid, message) do
        {:ok, items} ->
          replay_items = Enum.map(items, &provider_replay_item(&1, supports_image?))
          {:cont, {:ok, acc ++ replay_items}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp message_response_items(subject_uid, %Message{type: "checkpoint"} = message),
    do: CompactionArtifacts.output_for_checkpoint(subject_uid, message)

  defp message_response_items(_subject_uid, %{content: content}) when is_list(content),
    do: {:ok, content}

  defp message_response_items(_subject_uid, _message), do: {:ok, []}

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
    content = response_content(message)

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

  defp response_content(%Message{type: "checkpoint"} = message) do
    case CompactionArtifacts.output_for_checkpoint(message.subject_uid, message) do
      {:ok, content} -> content
      {:error, _reason} -> []
    end
  end

  defp response_content(%Message{content: content}) when is_list(content), do: content
  defp response_content(_message), do: []

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

  defp response_status("complete", %{"response" => %{"status" => "incomplete"}}),
    do: "incomplete"

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
    case Map.get(metadata, "request_metadata") do
      %{} = request_metadata -> request_metadata
      _missing -> %{}
    end
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

  defp validate_websocket_stateful_shape(request) do
    request = normalize_request_keys(request)
    previous_response_id = Map.get(request, "previous_response_id")
    conversation_id = Map.get(request, "conversation")

    continuation_field =
      Enum.find(@websocket_continuation_fields, &(not is_nil(Map.get(request, &1))))

    cond do
      not is_nil(previous_response_id) and not is_nil(conversation_id) ->
        {:error, :stateful_anchor_conflict}

      not is_nil(previous_response_id) &&
          validate_external_response_id(previous_response_id) != :ok ->
        {:error, :invalid_anchor}

      not is_nil(conversation_id) && validate_external_conversation_id(conversation_id) != :ok ->
        {:error, :invalid_conversation}

      continuation_field && request["store"] != true ->
        {:error, :stateful_store_required}

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

  defp normalize_request_keys(map), do: MapUtils.normalize_request_keys(map)
end
