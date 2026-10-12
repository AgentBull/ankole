defmodule Ankole.Conversations.CodexJobTest do
  use Ankole.SignalsGateway.ActorRuntimeCase
  alias Ankole.Conversations.{Admission, CodexJob, JobTurnRef, Run}
  alias Ankole.BackgroundAgentJobs
  alias Ankole.AIGateway.Schemas.Conversation

  test "dispatch starts a fenced non-conversation turn and increments attempts once" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "dispatch")

    assert {:ok, heavy_profile} = ModelProfiles.get_model_profile(agent.uid, "heavy")

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               provider_id: heavy_profile["provider_id"],
               model: "openai/gpt-5.4-nano",
               provider_options: %{"reasoningEffort" => "medium"}
             })

    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    now = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %Ankole.Conversations.CodexJob.Attempt{}} =
             admit_job(actor_key,
               now: now
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_start = turn_start_payload!(envelope)
    assert turn_start.turn.job_id == job.id
    assert {:ok, context} = Ankole.Conversations.Context.resolve(agent.uid, actor_key.session_id)
    claimed = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert {:ok, selected_context} = Ankole.Conversations.Context.job(context, claimed)

    assert turn_start.agent_context ==
             Ankole.SignalsGateway.ActorRuntime.TurnEnvelope.agent_context(selected_context)

    assert turn_start.agent_context.skills != []
    assert is_binary(turn_start.agent_context.skills_prompt)
    assert turn_start.agent_context.conversation.timezone == context.conversation.timezone
    assert turn_start.agent_context.soul == context.documents["soul"]["content"]
    assert turn_start.agent_context.mission == context.documents["mission"]["content"]
    assert turn_start.agent_context.design == context.documents["design"]["content"]

    assert turn_start.agent_context.confidentiality_policy ==
             context.documents["confidentiality_policy"]["content"]

    assert turn_start.model_ref.provider_id == heavy_profile["provider_id"]
    assert turn_start.model_ref.provider_kind == "openrouter"
    assert turn_start.model_ref.model == "openai/gpt-5.4-nano"

    assert turn_start.model_ref.provider_options_json ==
             Ankole.JSON.encode!(%{"reasoningEffort" => "medium"})

    assert is_binary(Ankole.Kernel.RuntimeFabric.encode_envelope(envelope))
    context = decoded_request_context(turn_start)
    refute Map.has_key?(context, "turn_mode")
    refute Map.has_key?(context, "job_id")
    refute Map.has_key?(context, "owner_session_id")
    refute Map.has_key?(context, "attempts")
    refute Map.has_key?(context, "model_ref")

    refute Repo.get_by(Conversation,
             subject_uid: agent.uid,
             conversation_key: actor_key.session_id
           )

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == "running"
    assert persisted.attempts == 1
  end

  test "a stopped Job closes its open trigger on readmission without starting another attempt" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)
    job = create_job!(agent.uid, "stopped-readmission")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, attempt} = admit_job(key, [])
    assert_receive {:actor_lane, _}, 200

    assert {:ok, %{job: stopped}} =
             BackgroundAgentJobs.request_stop(job.id, %{"agent_uid" => agent.uid})

    assert stopped.status == "stopped"
    assert Repo.reload!(attempt.event).completed_at == nil

    assert {:ok, %{status: :idle, actor_event: completed}} = Admission.admit(key, attempt.event)
    assert completed.turn_outcome == nil
    assert %DateTime{} = completed.completed_at
    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).attempts == 1
    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).status == "stopped"
    refute_receive {:actor_lane, _}, 100
  end

  test "Turn checkpoints accept identical retries and reject divergent equal revisions" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "turn-revision")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %Ankole.Conversations.CodexJob.Attempt{}} =
             admit_job(actor_key,
               now: DateTime.add(job.queued_at, 1, :second)
             )

    assert_receive {:actor_lane, envelope}, 200

    assert {:ok, turn_ref} =
             JobTurnRef.from_proto(turn_start_payload!(envelope).turn, agent.uid)

    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).attempts == 1

    now = DateTime.utc_now(:microsecond)

    attrs = %{
      "attempt" => 1,
      "runtime_thread_id" => "thread-revision",
      "runtime_turn_id" => "turn-revision",
      "kind" => "agent",
      "status" => "in_progress",
      "revision" => 0,
      "trajectory" => trajectory_header(),
      "turn_items" => turn_items([user_item("Original task", "user-original")]),
      "progress" => empty_turn_progress(),
      "usage" => nil,
      "error" => %{},
      "started_at" => now
    }

    assert {:ok, first} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               attrs,
               turn_ref,
               agent.uid
             )

    assert {:ok, retried} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               attrs,
               turn_ref,
               agent.uid
             )

    assert retried.id == first.id

    unsupported =
      put_in(
        attrs,
        ["trajectory", "messages"],
        [%{"role" => "user", "content" => "Different payload at the same revision"}]
      )

    assert {:error, :background_agent_job_trajectory_messages_unsupported} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               unsupported,
               turn_ref,
               agent.uid
             )

    divergent =
      Map.put(
        attrs,
        "turn_items",
        turn_items([user_item("Different payload at the same revision", "user-original")])
      )

    assert {:error, :background_agent_job_turn_revision_conflict} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               divergent,
               turn_ref,
               agent.uid
             )

    header_divergent =
      Map.put(attrs, "progress", %{
        "completed_items" => 1,
        "tool_calls" => 1,
        "tools_used" => [%{"name" => "shell", "calls" => 1}],
        "files_changed" => []
      })

    assert {:error, :background_agent_job_turn_revision_conflict} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               header_divergent,
               turn_ref,
               agent.uid
             )
  end

  test "Turn checkpoints persist native Codex child threads under the root job" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "child-turn")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %Ankole.Conversations.CodexJob.Attempt{}} =
             admit_job(actor_key,
               now: DateTime.add(job.queued_at, 1, :second)
             )

    assert_receive {:actor_lane, envelope}, 200

    assert {:ok, turn_ref} =
             JobTurnRef.from_proto(turn_start_payload!(envelope).turn, agent.uid)

    assert {:ok, %{job: anchored}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-root"
             })

    assert anchored.runtime_thread_id == "thread-root"
    now = DateTime.utc_now(:microsecond)

    assert {:ok, child_turn} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               %{
                 "attempt" => 1,
                 "runtime_thread_id" => "thread-child",
                 "runtime_turn_id" => "turn-child",
                 "kind" => "agent",
                 "status" => "completed",
                 "revision" => 0,
                 "trajectory" => trajectory_header(),
                 "turn_items" =>
                   turn_items([assistant_item("Challenge complete.", "assistant-challenge")]),
                 "progress" => empty_turn_progress(),
                 "usage" => nil,
                 "error" => %{},
                 "started_at" => now,
                 "completed_at" => now
               },
               turn_ref,
               agent.uid
             )

    assert child_turn.runtime_thread_id == "thread-child"
  end

  test "a Job without a ready Worker requests it and keeps its execution attempts" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "no-worker")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    Enum.reduce(1..4, job.queued_at, fn retry, now ->
      assert {:ok, %{status: :waiting_for_worker}} =
               admit_job(actor_key,
                 now: now
               )

      persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
      assert persisted.status == "queued", "retry #{retry} must remain visibly queued"
      assert persisted.attempts == 0, "retry #{retry} must not consume an execution attempt"

      DateTime.add(now, 31, :second)
    end)

    # The failed placement asked for the Agent's Worker; its join wakes the Job.
    assert %Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker{wanted_until: %DateTime{}} =
             Repo.get!(Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker, agent.uid)
  end

  test "credential sharing does not impose a local Job concurrency slot" do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()

    for agent <- [first_agent, second_agent] do
      route = unique_route()
      :ok = WorkerRoute.register_local_worker(route, self())
      on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route, %{worker_id: agent.uid})
    end

    first = create_job!(first_agent.uid, "subscription-first")
    second = create_job!(second_agent.uid, "subscription-second")

    first_key = %{
      agent_uid: first_agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(first.id)
    }

    second_key = %{
      agent_uid: second_agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(second.id)
    }

    assert {:ok, %Ankole.Conversations.CodexJob.Attempt{}} =
             admit_job(first_key,
               now: DateTime.add(first.queued_at, 1, :second)
             )

    assert_receive {:actor_lane, first_envelope}, 200

    assert {:ok, %Ankole.Conversations.CodexJob.Attempt{}} =
             admit_job(second_key,
               now: DateTime.add(second.queued_at, 1, :second)
             )

    assert_receive {:actor_lane, second_envelope}, 200
    assert turn_start_payload!(first_envelope).turn.job_id == first.id
    assert turn_start_payload!(second_envelope).turn.job_id == second.id
    assert BackgroundAgentJobs.get_job_for_agent(first.id, first_agent.uid).attempts == 1
    assert BackgroundAgentJobs.get_job_for_agent(second.id, second_agent.uid).attempts == 1
  end

  # Missing capacity defers the claim instead of losing it.
  test "a Job waits when the Agent's Worker has no free slot" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)

    assert {:ok, _worker} = admit_worker(route, %{capacity: %{"available_slots" => 1}})

    first_job = create_job!(agent.uid, "agent-full-first")

    first_key = %{
      agent_uid: agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(first_job.id)
    }

    assert {:ok, %Ankole.Conversations.CodexJob.Attempt{}} =
             admit_job(first_key,
               now: DateTime.add(first_job.queued_at, 1, :second)
             )

    assert_receive {:actor_lane, _first_envelope}, 200

    second_job = create_job!(agent.uid, "agent-full-second")

    second_key = %{
      agent_uid: agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(second_job.id)
    }

    assert {:ok, %{status: :waiting_for_worker}} =
             admit_job(second_key,
               now: DateTime.add(second_job.queued_at, 1, :second)
             )

    assert %{status: "queued", attempts: 0} =
             BackgroundAgentJobs.get_job_for_agent(second_job.id, agent.uid)
  end

  test "worker capacity deferral does not claim an execution attempt" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, _worker} = admit_worker(route, %{capacity: %{"available_slots" => 0}})

    job = create_job!(agent.uid, "worker-capacity")
    actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %{status: :waiting_for_worker}} =
             admit_job(actor_key,
               now: DateTime.add(job.queued_at, 1, :second)
             )

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == "queued"
    assert persisted.attempts == 0
    assert persisted.started_at == nil
  end

  test "Driver replacement adopts the same Codex attempt and accepts its checkpoint" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = admit_worker(route)
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    job = create_job!(agent.uid, "adopt")

    job =
      Repo.update!(
        Ecto.Changeset.change(job, Ankole.Principals.WorkAccess.from_sender(Repo, human.uid))
      )

    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    now = DateTime.add(job.queued_at, 1, :second)
    assert {:ok, first} = admit_job(key, now: now)
    assert_receive {:actor_lane, first_frame}
    assert turn_start_payload!(first_frame).mode == "start"

    assert Repo.reload!(first.event).last_attempt_at
    Repo.update!(Ecto.Changeset.change(human, access_version: human.access_version + 1))
    Repo.delete!(Repo.get!(Conversation, first.job.metadata["owner_conversation_id"]))

    assert {:error, :owner_conversation_not_found} =
             Ankole.Conversations.Context.resolve(agent.uid, key.session_id)

    assert {:ok, adopted} = admit_job(key, now: now)
    assert_receive {:actor_lane, adopted_frame}
    assert turn_start_payload!(adopted_frame).mode == "adopt"
    assert adopted.context == nil
    assert turn_start_payload!(adopted_frame).agent_context == nil
    assert adopted.epoch > first.epoch
    assert adopted.job_ref == first.job_ref
    assert adopted.job.attempts == 1
    assert adopted.job.execution_failures == 0
    assert {:error, :stale_driver} = CodexJob.start(first)
    refute_receive {:actor_lane, _}, 50

    timestamp = DateTime.utc_now(:microsecond)

    assert {:ok, _} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               agent.uid,
               %{
                 "attempt" => 1,
                 "runtime_thread_id" => "adopt-thread",
                 "runtime_turn_id" => "adopt-turn",
                 "kind" => "agent",
                 "status" => "in_progress",
                 "revision" => 0,
                 "trajectory" => trajectory_header(),
                 "turn_items" => turn_items([user_item("Work", "u")]),
                 "progress" => empty_turn_progress(),
                 "error" => %{},
                 "started_at" => timestamp
               },
               first.job_ref,
               agent.uid
             )
  end

  test "revoked fresh Job commands are rejected without changing the admitted attempt" do
    %{principal: agent} = agent_fixture()
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)
    job = create_job!(agent.uid, "revoked-command")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, run} = admit_job(key, now: DateTime.add(job.queued_at, 1, :second))
    assert_receive {:actor_lane, _start}

    events =
      for type <- ["command.steer"] do
        {:ok, event} =
          Repo.transact(
            &SignalsGateway.append_actor_event_in_tx(&1, %{
              agent_uid: agent.uid,
              session_id: key.session_id,
              sender_key: human.uid,
              binding_name: "control-plane:test",
              source_event_id: Ecto.UUID.generate(),
              type: type,
              payload: %{},
              available_at: DateTime.utc_now(:microsecond)
            })
          )

        event
      end

    Repo.update!(Ecto.Changeset.change(human, access_version: human.access_version + 1))

    for event <- events do
      assert {:ok, %{status: :dead_letter}} = CodexJob.admit(key, event, [])
      rejected = Repo.reload!(event)
      assert rejected.dead_letter_reason["code"] == "human_access_revoked"
      assert rejected.last_attempt_at == nil
    end

    assert Repo.reload!(job) == run.job
    assert Repo.reload!(run.event).completed_at == nil
    refute_receive {:actor_lane, _}, 50
  end

  test "a frozen Job model survives a changed logical profile on retry" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = admit_worker(route)
    job = create_job!(agent.uid, "frozen")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, first} = admit_job(key, now: DateTime.add(job.queued_at, 1, :second))
    assert_receive {:actor_lane, first_frame}
    frozen = turn_start_payload!(first_frame).model_ref

    {:ok, heavy} = ModelProfiles.get_model_profile(agent.uid, "heavy")

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               provider_id: heavy["provider_id"],
               model: "openai/gpt-5.4-nano"
             })

    retry_at = DateTime.add(DateTime.utc_now(:microsecond), 300, :second)

    error = %{
      "code" => "worker_turn_failed",
      "message" => "Pool unavailable",
      "details_json" => %{
        "error_code" => "credential_pool_exhausted",
        "retryable" => true,
        "retry_at" => DateTime.to_iso8601(retry_at)
      }
    }

    assert {:ok, event} = CodexJob.abort(first.job_ref, agent.uid, error)
    assert event.available_at == retry_at
    assert {:ok, retry} = admit_job(key, now: retry_at)
    assert_receive {:actor_lane, retry_frame}
    assert turn_start_payload!(retry_frame).model_ref == frozen
    assert retry.job.attempts == 2
    assert retry.job.execution_failures == 0
  end

  for {code, expected_failures} <- [
        {"socket_closed", 0},
        {"runtime_fabric_timeout", 0},
        {"runtime_rpc_timeout", 0},
        {"timeout", 1}
      ] do
    test "#{code} requeues a fenced attempt with #{expected_failures} execution failures" do
      code = unquote(code)
      expected_failures = unquote(expected_failures)
      %{principal: agent} = agent_fixture()
      route = unique_route()
      :ok = WorkerRoute.register_local_worker(route, self())
      on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
      assert {:ok, _} = admit_worker(route)

      job = create_job!(agent.uid, code)
      key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
      assert {:ok, first} = admit_job(key, now: DateTime.add(job.queued_at, 1, :second))
      assert_receive {:actor_lane, first_frame}
      assert turn_start_payload!(first_frame).turn.attempt == 1

      error = %{
        "code" => "worker_turn_failed",
        "message" => "connection interrupted",
        "details_json" => %{"error_code" => code, "retryable" => true}
      }

      assert {:ok, event} = CodexJob.abort(first.job_ref, agent.uid, error)
      assert event.input_state == "open"
      assert event.completed_at == nil

      assert %{status: "queued", attempts: 1, execution_failures: ^expected_failures} =
               Repo.reload!(job)

      assert {:ok, retry} = admit_job(key, now: event.available_at)
      assert_receive {:actor_lane, retry_frame}
      assert turn_start_payload!(retry_frame).turn.attempt == 2
      assert retry.job.execution_failures == expected_failures

      assert {:ok, _} =
               BackgroundAgentJobs.request_stop(job.id, %{
                 agent_uid: agent.uid,
                 reason: "transport classification test complete"
               })
    end
  end

  test "an unavailable profile settles an unstarted Job without creating a Worker" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "missing-profile")
    principal_agent = Repo.get!(Ankole.Principals.Agent, agent.uid)

    Repo.update!(
      change(principal_agent,
        options: Map.put(principal_agent.options, "ai_agent", %{"models" => %{}})
      )
    )

    event =
      Repo.get_by!(ActorEvent,
        session_id: BackgroundAgentJobs.job_session_id(job.id),
        type: "background_agent_job.dispatch"
      )

    key = %{agent_uid: agent.uid, session_id: event.session_id}

    Ankole.SignalsGateway.ActorRuntimeCase.stub_driver(%{
      agent_uid: agent.uid,
      session_id: job.owner_session_id
    })

    assert {:ok, %{status: :failed}} = Admission.admit(key, event)
    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).status == "failed"
    assert %ActorEvent{completed_at: %DateTime{}} = Repo.get!(ActorEvent, event.id)
    assert Repo.get!(AgentWorker, agent.uid).state == "absent"

    wakeup =
      Repo.get_by!(ActorEvent,
        agent_uid: agent.uid,
        session_id: job.owner_session_id,
        type: "background_agent_job.failed"
      )

    wakeup_id = wakeup.id
    assert_receive {:inbox, ^wakeup_id}
  end

  test "a start with a missing owner conversation fails before reserving or claiming" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, worker} = admit_worker(route)
    job = create_job!(agent.uid, "missing-owner")
    Repo.delete!(Repo.get!(Conversation, job.metadata["owner_conversation_id"]))

    event =
      Repo.get_by!(ActorEvent,
        session_id: BackgroundAgentJobs.job_session_id(job.id),
        type: "background_agent_job.dispatch"
      )

    key = %{agent_uid: agent.uid, session_id: event.session_id}
    assert {:ok, %{status: :dead_letter}} = Admission.admit(key, event)
    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == "failed"
    assert persisted.attempts == 0
    assert Repo.get!(ActorEvent, event.id).input_state == "dead_letter"
    assert Repo.get!(AgentWorker, agent.uid).capacity == worker.capacity
  end

  defp admit_job(key, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case Run.rebuild(key, now) do
      {:ok, %{event: event}} ->
        case Admission.admit(key, event, opts) do
          {:ok, %Ankole.Conversations.CodexJob.Attempt{} = run} ->
            assert {:ok, _} = CodexJob.start(run)
            {:ok, run}

          result ->
            result
        end

      result ->
        result
    end
  end

  defp create_job!(agent_uid, suffix) do
    assert {:ok, %{job: job}} =
             Repo.transact(fn _repo ->
               BackgroundAgentJobs.create_with_dispatch(%{
                 "source_actor_event_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
                 "agent_uid" => agent_uid,
                 "owner_session_id" => "owner-session-#{suffix}",
                 "source_tool_call_id" => "tool-background-agent-job-#{suffix}",
                 "title" => "Job #{suffix}",
                 "task" => "Complete job #{suffix}.",
                 "reply_route" => %{
                   "binding_name" => "bot",
                   "signal_channel_id" => "chat-#{suffix}"
                 }
               })
             end)

    job
  end

  defp empty_turn_progress do
    %{
      "completed_items" => 0,
      "tool_calls" => 0,
      "tools_used" => [],
      "files_changed" => []
    }
  end

  defp trajectory_header, do: %{"format" => "ankole_chatml", "version" => 1}

  defp turn_items(items) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, position} ->
      %{"position" => position, "item_key" => item["id"], "item" => item}
    end)
  end

  defp user_item(text, id) do
    %{"type" => "userMessage", "id" => id, "content" => [%{"type" => "text", "text" => text}]}
  end

  defp assistant_item(text, id) do
    %{"type" => "agentMessage", "id" => id, "text" => text}
  end
end
