defmodule Ankole.Conversations.Delivery.Attachment do
  @moduledoc "Validates frozen object references produced by reply_attachment and outbound intents."

  alias Ankole.Ecto.JSONPayload
  alias Ankole.Files
  alias Ankole.Conversations.Delivery.ToolOutput

  @tool_name "reply_attachment"

  @type attachment :: %{
          required(String.t()) => String.t() | non_neg_integer()
        }

  @doc "Authorizes the node and snapshots its current immutable object for a delivery effect."
  def from_node(agent_uid, node_id, opts \\ []) do
    with {:ok, node} <- Files.authorize_node(agent_uid, node_id, "node_view"),
         {:ok, object} <- Files.fetch_object(node.object_id) do
      {:ok,
       %{
         "node_id" => node.id,
         "object_id" => object.id,
         "path" => Files.file_name(node.name),
         "name" => Files.file_name(opts[:name] || node.name),
         "mime_type" => opts[:mime_type] || node.content_type,
         "size" => object.size
       }}
    end
  end

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

  @doc "Normalizes one reply attachment into the durable provider-intent shape."
  @spec normalize_attachment(term()) :: {:ok, attachment()} | {:error, term()}
  def normalize_attachment(attachment) do
    with {:ok, attachment} <- JSONPayload.normalize_map(attachment),
         {:ok, path} <- drive_path(attachment),
         {:ok, object_id} <- identifier(attachment, "object_id"),
         {:ok, node_id} <- identifier(attachment, "node_id"),
         {:ok, raw_name} <- required_text(attachment, "name"),
         {:ok, size} <- required_non_negative_integer(attachment, "size"),
         {:ok, mime_type} <- optional_text(attachment, "mime_type") do
      {:ok,
       %{
         "path" => path,
         "object_id" => object_id,
         "node_id" => node_id,
         "name" => Files.file_name(raw_name),
         "size" => size
       }
       |> Ankole.Attrs.maybe_put("mime_type", mime_type)}
    end
  end

  @doc "Checks the executing Agent can read each node and that it still identifies these bytes."
  @spec verify_in_drive(String.t(), [attachment()]) :: :ok | {:error, term()}
  def verify_in_drive(agent_uid, attachments) when is_binary(agent_uid) do
    Enum.reduce_while(attachments, :ok, fn attachment, :ok ->
      with {:ok, node} <- Files.authorize_node(agent_uid, attachment["node_id"], "node_view"),
           true <- node.object_id == attachment["object_id"] do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, {:reply_attachment_not_in_drive, attachment["path"]}}}
      end
    end)
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
        Ankole.Attrs.required_text(value, {:reply_attachment_required_text_blank, key})

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

  defp drive_path(attachment) do
    with {:ok, path} <- required_text(attachment, "path"),
         {:ok, existing} <- Files.normalize_existing_path(path),
         sanitized = existing |> String.split("/") |> Enum.map_join("/", &Files.file_name/1),
         {:ok, clean} <- Files.normalize_path(sanitized) do
      {:ok, clean}
    else
      {:error, {:reply_attachment_required_text_blank, _} = reason} -> {:error, reason}
      {:error, {:reply_attachment_required_text_missing, _} = reason} -> {:error, reason}
      _ -> {:error, :reply_attachment_path_invalid}
    end
  end

  defp identifier(attachment, key) do
    case Ecto.UUID.cast(attachment[key]) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:reply_attachment_identifier_invalid, key}}
    end
  end
end
