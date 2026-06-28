defmodule Ankole.AIGateway.Providers.OpenAICompatible do
  @moduledoc """
  Provider implementation for arbitrary OpenAI-compatible endpoints.

  This provider is intentionally conservative. It has no default URL and uses
  HTTP/1 by default because compatibility servers often sit behind simple HTTP/1
  gateways. It supports both Responses and Chat Completions wire APIs, then
  normalizes both into the AIGateway Responses contract.
  """

  @behaviour Ankole.AIGateway.Provider

  alias Ankole.AIGateway.Request
  alias Ankole.AIGateway.Response

  @terminal_events ["response.completed", "response.failed", "response.incomplete", "error"]

  @impl true
  def provider_id, do: "openai-compatible"

  @impl true
  def label, do: "OpenAI Compatible"

  @impl true
  def capabilities, do: ["llm"]

  @impl true
  def endpoint_modes, do: ["responses", "chat_completions"]

  @impl true
  def provider_strategy, do: "openai_compatible"

  @impl true
  def default_base_url, do: nil

  @impl true
  def default_http_protocol, do: "http1"

  @impl true
  def credential_schemes, do: ["api_key", "bearer"]

  @impl true
  def connection_option_keys,
    do:
      ~w(http_protocol endpoint_kind headers query_params include_usage supports_structured_outputs)

  @impl true
  def runtime_provider_option_keys,
    do: ~w(user reasoning reasoningEffort textVerbosity strictJsonSchema)

  @impl true
  def model_catalog_policy, do: "provider_specific"

  @impl true
  def response_endpoint_mode(%{"connection_options" => options}) do
    case Map.get(options, "endpoint_kind") do
      "responses" -> "responses"
      _kind -> "chat_completions"
    end
  end

  def response_endpoint_mode(_runtime), do: "chat_completions"

  @impl true
  def build_response_request(runtime, request, opts) do
    stream? = Keyword.get(opts, :stream?, false)

    with {:ok, request} <-
           Request.build_openai_compatible_response_request(
             runtime,
             request,
             response_endpoint_mode(runtime),
             stream?: stream?
           ) do
      {:ok, maybe_stream_request(request, stream?)}
    end
  end

  @impl true
  def normalize_response_body(runtime, upstream_request, upstream_response) do
    Response.normalize_body(runtime, upstream_request, upstream_response)
  end

  @impl true
  def put_headers(headers, _runtime), do: headers

  @impl true
  def put_auth_headers(headers, %{"credential" => credential}) when is_binary(credential) do
    Map.put(headers, "authorization", "Bearer #{credential}")
  end

  def put_auth_headers(headers, _runtime), do: headers

  @impl true
  def stream_init(runtime, %{response_mode: "responses"} = upstream_request) do
    %{
      mode: "responses",
      sequence_number: 0,
      response: nil,
      terminal?: false,
      runtime: runtime,
      public_request: Map.get(upstream_request, :public_request, %{})
    }
  end

  # Chat Completions streams do not carry a complete Responses body. We keep
  # enough state to reconstruct output items and usage when the stream finishes.
  def stream_init(runtime, %{response_mode: "chat_completions"} = upstream_request) do
    %{
      mode: "chat_completions",
      sequence_number: 0,
      response_id: nil,
      upstream_id: nil,
      created_at: nil,
      model: runtime["model"],
      message_item: nil,
      content_started?: false,
      output_text: "",
      tool_calls: %{},
      usage: %{},
      finish_reason: nil,
      response: nil,
      terminal?: false,
      runtime: runtime,
      public_request: Map.get(upstream_request, :public_request, %{})
    }
  end

  @impl true
  def decode_stream_message(_runtime, _upstream_request, state, :done), do: {:ok, [], state}

  # Responses SSE already uses the downstream event vocabulary. We still pass
  # embedded `response` resources through normal response completion so missing
  # defaults and request-derived fields are stable.
  def decode_stream_message(runtime, upstream_request, %{mode: "responses"} = state, %{
        "data" => data
      }) do
    with {:ok, event} <- decode_event_data(data),
         {:ok, event} <- normalize_response_event(runtime, upstream_request, event) do
      event = put_sequence_number(event, state.sequence_number)
      state = remember_response(state, event)
      {:ok, [event], advance_sequence(state, 1)}
    end
  end

  def decode_stream_message(runtime, upstream_request, %{mode: "chat_completions"} = state, %{
        "data" => data
      }) do
    with {:ok, chunk} <- decode_event_data(data) do
      decode_chat_chunk(runtime, upstream_request, state, chunk)
    end
  end

  @impl true
  def finish_stream(_runtime, _upstream_request, %{mode: "responses", terminal?: true} = state),
    do: {:ok, [], state}

  # A Responses stream must end with an explicit terminal event. A TCP close with
  # no terminal event is a truncated provider response, not a successful turn.
  def finish_stream(_runtime, _upstream_request, %{mode: "responses"} = state) do
    {:error, {:upstream_stream_closed_before_terminal_event, state.response}}
  end

  def finish_stream(
        runtime,
        _upstream_request,
        %{mode: "chat_completions", terminal?: true} = state
      ) do
    {:ok, [], %{state | response: chat_response_body(runtime, state)}}
  end

  def finish_stream(runtime, _upstream_request, %{mode: "chat_completions"} = state) do
    {events, state} = finish_chat_stream(runtime, state, "incomplete")
    {:ok, events, state}
  end

  defp maybe_stream_request(request, false), do: request

  # Some providers require an explicit SSE accept header before they stream, even
  # when the request body already has `"stream": true`.
  defp maybe_stream_request(request, true) do
    request
    |> put_in([:headers, "accept"], "text/event-stream")
    |> Map.put(:stream?, true)
  end

  defp decode_event_data(data) do
    case Ankole.JSON.decode(data) do
      {:ok, event} when is_map(event) -> {:ok, event}
      {:ok, value} -> {:error, {:invalid_upstream_stream_event, value}}
      {:error, reason} -> {:error, {:invalid_upstream_stream_json, reason}}
    end
  end

  defp normalize_response_event(runtime, upstream_request, %{"response" => response} = event)
       when is_map(response) do
    case Response.normalize_body(
           runtime,
           %{
             response_mode: "responses",
             public_request: Map.get(upstream_request, :public_request, %{})
           },
           %{status: 200, body: response}
         ) do
      {:ok, response} -> {:ok, Map.put(event, "response", response)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_response_event(_runtime, _upstream_request, event), do: {:ok, event}

  defp put_sequence_number(event, sequence_number) do
    Map.put_new(event, "sequence_number", sequence_number)
  end

  defp remember_response(state, %{"type" => type, "response" => response} = event) do
    state
    |> Map.put(:response, response)
    |> Map.put(:terminal?, type in @terminal_events or state.terminal?)
    |> maybe_mark_error_terminal(event)
  end

  defp remember_response(state, %{"type" => type} = event) do
    state
    |> Map.put(:terminal?, type in @terminal_events or state.terminal?)
    |> maybe_mark_error_terminal(event)
  end

  defp maybe_mark_error_terminal(state, %{"type" => "error"}), do: %{state | terminal?: true}
  defp maybe_mark_error_terminal(state, _event), do: state

  defp advance_sequence(state, count),
    do: %{state | sequence_number: state.sequence_number + count}

  # Converts Chat Completions delta chunks into Responses lifecycle events. The
  # state machine keeps text and tool-call arguments open until finish_reason or
  # stream close tells us to emit the done events.
  defp decode_chat_chunk(runtime, _upstream_request, state, chunk) do
    state =
      state
      |> put_chat_metadata(chunk)
      |> put_chat_usage(chunk)

    choice = chunk |> Map.get("choices", []) |> List.first() || %{}
    delta = Map.get(choice, "delta") || %{}
    finish_reason = Map.get(choice, "finish_reason")

    {events, state} =
      []
      |> maybe_start_chat_response(runtime, state)
      |> maybe_decode_chat_text(delta, state)
      |> maybe_decode_chat_tool_calls(delta, state)

    state =
      if is_binary(finish_reason) do
        %{state | finish_reason: finish_reason}
      else
        state
      end

    if is_binary(finish_reason) do
      {finish_events, state} = finish_chat_stream(runtime, state, terminal_status(finish_reason))
      {:ok, events ++ finish_events, state}
    else
      {:ok, events, state}
    end
  end

  defp put_chat_metadata(state, chunk) do
    upstream_id = Map.get(chunk, "id") || state.upstream_id
    response_id = state.response_id || upstream_id || "resp_#{Ecto.UUID.generate()}"
    created_at = Map.get(chunk, "created") || state.created_at || System.system_time(:second)
    model = Map.get(chunk, "model") || state.model

    %{
      state
      | upstream_id: upstream_id,
        response_id: response_id,
        created_at: created_at,
        model: model
    }
  end

  defp put_chat_usage(state, %{"usage" => usage}) when is_map(usage), do: %{state | usage: usage}
  defp put_chat_usage(state, _chunk), do: state

  defp maybe_start_chat_response(events, runtime, %{message_item: nil} = state) do
    response = chat_response_body(runtime, state)

    created = %{
      "type" => "response.created",
      "sequence_number" => state.sequence_number,
      "response" => response
    }

    item = message_item(state, "in_progress", [])

    added = %{
      "type" => "response.output_item.added",
      "sequence_number" => state.sequence_number + 1,
      "output_index" => 0,
      "item" => item
    }

    {[created, added | events],
     %{state | sequence_number: state.sequence_number + 2, message_item: item}}
  end

  defp maybe_start_chat_response(events, _runtime, state), do: {events, state}

  defp maybe_decode_chat_text({events, state}, %{"content" => content}, _old_state)
       when is_binary(content) and content != "" do
    {events, state} = maybe_start_content(events, state)

    event = %{
      "type" => "response.output_text.delta",
      "sequence_number" => state.sequence_number,
      "item_id" => state.message_item["id"],
      "output_index" => 0,
      "content_index" => 0,
      "delta" => content
    }

    {events ++ [event],
     %{
       state
       | sequence_number: state.sequence_number + 1,
         output_text: state.output_text <> content
     }}
  end

  defp maybe_decode_chat_text({events, state}, _delta, _old_state), do: {events, state}

  defp maybe_start_content(events, %{content_started?: true} = state), do: {events, state}

  defp maybe_start_content(events, state) do
    part = %{"type" => "output_text", "text" => "", "annotations" => []}

    event = %{
      "type" => "response.content_part.added",
      "sequence_number" => state.sequence_number,
      "item_id" => state.message_item["id"],
      "output_index" => 0,
      "content_index" => 0,
      "part" => part
    }

    {events ++ [event],
     %{state | sequence_number: state.sequence_number + 1, content_started?: true}}
  end

  defp maybe_decode_chat_tool_calls({events, state}, %{"tool_calls" => tool_calls}, _old_state)
       when is_list(tool_calls) do
    Enum.reduce(tool_calls, {events, state}, &decode_tool_call_delta/2)
  end

  defp maybe_decode_chat_tool_calls({events, state}, _delta, _old_state), do: {events, state}

  defp decode_tool_call_delta(delta, {events, state}) when is_map(delta) do
    index = Map.get(delta, "index") || map_size(state.tool_calls)
    existing = Map.get(state.tool_calls, index, %{})
    function = Map.get(delta, "function", %{})

    call =
      existing
      |> Map.put_new("id", "fc_#{Ecto.UUID.generate()}")
      |> Map.put(
        "call_id",
        Map.get(delta, "id") || existing["call_id"] || "call_#{Ecto.UUID.generate()}"
      )
      |> Map.put("name", Map.get(function, "name") || existing["name"] || "unknown")
      |> Map.put(
        "arguments",
        (existing["arguments"] || "") <> (Map.get(function, "arguments") || "")
      )

    {events, state} =
      if existing == %{} do
        item = function_call_item(call, "in_progress")

        event = %{
          "type" => "response.output_item.added",
          "sequence_number" => state.sequence_number,
          "output_index" => 1 + index,
          "item" => item
        }

        {events ++ [event], %{state | sequence_number: state.sequence_number + 1}}
      else
        {events, state}
      end

    argument_delta = Map.get(function, "arguments")

    {events, state} =
      if is_binary(argument_delta) and argument_delta != "" do
        event = %{
          "type" => "response.function_call_arguments.delta",
          "sequence_number" => state.sequence_number,
          "item_id" => call["id"],
          "output_index" => 1 + index,
          "delta" => argument_delta
        }

        {events ++ [event], %{state | sequence_number: state.sequence_number + 1}}
      else
        {events, state}
      end

    {events, %{state | tool_calls: Map.put(state.tool_calls, index, call)}}
  end

  defp decode_tool_call_delta(_delta, acc), do: acc

  # Finish emits closing events in the same order as the live Responses API:
  # text part done, output item done, tool call argument done, tool item done,
  # then the terminal response event.
  defp finish_chat_stream(runtime, state, status) do
    {events, state} = finish_chat_text([], state)
    {tool_events, state} = finish_chat_tools(state)

    response = chat_response_body(runtime, %{state | terminal?: true}, status)

    terminal = %{
      "type" => terminal_event(status),
      "sequence_number" => state.sequence_number,
      "response" => response
    }

    events = events ++ tool_events ++ [terminal]

    {events,
     %{
       state
       | sequence_number: state.sequence_number + 1,
         response: response,
         terminal?: true
     }}
  end

  defp finish_chat_text(events, %{content_started?: false} = state), do: {events, state}

  defp finish_chat_text(events, state) do
    text = state.output_text
    item_id = state.message_item["id"]

    finish_events = [
      %{
        "type" => "response.output_text.done",
        "sequence_number" => state.sequence_number,
        "item_id" => item_id,
        "output_index" => 0,
        "content_index" => 0,
        "text" => text
      },
      %{
        "type" => "response.content_part.done",
        "sequence_number" => state.sequence_number + 1,
        "item_id" => item_id,
        "output_index" => 0,
        "content_index" => 0,
        "part" => %{"type" => "output_text", "text" => text, "annotations" => []}
      },
      %{
        "type" => "response.output_item.done",
        "sequence_number" => state.sequence_number + 2,
        "output_index" => 0,
        "item" =>
          message_item(state, "completed", [
            %{"type" => "output_text", "text" => text, "annotations" => []}
          ])
      }
    ]

    {events ++ finish_events, %{state | sequence_number: state.sequence_number + 3}}
  end

  defp finish_chat_tools(state) do
    state.tool_calls
    |> Enum.sort_by(fn {index, _call} -> index end)
    |> Enum.reduce({[], state}, fn {index, call}, {events, state} ->
      finish_events = [
        %{
          "type" => "response.function_call_arguments.done",
          "sequence_number" => state.sequence_number,
          "item_id" => call["id"],
          "output_index" => 1 + index,
          "arguments" => call["arguments"] || ""
        },
        %{
          "type" => "response.output_item.done",
          "sequence_number" => state.sequence_number + 1,
          "output_index" => 1 + index,
          "item" => function_call_item(call, "completed")
        }
      ]

      {events ++ finish_events, %{state | sequence_number: state.sequence_number + 2}}
    end)
  end

  defp message_item(state, status, content) do
    id = get_in(state, [:message_item, "id"]) || "msg_#{Ecto.UUID.generate()}"

    %{
      "id" => id,
      "type" => "message",
      "status" => status,
      "role" => "assistant",
      "content" => content
    }
  end

  defp function_call_item(call, status) do
    %{
      "id" => call["id"],
      "type" => "function_call",
      "call_id" => call["call_id"],
      "name" => call["name"],
      "arguments" => call["arguments"] || "",
      "status" => status
    }
  end

  defp chat_response_body(runtime, state, status \\ "completed") do
    output =
      []
      |> maybe_append_message_output(state)
      |> Kernel.++(function_call_outputs(state))

    %{
      "id" => state.response_id || state.upstream_id || "resp_#{Ecto.UUID.generate()}",
      "object" => "response",
      "created_at" => state.created_at || System.system_time(:second),
      "completed_at" => if(status == "completed", do: System.system_time(:second), else: nil),
      "status" => status,
      "model" => state.model || runtime["model"],
      "output" => output,
      "usage" => normalize_chat_usage(state.usage),
      "previous_response_id" => nil,
      "metadata" => %{}
    }
  end

  defp maybe_append_message_output(output, %{content_started?: true} = state) do
    output ++
      [
        message_item(state, "completed", [
          %{"type" => "output_text", "text" => state.output_text, "annotations" => []}
        ])
      ]
  end

  defp maybe_append_message_output(output, _state), do: output

  defp function_call_outputs(state) do
    state.tool_calls
    |> Enum.sort_by(fn {index, _call} -> index end)
    |> Enum.map(fn {_index, call} -> function_call_item(call, "completed") end)
  end

  # OpenAI-compatible providers mix Chat Completions names and Responses names
  # for usage fields. Downstream always sees the Responses-style names.
  defp normalize_chat_usage(usage) when is_map(usage) do
    %{
      "input_tokens" => Map.get(usage, "input_tokens") || Map.get(usage, "prompt_tokens") || 0,
      "output_tokens" =>
        Map.get(usage, "output_tokens") || Map.get(usage, "completion_tokens") || 0,
      "total_tokens" => Map.get(usage, "total_tokens") || 0,
      "input_tokens_details" => Map.get(usage, "input_tokens_details") || %{},
      "output_tokens_details" => Map.get(usage, "output_tokens_details") || %{}
    }
  end

  defp normalize_chat_usage(_usage), do: %{}

  defp terminal_status("length"), do: "incomplete"
  defp terminal_status(_finish_reason), do: "completed"

  defp terminal_event("completed"), do: "response.completed"
  defp terminal_event("incomplete"), do: "response.incomplete"
  defp terminal_event("failed"), do: "response.failed"
end
