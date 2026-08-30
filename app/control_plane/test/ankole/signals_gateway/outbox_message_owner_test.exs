defmodule Ankole.SignalsGatewayOutboxMessageOwnerTest do
  use Ankole.DataCase, async: true

  alias Ankole.Repo
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.OutboxEntry

  import Ankole.PrincipalsFixtures

  @binding_name "bot"
  @signal_channel_id "lark:chat:owner-test"

  test "resolves multiple canonical rows with the same ActorEvent owner" do
    %{principal: agent} = agent_fixture()
    actor_event_id = Ecto.UUID.generate()
    provider_source_entry_id = "provider-reply"

    insert_outbox(agent.uid, %{
      operation: :post,
      source_actor_event_id: actor_event_id,
      created_source_entry_id: provider_source_entry_id
    })

    insert_outbox(agent.uid, %{
      operation: :edit,
      source_actor_event_id: actor_event_id,
      target_source_entry_id: provider_source_entry_id
    })

    assert {:ok, ^actor_event_id} =
             resolve_owner(agent.uid, provider_source_entry_id)

    assert Outbox.durable_reply_surface_exists_in_tx?(
             Repo,
             agent.uid,
             @binding_name,
             @signal_channel_id,
             actor_event_id
           )

    refute Outbox.durable_reply_surface_exists_in_tx?(
             Repo,
             agent.uid,
             "another-binding",
             @signal_channel_id,
             actor_event_id
           )
  end

  test "ignores a later generic delete and other non-canonical rows" do
    %{principal: agent} = agent_fixture()
    actor_event_id = Ecto.UUID.generate()
    provider_source_entry_id = "provider-deleted-reply"

    insert_outbox(agent.uid, %{
      operation: :reply,
      source_actor_event_id: actor_event_id,
      created_source_entry_id: provider_source_entry_id
    })

    insert_outbox(agent.uid, %{
      delivery_class: :generic,
      operation: :delete,
      source_actor_event_id: Ecto.UUID.generate(),
      target_source_entry_id: provider_source_entry_id
    })

    insert_outbox(agent.uid, %{
      status: :failed,
      operation: :edit,
      source_actor_event_id: Ecto.UUID.generate(),
      target_source_entry_id: provider_source_entry_id
    })

    assert {:ok, ^actor_event_id} =
             resolve_owner(agent.uid, provider_source_entry_id)
  end

  test "rejects one provider message with multiple ActorEvent owners" do
    %{principal: agent} = agent_fixture()
    provider_source_entry_id = "provider-ambiguous-reply"

    insert_outbox(agent.uid, %{
      operation: :card,
      source_actor_event_id: Ecto.UUID.generate(),
      created_source_entry_id: provider_source_entry_id
    })

    insert_outbox(agent.uid, %{
      operation: :edit,
      source_actor_event_id: Ecto.UUID.generate(),
      target_source_entry_id: provider_source_entry_id
    })

    assert {:error, :unresolved_reply_target} =
             resolve_owner(agent.uid, provider_source_entry_id)
  end

  test "an edit degraded to post owns only the newly created provider message" do
    %{principal: agent} = agent_fixture()
    actor_event_id = Ecto.UUID.generate()

    insert_outbox(agent.uid, %{
      operation: :post,
      source_actor_event_id: actor_event_id,
      created_source_entry_id: "provider-fallback-post"
    })

    assert {:ok, ^actor_event_id} =
             resolve_owner(agent.uid, "provider-fallback-post")

    assert {:error, :unresolved_reply_target} =
             resolve_owner(agent.uid, "provider-old-preview")
  end

  defp resolve_owner(agent_uid, provider_source_entry_id) do
    Outbox.resolve_durable_reply_actor_event_in_tx(
      Repo,
      agent_uid,
      @binding_name,
      @signal_channel_id,
      provider_source_entry_id
    )
  end

  defp insert_outbox(agent_uid, attrs) do
    defaults = %{
      agent_uid: agent_uid,
      binding_name: @binding_name,
      outbound_key: "owner-test-#{System.unique_integer([:positive])}",
      delivery_class: :durable_ai_reply,
      operation: :post,
      status: :succeeded,
      signal_channel_id: @signal_channel_id,
      payload: %{},
      attempt_count: 1,
      max_attempts: 10,
      last_error: %{},
      recovery_state: %{}
    }

    %OutboxEntry{}
    |> OutboxEntry.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
