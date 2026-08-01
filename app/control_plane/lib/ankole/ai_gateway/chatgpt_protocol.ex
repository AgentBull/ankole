defmodule Ankole.AIGateway.ChatGPTProtocol do
  @moduledoc false

  @lite_metadata_key "ws_request_header_x_openai_internal_codex_responses_lite"
  @forbidden_fields ~w(generate metadata prompt_cache_retention safety_identifier stream_options)
  @max_input_id_bytes 64

  @spec prepare(map(), map()) ::
          {:ok, %{request: map(), cache_key: String.t(), lite?: boolean()}} | {:error, term()}
  def prepare(request, request_context) when is_map(request) and is_map(request_context) do
    cache_key = Map.fetch!(request_context, "cache_key")
    lite? = lite_request?(request, request_context)

    with :ok <- reject_store(request),
         :ok <- reject_previous_response_id(request),
         {:ok, input} <- normalize_input(Map.get(request, "input")) do
      request =
        request
        |> Map.drop(@forbidden_fields)
        |> Map.put("input", input)
        |> Map.put("store", false)
        |> Map.put("include", include_reasoning(Map.get(request, "include")))
        |> Map.put("instructions", Map.get(request, "instructions") || "")
        |> Map.put("prompt_cache_key", cache_key)
        |> maybe_drop_parallel_tool_calls(lite?)

      {:ok, %{request: request, cache_key: cache_key, lite?: lite?}}
    end
  end

  @spec normalize_non_subscription(map(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_non_subscription(request, request_context)
      when is_map(request) and is_map(request_context) do
    if lite_request?(request, request_context) do
      restore_standard_request(request)
    else
      {:ok, request}
    end
  end

  @spec lite_request?(map(), map()) :: boolean()
  def lite_request?(request, request_context) do
    get_in(request_context, ["headers", "x-openai-internal-codex-responses-lite"]) == "true" or
      get_in(request, ["client_metadata", @lite_metadata_key]) == "true"
  end

  @doc false
  @spec codex_client?(map()) :: boolean()
  def codex_client?(%{"headers" => headers}) when is_map(headers) do
    Map.get(headers, "originator") == "codex_cli_rs" or
      codex_user_agent?(Map.get(headers, "user-agent")) or
      Map.get(headers, "x-openai-internal-codex-responses-lite") == "true"
  end

  def codex_client?(_request_context), do: false

  defp reject_store(%{"store" => true}), do: {:error, :chatgpt_subscription_store_forbidden}
  defp reject_store(_request), do: :ok

  defp reject_previous_response_id(%{"previous_response_id" => value}) when not is_nil(value),
    do: {:error, :chatgpt_subscription_previous_response_id_leaked}

  defp reject_previous_response_id(_request), do: :ok

  defp normalize_input(nil), do: {:ok, []}

  defp normalize_input(input) when is_binary(input) do
    {:ok,
     [
       %{
         "type" => "message",
         "role" => "user",
         "content" => [%{"type" => "input_text", "text" => input}]
       }
     ]}
  end

  defp normalize_input(input) when is_list(input) do
    Enum.reduce_while(input, {:ok, []}, fn item, {:ok, acc} ->
      with :ok <- validate_input_id(item),
           {:ok, item} <- normalize_reasoning_item(item) do
        {:cont, {:ok, [item | acc]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_input(_input), do: {:error, :invalid_chatgpt_subscription_input}

  defp validate_input_id(%{"id" => id})
       when is_binary(id) and byte_size(id) > @max_input_id_bytes,
       do: {:error, {:chatgpt_subscription_input_id_too_long, id}}

  defp validate_input_id(_item), do: :ok

  defp normalize_reasoning_item(%{"type" => "reasoning", "id" => _id} = item) do
    case Map.get(item, "encrypted_content") do
      encrypted when is_binary(encrypted) and encrypted != "" -> {:ok, item}
      _missing -> {:ok, Map.delete(item, "id")}
    end
  end

  defp normalize_reasoning_item(item), do: {:ok, item}

  defp include_reasoning(include) when is_list(include) do
    ["reasoning.encrypted_content" | include]
    |> Enum.uniq()
  end

  defp include_reasoning(_include), do: ["reasoning.encrypted_content"]

  defp maybe_drop_parallel_tool_calls(request, true), do: request

  defp maybe_drop_parallel_tool_calls(request, false) do
    case Map.get(request, "tools") do
      tools when is_list(tools) and tools != [] -> request
      _tools -> Map.delete(request, "parallel_tool_calls")
    end
  end

  defp codex_user_agent?(user_agent) when is_binary(user_agent),
    do: String.starts_with?(user_agent, "codex_cli_rs/")

  defp codex_user_agent?(_user_agent), do: false

  defp restore_standard_request(request) do
    input = Map.get(request, "input", [])

    if is_list(input) do
      {additional_tools, input} =
        Enum.split_with(input, fn
          %{"type" => "additional_tools"} -> true
          _item -> false
        end)

      tools =
        additional_tools
        |> Enum.flat_map(fn item ->
          case Map.get(item, "tools") do
            tools when is_list(tools) -> tools
            _value -> []
          end
        end)
        |> Kernel.++(tools_array(request))

      {instructions, input} = take_developer_instructions(input)

      request =
        request
        |> Map.put("input", input)
        |> Map.put("tools", tools)
        |> Map.put("instructions", instructions || Map.get(request, "instructions") || "")
        |> remove_lite_marker()

      {:ok, request}
    else
      {:error, :invalid_responses_lite_input}
    end
  end

  defp take_developer_instructions([
         %{"type" => "message", "role" => "developer"} = message | rest
       ]) do
    {message_text(message), rest}
  end

  defp take_developer_instructions(input), do: {nil, input}

  defp tools_array(%{"tools" => tools}) when is_list(tools), do: tools
  defp tools_array(_request), do: []

  defp remove_lite_marker(%{"client_metadata" => metadata} = request) when is_map(metadata) do
    metadata = Map.delete(metadata, @lite_metadata_key)

    if map_size(metadata) == 0 do
      Map.delete(request, "client_metadata")
    else
      Map.put(request, "client_metadata", metadata)
    end
  end

  defp remove_lite_marker(request), do: request

  defp message_text(%{"content" => content}) when is_binary(content), do: content

  defp message_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      _part -> []
    end)
    |> Enum.join("\n")
  end

  defp message_text(_message), do: nil
end
