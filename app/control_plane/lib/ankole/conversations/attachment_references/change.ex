defmodule Ankole.Conversations.AttachmentReferences.Change do
  @moduledoc false
  use Ash.Resource.Change
  alias Ankole.Conversations.AttachmentReferences

  @impl true
  def change(changeset, opts, _context) do
    owner = Keyword.fetch!(opts, :owner)
    {changeset, attachments} = take_attachments(changeset, owner)

    Ash.Changeset.after_action(changeset, fn changeset, record ->
      with :ok <- persist(changeset, record, owner, attachments),
           {:ok, [loaded]} <- AttachmentReferences.load([record], owner),
           :ok <- release(record, owner) do
        {:ok, loaded}
      end
    end)
  end

  defp take_attachments(changeset, :message),
    do: {changeset, Ash.Changeset.get_argument(changeset, :attachments)}

  defp take_attachments(changeset, :delivery) do
    case Ash.Changeset.fetch_change(changeset, :payload) do
      {:ok, payload} ->
        {Ash.Changeset.force_change_attribute(
           changeset,
           :payload,
           Map.delete(payload, "attachments")
         ), Map.get(payload, "attachments", [])}

      :error ->
        {changeset, nil}
    end
  end

  defp persist(%{action_type: :create}, _record, _owner, []), do: :ok

  defp persist(_changeset, record, owner, attachments) do
    if is_list(attachments) and Ash.Resource.get_metadata(record, :upsert_skipped) != true,
      do: AttachmentReferences.replace_in_tx(record, owner, attachments),
      else: :ok
  end

  defp release(%{status: status} = record, :delivery) when status in [:sent, :expired],
    do: AttachmentReferences.release_delivery_in_tx(record)

  defp release(_record, _owner), do: :ok
end
