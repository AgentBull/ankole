defmodule Ankole.SignalsGateway.ReplyAttachment do
  @moduledoc """
  Shared contract for `reply_attachment` tool outputs and outbound outbox payloads.
  """

  alias Ankole.Ecto.JSONPayload
  alias Ankole.SignalsGateway.ToolOutput

  @tool_name "reply_attachment"
  @user_files_path ~r/\A\/agents\/[a-z0-9][a-z0-9._-]{0,95}\/user-files\/(.+)\z/
  @path_keys [
    "agent_computer_path",
    :agent_computer_path,
    "user_files_relative_path",
    :user_files_relative_path
  ]

  @type attachment :: %{
          required(String.t()) => String.t() | non_neg_integer()
        }

  @doc "Extracts canonical reply attachments from durable Responses content items."
  @spec attachments_from_response_items(term()) :: {:ok, [attachment()]} | {:error, term()}
  def attachments_from_response_items(items) when is_list(items) do
    reply_attachment_call_ids = reply_attachment_call_ids(items)

    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case attachments_from_response_item(item, reply_attachment_call_ids) do
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
    with :ok <- validate_raw_path_bytes(attachment),
         {:ok, attachment} <- JSONPayload.normalize_map(attachment),
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
       |> Ankole.Attrs.maybe_put("mime_type", mime_type)}
    end
  end

  @doc "Normalizes a list of reply attachments."
  @spec normalize_attachments(term()) :: {:ok, [attachment()]} | {:error, term()}
  def normalize_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(&normalize_attachment/1)
    |> Ankole.Attrs.collect_results()
  end

  def normalize_attachments(_attachments), do: {:error, :reply_attachment_attachments_not_list}

  defp reply_attachment_call_ids(items) do
    items
    |> Enum.reduce(MapSet.new(), fn
      %{"type" => "function_call", "name" => @tool_name, "call_id" => call_id}, acc
      when is_binary(call_id) ->
        MapSet.put(acc, call_id)

      _item, acc ->
        acc
    end)
  end

  defp attachments_from_response_item(
         %{"type" => "function_call_output", "call_id" => call_id} = item,
         reply_attachment_call_ids
       )
       when is_binary(call_id) do
    if MapSet.member?(reply_attachment_call_ids, call_id) do
      attachments_from_reply_attachment_output(item)
    else
      :ignore
    end
  end

  defp attachments_from_response_item(_item, _reply_attachment_call_ids), do: :ignore

  defp attachments_from_reply_attachment_output(item) do
    item
    |> Map.get("output")
    |> ToolOutput.decode()
    |> attachments_from_tool_output(item["call_id"])
  end

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

  defp validate_raw_path_bytes(attachment) when is_map(attachment) do
    if Enum.any?(@path_keys, fn key ->
         case Map.get(attachment, key) do
           value when is_binary(value) -> :binary.match(value, <<0>>) != :nomatch
           _value -> false
         end
       end) do
      {:error, :reply_attachment_path_contains_null_byte}
    else
      :ok
    end
  end

  defp validate_raw_path_bytes(_attachment), do: :ok

  defp validate_user_files_path(agent_computer_path, user_files_relative_path) do
    cond do
      String.contains?(agent_computer_path, <<0>>) or
          String.contains?(user_files_relative_path, <<0>>) ->
        {:error, :reply_attachment_path_contains_null_byte}

      user_files_relative_path != String.trim_leading(user_files_relative_path, "/") ->
        {:error, :reply_attachment_relative_path_absolute}

      Path.split(user_files_relative_path) |> Enum.any?(&(&1 in ["", ".", ".."])) ->
        {:error, :reply_attachment_relative_path_invalid}

      true ->
        case Regex.run(@user_files_path, agent_computer_path, capture: :all_but_first) do
          [^user_files_relative_path] -> :ok
          [_other_path] -> {:error, :reply_attachment_path_mismatch}
          nil -> {:error, :reply_attachment_path_not_under_user_files}
        end
    end
  end
end
