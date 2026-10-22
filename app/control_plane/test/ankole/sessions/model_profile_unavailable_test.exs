defmodule Ankole.Sessions.ModelProfileUnavailableTest do
  use Ankole.SessionsCase

  alias Ankole.Sessions.Admission

  describe "admission model profile failures" do
    test "an addressed message is completed with a durable configuration notice" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{signal: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "hello", explicit: true}),
                 now: @base_time
               )

      assert input.type == "conversation.message.addressed"

      assert {:ok,
              %{
                status: :model_profile_unavailable,
                profile: "primary",
                profile_error: :model_profile_not_configured,
                posted: %{intents: [%Intent{} = notice]},
                notice_error: nil
              }} =
               Admission.admit(%{agent_uid: agent.uid, session_id: input.session_id}, input,
                 now: DateTime.add(@base_time, 20, :second)
               )

      assert notice.outbound_key == "ai-model-profile-unavailable:#{input.id}"
      assert notice.operation == :reply
      assert notice.reply_to_provider_message_id == input.provider_message_id
      assert notice.payload["text"] =~ "primary"

      assert notice.payload["metadata"] == %{
               "signal_id" => input.id,
               "profile" => "primary",
               "source" => "session_model_profile_unavailable_notice"
             }

      assert %Signal{producer: :kernel, completed_at: %DateTime{}} = Repo.get!(Signal, input.id)
      assert Repo.get!(AgentWorker, agent.uid).state == :absent
    end

    test "an ambient message is completed without emitting configuration spam" do
      now = DateTime.utc_now(:microsecond)
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      binding_fixture(agent.uid, "bot", :may_intervene)

      assert {:ok, %{signal: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "ambient message", provider_time: now}),
                 now: now
               )

      assert input.type == "im.message.may_intervene"

      assert {:ok, :settled} =
               Ankole.Sessions.AmbientTriage.run(
                 %{agent_uid: agent.uid, session_id: input.session_id},
                 input
               )

      assert %Signal{producer: :kernel, completed_at: %DateTime{}} = Repo.get!(Signal, input.id)
      refute Repo.get_by(Intent, source_signal_id: input.id)
      refute Repo.exists?(Ankole.Sessions.SessionWorkspace)
      refute Repo.exists?(Ankole.AIGateway.Schemas.Conversation)
      assert Repo.get!(AgentWorker, agent.uid).state == :absent
    end
  end
end
