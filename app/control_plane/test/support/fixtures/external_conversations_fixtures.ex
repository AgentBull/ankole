defmodule Ankole.ExternalConversationsFixtures do
  @moduledoc false

  alias Ankole.Conversations.{Conversation, External}
  alias Ankole.Repo

  def external_conversation_fixture(provider_id, attrs \\ %{}) do
    External.get_conversation(provider_id) ||
      create_external_conversation!(
        Map.merge(
          %{
            id: Ankole.Ecto.UUIDv7.autogenerate(),
            provider_conversation_id: provider_id,
            title: provider_id,
            external_kind: :im_group,
            reply_mode: :entry,
            first_seen_at: DateTime.utc_now(:microsecond),
            last_seen_at: DateTime.utc_now(:microsecond),
            last_activity_at: DateTime.utc_now(:microsecond)
          },
          attrs
        )
      )
  end

  def create_external_conversation!(attrs) do
    {:ok, conversation} =
      Repo.transact(fn ->
        Ankole.Ash.create(Conversation, :create_external, attrs)
      end)

    conversation
  end

  def external_conversation_id(id) when is_binary(id) do
    case byte_size(id) == 36 && Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      _ -> external_conversation_fixture(id).id
    end
  end

  def external_message(provider_conversation_id, provider_message_id) do
    conversation = External.get_conversation(provider_conversation_id)
    conversation && External.get_message(conversation.id, provider_message_id)
  end
end
