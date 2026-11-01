defmodule Ankole.Conversations.AttachmentReferences do
  @moduledoc "Persists attachment references and projects their public descriptors."
  require Ash.Query
  alias Ankole.Conversations.{MessageAttachment, DeliveryAttachment}
  alias Ankole.{Files, Repo}

  @delivery_keys [:agent_uid, :binding_name, :outbound_key]

  def load([], _owner), do: {:ok, []}

  def load(records, :message) do
    ids = Enum.map(records, & &1.id)

    rows =
      MessageAttachment
      |> Ash.Query.filter(message_id in ^ids)
      |> Ash.Query.sort(position: :asc)
      |> Ankole.Ash.read!()
      |> Enum.group_by(& &1.message_id, &descriptor/1)

    {:ok, Enum.map(records, &%{&1 | attachments: Map.get(rows, &1.id, [])})}
  end

  def load(records, :delivery) do
    filter = %{or: Enum.map(records, &Map.take(&1, @delivery_keys))}

    rows =
      DeliveryAttachment
      |> Ash.Query.filter(^filter)
      |> Ash.Query.sort(position: :asc)
      |> Ankole.Ash.read!()
      |> Enum.group_by(&delivery_key/1, &descriptor/1)

    {:ok,
     Enum.map(records, fn record ->
       attachments = Map.get(rows, delivery_key(record), [])
       payload = record.payload || %{}

       %{
         record
         | payload:
             if(attachments == [],
               do: payload,
               else: Map.put(payload, "attachments", attachments)
             )
       }
     end)}
  end

  def replace_in_tx(record, :message, attachments) do
    query = Ash.Query.filter(MessageAttachment, message_id == ^record.id)
    replace(query, MessageAttachment, %{message_id: record.id}, attachments)
  end

  def replace_in_tx(record, :delivery, attachments) do
    replace(
      delivery_query(record),
      DeliveryAttachment,
      Map.take(record, @delivery_keys),
      attachments
    )
  end

  def release_delivery_in_tx(record) do
    with :ok <- Repo.require_transaction(),
         {:ok, _} <- Ankole.Ash.update_where(delivery_query(record), :release),
         do: :ok
  end

  defp replace(query, resource, owner, attachments) do
    with :ok <- Repo.require_transaction(),
         {:ok, _} <- Ankole.Ash.destroy_where(query, :remove) do
      attachments
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {attachment, position}, :ok ->
        with :ok <- complete_object(attachment),
             attrs =
               Map.merge(owner, %{
                 position: position,
                 object_id: attachment["object_id"],
                 node_id: attachment["node_id"],
                 metadata: Map.drop(attachment, ["object_id", "node_id"])
               }),
             {:ok, _} <- Ankole.Ash.create(resource, :record, attrs) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp complete_object(%{"object_id" => object_id} = attachment) when is_binary(object_id) do
    stored =
      if is_binary(attachment["sha256"]),
        do: %{object_id: object_id, sha256: attachment["sha256"], size: attachment["size"]},
        else: object_id

    case Files.complete_object_in_tx(stored) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp complete_object(_attachment), do: :ok

  defp descriptor(row) do
    row.metadata
    |> Ankole.Attrs.maybe_put("object_id", row.object_id)
    |> Ankole.Attrs.maybe_put("node_id", row.node_id)
  end

  defp delivery_key(record), do: Map.take(record, @delivery_keys)

  defp delivery_query(record),
    do: Ash.Query.filter(DeliveryAttachment, ^delivery_key(record))
end
