defmodule Ankole.Conversations.Attachments.Native do
  @moduledoc "Owns verified Human uploads before their Message commits."

  require Ash.Query
  alias Ankole.Conversations.{Attachments, Message}
  alias Ankole.{Files, Principals, Repo, WorkerFiles}

  @salt "native-conversation-attachment"
  @max_age 86_400

  def upload(uid, file_id, name, {:file, path} = content, content_type) do
    with {:ok, %{type: :human, status: :active}} <- Principals.get_principal(uid),
         {:ok, file_id} <- Ecto.UUID.cast(file_id),
         {:ok, stat} <- File.stat(path),
         true <- stat.size <= WorkerFiles.max_transfer_bytes(),
         {:ok, attachment} <-
           Attachments.store_attachment(
             %{"upload_id" => file_id, "name" => Files.file_name(name)},
             content,
             content_type: content_type
           ) do
      attachment =
        Map.put(attachment, "resource_type", resource_type(Attachments.content_type(attachment)))

      receipt =
        Phoenix.Token.sign(AnkoleWeb.Endpoint, @salt, %{
          tenant_id: Repo.tenant_id!(),
          human_uid: uid,
          attachment: attachment
        })

      {:ok,
       %{
         receipt: receipt,
         name: attachment["name"],
         size: attachment["size"],
         content_type: Attachments.content_type(attachment)
       }}
    else
      false -> {:error, :file_too_large}
      _ -> {:error, :invalid_attachment}
    end
  end

  @doc "Verifies upload ownership; an accepted Message can retry an expired receipt."
  def resolve(uid, receipts, existing \\ [])
  def resolve(_uid, nil, _existing), do: {:ok, []}

  def resolve(uid, receipts, existing) when is_list(receipts) do
    Enum.reduce_while(receipts, {:ok, []}, fn receipt, {:ok, attachments} ->
      case verify(uid, receipt, existing) do
        {:ok, attachment} -> {:cont, {:ok, [attachment | attachments]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, attachments} ->
        attachments = Enum.reverse(attachments)

        if Enum.uniq_by(attachments, & &1["upload_id"]) == attachments,
          do: {:ok, attachments},
          else: {:error, :invalid_attachment}

      error ->
        error
    end
  end

  def resolve(_uid, _receipts, _existing), do: {:error, :invalid_attachment}

  defp verify(uid, receipt, existing) when is_binary(receipt) do
    tenant_id = Repo.tenant_id!()

    with {:ok, %{tenant_id: ^tenant_id, human_uid: ^uid, attachment: attachment}} <-
           Phoenix.Token.verify(AnkoleWeb.Endpoint, @salt, receipt, max_age: :infinity) do
      kept = Enum.find(existing, &same_upload?(&1, attachment))

      case Phoenix.Token.verify(AnkoleWeb.Endpoint, @salt, receipt, max_age: @max_age) do
        {:ok, _} -> {:ok, kept || attachment}
        {:error, :expired} when is_map(kept) -> {:ok, kept}
        _ -> {:error, :attachment_expired}
      end
    else
      _ -> {:error, :invalid_attachment}
    end
  end

  defp verify(_uid, _receipt, _existing), do: {:error, :invalid_attachment}

  defp same_upload?(left, right),
    do:
      Map.take(left, ~w(upload_id blob_ref name size content_type resource_type)) ==
        Map.take(right, ~w(upload_id blob_ref name size content_type resource_type))

  @doc "Reads frozen bytes through the current Human's Conversation membership."
  def read_to_file(uid, conversation_id, message_id, path, local_path) do
    with {:ok, message_id} <- Ecto.UUID.cast(message_id),
         {:ok, _} <- Ankole.Conversations.get(uid, conversation_id),
         %Message{attachments: attachments} <-
           Message
           |> Ash.Query.filter(id == ^message_id and conversation_id == ^conversation_id)
           |> Ankole.Ash.read_one!(),
         %{"blob_ref" => digest} = attachment <- Enum.find(attachments, &(&1["path"] == path)),
         :ok <- Files.read_content_to_file(digest, local_path) do
      {:ok, attachment}
    else
      _ -> {:error, :not_found}
    end
  end

  defp resource_type(type)
       when type in ~w(image/png image/jpeg image/gif image/webp image/avif image/bmp),
       do: "image"

  defp resource_type(_type), do: "file"
end
