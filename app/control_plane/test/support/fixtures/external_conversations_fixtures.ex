defmodule Ankole.ExternalConversationsFixtures do
  @moduledoc false

  alias Ankole.Conversations.{Conversation, External}
  alias Ankole.Repo

  def external_conversation_fixture(provider_id, attrs \\ %{}) do
    External.get_conversation(Repo, provider_id) ||
      %Conversation{}
      |> Conversation.changeset(
        Map.merge(
          %{
            id: Ankole.Ecto.UUIDv7.autogenerate(),
            kind: :external,
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
      |> Repo.insert!()
  end

  def external_conversation_id(id) when is_binary(id) do
    case byte_size(id) == 36 && Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      _ -> external_conversation_fixture(id).id
    end
  end

  def external_message(provider_conversation_id, provider_message_id) do
    conversation = External.get_conversation(Repo, provider_conversation_id)
    conversation && External.get_message(Repo, conversation.id, provider_message_id)
  end
end
