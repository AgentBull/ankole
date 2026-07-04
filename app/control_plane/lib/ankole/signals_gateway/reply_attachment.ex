defmodule Ankole.SignalsGateway.ReplyAttachment do
  @moduledoc """
  Shared contract for `reply_attachment` tool outputs and outbound outbox payloads.
  """

  alias Ankole.JSON
  alias Ankole.SignalsGateway.JsonPayload

  @tool_name "reply_attachment"
  @user_files_prefix "/workspace/user-files/"

  @type attachment :: %{
          required(String.t()) => String.t() | non_neg_integer()
        }

  @doc "Extracts canonical reply attachments from durable Responses content items."
  @spec attachments_from_response_items(term()) :: {:ok, [attachment()]} | {:error, term()}
  def attachments_from_response_items(items) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case attachments_from_response_item(item) do
        {:ok, attachments} -> {:cont, {:ok, acc ++ attachments}}
        :ignore -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def attachments_from_response_items(_items), do: {:ok, []}

  @doc "Normalizes one reply attachment into the durable provider-outbox shape."
  @spec normalize_attachment(term()) :: {:ok, attachment()} | {:error, term()}
  def normalize_attachment(attachment) do
    with {:ok, attachment} <- JsonPayload.normalize_map(attachment),
         {:ok, agent_computer_path} <- required_text(attachment, "agent_computer_path"),
         {:ok, user_files_relative_path} <- required_text(attachment, "user_files_relative_path"),
         :ok <- validate_user_files_path(agent_computer_path, user_files_relative_path),
         {:ok, name} <- required_text(attachment, "name"),
         {:ok, size} <- required_non_negative_integer(attachment, "size"),
         {:ok, mime_type} <- optional_text(attachment, "mime_type") do
      {:ok,
       %{
         "agent_computer_path" => agent_computer_path,
         "user_files_relative_path" => user_files_relative_path,
         "name" => name,
         "size" => size
       }
       |> maybe_put("mime_type", mime_type)}
    end
  end

  @doc "Normalizes a list of reply attachments."
  @spec normalize_attachments(term()) :: {:ok, [attachment()]} | {:error, term()}
  def normalize_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(&normalize_attachment/1)
    |> collect_results()
  end

  def normalize_attachments(_attachments), do: {:error, :reply_attachment_attachments_not_list}

  defp attachments_from_response_item(%{"type" => "function_call_output"} = item) do
    item
    |> Map.get("output")
    |> decode_tool_output()
    |> attachments_from_tool_output(item["call_id"])
  end

  defp attachments_from_response_item(_item), do: :ignore

  defp decode_tool_output(output) when is_binary(output) do
    case JSON.decode(output) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  defp decode_tool_output(output) when is_map(output), do: output
  defp decode_tool_output(_output), do: nil

  defp attachments_from_tool_output(
         %{"tool" => @tool_name, "attachments" => attachments},
         call_id
       ) do
    case normalize_attachments(attachments) do
      {:ok, attachments} -> {:ok, attachments}
      {:error, reason} -> {:error, {:invalid_reply_attachment_output, call_id, reason}}
    end
  end

  defp attachments_from_tool_output(%{"tool" => @tool_name}, call_id),
    do:
      {:error, {:invalid_reply_attachment_output, call_id, :reply_attachment_attachments_missing}}

  defp attachments_from_tool_output(_output, _call_id), do: :ignore

  defp required_text(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:reply_attachment_required_text_blank, key}}
          value -> {:ok, value}
        end

      _value ->
        {:error, {:reply_attachment_required_text_missing, key}}
    end
  end

  defp optional_text(map, key) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:reply_attachment_optional_text_blank, key}}
          value -> {:ok, value}
        end

      _value ->
        {:error, {:reply_attachment_optional_text_invalid, key}}
    end
  end

  defp required_non_negative_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, {:reply_attachment_non_negative_integer_required, key}}
    end
  end

  defp validate_user_files_path(agent_computer_path, user_files_relative_path) do
    cond do
      String.contains?(agent_computer_path, <<0>>) or
          String.contains?(user_files_relative_path, <<0>>) ->
        {:error, :reply_attachment_path_contains_null_byte}

      not String.starts_with?(agent_computer_path, @user_files_prefix) ->
        {:error, :reply_attachment_path_not_under_user_files}

      user_files_relative_path != String.trim_leading(user_files_relative_path, "/") ->
        {:error, :reply_attachment_relative_path_absolute}

      Path.split(user_files_relative_path) |> Enum.any?(&(&1 in ["", ".", ".."])) ->
        {:error, :reply_attachment_relative_path_invalid}

      agent_computer_path != @user_files_prefix <> user_files_relative_path ->
        {:error, :reply_attachment_path_mismatch}

      true ->
        :ok
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end
end
