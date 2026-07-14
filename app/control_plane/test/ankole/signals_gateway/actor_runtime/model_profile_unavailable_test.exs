defmodule Ankole.SignalsGateway.ActorRuntime.ModelProfileUnavailableTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  describe "turn start model profile failures" do
    test "an addressed message is completed with a durable configuration notice" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      assert {:ok, _worker} = admit_worker(unique_route())

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "hello", explicit: true}),
                 now: @base_time
               )

      assert input.type == "im.message.addressed"

      assert {:ok,
              %{
                status: :model_profile_unavailable,
                profile: "primary",
                profile_error: :model_profile_not_configured,
                notice_outbox: %OutboxEntry{} = notice,
                notice_error: nil
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 20, :second))

      assert notice.outbound_key == "ai-model-profile-unavailable:#{input.id}"
      assert notice.operation == :reply
      assert notice.reply_to_source_entry_id == input.source_entry_id
      assert notice.payload["text"] =~ "primary"

      assert notice.payload["metadata"] == %{
               "actor_event_id" => input.id,
               "profile" => "primary",
               "source" => "actor_model_profile_unavailable_notice"
             }

      assert %ActorEvent{completed_at: %DateTime{}} = Repo.get!(ActorEvent, input.id)
      refute Repo.get_by(ActorEventDelivery, actor_event_id: input.id)
    end

    test "an ambient message is completed without emitting configuration spam" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      binding_fixture(agent.uid, "bot", :may_intervene)
      assert {:ok, _worker} = admit_worker(unique_route())

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "ambient message"}),
                 now: @base_time
               )

      assert input.type == "im.message.may_intervene"

      assert {:ok,
              %{
                status: :model_profile_unavailable,
                profile: "light",
                profile_error: :model_profile_not_configured,
                notice_outbox: nil,
                notice_error: nil
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 20, :second))

      assert %ActorEvent{completed_at: %DateTime{}} = Repo.get!(ActorEvent, input.id)
      refute Repo.get_by(OutboxEntry, source_actor_event_id: input.id)
      refute Repo.get_by(ActorEventDelivery, actor_event_id: input.id)
    end
  end
end
