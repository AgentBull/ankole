defmodule Ankole.Sessions.CodexJobTest do
  use Ankole.SessionsCase
  import Ankole.PrincipalsFixtures, only: [human_fixture: 0]
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.CodexJob
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.AgentWorkers.RunnerDevices
  alias Ankole.AuthZ.Actor
  alias Ankole.BackgroundAgentJobs
  alias Ankole.AIGateway.Schemas.Conversation

  test "a Job waits for its selected device and respawns on the same Home" do
    %{principal: owner} = human_fixture()

    %{principal: agent} =
      agent_fixture(%{type: :personal_assistant, owner_principal_uid: owner.uid})

    origin = "https://ankole.example.test"

    assert {:ok, %{id: runner_id, code: code}} =
             RunnerDevices.register(Actor.new(owner), "Research machine", origin)

    assert {:ok, %{token: token}} = RunnerDevices.pair(code)
    assert {:ok, [spec]} = RunnerDevices.bootstrap(token, origin)
    uid = spec.agent_uid
    assert uid == agent.uid

    assert {:ok, cloud} = admit_worker(unique_route(), %{worker_id: uid})
    creator = %{"principal_uid" => to_string(Ankole.ActorRef.from_principal(owner))}

    %{job: job, dispatch_event: dispatch} = create_device_job!(uid, creator, runner_id, "device")

    assert {:ok, devices} =
             Ankole.Sessions.Tools.Jobs.execute(
               %{agent_uid: uid, signal_id: dispatch.id},
               %{"name" => "list_background_job_devices"},
               %{}
             )

    assert devices.details["devices"] == [
             %{"runner_id" => runner_id, "name" => "Research machine", "status" => "offline"}
           ]

    key = %{agent_uid: uid, session_id: dispatch.session_id}
    now = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %{status: :waiting_for_worker, runner_id: ^runner_id}} =
             CodexJob.admit(key, dispatch, now: now)

    assert %{status: :queued, runner_id: ^runner_id, attempts: 0} =
             BackgroundAgentJobs.get_job_for_agent(job.id, uid)

    assert {:ok, managed} = AgentWorkers.get_agent_worker(uid)
    assert managed.wanted_until == cloud.wanted_until

    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)

    binding = admit_device_binding!(spec, runner_id, route)

    assert {:ok, run} = CodexJob.admit(key, dispatch, now: DateTime.add(now, 1, :second))
    assert run.job_worker.transport_route == route
    assert {:ok, _} = CodexJob.start(run)
    assert_receive {:actor_lane, envelope}
    assert turn_start_payload!(envelope).drive_vfs == nil

    assert {:error, :worker_not_assigned_to_turn} =
             Ankole.AgentWorkers.WorkerRouteAuth.authorize_turn(
               run.job_ref,
               AgentWorkers.target(cloud),
               :read
             )

    assert {:ok, _} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               uid,
               %{"status" => "running", "runtime_thread_id" => "device-thread"},
               turn_ref: run.job_ref,
               worker_id: AgentWorkers.target(binding)
             )

    assert {:ok, %{job: completed}} =
             BackgroundAgentJobs.request_complete(job.id, %{
               "agent_uid" => uid,
               "result_summary" => "Verified on the research machine"
             })

    assert {:ok, %{job: successor}} =
             BackgroundAgentJobs.respawn_with_dispatch(completed.id, %{
               "agent_uid" => uid,
               "created_by" => creator,
               "owner_session_id" => completed.owner_session_id,
               "source_tool_call_id" => "tool-device-job-successor",
               "message" => "Continue with the next dataset.",
               "reply_route" => completed.reply_route
             })

    assert successor.runner_id == runner_id
    assert successor.workspace_owner_job_id == job.id
    assert successor.runtime_thread_id == "device-thread"
  end

  test "two Agent bindings share the device's durable Job capacity" do
    %{principal: owner} = human_fixture()
    actor = Actor.new(owner)
    creator = %{"principal_uid" => to_string(Ankole.ActorRef.from_principal(owner))}
    origin = "https://ankole.example.test"

    %{principal: assistant} =
      agent_fixture(%{type: :personal_assistant, owner_principal_uid: owner.uid})

    %{principal: colleague} = agent_fixture(%{owner_principal_uid: owner.uid})

    assert {:ok, %{id: runner_id, code: code}} =
             RunnerDevices.register(actor, "Shared device capacity", origin)

    assert {:ok, %{token: token}} = RunnerDevices.pair(code)
    assert {:ok, _} = RunnerDevices.bind(actor, runner_id, colleague.uid, origin)
    assert {:ok, specs} = RunnerDevices.bootstrap(token, origin)
    assert Enum.sort(Enum.map(specs, & &1.agent_uid)) == Enum.sort([assistant.uid, colleague.uid])

    for spec <- specs, do: admit_device_binding!(spec, runner_id, unique_route())

    %{job: first, dispatch_event: first_dispatch} =
      create_device_job!(assistant.uid, creator, runner_id, "shared-first")

    %{job: second, dispatch_event: second_dispatch} =
      create_device_job!(colleague.uid, creator, runner_id, "shared-second")

    first_key = %{agent_uid: assistant.uid, session_id: first_dispatch.session_id}
    second_key = %{agent_uid: colleague.uid, session_id: second_dispatch.session_id}
    now = DateTime.add(second.queued_at, 1, :second)

    assert {:ok, %CodexJob.Attempt{}} = CodexJob.admit(first_key, first_dispatch, now: now)

    assert {:ok, %{status: :waiting_for_worker, reason: :no_worker_capacity}} =
             CodexJob.admit(second_key, second_dispatch, now: now)

    assert %{status: :queued, attempts: 0} =
             BackgroundAgentJobs.get_job_for_agent(second.id, colleague.uid)

    assert {:ok, %{job: %{status: :stopped}}} =
             BackgroundAgentJobs.request_stop(first.id, %{"agent_uid" => assistant.uid})

    assert {:ok, %CodexJob.Attempt{job_worker: %{runner_id: ^runner_id}}} =
             CodexJob.admit(second_key, second_dispatch, now: DateTime.add(now, 1, :second))
  end

  test "revoking a device fails its running Job and frees the Agent's hosted capacity" do
    assert {:ok, 1} =
             Ankole.AppConfigure.put_tenant_by_key(
               "background_agent_jobs.max_running_per_agent",
               1
             )

    %{principal: owner} = human_fixture()
    actor = Actor.new(owner)
    creator = %{"principal_uid" => to_string(Ankole.ActorRef.from_principal(owner))}
    origin = "https://ankole.example.test"

    %{principal: agent} =
      agent_fixture(%{type: :personal_assistant, owner_principal_uid: owner.uid})

    assert {:ok, %{id: runner_id, code: code}} =
             RunnerDevices.register(actor, "Revoked device", origin)

    assert {:ok, %{token: token}} = RunnerDevices.pair(code)
    assert {:ok, [spec]} = RunnerDevices.bootstrap(token, origin)
    route = unique_route()
    admit_device_binding!(spec, runner_id, route)

    cloud_route = unique_route()
    :ok = WorkerRoute.register_local_worker(cloud_route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(cloud_route) end)
    assert {:ok, _} = admit_worker(cloud_route, %{worker_id: agent.uid})

    %{job: pinned, dispatch_event: dispatch} =
      create_device_job!(agent.uid, creator, runner_id, "revoked-running")

    hosted = create_job!(agent.uid, "after-device-revoke")
    device_key = %{agent_uid: agent.uid, session_id: dispatch.session_id}
    hosted_key = %{device_key | session_id: BackgroundAgentJobs.job_session_id(hosted.id)}
    now = DateTime.add(hosted.queued_at, 1, :second)

    assert {:ok, %CodexJob.Attempt{} = run} = CodexJob.admit(device_key, dispatch, now: now)

    assert {:ok, %{reason: :background_agent_job_agent_at_capacity}} =
             admit_job(hosted_key, now: now)

    assert {:ok, :marked_stale} =
             AgentWorkers.WorkerAdmission.mark_route_unusable(route, :socket_closed)

    assert {:ok, :disconnected} = CodexJob.observe(run)
    assert %{status: :running} = BackgroundAgentJobs.get_job(pinned.id)

    assert {:ok, _} = RunnerDevices.revoke(actor, runner_id)
    assert {:ok, _} = RunnerDevices.revoke(actor, runner_id)

    assert %{status: :failed, error: %{"code" => "runner_revoked"}} =
             BackgroundAgentJobs.get_job(pinned.id)

    assert {:ok, %{status: :completed}} = Ankole.Signals.get_signal(dispatch.id)

    assert {:ok, [%{data: %{"job_id" => id}}]} =
             Ankole.Signals.list_signals(
               query: [
                 filter: [
                   session_id: pinned.owner_session_id,
                   type: "background_agent_job.failed"
                 ]
               ]
             )

    assert id == pinned.id

    assert {:ok, %CodexJob.Attempt{job_worker: %{transport_route: ^cloud_route}}} =
             admit_job(hosted_key, now: DateTime.add(now, 1, :second))
  end

  test "a reflection without Bindings starts with its Agent context and a fenced attempt" do
    %{principal: agent} = agent_fixture()
    refute Repo.exists?(Ankole.Signals.Binding)
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    assert {:ok, %{job: job, dispatch_event: dispatch}} =
             create_job_with_stub_driver(%{
               "agent_uid" => agent.uid,
               "created_by" => %{
                 "principal_uid" => to_string(Ankole.ActorRef.from_principal(agent))
               },
               "owner_session_id" => "brain:skill-lessons:" <> agent.uid,
               "source_tool_call_id" => "skill-lessons:binding-free",
               "title" => "Skill lessons reflection",
               "task" => "Reflect over the evidence bundle.",
               "metadata" => %{"skill_lesson_reflection" => true}
             })

    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, run} = admit_job(key, now: DateTime.add(job.queued_at, 1, :second))
    assert_receive {:actor_lane, envelope}, 200
    turn_start = turn_start_payload!(envelope)

    assert turn_start.signal.binding_name == ""
    assert dispatch.reply_binding_name == nil
    assert dispatch.conversation_id == nil
    assert run.event.authorization_kind == "service"
    assert run.job_ref.job_id == job.id
    assert run.job_ref.signal_id == dispatch.id
    assert run.job_ref.attempt == 1
    assert run.epoch > 0
    assert run.job.attempts == 1
    assert run.job.status == :running
    assert run.context.conversation.id == job.metadata["owner_conversation_id"]
    assert turn_start.agent_context == Ankole.Sessions.TurnEnvelope.agent_context(run.context)
    assert turn_start.agent_context.skills != []
    assert is_binary(Ankole.RuntimeFabric.encode_envelope(envelope))
    refute Repo.exists?(Ankole.Signals.Binding)
  end

  test "dispatch starts a fenced non-conversation turn and increments attempts once" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{principal: reader} = human_fixture()

    {:ok, group} =
      Ankole.AuthZ.create_principal_group(%{
        name: "dispatch-readers-#{System.unique_integer([:positive])}",
        display_name: "Dispatch readers",
        domain: :im_group,
        kind: :static
      })

    {:ok, _} = Ankole.AuthZ.replace_static_group_members(group.id, :im_group, [reader.uid])

    Ankole.ExternalConversationsFixtures.external_conversation_fixture("chat-dispatch", %{
      principal_group_id: group.id
    })

    job = create_job!(agent.uid, "dispatch")

    assert {:ok, heavy_profile} = ModelProfiles.get_model_profile(agent.uid, "heavy")

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               provider_id: heavy_profile["provider_id"],
               model: "openai/gpt-5.4-nano",
               provider_options: %{"reasoningEffort" => "medium"}
             })

    session_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    now = DateTime.add(job.queued_at, 1, :second)

    assert {:ok, %Ankole.Sessions.CodexJob.Attempt{}} =
             admit_job(session_key,
               now: now
             )

    assert_receive {:actor_lane, envelope}, 200
    turn_start = turn_start_payload!(envelope)
    assert turn_start.turn.job_id == job.id

    assert {:ok, context} =
             Ankole.Sessions.Context.resolve(agent.uid, session_key.session_id, %{
               "signal_id" => turn_start.turn.signal_id
             })

    claimed = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert {:ok, selected_context} = Ankole.Sessions.Context.job(context, claimed)

    assert turn_start.agent_context ==
             Ankole.Sessions.TurnEnvelope.agent_context(selected_context)

    assert turn_start.agent_context.skills != []
    assert is_binary(turn_start.agent_context.skills_prompt)
    assert turn_start.agent_context.conversation.timezone == context.conversation.timezone
    assert turn_start.agent_context.agents == context.documents["agents"]["content"]
    assert turn_start.agent_context.design == context.documents["design"]["content"]

    assert turn_start.model_ref.provider_id == heavy_profile["provider_id"]
    assert turn_start.model_ref.provider_kind == "openrouter"
    assert turn_start.model_ref.model == "openai/gpt-5.4-nano"

    assert turn_start.model_ref.provider_options_json ==
             Ankole.JSON.encode!(%{"reasoningEffort" => "medium"})

    assert is_binary(Ankole.RuntimeFabric.encode_envelope(envelope))
    context = decoded_request_context(turn_start)
    refute Map.has_key?(context, "turn_mode")
    refute Map.has_key?(context, "owner_session_id")
    refute Map.has_key?(context, "model_ref")
    # The claimed attempt is the identity that the usage ledger and the Turn
    # root span attribute the Turn's provider rounds to.
    assert context["job_id"] == job.id
    assert context["attempts"] == 1
    assert context["session_id"] == session_key.session_id

    refute Repo.get_by(Conversation,
             subject_uid: agent.uid,
             conversation_key: session_key.session_id
           )

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == :running
    assert persisted.attempts == 1
  end

  test "a steer claims a continuation beyond the execution-failure budget and adoption keeps it" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)
    job = create_job!(agent.uid, "steer-continuation")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    now = DateTime.add(job.queued_at, 1, :second)
    assert {:ok, %{event: dispatch}} = CodexJob.rebuild(key, now)

    assert {:ok, _} =
             Repo.transact(fn -> Queue.mark_event_completed_in_tx(dispatch, now) end)

    Repo.update!(
      Ecto.Changeset.change(job,
        status: :waiting_on_user,
        attempts: 1,
        execution_failures: 5,
        started_at: now,
        runtime_thread_id: "thread-steer-continuation"
      )
    )

    assert {:ok, %{command_event: steer}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => agent.uid,
               "request_id" => "steer-continuation",
               "message" => "Continue with this input."
             })

    now = DateTime.add(steer.available_at, 1, :second)
    assert {:ok, run} = admit_job(key, now: now)
    assert_receive {:actor_lane, started}
    assert turn_start_payload!(started).mode == "start"
    assert run.job_ref.signal_id == steer.id
    assert %{status: :running, attempts: 2, execution_failures: 5} = run.job

    assert {:ok, adopted} = admit_job(key, now: now)
    assert_receive {:actor_lane, resumed}
    assert turn_start_payload!(resumed).mode == "adopt"
    assert adopted.job_ref == run.job_ref
    assert adopted.job.attempts == 2
  end

  test "a repeated retryable abort settles the attempt only once" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)
    job = create_job!(agent.uid, "repeated-abort")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, run} = admit_job(key, now: DateTime.add(job.queued_at, 1, :second))
    assert_receive {:actor_lane, _started}

    error = %{
      "code" => "worker_turn_failed",
      "message" => "The provider has no capacity.",
      "details_json" => %{"retryable" => true}
    }

    assert {:ok, event} = CodexJob.abort(run.job_ref, agent.uid, error)
    assert %{status: :queued, attempts: 1, execution_failures: 1} = Repo.reload!(job)
    assert event.status == :queued

    assert {:ok, %Signal{} = repeated} = CodexJob.abort(run.job_ref, agent.uid, error)
    assert repeated.__metadata__[:compensation] == nil
    assert repeated.available_at == event.available_at
    assert %{status: :queued, attempts: 1, execution_failures: 1} = Repo.reload!(job)
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

    assert stopped.status == :stopped
    assert Repo.reload!(attempt.event).completed_at == nil

    assert {:ok, %{status: :idle, signal: completed}} = Admission.admit(key, attempt.event)
    assert completed.turn_outcome == nil
    assert %DateTime{} = completed.completed_at
    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).attempts == 1
    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).status == :stopped
    refute_receive {:actor_lane, _}, 100
  end

  test "Turn checkpoints accept identical retries and reject divergent equal revisions" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    job = create_job!(agent.uid, "turn-revision")
    session_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %Ankole.Sessions.CodexJob.Attempt{}} =
             admit_job(session_key,
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
    session_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %Ankole.Sessions.CodexJob.Attempt{}} =
             admit_job(session_key,
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
    session_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    Enum.reduce(1..4, job.queued_at, fn retry, now ->
      assert {:ok, %{status: :waiting_for_worker}} =
               admit_job(session_key,
                 now: now
               )

      persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
      assert persisted.status == :queued, "retry #{retry} must remain visibly queued"
      assert persisted.attempts == 0, "retry #{retry} must not consume an execution attempt"

      DateTime.add(now, 31, :second)
    end)

    # The failed placement asked for the Agent's Worker; its join wakes the Job.
    assert %Ankole.AgentWorkers.AgentWorker{wanted_until: %DateTime{}} =
             Repo.get_by!(Ankole.AgentWorkers.AgentWorker, agent_uid: agent.uid)
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

    assert {:ok, %Ankole.Sessions.CodexJob.Attempt{}} =
             admit_job(first_key,
               now: DateTime.add(first.queued_at, 1, :second)
             )

    assert_receive {:actor_lane, first_envelope}, 200

    assert {:ok, %Ankole.Sessions.CodexJob.Attempt{}} =
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

    assert {:ok, %Ankole.Sessions.CodexJob.Attempt{}} =
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

    assert %{status: :queued, attempts: 0} =
             BackgroundAgentJobs.get_job_for_agent(second_job.id, agent.uid)
  end

  test "worker capacity deferral does not claim an execution attempt" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, _worker} = admit_worker(route, %{capacity: %{"available_slots" => 0}})

    job = create_job!(agent.uid, "worker-capacity")
    session_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}

    assert {:ok, %{status: :waiting_for_worker}} =
             admit_job(session_key,
               now: DateTime.add(job.queued_at, 1, :second)
             )

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == :queued
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
        Ecto.Changeset.change(job, Ankole.Principals.WorkAccess.from_sender(human.uid))
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
             Ankole.Sessions.Context.resolve(agent.uid, key.session_id)

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
          Repo.transact(fn ->
            Ankole.Signals.accept_in_tx(%{
              producer: :kernel,
              target: %{agent_uid: agent.uid, session_id: key.session_id},
              source: "test:runtime",
              reply_route: %{binding_name: "control-plane:test"},
              sender: human.uid,
              id: Ecto.UUID.generate(),
              data: %{},
              type: type,
              available_at: DateTime.utc_now(:microsecond)
            })
          end)

        event
      end

    Repo.update!(Ecto.Changeset.change(human, access_version: human.access_version + 1))

    for event <- events do
      assert {:ok, %{status: :dead_letter}} = CodexJob.admit(key, event, [])
      rejected = Repo.reload!(event)
      assert rejected.dead_letter_reason["code"] == "human_access_revoked"
      assert rejected.last_attempt_at == nil
    end

    Ankole.DataCase.assert_persisted_equal(Repo.reload!(job), run.job)
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
      assert event.status == :queued
      assert event.completed_at == nil

      assert %{status: :queued, attempts: 1, execution_failures: ^expected_failures} =
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

  test "a rejected Ash transition preserves the real abort transaction's settlement and wakeup" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = admit_worker(route)
    job = create_job!(agent.uid, "ash-abort-compensation")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, first} = admit_job(key, now: DateTime.add(job.queued_at, 1, :second))
    assert_receive {:actor_lane, _}

    error = %{
      "code" => "worker_turn_failed",
      "message" => "The runtime rejected the task.",
      "details_json" => %{"error_code" => "task_failed", "retryable" => false}
    }

    assert {:ok, event} =
             Repo.transact(fn repo ->
               assert {:ok, :authorized} =
                        Ankole.AgentWorkers.WorkerRouteAuth.authorize_turn_in_tx(
                          first.job_ref,
                          agent.uid,
                          :terminal
                        )

               running = repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, job.id)
               assert {:error, _} = Ankole.Ash.update(running, :claim_attempt, %{})

               BackgroundAgentJobs.abort_attempt_in_tx(
                 first.job_ref,
                 agent.uid,
                 error,
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert event.status == :dead_letter
    assert Repo.get!(Signal, event.id).status == :dead_letter
    assert Repo.reload!(job).status == :failed

    assert Repo.exists?(
             from signal in Signal,
               where:
                 signal.agent_uid == ^agent.uid and signal.type == "background_agent_job.failed"
           )

    assert_enqueued(
      worker: Ankole.Sessions.Jobs.EnsureDriver,
      args: %{agent_uid: agent.uid, session_id: key.session_id}
    )
  end

  test "an unavailable profile settles an unstarted Job without creating a Worker" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "missing-profile")
    principal_agent = Repo.get_by!(Ankole.Principals.Agent, uid: agent.uid)

    Repo.update!(
      change(principal_agent,
        options: Map.put(principal_agent.options, "ai_agent", %{"models" => %{}})
      )
    )

    event =
      Repo.get_by!(Signal,
        session_id: BackgroundAgentJobs.job_session_id(job.id),
        type: "background_agent_job.dispatch"
      )

    key = %{agent_uid: agent.uid, session_id: event.session_id}

    Ankole.SessionsCase.stub_driver(%{
      agent_uid: agent.uid,
      session_id: job.owner_session_id
    })

    assert {:ok, %{status: :failed}} = Admission.admit(key, event)
    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).status == :failed
    assert %Signal{producer: :kernel, completed_at: %DateTime{}} = Repo.get!(Signal, event.id)
    assert Repo.get_by!(AgentWorker, agent_uid: agent.uid).state == :absent

    wakeup =
      Repo.get_by!(Signal,
        agent_uid: agent.uid,
        session_id: job.owner_session_id,
        type: "background_agent_job.failed"
      )

    assert :ok =
             Ankole.Sessions.Jobs.EnsureDriver.run(%Oban.Job{
               args: %{"agent_uid" => agent.uid, "session_id" => wakeup.session_id}
             })

    assert_receive :reconcile_inbox
  end

  test "a start with a missing owner conversation fails before reserving or claiming" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, worker} = admit_worker(route)
    job = create_job!(agent.uid, "missing-owner")
    Repo.delete!(Repo.get!(Conversation, job.metadata["owner_conversation_id"]))

    event =
      Repo.get_by!(Signal,
        session_id: BackgroundAgentJobs.job_session_id(job.id),
        type: "background_agent_job.dispatch"
      )

    key = %{agent_uid: agent.uid, session_id: event.session_id}
    assert {:ok, %{status: :dead_letter}} = Admission.admit(key, event)
    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == :failed
    assert persisted.attempts == 0
    assert Repo.get!(Signal, event.id).status == :dead_letter
    assert Repo.get_by!(AgentWorker, agent_uid: agent.uid).capacity == worker.capacity
  end

  test "a queued Job (including requeued attempts >= 1) fails when Worker ready timeout expires" do
    %{principal: agent} = agent_fixture()

    for {suffix, initial_attempts} <- [{"timeout-unstarted", 0}, {"timeout-requeued", 1}] do
      job = create_job!(agent.uid, suffix)

      if initial_attempts > 0 do
        Repo.update!(Ecto.Changeset.change(job, attempts: initial_attempts))
      end

      session_key = %{
        agent_uid: agent.uid,
        session_id: BackgroundAgentJobs.job_session_id(job.id)
      }

      t0 = job.queued_at

      assert {:ok, %{status: :waiting_for_worker, reason: :agent_worker_unavailable}} =
               admit_job(session_key, now: t0, ready_timeout_ms: 60_000)

      persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
      assert persisted.status == :queued
      assert persisted.worker_wait_started_at == t0

      assert {:ok,
              %{status: :dead_letter, wakeup_event: %Signal{type: "background_agent_job.failed"}}} =
               admit_job(session_key,
                 now: DateTime.add(t0, 61, :second),
                 ready_timeout_ms: 60_000
               )

      failed = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
      assert failed.status == :failed
      assert failed.error["code"] == "agent_worker_unavailable"
      assert failed.worker_wait_started_at == nil
    end
  end

  test "a waiting_on_user Job stays waiting_on_user and emits input_undeliverable when steer hits Worker ready timeout" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "waiting-steer-timeout")
    session_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    t0 = DateTime.add(job.queued_at, 1, :second)

    dispatch =
      Repo.get_by!(Signal,
        session_id: session_key.session_id,
        type: "background_agent_job.dispatch"
      )

    {:ok, _} =
      Repo.transact(fn -> Ankole.Sessions.Queue.mark_event_completed_in_tx(dispatch, t0) end)

    Repo.update!(
      Ecto.Changeset.change(job,
        status: :waiting_on_user,
        attempts: 1,
        started_at: t0,
        runtime_thread_id: "thread-waiting"
      )
    )

    assert {:ok, %{command_event: steer}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => agent.uid,
               "request_id" => "req-waiting-steer",
               "message" => "Here is the requested input."
             })

    assert {:ok, %{status: :waiting_for_worker, reason: :agent_worker_unavailable}} =
             admit_job(session_key, now: t0, ready_timeout_ms: 60_000)

    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).worker_wait_started_at == t0

    assert {:ok,
            %{
              status: :dead_letter,
              signal: dead_steer,
              wakeup_event: %Signal{type: "background_agent_job.input_undeliverable"} = wakeup
            }} =
             admit_job(session_key,
               now: DateTime.add(t0, 61, :second),
               ready_timeout_ms: 60_000
             )

    assert dead_steer.id == steer.id
    assert dead_steer.status == :dead_letter
    assert wakeup.session_id == job.owner_session_id

    preserved = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert preserved.status == :waiting_on_user
    assert preserved.worker_wait_started_at == nil
  end

  test "worker capacity wait clears worker_wait_started_at and does not count against ready_timeout_ms" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "capacity-clears-wait")
    session_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    t0 = job.queued_at

    assert {:ok, %{status: :waiting_for_worker, reason: :agent_worker_unavailable}} =
             admit_job(session_key, now: t0, ready_timeout_ms: 60_000)

    assert BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid).worker_wait_started_at == t0

    route = unique_route()
    assert {:ok, _worker} = admit_worker(route, %{capacity: %{"available_slots" => 0}})

    assert {:ok, %{status: :waiting_for_worker, reason: :no_worker_capacity}} =
             admit_job(session_key,
               now: DateTime.add(t0, 120, :second),
               ready_timeout_ms: 60_000
             )

    persisted = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
    assert persisted.status == :queued
    assert persisted.worker_wait_started_at == nil
  end

  test "full Agent capacity preserves an old wait and does not start a new wait until a slot is free" do
    assert {:ok, 1} =
             Ankole.AppConfigure.put_tenant_by_key(
               "background_agent_jobs.max_running_per_agent",
               1
             )

    %{principal: agent} = agent_fixture()
    waiting = create_job!(agent.uid, "old-capacity-wait")
    fresh = create_job!(agent.uid, "new-capacity-wait")
    blocker = create_job!(agent.uid, "capacity-blocker")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(waiting.id)}
    fresh_key = %{key | session_id: BackgroundAgentJobs.job_session_id(fresh.id)}
    blocker_key = %{key | session_id: BackgroundAgentJobs.job_session_id(blocker.id)}
    t0 = DateTime.add(blocker.queued_at, 1, :second)

    assert {:ok, %{reason: :agent_worker_unavailable}} =
             admit_job(key, now: t0, ready_timeout_ms: 60_000)

    route = unique_route()
    assert {:ok, _worker} = admit_worker(route)
    assert {:ok, %{event: event}} = CodexJob.rebuild(blocker_key, t0)
    assert {:ok, %CodexJob.Attempt{}} = Admission.admit(blocker_key, event, now: t0)

    assert {:ok, :marked_stale} =
             AgentWorkers.WorkerAdmission.mark_route_unusable(route, :socket_closed)

    after_timeout = DateTime.add(t0, 120, :second)

    for {job, session_key, started_at} <- [{waiting, key, t0}, {fresh, fresh_key, nil}] do
      assert {:ok, %{reason: :agent_worker_unavailable, retry_at: retry_at}} =
               admit_job(session_key, now: after_timeout, ready_timeout_ms: 60_000)

      assert retry_at == DateTime.add(after_timeout, 30, :second)

      assert %{status: :queued, attempts: 0, worker_wait_started_at: ^started_at} =
               Repo.reload!(job)
    end

    assert {:ok, %{job: %{status: :stopped}}} =
             BackgroundAgentJobs.request_stop(blocker.id, %{"agent_uid" => agent.uid})

    assert {:ok, %{status: :dead_letter}} =
             admit_job(key, now: after_timeout, ready_timeout_ms: 60_000)

    assert %{status: :failed, attempts: 0} = Repo.reload!(waiting)

    assert {:ok, %{reason: :agent_worker_unavailable}} =
             admit_job(fresh_key, now: after_timeout, ready_timeout_ms: 60_000)

    assert %{status: :queued, attempts: 0, worker_wait_started_at: ^after_timeout} =
             Repo.reload!(fresh)
  end

  test "an expired Worker wait cannot fail a Signal before its business deadline" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "expired-wait-not-due")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    t0 = job.queued_at

    assert {:ok, %{reason: :agent_worker_unavailable, signal: event}} =
             admit_job(key, now: t0, ready_timeout_ms: 60_000)

    due = DateTime.add(t0, 120, :second)
    Repo.update!(Ecto.Changeset.change(event, available_at: due))

    assert {:ok, %{status: :deferred, retry_at: ^due}} =
             admit_job(key, now: DateTime.add(t0, 61, :second), ready_timeout_ms: 60_000)

    assert %{status: :queued, attempts: 0, worker_wait_started_at: ^t0} = Repo.reload!(job)

    assert {:ok, %{status: :dead_letter}} =
             admit_job(key, now: due, ready_timeout_ms: 60_000)

    assert Repo.reload!(job).status == :failed
  end

  test "a ready Worker clears a Job wait even while Agent capacity is full" do
    assert {:ok, 1} =
             Ankole.AppConfigure.put_tenant_by_key(
               "background_agent_jobs.max_running_per_agent",
               1
             )

    %{principal: agent} = agent_fixture()
    waiting = create_job!(agent.uid, "ready-capacity-wait")
    blocker = create_job!(agent.uid, "ready-capacity-blocker")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(waiting.id)}
    blocker_key = %{key | session_id: BackgroundAgentJobs.job_session_id(blocker.id)}
    t0 = DateTime.add(blocker.queued_at, 1, :second)

    assert {:ok, %{reason: :agent_worker_unavailable}} =
             admit_job(key, now: t0, ready_timeout_ms: 60_000)

    assert {:ok, worker} = admit_worker(unique_route())
    assert {:ok, %{event: event}} = CodexJob.rebuild(blocker_key, t0)
    assert {:ok, %CodexJob.Attempt{}} = Admission.admit(blocker_key, event, now: t0)
    slots = Repo.get_by!(Ankole.AgentWorkers.AgentWorker, agent_uid: worker.agent_uid).capacity

    assert {:ok, %{reason: :background_agent_job_agent_at_capacity}} =
             admit_job(key, now: DateTime.add(t0, 120, :second), ready_timeout_ms: 60_000)

    assert %{status: :queued, attempts: 0, worker_wait_started_at: nil} = Repo.reload!(waiting)

    assert Repo.get_by!(Ankole.AgentWorkers.AgentWorker, agent_uid: worker.agent_uid).capacity ==
             slots
  end

  test "a running Job delivers fresh human mail and rejects revoked mail under ordered locks" do
    %{principal: agent} = agent_fixture()
    %{principal: allowed} = Ankole.PrincipalsFixtures.human_fixture()
    %{principal: revoked} = Ankole.PrincipalsFixtures.human_fixture()
    route = unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)
    job = create_job!(agent.uid, "human-mailbox")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, run} = admit_job(key, now: DateTime.add(job.queued_at, 1, :second))
    assert_receive {:actor_lane, _start}

    [allowed_event, revoked_event] =
      for human <- [allowed, revoked] do
        assert {:ok, event} =
                 Repo.transact(fn ->
                   Ankole.Signals.accept_in_tx(%{
                     producer: :kernel,
                     target: key,
                     source: "test:runtime",
                     reply_route: %{binding_name: "control-plane:test"},
                     sender: human.uid,
                     id: Ecto.UUID.generate(),
                     data: %{},
                     type: "command.steer",
                     available_at: DateTime.utc_now(:microsecond)
                   })
                 end)

        assert event.authorization_kind == "human"
        assert event.last_attempt_at == nil
        event
      end

    Repo.update!(Ecto.Changeset.change(revoked, access_version: revoked.access_version + 1))
    assert :ok = CodexJob.mailbox(run)
    assert_receive {:actor_lane, %{body: {:mailbox_updated, mailbox}}}
    assert mailbox.signal.signal_id == allowed_event.id
    assert mailbox.turn == JobTurnRef.to_proto(run.job_ref)
    refute_receive {:actor_lane, %{body: {:mailbox_updated, _}}}
    assert Repo.reload!(allowed_event).last_attempt_at
    assert Repo.reload!(revoked_event).status == :dead_letter
    assert Repo.reload!(revoked_event).last_attempt_at == nil
  end

  test "admission rechecks the queue head and its durable due time before committing a claim" do
    %{principal: agent} = agent_fixture()
    route = unique_route()
    assert {:ok, worker} = admit_worker(route)
    job = create_job!(agent.uid, "future-head")
    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, %{event: snapshot}} = CodexJob.rebuild(key)
    now = DateTime.utc_now(:microsecond)
    due = DateTime.add(now, 300)
    event = Repo.update!(Ecto.Changeset.change(snapshot, available_at: due))

    assert {:ok, %{status: :deferred, signal: deferred, retry_at: ^due}} =
             Admission.admit(key, snapshot, now: now)

    assert deferred.id == event.id
    assert Repo.reload!(job).status == :queued
    assert Repo.reload!(job).attempts == 0

    assert Repo.get_by!(Ankole.AgentWorkers.AgentWorker, agent_uid: worker.agent_uid).capacity ==
             worker.capacity

    refute Repo.get_by(Ankole.Sessions.SessionWorkspace, key)

    assert {:ok, %{command_event: later}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => agent.uid,
               "request_id" => "later-command",
               "message" => "A later command must not pass the scheduled head."
             })

    assert {:error, :input_unavailable} = Admission.admit(key, later, now: now)
    assert Repo.reload!(job).attempts == 0
    assert {:ok, %{job_mode: "start"}} = Admission.admit(key, event, now: due)
    assert Repo.reload!(job).attempts == 1
  end

  @tag sandbox: false
  test "observe reports disconnected while stale and JobDriver immediately adopts on reconnect" do
    %{principal: agent} = agent_fixture()
    route_1 = unique_route()
    route_2 = unique_route()
    :ok = WorkerRoute.register_local_worker(route_1, self())
    :ok = WorkerRoute.register_local_worker(route_2, self())

    on_exit(fn ->
      WorkerRoute.unregister_local_worker(route_1)
      WorkerRoute.unregister_local_worker(route_2)
    end)

    assert {:ok, _worker_1} = admit_worker(route_1, %{incarnation_id: "incarnation-same"})

    source_signal_id = Ankole.WorkFixtures.service_source(agent.uid).id

    assert {:ok, %{job: job}} =
             Repo.transact_top_level(fn ->
               Ankole.BackgroundAgentJobs.Dispatch.create_with_dispatch_in_tx(%{
                 "source_signal_id" => source_signal_id,
                 "agent_uid" => agent.uid,
                 "owner_session_id" => "owner-session-rapid-reconnect",
                 "source_tool_call_id" => "tool-background-agent-job-rapid-reconnect",
                 "title" => "Job rapid reconnect",
                 "task" => "Complete job across rapid stale reconnect.",
                 "reply_route" => %{
                   "binding_name" => "bot",
                   "conversation_id" =>
                     Ankole.ExternalConversationsFixtures.external_conversation_id(
                       "chat-rapid-reconnect"
                     )
                 }
               })
             end)

    key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    driver_pid = start_supervised!({Ankole.Sessions.JobDriver, {key, Repo.tenant_id!()}})

    assert_receive {:actor_lane, initial_start}, 15_000
    initial_payload = turn_start_payload!(initial_start)
    assert initial_payload.mode == "start"
    assert initial_payload.turn.job_id == job.id
    assert initial_payload.turn.attempt == 1

    {:starting,
     %{
       attempt:
         %CodexJob.Attempt{
           job_worker: %AgentWorker{
             transport_route: ^route_1,
             incarnation_id: "incarnation-same"
           }
         } = run_snapshot
     }} = :sys.get_state(driver_pid)

    WorkerRoute.unregister_local_worker(route_1)

    assert {:ok, :marked_stale} =
             Ankole.AgentWorkers.WorkerAdmission.mark_route_unusable(route_1, :socket_closed)

    assert {:ok, :disconnected} = CodexJob.observe(run_snapshot)
    refute_receive {:actor_lane, _}, 50

    assert {:ok, _worker_2} = admit_worker(route_2, %{incarnation_id: "incarnation-same"})

    assert {:ok,
            {:adopt,
             %AgentWorker{
               transport_route: ^route_2,
               incarnation_id: "incarnation-same"
             }}} = CodexJob.observe(run_snapshot)

    assert_receive {:actor_lane, adopt_start}, 5_000
    adopt_payload = turn_start_payload!(adopt_start)
    assert adopt_payload.mode == "adopt"
    assert adopt_payload.turn.job_id == job.id
    assert adopt_payload.turn.attempt == 1
  end

  defp admit_job(key, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case CodexJob.rebuild(key, now) do
      {:ok, %{event: event}} ->
        case Admission.admit(key, event, opts) do
          {:ok, %Ankole.Sessions.CodexJob.Attempt{} = run} ->
            assert {:ok, _} = CodexJob.start(run)
            {:ok, run}

          result ->
            result
        end

      result ->
        result
    end
  end

  defp admit_device_binding!(spec, runner_id, route) do
    assert {:ok, binding} =
             AgentWorkers.admit_join(
               %{incarnation_id: "device-" <> route, max_slots: 1, available_slots: 1},
               %{
                 transport_route: route,
                 worker_id: spec.agent_uid,
                 runner_id: runner_id,
                 generation: spec.generation
               }
             )

    binding
  end

  defp create_device_job!(uid, creator, runner_id, suffix) do
    assert {:ok, value} =
             create_job_with_stub_driver(%{
               "agent_uid" => uid,
               "created_by" => creator,
               "runner_id" => runner_id,
               "owner_session_id" => "owner-session-#{suffix}-job",
               "source_tool_call_id" => "tool-#{suffix}-job",
               "title" => "Device Job #{suffix}",
               "task" => "Run the analysis on the selected device.",
               "reply_route" => %{"binding_name" => "bot"}
             })

    value
  end

  defp create_job!(agent_uid, suffix) do
    assert {:ok, %{job: job}} =
             create_job_with_stub_driver(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
               "agent_uid" => agent_uid,
               "owner_session_id" => "owner-session-#{suffix}",
               "source_tool_call_id" => "tool-background-agent-job-#{suffix}",
               "title" => "Job #{suffix}",
               "task" => "Complete job #{suffix}.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "conversation_id" =>
                   Ankole.ExternalConversationsFixtures.external_conversation_id("chat-#{suffix}")
               }
             })

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
