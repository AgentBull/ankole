defmodule Ankole.AIGateway.Providers.Claude do
  @moduledoc """
  Provider implementation for Anthropic Claude Messages API.

  Claude is a real adapter, not an OpenAI-compatible pass-through. Requests are
  converted from the AIGateway Responses-style body to Anthropic Messages, and
  Anthropic SSE events are converted back into the Responses event vocabulary.
  `messages_path` exists for Anthropic-compatible routers whose base URL already
  includes the API version, such as OpenRouter's `/api/v1/messages` endpoint.
  """

  @behaviour Ankole.AIGateway.Provider

  alias Ankole.AIGateway.Request
  alias Ankole.AIGateway.Response

  @anthropic_version "2023-06-01"

  @impl true
  def provider_id, do: "claude"

  @impl true
  def label, do: "Claude"

  @impl true
  def capabilities, do: ["llm"]

  @impl true
  def endpoint_modes, do: ["anthropic_messages"]

  @impl true
  def provider_strategy, do: "anthropic"

  @impl true
  def default_base_url, do: "https://api.anthropic.com"

  @impl true
  def default_http_protocol, do: "http2"

  @impl true
  def credential_schemes, do: ["api_key", "auth_token"]

  @impl true
  def connection_option_keys,
    do: ~w(http_protocol auth_mode headers anthropic_version anthropic_beta messages_path)

  @impl true
  def runtime_provider_option_keys,
    do:
      ~w(thinking cacheControl structuredOutputMode toolStreaming effort taskBudget speed inferenceGeo anthropicBeta contextManagement)

  @impl true
  def model_catalog_policy, do: "known_or_custom"

  @impl true
  def response_endpoint_mode(_runtime), do: "anthropic_messages"

  @impl true
  def build_response_request(runtime, request, opts) do
    stream? = Keyword.get(opts, :stream?, false)

    with {:ok, request} <-
           Request.build_anthropic_response_request(runtime, request, stream?: stream?) do
      {:ok, maybe_stream_request(request, stream?)}
    end
  end

  @impl true
  def normalize_response_body(runtime, upstream_request, %{status: status, body: body})
      when status in 200..299 and is_map(body) do
    response_body = anthropic_body_to_response(runtime, body)

    Response.normalize_body(
      runtime,
      %{
        response_mode: "responses",
        public_request: Map.get(upstream_request, :public_request, %{})
      },
      %{status: status, body: response_body}
    )
  end

  def normalize_response_body(_runtime, _upstream_request, %{status: status, body: body})
      when is_integer(status) and is_map(body),
      do: {:error, {:upstream_response_failed, status, body}}

  def normalize_response_body(_runtime, _upstream_request, response),
    do: {:error, {:invalid_upstream_response, response}}

  @impl true
  def put_headers(headers, %{"connection_options" => options}) do
    headers
    |> Map.put_new(
      "anthropic-version",
      Map.get(options, "anthropic_version") || @anthropic_version
    )
    |> maybe_put_beta(Map.get(options, "anthropic_beta"))
  end

  def put_headers(headers, _runtime),
    do: Map.put_new(headers, "anthropic-version", @anthropic_version)

  @impl true
  def put_auth_headers(headers, %{"credential" => credential} = runtime)
      when is_binary(credential) do
    mode =
      get_in(runtime, ["connection_options", "auth_mode"]) ||
        runtime["credential_mode"] ||
        "api_key"

    # Anthropic API keys use `x-api-key`, while OAuth-style tokens use bearer
    # auth. The mode can come from the provider row or a connection override.
    case mode do
      "auth_token" -> Map.put(headers, "authorization", "Bearer #{credential}")
      "oauth" -> Map.put(headers, "authorization", "Bearer #{credential}")
      _mode -> Map.put(headers, "x-api-key", credential)
    end
  end

  def put_auth_headers(headers, _runtime), do: headers

  @impl true
  def stream_init(runtime, upstream_request) do
    %{
      sequence_number: 0,
      runtime: runtime,
      public_request: Map.get(upstream_request, :public_request, %{}),
      response_id: nil,
      model: runtime["model"],
      message_item_id: nil,
      text: "",
      text_started?: false,
      tool_calls: %{},
      usage: %{},
      stop_reason: nil,
      response: nil,
      terminal?: false
    }
  end

  @impl true
  def decode_stream_message(_runtime, _upstream_request, state, :done), do: {:ok, [], state}

  # Anthropic sends typed JSON events inside SSE `data:` fields. The generic SSE
  # parser only frames the messages; this module owns the semantic conversion.
  def decode_stream_message(runtime, _upstream_request, state, %{"data" => data}) do
    with {:ok, event} <- decode_event_data(data) do
      decode_anthropic_event(runtime, state, event)
    end
  end

  @impl true
  def finish_stream(_runtime, _upstream_request, %{terminal?: true} = state), do: {:ok, [], state}

  def finish_stream(runtime, _upstream_request, state) do
    {:ok, events, state} =
      finish_message(runtime, %{state | stop_reason: "stream_closed"}, "incomplete")

    {:ok, events, state}
  end

  defp maybe_stream_request(request, false), do: request

  defp maybe_stream_request(request, true) do
    request
    |> put_in([:headers, "accept"], "text/event-stream")
    |> Map.put(:stream?, true)
  end

  defp maybe_put_beta(headers, value) when is_binary(value) and value != "",
    do: Map.put(headers, "anthropic-beta", value)

  defp maybe_put_beta(headers, values) when is_list(values) do
    Map.put(headers, "anthropic-beta", Enum.join(values, ","))
  end

  defp maybe_put_beta(headers, _value), do: headers

  defp decode_event_data(data) do
    case Ankole.JSON.decode(data) do
      {:ok, event} when is_map(event) -> {:ok, event}
      {:ok, value} -> {:error, {:invalid_upstream_stream_event, value}}
      {:error, reason} -> {:error, {:invalid_upstream_stream_json, reason}}
    end
  end

  # `message_start` is the earliest moment where Anthropic gives us the message
  # id/model/usage. We emit `response.created` immediately so downstream clients
  # can use the same lifecycle as OpenAI Responses streams.
  defp decode_anthropic_event(runtime, state, %{"type" => "message_start", "message" => message})
       when is_map(message) do
    state =
      state
      |> Map.put(:response_id, Map.get(message, "id") || "resp_#{Ecto.UUID.generate()}")
      |> Map.put(:model, Map.get(message, "model") || state.model)
      |> Map.put(:usage, Map.get(message, "usage") || %{})

    event = %{
      "type" => "response.created",
      "sequence_number" => state.sequence_number,
      "response" => response_body(runtime, state, "in_progress")
    }

    {:ok, [event], %{state | sequence_number: state.sequence_number + 1}}
  end

  # Anthropic content blocks can be text or tool_use. Text blocks become message
  # content part events; tool_use blocks become function_call output items.
  defp decode_anthropic_event(_runtime, state, %{
         "type" => "content_block_start",
         "index" => index,
         "content_block" => %{"type" => "text"}
       }) do
    {events, state} = ensure_message_item(state)
    {events, state} = ensure_text_part(events, state)
    {:ok, events, put_active_block(state, index, "text")}
  end

  defp decode_anthropic_event(_runtime, state, %{
         "type" => "content_block_start",
         "index" => index,
         "content_block" => %{"type" => "tool_use"} = block
       }) do
    call = %{
      "id" => "fc_#{Ecto.UUID.generate()}",
      "call_id" => Map.get(block, "id") || "call_#{Ecto.UUID.generate()}",
      "name" => Map.get(block, "name") || "unknown",
      "arguments" => ""
    }

    output_index = output_index_for_tool(state, index)

    event = %{
      "type" => "response.output_item.added",
      "sequence_number" => state.sequence_number,
      "output_index" => output_index,
      "item" => function_call_item(call, "in_progress")
    }

    state =
      state
      |> Map.put(:sequence_number, state.sequence_number + 1)
      |> put_active_block(index, "tool_use")
      |> put_in([:tool_calls, index], Map.put(call, "output_index", output_index))

    {:ok, [event], state}
  end

  defp decode_anthropic_event(_runtime, state, %{
         "type" => "content_block_delta",
         "index" => index,
         "delta" => %{"type" => "text_delta", "text" => text}
       })
       when is_binary(text) do
    {events, state} = ensure_message_item(state)
    {events, state} = ensure_text_part(events, state)

    event = %{
      "type" => "response.output_text.delta",
      "sequence_number" => state.sequence_number,
      "item_id" => state.message_item_id,
      "output_index" => 0,
      "content_index" => 0,
      "delta" => text
    }

    state =
      state
      |> Map.put(:sequence_number, state.sequence_number + 1)
      |> Map.put(:text, state.text <> text)
      |> put_active_block(index, "text")

    {:ok, events ++ [event], state}
  end

  defp decode_anthropic_event(_runtime, state, %{
         "type" => "content_block_delta",
         "index" => index,
         "delta" => %{"type" => "input_json_delta", "partial_json" => json}
       })
       when is_binary(json) do
    call = Map.get(state.tool_calls, index)

    if is_map(call) do
      call = Map.put(call, "arguments", (call["arguments"] || "") <> json)

      event = %{
        "type" => "response.function_call_arguments.delta",
        "sequence_number" => state.sequence_number,
        "item_id" => call["id"],
        "output_index" => call["output_index"],
        "delta" => json
      }

      {:ok, [event],
       %{
         state
         | sequence_number: state.sequence_number + 1,
           tool_calls: Map.put(state.tool_calls, index, call)
       }}
    else
      {:ok, [], state}
    end
  end

  defp decode_anthropic_event(_runtime, state, %{"type" => "content_block_stop", "index" => index}) do
    case get_in(state, [:active_blocks, index]) do
      "text" ->
        finish_text_part(state)

      "tool_use" ->
        finish_tool_call(state, index)

      _block ->
        {:ok, [], state}
    end
  end

  defp decode_anthropic_event(
         _runtime,
         state,
         %{"type" => "message_delta", "delta" => delta} = event
       ) do
    usage =
      case Map.get(event, "usage") do
        usage when is_map(usage) -> Map.merge(state.usage, usage)
        _usage -> state.usage
      end

    {:ok, [],
     %{
       state
       | usage: usage,
         stop_reason: Map.get(delta || %{}, "stop_reason") || state.stop_reason
     }}
  end

  defp decode_anthropic_event(runtime, state, %{"type" => "message_stop"}) do
    finish_message(runtime, state, terminal_status(state.stop_reason))
  end

  defp decode_anthropic_event(_runtime, state, %{"type" => "ping"}), do: {:ok, [], state}
  defp decode_anthropic_event(_runtime, state, _event), do: {:ok, [], state}

  defp ensure_message_item(%{message_item_id: nil} = state) do
    item_id = "msg_#{Ecto.UUID.generate()}"

    event = %{
      "type" => "response.output_item.added",
      "sequence_number" => state.sequence_number,
      "output_index" => 0,
      "item" => %{
        "id" => item_id,
        "type" => "message",
        "status" => "in_progress",
        "role" => "assistant",
        "content" => []
      }
    }

    {[event], %{state | sequence_number: state.sequence_number + 1, message_item_id: item_id}}
  end

  defp ensure_message_item(state), do: {[], state}

  defp ensure_text_part(events, %{text_started?: true} = state), do: {events, state}

  defp ensure_text_part(events, state) do
    event = %{
      "type" => "response.content_part.added",
      "sequence_number" => state.sequence_number,
      "item_id" => state.message_item_id,
      "output_index" => 0,
      "content_index" => 0,
      "part" => %{"type" => "output_text", "text" => "", "annotations" => []}
    }

    {events ++ [event],
     %{state | sequence_number: state.sequence_number + 1, text_started?: true}}
  end

  defp finish_text_part(state) do
    events = [
      %{
        "type" => "response.output_text.done",
        "sequence_number" => state.sequence_number,
        "item_id" => state.message_item_id,
        "output_index" => 0,
        "content_index" => 0,
        "text" => state.text
      },
      %{
        "type" => "response.content_part.done",
        "sequence_number" => state.sequence_number + 1,
        "item_id" => state.message_item_id,
        "output_index" => 0,
        "content_index" => 0,
        "part" => %{"type" => "output_text", "text" => state.text, "annotations" => []}
      }
    ]

    {:ok, events, %{state | sequence_number: state.sequence_number + 2}}
  end

  defp finish_tool_call(state, index) do
    call = Map.get(state.tool_calls, index)

    if is_map(call) do
      events = [
        %{
          "type" => "response.function_call_arguments.done",
          "sequence_number" => state.sequence_number,
          "item_id" => call["id"],
          "output_index" => call["output_index"],
          "arguments" => call["arguments"] || ""
        },
        %{
          "type" => "response.output_item.done",
          "sequence_number" => state.sequence_number + 1,
          "output_index" => call["output_index"],
          "item" => function_call_item(call, "completed")
        }
      ]

      {:ok, events, %{state | sequence_number: state.sequence_number + 2}}
    else
      {:ok, [], state}
    end
  end

  # Anthropic sends `message_stop` after all content blocks. We close any open
  # output item and then emit the terminal Responses event with the final body.
  defp finish_message(runtime, state, status) do
    {message_events, state} =
      if state.message_item_id do
        event = %{
          "type" => "response.output_item.done",
          "sequence_number" => state.sequence_number,
          "output_index" => 0,
          "item" => message_item(state, "completed")
        }

        {[event], %{state | sequence_number: state.sequence_number + 1}}
      else
        {[], state}
      end

    response = response_body(runtime, state, status)

    terminal = %{
      "type" => terminal_event(status),
      "sequence_number" => state.sequence_number,
      "response" => response
    }

    {:ok, message_events ++ [terminal],
     %{state | sequence_number: state.sequence_number + 1, response: response, terminal?: true}}
  end

  # Anthropic block indexes are local to content blocks. Responses output indexes
  # also include the assistant message item, so tool indexes shift when text has
  # already opened an output item.
  defp output_index_for_tool(state, anthropic_index) do
    if state.message_item_id, do: anthropic_index + 1, else: anthropic_index
  end

  defp put_active_block(state, index, type) do
    active_blocks = Map.put(Map.get(state, :active_blocks, %{}), index, type)
    Map.put(state, :active_blocks, active_blocks)
  end

  # Non-streaming Anthropic Messages responses arrive as content blocks. We
  # collapse text blocks into one assistant message and convert tool_use blocks
  # into function_call output items before the generic response normalizer fills
  # the remaining ResponseResource fields.
  defp anthropic_body_to_response(runtime, body) do
    text =
      body
      |> Map.get("content", [])
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) -> [text]
        _block -> []
      end)
      |> Enum.join("")

    tool_calls =
      body
      |> Map.get("content", [])
      |> Enum.flat_map(fn
        %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
          [
            %{
              "id" => "fc_#{Ecto.UUID.generate()}",
              "type" => "function_call",
              "call_id" => id,
              "name" => name,
              "arguments" => Ankole.JSON.encode!(input || %{}),
              "status" => "completed"
            }
          ]

        _block ->
          []
      end)

    output =
      if text == "" do
        tool_calls
      else
        [
          message_item(%{message_item_id: "msg_#{Ecto.UUID.generate()}", text: text}, "completed")
          | tool_calls
        ]
      end

    %{
      "id" => Map.get(body, "id") || "resp_#{Ecto.UUID.generate()}",
      "object" => "response",
      "created_at" => System.system_time(:second),
      "completed_at" => System.system_time(:second),
      "status" => "completed",
      "model" => Map.get(body, "model") || runtime["model"],
      "output" => output,
      "usage" => normalize_usage(Map.get(body, "usage")),
      "metadata" => %{}
    }
  end

  defp response_body(runtime, state, status) do
    output =
      []
      |> maybe_add_message_item(state)
      |> Kernel.++(tool_call_items(state))

    %{
      "id" => state.response_id || "resp_#{Ecto.UUID.generate()}",
      "object" => "response",
      "created_at" => System.system_time(:second),
      "completed_at" => if(status == "completed", do: System.system_time(:second), else: nil),
      "status" => status,
      "model" => state.model || runtime["model"],
      "output" => output,
      "usage" => normalize_usage(state.usage),
      "metadata" => %{}
    }
  end

  defp maybe_add_message_item(output, %{message_item_id: id, text: text}) when is_binary(id) do
    output ++ [message_item(%{message_item_id: id, text: text}, "completed")]
  end

  defp maybe_add_message_item(output, _state), do: output

  defp message_item(state, status) do
    %{
      "id" => state.message_item_id,
      "type" => "message",
      "status" => status,
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => state.text || "", "annotations" => []}]
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

  defp tool_call_items(state) do
    state.tool_calls
    |> Enum.sort_by(fn {_index, call} -> call["output_index"] end)
    |> Enum.map(fn {_index, call} -> function_call_item(call, "completed") end)
  end

  defp normalize_usage(usage) when is_map(usage) do
    input_tokens = Map.get(usage, "input_tokens") || 0
    output_tokens = Map.get(usage, "output_tokens") || 0

    %{
      "input_tokens" => input_tokens,
      "output_tokens" => output_tokens,
      "total_tokens" => input_tokens + output_tokens,
      "input_tokens_details" => %{},
      "output_tokens_details" => %{}
    }
  end

  defp normalize_usage(_usage), do: %{}

  defp terminal_status("max_tokens"), do: "incomplete"
  defp terminal_status("stream_closed"), do: "incomplete"
  defp terminal_status(_reason), do: "completed"

  defp terminal_event("completed"), do: "response.completed"
  defp terminal_event("incomplete"), do: "response.incomplete"
  defp terminal_event("failed"), do: "response.failed"
end
