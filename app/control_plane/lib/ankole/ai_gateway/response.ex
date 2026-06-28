defmodule Ankole.AIGateway.Response do
  @moduledoc """
  Normalizes upstream LLM response bodies into the AIGateway Responses contract.

  Providers may return native Responses bodies or Chat Completions bodies. The
  gateway exposes one downstream shape, so this module fills missing boring
  fields, preserves public request facts where upstreams omit them, and fails
  closed for upstream errors.
  """

  import Ankole.AIGateway.MapUtils,
    only: [
      blank_string?: 1,
      boolean_value: 2,
      integer_value: 1,
      maybe_put: 3,
      normalize_request_keys: 1,
      nullable_string: 1,
      now_seconds: 0,
      number_value: 2,
      preferred_value: 3,
      put_default: 3,
      string_value: 1
    ]

  @doc """
  Normalizes a provider response into a complete Responses-style body.

  Non-2xx provider bodies are returned as structured errors instead of being
  wrapped as successful AIGateway responses. This keeps billing and retry logic
  from treating an upstream provider error as a completed model turn.
  """
  @spec normalize_body(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_body(runtime, %{response_mode: "responses"} = request, %{
        status: status,
        body: body
      })
      when status in 200..299 and is_map(body) do
    {:ok, complete_response_resource(runtime, Map.get(request, :public_request, %{}), body)}
  end

  def normalize_body(runtime, %{response_mode: "chat_completions"} = request, %{
        status: status,
        body: body
      })
      when status in 200..299 and is_map(body) do
    {:ok, chat_completion_to_response(runtime, Map.get(request, :public_request, %{}), body)}
  end

  def normalize_body(_runtime, _request, %{status: status, body: body})
      when is_integer(status) and is_map(body) do
    {:error, {:upstream_response_failed, status, normalize_request_keys(body)}}
  end

  def normalize_body(_runtime, _request, response),
    do: {:error, {:invalid_upstream_response, response}}

  # Chat Completions has no top-level Response resource. We synthesize only the
  # minimal output item sequence needed by the downstream contract and leave
  # detailed chat metadata out of the public body.
  defp chat_completion_to_response(runtime, public_request, body) do
    message = get_in(body, ["choices", Access.at(0), "message"]) || %{}
    id = Map.get(body, "id") || "resp_#{Ecto.UUID.generate()}"
    created_at = Map.get(body, "created") || System.system_time(:second)
    model = Map.get(body, "model") || runtime["model"]

    runtime
    |> complete_response_resource(public_request, %{
      "id" => id,
      "object" => "response",
      "created_at" => created_at,
      "completed_at" => created_at,
      "status" => "completed",
      "model" => model,
      "output" => chat_output_items(message),
      "usage" => normalize_response_usage(Map.get(body, "usage")),
      "metadata" => %{}
    })
  end

  # AIGateway callers expect a stable ResponseResource-like map even when an
  # upstream omits optional fields. Defaults are chosen to match stateless v1:
  # no persisted previous response, no background jobs, and no stored response.
  defp complete_response_resource(runtime, public_request, body) do
    request = normalize_request_keys(public_request)
    body = normalize_request_keys(body)

    created_at =
      integer_value(Map.get(body, "created_at") || Map.get(body, "created")) || now_seconds()

    status = string_value(Map.get(body, "status")) || "completed"

    completed_at =
      cond do
        Map.has_key?(body, "completed_at") -> Map.get(body, "completed_at")
        status == "completed" -> now_seconds()
        true -> nil
      end

    body
    |> Map.put("object", "response")
    |> put_default("id", "resp_#{Ecto.UUID.generate()}")
    |> Map.put("created_at", created_at)
    |> Map.put("completed_at", completed_at)
    |> Map.put("status", status)
    |> Map.put("incomplete_details", Map.get(body, "incomplete_details"))
    |> Map.put("model", string_value(Map.get(body, "model")) || runtime["model"])
    |> Map.put("previous_response_id", nil)
    |> Map.put("next_response_ids", normalize_string_list(Map.get(body, "next_response_ids")))
    |> Map.put(
      "instructions",
      normalize_instructions(preferred_value(body, request, "instructions"))
    )
    |> Map.put("input", normalize_input_items(preferred_value(body, request, "input")))
    |> Map.put("output", normalize_output_items(Map.get(body, "output")))
    |> Map.put("error", Map.get(body, "error"))
    |> Map.put("tools", normalize_tools(preferred_value(body, request, "tools")))
    |> Map.put(
      "tool_choice",
      normalize_tool_choice(preferred_value(body, request, "tool_choice"))
    )
    |> Map.put("truncation", normalize_truncation(preferred_value(body, request, "truncation")))
    |> Map.put(
      "parallel_tool_calls",
      boolean_value(preferred_value(body, request, "parallel_tool_calls"), true)
    )
    |> Map.put("text", normalize_text_field(preferred_value(body, request, "text")))
    |> Map.put("top_p", number_value(preferred_value(body, request, "top_p"), 1))
    |> Map.put(
      "presence_penalty",
      number_value(preferred_value(body, request, "presence_penalty"), 0)
    )
    |> Map.put(
      "frequency_penalty",
      number_value(preferred_value(body, request, "frequency_penalty"), 0)
    )
    |> Map.put("top_logprobs", integer_value(preferred_value(body, request, "top_logprobs")) || 0)
    |> Map.put(
      "temperature",
      number_value(preferred_value(body, request, "temperature"), 1)
    )
    |> Map.put("reasoning", normalize_reasoning(preferred_value(body, request, "reasoning")))
    |> Map.put("user", nullable_string(preferred_value(body, request, "user")))
    |> Map.put("usage", normalize_response_usage(Map.get(body, "usage")))
    |> maybe_put("cost_token", nullable_string(Map.get(body, "cost_token")))
    |> Map.put(
      "max_output_tokens",
      integer_value(preferred_value(body, request, "max_output_tokens"))
    )
    |> Map.put("max_tool_calls", integer_value(preferred_value(body, request, "max_tool_calls")))
    |> Map.put("store", boolean_value(preferred_value(body, request, "store"), false))
    |> Map.put("background", boolean_value(preferred_value(body, request, "background"), false))
    |> Map.put(
      "service_tier",
      string_value(preferred_value(body, request, "service_tier")) || "default"
    )
    |> Map.put("metadata", normalize_metadata(preferred_value(body, request, "metadata")))
    |> Map.put(
      "safety_identifier",
      nullable_string(preferred_value(body, request, "safety_identifier"))
    )
    |> Map.put(
      "prompt_cache_key",
      nullable_string(preferred_value(body, request, "prompt_cache_key"))
    )
    |> Map.put(
      "prompt_cache_retention",
      normalize_prompt_cache_retention(preferred_value(body, request, "prompt_cache_retention"))
    )
    |> Map.put("context_edits", normalize_list(Map.get(body, "context_edits")))
    |> Map.put(
      "conversation",
      normalize_conversation(preferred_value(body, request, "conversation"))
    )
    |> maybe_put("billing", Map.get(body, "billing"))
  end

  # Some chat-compatible providers return both assistant text and tool calls in
  # the same message. Responses represents those as separate output items, so the
  # conversion keeps both instead of picking one.
  defp chat_output_items(message) when is_map(message) do
    content = Map.get(message, "content")
    text_items = if blank_string?(content), do: [], else: [assistant_message_item(content)]
    tool_items = message |> Map.get("tool_calls") |> chat_tool_call_items()

    case text_items ++ tool_items do
      [] -> [assistant_message_item("")]
      items -> items
    end
  end

  defp chat_output_items(_message), do: [assistant_message_item("")]

  defp assistant_message_item(content) do
    %{
      "id" => "msg_#{Ecto.UUID.generate()}",
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [
        %{
          "type" => "output_text",
          "text" => content_to_response_text(content),
          "annotations" => []
        }
      ]
    }
  end

  defp chat_tool_call_items(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn
      %{"id" => call_id, "function" => %{"name" => name, "arguments" => arguments}} ->
        %{
          "id" => "fc_#{Ecto.UUID.generate()}",
          "type" => "function_call",
          "call_id" => to_string(call_id),
          "name" => to_string(name),
          "arguments" => tool_arguments_to_string(arguments),
          "status" => "completed"
        }

      value ->
        %{
          "id" => "fc_#{Ecto.UUID.generate()}",
          "type" => "function_call",
          "call_id" => "call_#{Ecto.UUID.generate()}",
          "name" => "unknown",
          "arguments" => Ankole.JSON.encode!(value),
          "status" => "completed"
        }
    end)
  end

  defp chat_tool_call_items(_tool_calls), do: []

  defp tool_arguments_to_string(arguments) when is_binary(arguments), do: arguments
  defp tool_arguments_to_string(nil), do: "{}"
  defp tool_arguments_to_string(arguments), do: Ankole.JSON.encode!(arguments)

  defp content_to_response_text(value) when is_binary(value), do: value
  defp content_to_response_text(nil), do: ""
  defp content_to_response_text(value), do: inspect(value)

  # Native Responses bodies are still normalized because compatible providers
  # often omit ids, statuses, or annotations that the worker relies on when it
  # consumes HTTP SSE and WebSocket events through the same contract.
  defp normalize_output_items(items) when is_list(items) do
    Enum.map(items, fn
      %{"type" => "message"} = item ->
        item
        |> put_default("id", "msg_#{Ecto.UUID.generate()}")
        |> put_default("status", "completed")
        |> put_default("role", "assistant")
        |> Map.update("content", [], &normalize_output_content/1)

      %{"type" => "function_call"} = item ->
        item
        |> put_default("id", "fc_#{Ecto.UUID.generate()}")
        |> put_default("call_id", "call_#{Ecto.UUID.generate()}")
        |> put_default("name", "unknown")
        |> put_default("arguments", "{}")
        |> put_default("status", "completed")

      item ->
        item
    end)
  end

  defp normalize_output_items(_items), do: []

  defp normalize_input_items(input) when is_binary(input) do
    [
      %{
        "id" => "msg_#{Ecto.UUID.generate()}",
        "type" => "message",
        "status" => "completed",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => input}]
      }
    ]
  end

  defp normalize_input_items(input) when is_list(input),
    do: Enum.map(input, &normalize_input_item/1)

  defp normalize_input_items(_input), do: []

  defp normalize_input_item(%{"type" => "message"} = item) do
    role = string_value(Map.get(item, "role")) || "user"

    item
    |> put_default("id", "msg_#{Ecto.UUID.generate()}")
    |> put_default("status", "completed")
    |> Map.put("role", role)
    |> Map.update("content", [], &normalize_message_content_for_role(role, &1))
  end

  defp normalize_input_item(%{"role" => role, "content" => _content} = item)
       when is_binary(role) do
    item
    |> Map.put("type", "message")
    |> normalize_input_item()
  end

  defp normalize_input_item(%{"type" => "function_call"} = item) do
    item
    |> put_default("id", "fc_#{Ecto.UUID.generate()}")
    |> put_default("call_id", "call_#{Ecto.UUID.generate()}")
    |> put_default("name", "unknown")
    |> put_default("arguments", "{}")
    |> put_default("status", "completed")
  end

  defp normalize_input_item(%{"type" => "function_call_output"} = item) do
    item
    |> put_default("id", "fco_#{Ecto.UUID.generate()}")
    |> put_default("call_id", "call_#{Ecto.UUID.generate()}")
    |> put_default("output", "")
    |> put_default("status", "completed")
  end

  defp normalize_input_item(item), do: item

  defp normalize_message_content_for_role(role, content)
       when role in ["assistant", "tool"] do
    normalize_assistant_content(content)
  end

  defp normalize_message_content_for_role(_role, content), do: normalize_user_content(content)

  defp normalize_user_content(content) when is_binary(content),
    do: [%{"type" => "input_text", "text" => content}]

  defp normalize_user_content(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "input_text"} = part ->
        Map.put_new(part, "text", "")

      %{"type" => "text", "text" => text} ->
        %{"type" => "input_text", "text" => to_string(text)}

      %{"text" => text} ->
        %{"type" => "input_text", "text" => to_string(text)}

      part when is_map(part) ->
        part

      value ->
        %{"type" => "input_text", "text" => inspect(value)}
    end)
  end

  defp normalize_user_content(content),
    do: [%{"type" => "input_text", "text" => inspect(content)}]

  defp normalize_assistant_content(content) when is_binary(content),
    do: [%{"type" => "output_text", "text" => content, "annotations" => []}]

  defp normalize_assistant_content(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "output_text"} = part ->
        part
        |> put_default("text", "")
        |> put_default("annotations", [])

      %{"type" => "refusal"} = part ->
        Map.put_new(part, "refusal", "")

      %{"type" => "text", "text" => text} ->
        %{"type" => "output_text", "text" => to_string(text), "annotations" => []}

      %{"text" => text} ->
        %{"type" => "output_text", "text" => to_string(text), "annotations" => []}

      part when is_map(part) ->
        part

      value ->
        %{"type" => "output_text", "text" => inspect(value), "annotations" => []}
    end)
  end

  defp normalize_assistant_content(content),
    do: [%{"type" => "output_text", "text" => inspect(content), "annotations" => []}]

  defp normalize_output_content(content) when is_binary(content) do
    [%{"type" => "output_text", "text" => content, "annotations" => []}]
  end

  defp normalize_output_content(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "output_text"} = part ->
        part
        |> put_default("text", "")
        |> put_default("annotations", [])

      %{"type" => "refusal"} = part ->
        Map.put_new(part, "refusal", "")

      %{"type" => "text", "text" => text} ->
        %{"type" => "output_text", "text" => to_string(text), "annotations" => []}

      %{"text" => text} ->
        %{"type" => "output_text", "text" => to_string(text), "annotations" => []}

      value ->
        %{"type" => "output_text", "text" => inspect(value), "annotations" => []}
    end)
  end

  defp normalize_output_content(_content), do: []

  defp normalize_tools(tools) when is_list(tools) do
    Enum.map(tools, fn
      %{"type" => "function"} = tool ->
        tool
        |> put_default("description", nil)
        |> put_default("parameters", nil)
        |> put_default("strict", nil)

      tool ->
        tool
    end)
  end

  defp normalize_tools(_tools), do: []

  defp normalize_tool_choice(choice) when choice in ["none", "auto", "required"], do: choice
  defp normalize_tool_choice(choice) when is_map(choice), do: choice
  defp normalize_tool_choice(_choice), do: "auto"

  defp normalize_truncation(value) when value in ["auto", "disabled"], do: value
  defp normalize_truncation(_value), do: "disabled"

  defp normalize_text_field(%{} = text), do: Map.put_new(text, "format", %{"type" => "text"})
  defp normalize_text_field(_text), do: %{"format" => %{"type" => "text"}}

  defp normalize_reasoning(%{} = reasoning) do
    reasoning
    |> Map.put_new("effort", nil)
    |> Map.put_new("summary", nil)
  end

  defp normalize_reasoning(_reasoning), do: %{"effort" => nil, "summary" => nil}

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp normalize_instructions(instructions) when is_binary(instructions), do: instructions
  defp normalize_instructions(instructions) when is_list(instructions), do: instructions
  defp normalize_instructions(_instructions), do: nil

  defp normalize_string_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp normalize_string_list(_values), do: []

  defp normalize_list(values) when is_list(values), do: values
  defp normalize_list(_values), do: []

  defp normalize_prompt_cache_retention(value) when value in ["in_memory", "24h"], do: value
  defp normalize_prompt_cache_retention(_value), do: nil

  defp normalize_conversation(value) when is_binary(value) and value != "",
    do: %{"id" => value}

  defp normalize_conversation(%{"id" => id} = value) when is_binary(id) and id != "",
    do: value

  defp normalize_conversation(_value), do: nil

  defp normalize_response_usage(usage) when is_map(usage) do
    input_tokens =
      integer_value(Map.get(usage, "input_tokens") || Map.get(usage, "prompt_tokens")) || 0

    output_tokens =
      integer_value(Map.get(usage, "output_tokens") || Map.get(usage, "completion_tokens")) || 0

    total_tokens = integer_value(Map.get(usage, "total_tokens")) || input_tokens + output_tokens

    input_details =
      case Map.get(usage, "input_tokens_details") || Map.get(usage, "prompt_tokens_details") do
        details when is_map(details) -> details
        _value -> %{}
      end

    output_details =
      case Map.get(usage, "output_tokens_details") || Map.get(usage, "completion_tokens_details") do
        details when is_map(details) -> details
        _value -> %{}
      end

    %{
      "input_tokens" => input_tokens,
      "output_tokens" => output_tokens,
      "total_tokens" => total_tokens,
      "input_tokens_details" => Map.put_new(input_details, "cached_tokens", 0),
      "output_tokens_details" => Map.put_new(output_details, "reasoning_tokens", 0)
    }
  end

  defp normalize_response_usage(_usage) do
    %{
      "input_tokens" => 0,
      "output_tokens" => 0,
      "total_tokens" => 0,
      "input_tokens_details" => %{"cached_tokens" => 0},
      "output_tokens_details" => %{"reasoning_tokens" => 0}
    }
  end
end
