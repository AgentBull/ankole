defmodule Ankole.Conversations.AttachmentReferences.Preparation do
  @moduledoc false
  use Ash.Resource.Preparation

  @impl true
  def prepare(%{action: %{name: :due_across_tenants}} = query, _opts, _context), do: query

  def prepare(query, opts, _context) do
    owner = Keyword.fetch!(opts, :owner)

    cond do
      owner == :message ->
        if is_nil(query.select), do: Ash.Query.load(query, :attachments), else: query

      is_list(query.select) and :payload not in query.select ->
        query

      true ->
        query
        |> Ash.Query.ensure_selected([:agent_uid, :binding_name, :outbound_key, :payload])
        |> Ash.Query.after_action(fn _query, records ->
          Ankole.Conversations.AttachmentReferences.load(records, owner)
        end)
    end
  end
end
