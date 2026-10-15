defmodule Ankole.Conversations.Assertions do
  @moduledoc false
  import Ecto.Query
  alias Ankole.Conversations.{Conversation, ExternalMessageRef, Message}
  alias Ankole.Repo

  def conversation_id!(provider_id) do
    Repo.get_by!(Conversation, provider_conversation_id: provider_id).id
  end

  # Read the public statement and its provider facts together for assertions.
  # The id and seq always come from Message, never from a derived provider key.
  def message_snapshot(attrs) do
    id = Keyword.get(attrs, :conversation_id)

    attrs =
      if id && Ecto.UUID.cast(id) == :error,
        do: Keyword.put(attrs, :conversation_id, conversation_id!(id)),
        else: attrs

    query =
      from r in ExternalMessageRef,
        join: m in Message,
        on: m.id == r.message_id and m.tenant_id == r.tenant_id,
        select: {m, r},
        limit: 1

    query =
      Enum.reduce(attrs, query, fn {key, value}, query ->
        where(query, [r, _m], field(r, ^key) == ^value)
      end)

    case Repo.one(query) do
      nil -> nil
      {m, r} -> observation_snapshot(%{message: m, external_ref: r})
    end
  end

  def observation_snapshot(%{message: m, external_ref: r}),
    do: Map.merge(Map.from_struct(r), Map.from_struct(m))

  def message_snapshot!(attrs),
    do:
      message_snapshot(attrs) ||
        raise("expected a canonical Message with its external reference: #{inspect(attrs)}")
end
