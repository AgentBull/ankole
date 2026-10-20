defmodule Ankole.Conversations.Delivery.Attachment do
  @moduledoc """
  Shared contract for `reply_attachment` tool outputs and outbound intent payloads.

  A reply attachment names one file in the Agent's drive: its drive `path` and
  the SHA-256 digest of its content as `blob_ref`. The control plane keeps the
  original drive path. `verify_in_drive/2` checks that the Agent's drive
  still names that content at that path before the intent commits.
  """

  import Ecto.Query

  alias Ankole.Ecto.JSONPayload
  alias Ankole.Files
  alias Ankole.Files.Schemas.DriveFile
  alias Ankole.Conversations.Delivery.ToolOutput

  @tool_name "reply_attachment"

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

  @doc "Normalizes one reply attachment into the durable provider-intent shape."
  @spec normalize_attachment(term()) :: {:ok, attachment()} | {:error, term()}
  def normalize_attachment(attachment) do
    with {:ok, attachment} <- JSONPayload.normalize_map(attachment),
         {:ok, path} <- drive_path(attachment),
         {:ok, blob_ref} <- blob_ref(attachment),
         {:ok, name} <- required_text(attachment, "name"),
         {:ok, size} <- required_non_negative_integer(attachment, "size"),
         {:ok, mime_type} <- optional_text(attachment, "mime_type") do
      {:ok,
       %{"path" => path, "blob_ref" => blob_ref, "name" => name, "size" => size}
       |> Ankole.Attrs.maybe_put("mime_type", mime_type)}
    end
  end

  @doc """
  Checks that the Agent's drive names each attachment's content at its path.

  Runs inside the caller's transaction, so the check and the intent commit see
  the same drive.
  """
  @spec verify_in_drive(String.t(), [attachment()]) :: :ok | {:error, term()}
  def verify_in_drive(agent_uid, attachments) when is_binary(agent_uid) do
    Enum.reduce_while(attachments, :ok, fn %{"path" => path, "blob_ref" => blob_ref}, :ok ->
      digest = Base.decode16!(blob_ref, case: :lower)

      exists? =
        Ankole.Repo.exists?(
          from(file in DriveFile,
            where: file.agent_uid == ^agent_uid and file.path == ^path and file.sha256 == ^digest
          )
        )

      if exists?,
        do: {:cont, :ok},
        else: {:halt, {:error, {:reply_attachment_not_in_drive, path}}}
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
    with {:ok, path} <- required_text(attachment, "path") do
      case Files.normalize_path(path) do
        {:ok, path} -> {:ok, path}
        {:error, _reason} -> {:error, :reply_attachment_path_invalid}
      end
    end
  end

  defp blob_ref(attachment) do
    case Map.get(attachment, "blob_ref") do
      <<_::binary-size(64)>> = value ->
        if value =~ ~r/\A[0-9a-f]{64}\z/,
          do: {:ok, value},
          else: {:error, :reply_attachment_blob_ref_invalid}

      _value ->
        {:error, :reply_attachment_blob_ref_invalid}
    end
  end
end
