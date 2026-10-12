defmodule Ankole.Conversations.LLMCommandTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.SignalsGateway.ActorRuntimeCase
  alias Ankole.Conversations.{Admission, Commands, Run}
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  test "/llm returns usage without a Worker when no custom profile exists" do
    {agent, input} = input("/llm")
    assert input.type == "command.llm_help"

    assert {:ok, %{status: :command_consumed, feedback: text}} =
             Commands.process(key(input), input)

    assert text =~ "Usage: /llm <custom-model-profile> [message]"
    assert text =~ "No custom model profiles are configured"
    assert Repo.reload!(input).completed_at
    assert Repo.get!(AgentWorker, agent.uid).state == "absent"
  end

  test "help lists custom profiles without changing the current run" do
    {agent, active} = input("Active request")
    configure_profile(agent.uid, "moonshotai/kimi-k2.7-code", "high")
    assert {:ok, run} = Admission.admit(key(active), active)
    help = command(agent.uid, "/llm")
    assert {:ok, %{feedback: text}} = Commands.process(key(help), help)
    assert text =~ "kimi:"
    assert text =~ "Long-context coding"
    refute Repo.reload!(active).completed_at
    assert run.spec.model_ref["profile"] == "primary"
  end

  test "a custom profile applies to one turn and the next request uses primary" do
    {agent, _} = input("Initial request")
    configure_profile(agent.uid, "moonshotai/kimi-k2.7-code", "xhigh")
    custom = command(agent.uid, "/llm kimi")
    assert custom.type == "command.llm"
    assert {:ok, run} = Admission.admit(key(custom), custom)
    assert run.spec.model_ref["profile"] == "kimi"
    assert run.spec.model_ref["model"] == "moonshotai/kimi-k2.7-code"
    assert run.spec.model_ref["provider_options"] == %{"reasoningEffort" => "xhigh"}
    finish(run)
    normal = command(agent.uid, "Normal request")
    assert {:ok, next} = Admission.admit(key(normal), normal)
    assert next.spec.model_ref["profile"] == "primary"
  end

  test "a profile command queues as a new turn instead of steering an active run" do
    {agent, active} = input("Active request")
    configure_profile(agent.uid, "moonshotai/kimi-k2.7-code", "high")
    assert {:ok, run} = Admission.admit(key(active), active)
    queued = command(agent.uid, "/llm kimi Queued request")
    refute Commands.injectable?(queued)

    assert Ankole.SignalsGateway.Actors.next_ready_event(agent.uid, active.session_id).id ==
             active.id

    refute Repo.reload!(queued).last_attempt_at
    finish(run)

    assert Ankole.SignalsGateway.Actors.next_ready_event(agent.uid, active.session_id).id ==
             queued.id

    assert {:ok, next} = Admission.admit(key(queued), queued)
    assert next.spec.model_ref["profile"] == "kimi"
  end

  test "an unknown profile produces a durable notice without a model or Worker" do
    {agent, input} = input("/llm missing Run this")

    assert {:ok, %{status: :model_profile_unavailable, notice_outbox: notice}} =
             Admission.admit(key(input), input)

    assert notice.fallback_visible_text =~ "missing"
    assert Repo.reload!(input).completed_at
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.get!(AgentWorker, agent.uid).state == "absent"
  end

  test "retry retains the logical profile and resolves its current model" do
    {agent, _} = input("Initial request")
    configure_profile(agent.uid, "moonshotai/kimi-k2.7-code", "high")
    original = command(agent.uid, "/llm kimi First run")
    assert {:ok, run} = Admission.admit(key(original), original)
    finish(run)

    outbox =
      Repo.get_by!(OutboxEntry,
        source_actor_event_id: original.id,
        delivery_class: :durable_ai_reply
      )

    assert {:ok, %{status: :succeeded}} =
             SignalsGateway.dispatch_outbox(
               outbox.agent_uid,
               outbox.binding_name,
               outbox.outbound_key,
               outbox_adapter([:post_entry, :reply_entry], fn _ ->
                 {:ok, %{created_source_entry_id: "provider-llm-reply"}}
               end)
             )

    configure_profile(agent.uid, "moonshotai/kimi-k3-code", "max")
    retry = command(agent.uid, "/retry actor-event::#{original.id}")
    assert {:ok, %ActorEvent{} = retried} = Commands.process(key(retry), retry)
    assert retried.type == "command.llm"
    assert get_in(retried.payload, ["data", "command", "modelProfile"]) == "kimi"
    assert get_in(retried.payload, ["data", "entry", "retry_of_actor_event_id"]) == original.id
    assert {:ok, next} = Admission.admit(key(retried), retried)
    assert next.spec.model_ref["profile"] == "kimi"
    assert next.spec.model_ref["model"] == "moonshotai/kimi-k3-code"
    assert next.spec.model_ref["provider_options"] == %{"reasoningEffort" => "max"}
  end

  defp input(text) do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
    {agent, command(agent.uid, text)}
  end

  defp command(agent_uid, text) do
    suffix = Ecto.UUID.generate()

    {:ok, %{actor_event: event}} =
      emit_entry(
        agent_uid,
        "bot",
        group_entry(%{
          text: text,
          explicit: true,
          source_entry_id: suffix,
          source_event_id: suffix
        }),
        now: @base_time
      )

    event
  end

  defp key(event), do: %{agent_uid: event.agent_uid, session_id: event.session_id}

  defp finish(run) do
    {:ok, response} =
      start_response_run(%{
        subject_uid: run.agent_uid,
        conversation_id: run.conversation.id,
        metadata: %{"request_metadata" => Run.metadata(run)}
      })

    {:ok, response} =
      ResponseCommit.commit_complete(response, [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Done"}]
        }
      ])

    assert {:ok, _} = Run.finalize(%{run | anchor: response.id})
  end

  defp configure_profile(agent_uid, model, effort) do
    {:ok, heavy} = ModelProfiles.get_model_profile(agent_uid, "heavy")

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent_uid, "kimi", %{
               description: "Long-context coding",
               provider_id: heavy["provider_id"],
               model: model,
               provider_options: %{"reasoningEffort" => effort}
             })
  end
end
