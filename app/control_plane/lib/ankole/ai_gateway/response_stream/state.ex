defmodule Ankole.AIGateway.ResponseStream.State do
  @moduledoc false

  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.ImageStreamPersistence
  alias Ankole.AIGateway.MaxToolCalls
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Logging

  @terminal_event_types ~w(response.completed response.failed response.incomplete)

  defstruct subject_uid: nil,
            stateful: nil,
            image_persistence: nil,
            max_tool_calls: nil,
            public_items: [],
            durable_items: [],
            provider_response_id: nil,
            terminal_response: nil,
            terminal_error: nil,
            terminal?: false,
            sequence_number: nil

  @type t :: %__MODULE__{}
  @type outcome :: %{
          required(:stateful?) => boolean(),
          required(:terminal_response) => map() | nil,
          required(:terminal_error) => map() | nil,
          required(:public_items) => [map()]
        }
  @type status :: :continue | {:terminal, outcome(), :keep_upstream | :cancel_upstream}

  @spec new(String.t(), map(), map(), keyword()) :: t()
  def new(subject_uid, request, meta, opts \\ []) do
    stateful = Keyword.get(opts, :stateful)

    %__MODULE__{
      subject_uid: subject_uid,
      stateful: stateful,
      image_persistence:
        ImageStreamPersistence.new(subject_uid, message_id: stateful_message_id(stateful)),
      max_tool_calls:
        MaxToolCalls.new(
          Map.get(request, "max_tool_calls"),
          Map.get(meta, "api_resolver") || Map.get(meta, :api_resolver)
        )
    }
  end

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{terminal?: terminal?}), do: terminal?

  @spec stateful_context(t()) :: map() | nil
  def stateful_context(%__MODULE__{stateful: stateful}), do: stateful

  @spec observe(t(), map(), non_neg_integer()) ::
          {:ok, t(), [map()], status()}
          | {:error, t(), [map()], status(), term()}
  def observe(%__MODULE__{} = state, %{} = event, fallback_sequence) do
    case ImageStreamPersistence.observe(state.image_persistence, event) do
      {:ok, image_persistence, events} ->
        {state, public_events, status} =
          state
          |> Map.put(:image_persistence, image_persistence)
          |> observe_public_events(events, fallback_sequence)

        {:ok, state, public_events, status}

      {:error, image_persistence, events, reason} ->
        {state, public_events, status} =
          state
          |> Map.put(:image_persistence, image_persistence)
          |> observe_public_events(events, fallback_sequence)

        {:error, state, public_events, force_cancel(status), reason}
    end
  end

  @spec fail(t(), String.t(), keyword()) :: {t(), [map()], outcome() | nil}
  def fail(%__MODULE__{terminal?: true} = state, _reason, _opts),
    do: {state, [], outcome(state)}

  def fail(%__MODULE__{} = state, reason, opts) when is_binary(reason) do
    code = Keyword.get(opts, :code, "provider_stream_error")
    retryable? = Keyword.get(opts, :retryable, false)

    commit_stateful_error(state.stateful, reason, state.durable_items,
      code: code,
      retryable: retryable?
    )

    response = %{
      "id" => cleanup_response_id(state),
      "object" => "response",
      "status" => "failed",
      "error" =>
        %{
          "code" => code,
          "message" => cleanup_error_message(code),
          "details" => reason
        }
        |> maybe_put_retryable(retryable?),
      "output" => []
    }

    event =
      %{"type" => "response.failed", "response" => response}
      |> maybe_put_sequence_number(next_sequence_number(state))
      |> rewrite_response_id(state)

    state = %{
      state
      | terminal?: true,
        terminal_response: event["response"],
        terminal_error: event["response"]["error"]
    }

    {state, [event], outcome(state)}
  end

  @spec outcome(t()) :: outcome()
  def outcome(%__MODULE__{} = state) do
    %{
      stateful?: not is_nil(state.stateful),
      terminal_response: state.terminal_response,
      terminal_error: state.terminal_error,
      public_items: state.public_items
    }
  end

  defp observe_public_events(state, events, fallback_sequence) do
    Enum.reduce_while(events, {state, [], :continue}, fn event,
                                                         {state, public_events, :continue} ->
      {state, emitted, status} = observe_public_event(state, event, fallback_sequence)
      result = {state, public_events ++ emitted, status}

      case status do
        :continue -> {:cont, result}
        {:terminal, _outcome, _upstream_action} -> {:halt, result}
      end
    end)
  end

  defp observe_public_event(state, event, fallback_sequence) do
    sequence = public_sequence_number(event, fallback_sequence)

    state =
      state
      |> remember_provider_response_id(event)
      |> Map.put(:sequence_number, sequence)
      |> observe_max_tool_calls(event)

    if event["type"] in @terminal_event_types do
      finalize_terminal(state, event, sequence, :keep_upstream)
    else
      state = remember_non_terminal_event(state, event, sequence)
      public_event = rewrite_response_id(event, state)

      if MaxToolCalls.stop?(state.max_tool_calls) do
        {state, [terminal_event], status} =
          finalize_terminal(
            state,
            max_tool_calls_incomplete_event(state),
            next_sequence_number(state),
            :cancel_upstream
          )

        {state, [public_event, terminal_event], status}
      else
        {state, [public_event], :continue}
      end
    end
  end

  defp remember_non_terminal_event(state, %{"type" => "response.output_text.delta"} = event, seq) do
    delta = Map.get(event, "delta", "")

    if is_binary(delta) and delta != "" do
      publish(state, :output_text_delta, %{text: delta, seq: seq})
      state
    else
      state
    end
  end

  defp remember_non_terminal_event(
         state,
         %{"type" => type} = event,
         seq
       )
       when type in ["response.reasoning_summary_text.delta", "response.reasoning_text.delta"] do
    delta = Map.get(event, "delta", "")

    if is_binary(delta) and delta != "" do
      publish(state, :reasoning_delta, %{text: delta, source: type, seq: seq})
    end

    state
  end

  defp remember_non_terminal_event(
         state,
         %{"type" => "response.output_item.done", "item" => %{} = item},
         seq
       ) do
    if tool_activity_item?(item) do
      publish(state, :tool_call_started, tool_activity_payload(item, seq))
    end

    %{
      state
      | public_items: state.public_items ++ [item],
        durable_items: state.durable_items ++ [ImageStreamPersistence.storage_item(item)]
    }
  end

  defp remember_non_terminal_event(state, _event, _seq), do: state

  defp finalize_terminal(state, event, sequence, upstream_action) do
    response = Map.get(event, "response", %{})
    terminal_items = response |> Map.get("output", []) |> map_items()
    public_items = terminal_items_or_accumulated(state.public_items, terminal_items)
    durable_items = ImageStreamPersistence.storage_items(public_items)
    response = Map.put(response, "output", public_items)
    terminal_error = terminal_error(event["type"], response)
    terminal_metadata = terminal_response_metadata(state, event["type"], response)

    state = %{
      state
      | public_items: public_items,
        durable_items: durable_items,
        terminal_error: terminal_error
    }

    case commit_stateful_terminal(
           state.stateful,
           durable_items,
           terminal_error,
           terminal_metadata
         ) do
      :ok ->
        public_event =
          event
          |> Map.put("response", response)
          |> maybe_put_sequence_number(sequence)
          |> rewrite_response_id(state)

        state = %{
          state
          | terminal?: true,
            terminal_response: public_event["response"]
        }

        {state, [public_event], {:terminal, outcome(state), upstream_action}}

      {:error, reason} ->
        public_event = stateful_commit_failed_event(state, reason, sequence)

        state = %{
          state
          | terminal?: true,
            terminal_response: public_event["response"],
            terminal_error: public_event["response"]["error"]
        }

        {state, [public_event], {:terminal, outcome(state), :cancel_upstream}}
    end
  end

  defp terminal_error("response.failed", response) do
    response
    |> Map.take(["error", "incomplete_details", "status", "id"])
    |> Map.put_new("type", "response.failed")
    |> maybe_mark_retryable_terminal_error()
  end

  defp terminal_error("response.incomplete", response) do
    reason = incomplete_response_reason(response) || "unknown"

    cond do
      response_has_incomplete_function_call?(response) ->
        %{
          "type" => "response.incomplete",
          "code" => "partial_function_call_incomplete",
          "status" => Map.get(response, "status", "incomplete"),
          "incomplete_details" => Map.get(response, "incomplete_details"),
          "reason" => reason,
          "retryable" => transient_incomplete_reason?(reason)
        }

      intentional_incomplete_response?(response) ->
        nil

      true ->
        %{
          "type" => "response.incomplete",
          "code" => "response_incomplete",
          "status" => Map.get(response, "status", "incomplete"),
          "incomplete_details" => Map.get(response, "incomplete_details"),
          "reason" => reason,
          "retryable" => transient_incomplete_reason?(reason)
        }
    end
  end

  defp terminal_error("response.completed", %{"output" => output}) when is_list(output) do
    if Enum.any?(output, &incomplete_function_call_item?/1) do
      %{
        "type" => "response.completed",
        "code" => "partial_function_call_completed",
        "reason" =>
          "provider marked the response completed while a function call remained incomplete",
        "retryable" => false
      }
    end
  end

  defp terminal_error(_type, _response), do: nil

  defp response_has_incomplete_function_call?(%{"output" => output}) when is_list(output),
    do: Enum.any?(output, &incomplete_function_call_item?/1)

  defp response_has_incomplete_function_call?(_response), do: false

  defp intentional_incomplete_response?(response) do
    incomplete_response_reason(response) == "max_output_tokens" or
      match?(%{"max_tool_calls" => %{}}, Map.get(response, "provider_metadata"))
  end

  defp incomplete_response_reason(%{"incomplete_details" => %{"reason" => reason}})
       when is_binary(reason),
       do: reason

  defp incomplete_response_reason(_response), do: nil

  defp transient_incomplete_reason?(reason) do
    reason in [
      "upstream_stream_closed",
      "upstream_stream_closed_before_terminal_event",
      "provider_stream_closed_without_terminal"
    ]
  end

  defp incomplete_function_call_item?(%{"type" => "function_call"} = item) do
    status = Map.get(item, "status")

    status not in [nil, "completed"] or
      not non_empty_binary?(Map.get(item, "call_id")) or
      not non_empty_binary?(Map.get(item, "name")) or
      not is_binary(Map.get(item, "arguments"))
  end

  defp incomplete_function_call_item?(_item), do: false

  defp non_empty_binary?(value), do: is_binary(value) and value != ""

  defp max_tool_calls_incomplete_event(state) do
    %{
      "type" => "response.incomplete",
      "response" => %{
        "id" => cleanup_response_id(state),
        "object" => "response",
        "status" => "incomplete",
        "incomplete_details" => nil,
        "output" => state.public_items,
        "provider_metadata" => %{
          "max_tool_calls" => MaxToolCalls.details(state.max_tool_calls)
        }
      }
    }
  end

  defp observe_max_tool_calls(state, event) do
    %{state | max_tool_calls: MaxToolCalls.observe(state.max_tool_calls, event)}
  end

  defp force_cancel(:continue), do: :continue
  defp force_cancel({:terminal, outcome, _action}), do: {:terminal, outcome, :cancel_upstream}

  defp map_items(items) when is_list(items), do: Enum.filter(items, &is_map/1)
  defp map_items(_items), do: []

  defp terminal_items_or_accumulated(accumulated, []), do: accumulated
  defp terminal_items_or_accumulated(_accumulated, terminal_items), do: terminal_items

  defp terminal_response_metadata(
         state,
         "response.incomplete",
         %{"provider_metadata" => %{"max_tool_calls" => _details}} = response
       ) do
    %{
      "provider_metadata" => response["provider_metadata"],
      "response" => %{
        "id" => state.provider_response_id || response["id"],
        "object" => "response",
        "status" => "incomplete"
      }
    }
  end

  defp terminal_response_metadata(_state, _event_type, %{} = response) do
    %{}
    |> maybe_put_metadata("usage", response["usage"])
    |> maybe_put_metadata("provider_model", response["model"])
    |> maybe_put_metadata("provider_metadata", provider_response_metadata(response))
    |> maybe_put_metadata("stop_reason", response_stop_reason(response))
    |> maybe_put_metadata("response", response_trace_metadata(response))
    |> maybe_put_metadata("incomplete_details", response["incomplete_details"])
  end

  defp provider_response_metadata(response) do
    Map.take(response, [
      "id",
      "object",
      "model",
      "status",
      "service_tier",
      "system_fingerprint"
    ])
  end

  defp response_trace_metadata(response) do
    Map.take(response, ["id", "object", "created_at", "completed_at", "status"])
  end

  defp response_stop_reason(%{"stop_reason" => stop_reason}) when is_binary(stop_reason),
    do: stop_reason

  defp response_stop_reason(%{"finish_reason" => finish_reason}) when is_binary(finish_reason),
    do: finish_reason

  defp response_stop_reason(%{"incomplete_details" => %{"reason" => reason}})
       when is_binary(reason),
       do: reason

  defp response_stop_reason(%{"status" => status}) when status in ["failed", "error"],
    do: "error"

  defp response_stop_reason(%{"output" => output}) when is_list(output) do
    if Enum.any?(output, &completed_function_call_item?/1), do: "tool_use", else: "stop"
  end

  defp response_stop_reason(_response), do: "stop"

  defp completed_function_call_item?(%{"type" => "function_call"} = item),
    do: not incomplete_function_call_item?(item)

  defp completed_function_call_item?(_item), do: false

  defp commit_stateful_terminal(nil, _items, _terminal_error, _terminal_metadata), do: :ok

  defp commit_stateful_terminal(stateful, items, nil, terminal_metadata) do
    case StatefulResponses.commit_complete(stateful.message_id, items, terminal_metadata) do
      {:ok, %{} = _message} ->
        :ok

      {:ok, :already_terminal} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "ai_gateway.response_stream.complete_commit_failed",
          "AIGateway response stream complete commit failed",
          %{message_id: stateful.message_id, reason: inspect(reason)}
        )

        commit_stateful_terminal_commit_failure(stateful, items, reason)
        {:error, reason}
    end
  end

  defp commit_stateful_terminal(stateful, items, error_details, terminal_metadata) do
    case StatefulResponses.commit_error(stateful.message_id, items, error_details,
           metadata: terminal_metadata
         ) do
      {:ok, %{} = _message} ->
        :ok

      {:ok, :already_terminal} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "ai_gateway.response_stream.error_commit_failed",
          "AIGateway response stream error commit failed",
          %{message_id: stateful.message_id, reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  defp commit_stateful_terminal_commit_failure(stateful, items, reason) do
    StatefulResponses.commit_error(
      stateful.message_id,
      items,
      %{
        "reason" => "stateful_terminal_commit_failed",
        "stage" => "terminal_commit",
        "details" => inspect(reason)
      }
    )
  end

  defp commit_stateful_error(nil, _reason, _partial_content, _opts), do: :ok

  defp commit_stateful_error(%{message_id: message_id}, reason, partial_content, opts) do
    error_details =
      %{
        "code" => Keyword.get(opts, :code, "response_stream_cleanup_error"),
        "reason" => reason,
        "stage" => "response_stream_cleanup"
      }
      |> maybe_put_retryable(Keyword.get(opts, :retryable, false))

    case StatefulResponses.commit_error(message_id, partial_content, error_details) do
      {:ok, _message_or_terminal} ->
        :ok

      {:error, commit_reason} ->
        Logging.warning(
          "ai_gateway.response_stream.cleanup_commit_failed",
          "AIGateway response stream cleanup commit failed",
          %{message_id: message_id, reason: inspect(commit_reason)}
        )

        {:error, commit_reason}
    end
  end

  defp stateful_commit_failed_event(state, reason, sequence_number) do
    response = %{
      "id" => stateful_response_id(state.stateful),
      "object" => "response",
      "status" => "failed",
      "error" => %{
        "code" => "stateful_commit_failed",
        "message" =>
          "AIGateway failed to commit the stateful response before forwarding the terminal frame.",
        "details" => inspect(reason)
      },
      "output" => []
    }

    %{"type" => "response.failed", "response" => response}
    |> maybe_put_sequence_number(sequence_number)
  end

  defp remember_provider_response_id(state, %{"response" => %{"id" => response_id}})
       when is_binary(response_id) do
    %{state | provider_response_id: state.provider_response_id || response_id}
  end

  defp remember_provider_response_id(state, %{"response_id" => response_id})
       when is_binary(response_id) do
    %{state | provider_response_id: state.provider_response_id || response_id}
  end

  defp remember_provider_response_id(state, _event), do: state

  defp rewrite_response_id(event, %{stateful: %{message_id: message_id}}) do
    new_id = "resp_#{message_id}"

    event
    |> rewrite_nested_response_id(new_id)
    |> rewrite_top_level_response_id(new_id)
  end

  defp rewrite_response_id(event, _state), do: event

  defp rewrite_nested_response_id(%{"response" => %{}} = event, new_id),
    do: put_in(event, ["response", "id"], new_id)

  defp rewrite_nested_response_id(event, _new_id), do: event

  defp rewrite_top_level_response_id(%{"response_id" => response_id} = event, new_id)
       when is_binary(response_id),
       do: Map.put(event, "response_id", new_id)

  defp rewrite_top_level_response_id(event, _new_id), do: event

  defp cleanup_response_id(%{stateful: %{message_id: message_id}}), do: "resp_#{message_id}"

  defp cleanup_response_id(%{provider_response_id: response_id}) when is_binary(response_id),
    do: response_id

  defp cleanup_response_id(_state), do: nil

  defp stateful_response_id(%{message_id: message_id}), do: "resp_#{message_id}"
  defp stateful_response_id(_stateful), do: nil

  defp stateful_message_id(%{message_id: message_id}), do: message_id
  defp stateful_message_id(_stateful), do: nil

  defp cleanup_error_message("provider_stream_closed_without_terminal"),
    do: "AIGateway provider stream closed before a terminal response."

  defp cleanup_error_message("provider_stream_aborted"),
    do: "AIGateway provider stream was aborted before a terminal response."

  defp cleanup_error_message(_code),
    do: "AIGateway provider stream failed before a terminal response."

  defp public_sequence_number(%{"sequence_number" => sequence}, _fallback)
       when is_integer(sequence),
       do: sequence

  defp public_sequence_number(_event, fallback), do: fallback

  defp next_sequence_number(%{sequence_number: sequence}) when is_integer(sequence),
    do: sequence + 1

  defp next_sequence_number(_state), do: nil

  defp maybe_put_sequence_number(event, nil), do: event

  defp maybe_put_sequence_number(event, sequence_number),
    do: Map.put(event, "sequence_number", sequence_number)

  defp maybe_put_metadata(map, _key, nil), do: map

  defp maybe_put_metadata(map, _key, value) when is_map(value) and map_size(value) == 0,
    do: map

  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_retryable(details, true), do: Map.put(details, "retryable", true)
  defp maybe_put_retryable(details, _retryable?), do: details

  defp maybe_mark_retryable_terminal_error(%{} = details) do
    if retryable_terminal_error?(details), do: Map.put(details, "retryable", true), else: details
  end

  defp retryable_terminal_error?(%{"retryable" => true}), do: true

  defp retryable_terminal_error?(%{} = details) do
    status =
      integer_value(details["status"]) || integer_value(get_in(details, ["error", "status"]))

    code =
      (string_value(get_in(details, ["error", "code"])) || string_value(details["code"]) || "")
      |> String.downcase()

    message =
      (string_value(get_in(details, ["error", "message"])) ||
         string_value(details["message"]) || "")
      |> String.downcase()

    retryable_upstream_status?(status) or
      String.contains?(code, "429") or
      String.contains?(code, "rate_limit") or
      String.contains?(message, "rate limit") or
      String.contains?(message, "too many requests") or
      Regex.match?(~r/(^|\D)429(\D|$)/, message)
  end

  defp retryable_upstream_status?(status) when status in [408, 409, 425, 429], do: true
  defp retryable_upstream_status?(status) when is_integer(status) and status >= 500, do: true
  defp retryable_upstream_status?(_status), do: false

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: nil

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: nil

  defp publish(%{stateful: %{message: %{} = message}}, type, payload),
    do: Events.publish(message, type, payload)

  defp publish(_state, _type, _payload), do: :ok

  defp tool_activity_payload(item, seq) do
    item
    |> Map.take(["type", "id", "call_id", "name", "status", "output", "action"])
    |> maybe_put_payload("seq", seq)
  end

  defp tool_activity_item?(%{"type" => type}) when is_binary(type) do
    type in ["function_call", "custom_tool_call", "mcp_list_tools"] or
      String.ends_with?(type, "_call")
  end

  defp tool_activity_item?(_item), do: false

  defp maybe_put_payload(payload, _key, nil), do: payload
  defp maybe_put_payload(payload, key, value), do: Map.put(payload, key, value)
end
