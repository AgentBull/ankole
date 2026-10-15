defmodule Ankole.Sessions.AmbientInterventionTest do
  use Ankole.SessionsCase

  alias Ankole.BackgroundAgentJobs
  alias Ankole.Sessions.Admission

  setup do
    %{principal: agent} = agent_fixture()
    {:ok, agent: agent}
  end

  test "supersedes an older ambient scene and delivers only the latest stable scene", %{
    agent: agent
  } do
    binding_fixture(agent.uid, "bot", :may_intervene)

    assert {:ok, %{signal: first_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "ambient-first-event",
                 provider_message_id: "ambient-first-entry",
                 text: "Which benchmark should we use?"
               }),
               now: @base_time
             )

    second_at = DateTime.add(@base_time, 20, :second)

    assert {:ok, %{signal: second_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "ambient-second-event",
                 provider_message_id: "ambient-second-entry",
                 text: "Use CSI 300.",
                 provider_time: second_at
               }),
               now: second_at
             )

    first_snapshot = first_event.data["ambient_batch"]
    third_at = DateTime.add(@base_time, 40, :second)

    assert {:ok, %{signal: third_event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "ambient-third-event",
                 provider_message_id: "ambient-third-entry",
                 text: "Use the total-return series.",
                 provider_time: third_at
               }),
               now: third_at
             )

    third_snapshot = third_event.data["ambient_batch"]

    assert is_binary(first_snapshot["scene_fingerprint"])
    assert is_binary(first_snapshot["as_of"])
    assert is_binary(first_snapshot["expires_at"])
    refute first_snapshot["scene_fingerprint"] == third_snapshot["scene_fingerprint"]

    process_at = DateTime.add(third_event.available_at, 1, :second)

    assert {:ok,
            %{
              status: :ambient_superseded,
              reason: :scene_changed,
              signal: superseded_event,
              superseded_count: 2
            }} =
             Admission.admit(
               %{agent_uid: agent.uid, session_id: first_event.session_id},
               first_event,
               now: process_at
             )

    assert superseded_event.id == first_event.id
    assert %DateTime{} = Repo.get!(Signal, first_event.id).completed_at
    assert %DateTime{} = Repo.get!(Signal, second_event.id).completed_at
    assert is_nil(Repo.get!(Signal, third_event.id).completed_at)
    refute_receive {:actor_lane, _envelope}, 50

    assert {:ok, run} =
             Admission.admit(
               %{agent_uid: agent.uid, session_id: third_event.session_id},
               third_event,
               now: process_at
             )

    assert run.signal_id == third_event.id
    assert Repo.get!(AgentWorker, agent.uid).state == "absent"
  end

  test "expires a queued ambient opportunity without starting a worker turn", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :may_intervene)

    assert {:ok, %{signal: event}} =
             emit_entry(agent.uid, "bot", group_entry(%{text: "Could this be useful?"}),
               now: @base_time
             )

    {:ok, expires_at, _offset} =
      event.data["ambient_batch"]["expires_at"]
      |> DateTime.from_iso8601()

    assert {:ok,
            %{
              status: :ambient_superseded,
              reason: :expired,
              signal: completed_event
            }} =
             Admission.admit(%{agent_uid: agent.uid, session_id: event.session_id}, event,
               now: expires_at
             )

    assert completed_event.id == event.id
    refute_receive {:actor_lane, _envelope}, 50
    assert Repo.get!(AgentWorker, agent.uid).state == "absent"
  end

  test "does not stale an ambient scene on an exact provider redelivery", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :may_intervene)

    entry =
      group_entry(%{
        source_event_id: "ambient-redelivery-event",
        provider_message_id: "ambient-redelivery-entry",
        text: "The strategy may need a backtest."
      })

    assert {:ok, %{signal: event}} =
             emit_entry(agent.uid, "bot", entry, now: @base_time)

    assert {:ok, %{status: :duplicate}} =
             Observe.emit_entry(agent.uid, "bot", entry,
               now: DateTime.add(@base_time, 20, :second)
             )

    assert {:ok, run} =
             Admission.admit(%{agent_uid: agent.uid, session_id: event.session_id}, event,
               now: DateTime.add(@base_time, 21, :second)
             )

    assert run.signal_id == event.id
  end

  test "supersedes queued ambient work after its binding policy changes", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :may_intervene)

    assert {:ok, %{signal: event}} =
             emit_entry(agent.uid, "bot", group_entry(%{}), now: @base_time)

    binding_fixture(agent.uid, "bot", :record_only)

    assert {:ok,
            %{
              status: :ambient_superseded,
              reason: :binding_policy_changed,
              signal: completed_event
            }} =
             Admission.admit(%{agent_uid: agent.uid, session_id: event.session_id}, event,
               now: DateTime.add(@base_time, 20, :second)
             )

    assert completed_event.id == event.id
    refute_receive {:actor_lane, _envelope}, 50
  end

  test "injects only bounded live work candidates from the same room session", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :may_intervene)

    assert {:ok, %{signal: event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "The deploy has a new database timeout."}),
               now: @base_time
             )

    matching = create_job!(agent.uid, event, "matching", %{})

    _other_session =
      create_job!(agent.uid, event, "other-session", %{owner_session_id: "another-session"})

    _other_channel =
      create_job!(agent.uid, event, "other-channel", %{
        conversation_id:
          Ankole.ExternalConversationsFixtures.external_conversation_id("lark:chat:other")
      })

    assert {:ok, run} =
             Admission.admit(%{agent_uid: agent.uid, session_id: event.session_id}, event,
               now: DateTime.add(@base_time, 20, :second)
             )

    context = run.spec.request_context

    assert %{
             "complete" => true,
             "jobs" => [
               %{
                 "job_id" => job_id,
                 "title" => "Investigate deploy matching",
                 "status" => "queued",
                 "task_excerpt" => task_excerpt
               }
             ]
           } = context["ambient_work_candidates"]

    assert job_id == Integer.to_string(matching.id)
    assert task_excerpt =~ "matching"
  end

  test "a policy change after admission rejects judgment and supersedes the next admission", %{
    agent: agent
  } do
    binding_fixture(agent.uid, "bot", :may_intervene)

    assert {:ok, %{signal: event}} =
             emit_entry(agent.uid, "bot", group_entry(%{text: "Which benchmark?"}),
               now: @base_time
             )

    key = %{agent_uid: agent.uid, session_id: event.session_id}
    now = DateTime.add(@base_time, 20, :second)
    assert {:ok, run} = Admission.admit(key, event, now: now)
    assert run.signal_id == event.id
    binding_fixture(agent.uid, "bot", :record_only)

    assert {:error, {:ambient_stale, :binding_policy_changed}} =
             Ankole.Sessions.AmbientCuration.record_judgment(
               key,
               event.id,
               %{action: "NOOP", authority: "NONE", handoff_job_id: nil},
               now: now
             )

    assert is_nil(Repo.get(Ankole.Sessions.AmbientJudgment, event.id))

    assert is_nil(
             Ankole.Sessions.AmbientCuration.judged_until(event.agent_uid, event.conversation_id)
           )

    assert is_nil(Repo.get!(Signal, event.id).completed_at)

    assert {:ok, %{status: :ambient_superseded, reason: :binding_policy_changed}} =
             Admission.admit(key, event, now: now)

    completed = Repo.get!(Signal, event.id)
    assert %DateTime{} = completed.completed_at
    refute completed.input_state == "dead_letter"
    refute_receive {:actor_lane, _envelope}, 50
  end

  test "a visible reply keeps the admitted light model and other request context", %{agent: agent} do
    binding_fixture(agent.uid, "bot", :may_intervene)

    assert {:ok, %{signal: event}} =
             emit_entry(agent.uid, "bot", group_entry(%{text: "Which benchmark?"}),
               now: @base_time
             )

    key = %{agent_uid: agent.uid, session_id: event.session_id}
    now = DateTime.add(@base_time, 20, :second)
    assert {:ok, run} = Admission.admit(key, event, now: now)

    run = %{
      run
      | spec: Map.update!(run.spec, :request_context, &Map.put(&1, "retained", "value"))
    }

    assert {:ok, _} =
             Ankole.Sessions.AmbientCuration.record_judgment(
               key,
               event.id,
               %{action: "FOREGROUND_REPLY", authority: "NONE", handoff_job_id: nil},
               now: now
             )

    assert {:ok, {:prepare, prepared}} = Ankole.Sessions.Ambient.prepare(run)
    assert prepared.spec.model_ref == run.spec.model_ref
    assert Map.delete(prepared.spec, :request_context) == Map.delete(run.spec, :request_context)

    assert prepared.spec.request_context["ambient"] == %{
             "action" => "FOREGROUND_REPLY",
             "authority" => "NONE",
             "handoff_job_id" => nil
           }

    assert Map.delete(prepared.spec.request_context, "ambient") == run.spec.request_context
  end

  defp create_job!(agent_uid, event, suffix, overrides) do
    assert {:ok, %{job: job}} =
             Repo.transact(fn _repo ->
               BackgroundAgentJobs.create_with_dispatch(%{
                 "source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
                 "agent_uid" => agent_uid,
                 "owner_session_id" => Map.get(overrides, :owner_session_id, event.session_id),
                 "source_tool_call_id" => "ambient-candidate-#{suffix}",
                 "title" => "Investigate deploy #{suffix}",
                 "task" => "Find the cause of deploy #{suffix}.",
                 "reply_route" => %{
                   "binding_name" => event.reply_binding_name,
                   "conversation_id" =>
                     Map.get(overrides, :conversation_id, event.conversation_id),
                   "provider_thread_id" => event.provider_thread_id,
                   "provider_message_id" => event.provider_message_id
                 }
               })
             end)

    job
  end
end
