defmodule Ankole.Conversations.Delivery.MessageOwnerTest do
  use Ankole.DataCase, async: true

  alias Ankole.Conversations.Delivery

  import Ankole.PrincipalsFixtures

  @binding_name "bot"
  import Ankole.ExternalConversationsFixtures
  defp room_id, do: external_conversation_id("lark:chat:owner-test")

  test "resolves multiple canonical rows with the same Signal owner" do
    %{principal: agent} = agent_fixture()
    signal_id = Ecto.UUID.generate()
    provider_provider_message_id = "provider-reply"

    insert_intent(agent.uid, %{
      operation: :post,
      source_signal_id: signal_id,
      created_provider_message_id: provider_provider_message_id
    })

    insert_intent(agent.uid, %{
      operation: :edit,
      source_signal_id: signal_id,
      target_provider_message_id: provider_provider_message_id
    })

    assert {:ok, ^signal_id} =
             resolve_owner(agent.uid, provider_provider_message_id)

    assert Delivery.durable_reply_surface_exists_in_tx?(
             agent.uid,
             @binding_name,
             room_id(),
             signal_id
           )

    refute Delivery.durable_reply_surface_exists_in_tx?(
             agent.uid,
             "another-binding",
             room_id(),
             signal_id
           )
  end

  test "ignores a later generic delete and other non-canonical rows" do
    %{principal: agent} = agent_fixture()
    signal_id = Ecto.UUID.generate()
    provider_provider_message_id = "provider-deleted-reply"

    insert_intent(agent.uid, %{
      operation: :reply,
      source_signal_id: signal_id,
      created_provider_message_id: provider_provider_message_id
    })

    insert_intent(agent.uid, %{
      delivery_class: :generic,
      operation: :delete,
      source_signal_id: Ecto.UUID.generate(),
      target_provider_message_id: provider_provider_message_id
    })

    insert_intent(agent.uid, %{
      status: :failed,
      operation: :edit,
      source_signal_id: Ecto.UUID.generate(),
      target_provider_message_id: provider_provider_message_id
    })

    assert {:ok, ^signal_id} =
             resolve_owner(agent.uid, provider_provider_message_id)
  end

  test "rejects one provider message with multiple Signal owners" do
    %{principal: agent} = agent_fixture()
    provider_provider_message_id = "provider-ambiguous-reply"

    insert_intent(agent.uid, %{
      operation: :card,
      source_signal_id: Ecto.UUID.generate(),
      created_provider_message_id: provider_provider_message_id
    })

    insert_intent(agent.uid, %{
      operation: :edit,
      source_signal_id: Ecto.UUID.generate(),
      target_provider_message_id: provider_provider_message_id
    })

    assert {:error, :unresolved_reply_target} =
             resolve_owner(agent.uid, provider_provider_message_id)
  end

  test "an edit degraded to post owns only the newly created provider message" do
    %{principal: agent} = agent_fixture()
    signal_id = Ecto.UUID.generate()

    insert_intent(agent.uid, %{
      operation: :post,
      source_signal_id: signal_id,
      created_provider_message_id: "provider-fallback-post"
    })

    assert {:ok, ^signal_id} =
             resolve_owner(agent.uid, "provider-fallback-post")

    assert {:error, :unresolved_reply_target} =
             resolve_owner(agent.uid, "provider-old-preview")
  end

  test "resolves the same provider message ID independently in each tenant" do
    %{principal: agent} = agent_fixture()
    signal_id = Ecto.UUID.generate()
    provider_message_id = "provider-shared-across-tenants"

    insert_intent(agent.uid, %{
      source_signal_id: signal_id,
      created_provider_message_id: provider_message_id
    })

    other = create_tenant()

    {foreign_agent_uid, foreign_signal_id} =
      Repo.with_tenant(other.id, fn ->
        %{principal: foreign_agent} = agent_fixture()
        foreign_signal_id = Ecto.UUID.generate()

        insert_intent(foreign_agent.uid, %{
          source_signal_id: foreign_signal_id,
          created_provider_message_id: provider_message_id
        })

        {foreign_agent.uid, foreign_signal_id}
      end)

    assert {:ok, ^signal_id} = resolve_owner(agent.uid, provider_message_id)

    assert {:ok, ^foreign_signal_id} =
             Repo.with_tenant(other.id, fn ->
               resolve_owner(foreign_agent_uid, provider_message_id)
             end)
  end

  defp resolve_owner(agent_uid, provider_provider_message_id) do
    Delivery.resolve_durable_reply_signal_in_tx(
      agent_uid,
      @binding_name,
      room_id(),
      provider_provider_message_id
    )
  end

  defp insert_intent(agent_uid, attrs) do
    defaults = %{
      agent_uid: agent_uid,
      binding_name: @binding_name,
      outbound_key: "owner-test-#{System.unique_integer([:positive])}",
      delivery_class: :durable_ai_reply,
      operation: :post,
      status: :sent,
      conversation_id: room_id(),
      payload: %{},
      attempt_count: 1,
      max_attempts: 10,
      last_error: %{},
      recovery_state: %{}
    }

    Ankole.SignalsFixtures.delivery_fixture!(Map.merge(defaults, attrs))
  end
end
