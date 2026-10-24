defmodule Ankole.Conversations.TargetTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Conversations.External
  alias Ankole.Conversations.Target, as: StatementTarget

  setup do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})

    {:ok, native} =
      Ankole.ConversationsFixtures.create(human.uid, %{
        conversation_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        agent_uid: agent.uid,
        text: "Initial question"
      })

    {:ok, external} =
      Repo.transact(fn ->
        External.observe_conversation_in_tx(
          %{agent_uid: agent.uid},
          %{
            provider_conversation_id: "lark:target-rules",
            title: "External room",
            external_kind: :im_group,
            reply_mode: :channel
          },
          DateTime.utc_now(:microsecond)
        )
      end)

    %{human: human, agent: agent, native: native.conversation, external: external}
  end

  test "native delivery requires participation and excludes provider route fields", context do
    assert {:ok, target} =
             StatementTarget.for_delivery_in_tx(context.agent.uid, %{
               conversation_id: context.native.id
             })

    assert target.kind == :native

    for field <- [:binding_name, :provider_thread_id] do
      assert {:error, :cron_delivery_route_required} =
               StatementTarget.for_delivery_in_tx(
                 context.agent.uid,
                 Map.put(%{conversation_id: context.native.id}, field, "provider-value")
               )
    end

    assert {:error, :conversation_not_found} =
             StatementTarget.for_delivery_in_tx(
               context.human.uid,
               %{conversation_id: context.native.id}
             )

    %{principal: other} = agent_fixture()

    assert {:error, :conversation_not_found} =
             StatementTarget.for_delivery_in_tx(
               other.uid,
               %{conversation_id: context.native.id}
             )
  end

  test "a binding without a conversation is not a statement destination" do
    for id <- [nil, Ecto.UUID.generate()] do
      assert {:error, :reply_route_unavailable} =
               StatementTarget.for_reply(%Ankole.Signals.Signal{
                 conversation_id: id,
                 session_id: "workflow-owner",
                 reply_binding_name: "bot"
               })
    end
  end

  test "external delivery requires a binding and retains thread and primary", context do
    assert {:error, :cron_delivery_route_required} =
             StatementTarget.for_delivery_in_tx(
               context.agent.uid,
               %{"conversation_id" => context.external.id}
             )

    assert {:ok, target} =
             StatementTarget.for_delivery_in_tx(context.agent.uid, %{
               "conversation_id" => context.external.id,
               "binding_name" => "bot",
               "provider_thread_id" => "thread",
               "primary" => false
             })

    assert target.kind == :external
    assert target.provider_thread_id == "thread"
    refute target.primary

    assert {:error, :conversation_not_found} =
             StatementTarget.for_delivery_in_tx(
               context.agent.uid,
               %{conversation_id: Ecto.UUID.generate(), binding_name: "bot"}
             )
  end
end
