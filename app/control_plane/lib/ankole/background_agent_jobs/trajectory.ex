defmodule Ankole.BackgroundAgentJobs.Trajectory do
  @moduledoc false

  @metadata_keys ~w(redacted content_truncated)

  @spec empty_header() :: map()
  def empty_header, do: %{"format" => "ankole_chatml", "version" => 1}

  @spec valid_header?(term()) :: boolean()
  def valid_header?(%{"format" => "ankole_chatml", "version" => 1} = value) do
    Map.keys(value) -- ~w(format version metadata) == [] and
      valid_metadata?(Map.get(value, "metadata"))
  end

  def valid_header?(_value), do: false

  @spec valid_group_content?(term()) :: boolean()
  def valid_group_content?(%{"messages" => messages} = content) when is_list(messages) do
    Map.keys(content) == ["messages"] and messages != [] and
      Enum.all?(messages, &valid_message?/1)
  end

  def valid_group_content?(_content), do: false

  defp valid_message?(%{"role" => role} = message) when role in ~w(user developer) do
    valid_optional_id?(message) and valid_optional_metadata?(message) and
      valid_user_content?(message["content"])
  end

  defp valid_message?(%{"role" => "assistant", "content" => content} = message)
       when is_binary(content) do
    valid_optional_id?(message) and valid_optional_metadata?(message) and
      valid_tool_calls?(Map.get(message, "tool_calls"))
  end

  defp valid_message?(
         %{
           "role" => "tool",
           "tool_call_id" => tool_call_id,
           "name" => name,
           "content" => content
         } = message
       )
       when is_binary(tool_call_id) and is_binary(name) and is_binary(content) do
    valid_optional_id?(message) and valid_optional_metadata?(message)
  end

  defp valid_message?(_message), do: false

  defp valid_optional_id?(message),
    do: not Map.has_key?(message, "id") or is_binary(message["id"])

  defp valid_optional_metadata?(message),
    do: not Map.has_key?(message, "metadata") or is_map(message["metadata"])

  defp valid_user_content?(content) when is_binary(content), do: true

  defp valid_user_content?(content) when is_list(content) do
    Enum.all?(content, fn
      %{"type" => type} when is_binary(type) -> true
      _part -> false
    end)
  end

  defp valid_user_content?(_content), do: false

  defp valid_tool_calls?(nil), do: true

  defp valid_tool_calls?(tool_calls) when is_list(tool_calls) do
    Enum.all?(tool_calls, fn
      %{
        "id" => id,
        "type" => "function",
        "function" => %{"name" => name, "arguments" => arguments}
      }
      when is_binary(id) and is_binary(name) and is_binary(arguments) ->
        true

      _tool_call ->
        false
    end)
  end

  defp valid_tool_calls?(_tool_calls), do: false

  defp valid_metadata?(nil), do: true

  defp valid_metadata?(metadata) when is_map(metadata) do
    Map.keys(metadata) -- @metadata_keys == [] and
      optional_boolean?(metadata, "redacted") and
      optional_boolean?(metadata, "content_truncated")
  end

  defp valid_metadata?(_metadata), do: false

  defp optional_boolean?(map, key),
    do: not Map.has_key?(map, key) or is_boolean(map[key])
end
