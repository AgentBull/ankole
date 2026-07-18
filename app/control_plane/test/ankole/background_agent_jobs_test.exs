defmodule Ankole.BackgroundAgentJobsTest do
  use Ankole.AIGatewayCase

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Text
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.Repo

  require Ankole.BackgroundAgentJobs

  describe "job session identity" do
    test "job_session_id/1 pins the persisted wire format" do
      job_id = Ecto.UUID.generate()

      assert BackgroundAgentJobs.job_session_id(job_id) == "job:" <> job_id
      assert BackgroundAgentJobs.job_session_prefix() == "job:"
    end

    test "parse_job_session_id/1 round-trips built ids and rejects everything else" do
      job_id = Ecto.UUID.generate()
      session_id = BackgroundAgentJobs.job_session_id(job_id)

      assert BackgroundAgentJobs.parse_job_session_id(session_id) == {:ok, job_id}

      for other <- ["job:", "job", "", job_id, "signal-channel:lark:oc_1", nil, :job] do
        assert BackgroundAgentJobs.parse_job_session_id(other) == :error
      end
    end

    test "is_job_session_id/1 agrees with parse_job_session_id/1" do
      values = [
        BackgroundAgentJobs.job_session_id(Ecto.UUID.generate()),
        "job:",
        "job",
        "",
        Ecto.UUID.generate(),
        "signal-channel:lark:oc_1",
        nil
      ]

      for value <- values do
        assert BackgroundAgentJobs.is_job_session_id(value) ==
                 match?({:ok, _job_id}, BackgroundAgentJobs.parse_job_session_id(value))
      end
    end
  end

  test "bounded trajectory excerpts preserve valid UTF-8 at both ends" do
    excerpt = Text.truncate_utf8_window("开" <> String.duplicate("大", 100) <> "终", 64)

    assert String.valid?(excerpt)
    assert byte_size(excerpt) <= 64
    assert String.starts_with?(excerpt, "开")
    assert String.ends_with?(excerpt, "终")
    assert excerpt =~ "[truncated]"
  end

  test "Turn changesets validate concrete progress and official usage snapshots" do
    now = DateTime.utc_now(:microsecond)

    attrs = %{
      job_id: Ecto.UUID.generate(),
      attempt: 1,
      runtime_thread_id: "thread-schema",
      runtime_turn_id: "turn-schema",
      kind: "agent",
      status: "completed",
      revision: 1,
      trajectory: trajectory([assistant_message("complete")]),
      progress: %{
        "completed_items" => 2,
        "tool_calls" => 1,
        "tools_used" => [%{"name" => "shell", "calls" => 1}],
        "files_changed" => ["a.ts"],
        "plan" => %{
          "steps" => [%{"step" => "Run tests", "status" => "completed"}]
        }
      },
      usage: usage_snapshot(21),
      error: %{},
      started_at: now,
      completed_at: now
    }

    assert Turn.changeset(%Turn{}, attrs).valid?
    assert Turn.changeset(%Turn{}, %{attrs | usage: nil}).valid?

    refute Turn.changeset(%Turn{}, %{attrs | usage: %{}}).valid?

    invalid_progress =
      put_in(attrs, [:progress], %{
        "completed_items" => -1,
        "tool_calls" => 2,
        "tools_used" => [%{"name" => "shell", "calls" => 1}],
        "files_changed" => ["b.ts", "a.ts"],
        "plan" => %{"steps" => [%{"step" => "Run tests", "status" => "started"}]}
      })

    refute Turn.changeset(%Turn{}, invalid_progress).valid?
  end

  test "forward migration installs the runtime snapshot columns and removes activity timestamps" do
    columns =
      Repo.query!("""
      SELECT column_name, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_schema = current_schema()
        AND table_name = 'background_agent_job_turns'
        AND column_name IN ('progress', 'usage', 'last_activity_at')
      ORDER BY column_name
      """).rows

    assert [
             ["progress", "NO", progress_default],
             ["usage", "YES", nil]
           ] = columns

    assert progress_default =~ "completed_items"

    assert [["background_agent_job_turns_progress_object"]] =
             Repo.query!("""
             SELECT constraint_name
             FROM information_schema.table_constraints
             WHERE table_schema = current_schema()
               AND table_name = 'background_agent_job_turns'
               AND constraint_name = 'background_agent_job_turns_progress_object'
             """).rows
  end

  test "create_with_dispatch durably creates one queued work item and one isolated dispatch event" do
    %{principal: agent} = agent_fixture()

    attrs = %{
      "agent_uid" => agent.uid,
      "owner_session_id" => "parent-session",
      "source_tool_call_id" => "tool-background-agent-job-1",
      "title" => "Prepare the launch brief",
      "task" =>
        "\n  Read the source material, write the brief, and verify every acceptance criterion.  \n",
      "background" => "The brief is for the operations team.",
      "notes" => "Keep the handoff concise.",
      "reply_route" => %{
        "binding_name" => "lark",
        "signal_channel_id" => "chat-1",
        "provider_thread_id" => "thread-1",
        "source_entry_id" => "message-1"
      }
    }

    assert {:ok, %{job: %Job{} = job, dispatch_event: %ActorEvent{} = event}} =
             BackgroundAgentJobs.create_with_dispatch(attrs)

    assert job.status == "queued"
    assert job.attempts == 0
    assert job.title == attrs["title"]
    assert job.task == attrs["task"]
    assert job.background == attrs["background"]
    assert job.notes == attrs["notes"]
    assert job.reply_route == attrs["reply_route"]
    assert job.agent_plugin_ids == []
    assert is_list(job.skill_names)

    assert [workspace] = job.workspace_mounts
    assert workspace["id"] == "workspace"
    assert workspace["access"] == "read_write"

    assert workspace["source"] ==
             "/workspace/user-files/background-agent-jobs/#{job.id}/workspace"

    assert event.agent_uid == agent.uid
    assert event.binding_name == "lark"
    assert event.session_id == BackgroundAgentJobs.job_session_id(job.id)
    assert event.signal_channel_id == "chat-1"
    assert event.provider_thread_id == "thread-1"
    assert event.source_entry_id == nil
    assert event.type == "background_agent_job.dispatch"
    assert event.source_event_id == "background_agent_job:#{job.id}:dispatch"

    assert get_in(event.payload, ["data", "job_id"]) == job.id
    assert get_in(event.payload, ["data", "owner_session_id"]) == "parent-session"
    assert get_in(event.payload, ["data", "agent_plugin_ids"]) == []
    assert get_in(event.payload, ["data", "workspace_mounts"]) == job.workspace_mounts
    assert get_in(event.payload, ["data", "attempts"]) == 0
    refute inspect(event.payload) =~ attrs["task"]

    assert {:ok, %{job: same_job, dispatch_event: same_event}} =
             BackgroundAgentJobs.create_with_dispatch(attrs)

    assert same_job.id == job.id
    assert same_event.id == event.id
    assert Repo.aggregate(Job, :count) == 1
    assert Repo.aggregate(ActorEvent, :count) == 1
  end

  test "start replay returns the original dispatch after attempts and lifecycle state change" do
    %{principal: agent} = agent_fixture()

    attrs = %{
      "agent_uid" => agent.uid,
      "owner_session_id" => "parent-session-replay",
      "source_tool_call_id" => "tool-replay",
      "title" => "Replay-safe Job",
      "task" => "Do the work once.",
      "reply_route" => %{"binding_name" => "lark"}
    }

    assert {:ok, %{job: original, dispatch_event: dispatch}} =
             BackgroundAgentJobs.create_with_dispatch(attrs)

    for {status, attempts} <- [
          {"queued", 3},
          {"running", 4},
          {"waiting_on_user", 5},
          {"succeeded", 6},
          {"failed", 7},
          {"stopped", 8}
        ] do
      from(row in Job, where: row.id == ^original.id)
      |> Repo.update_all(set: [status: status, attempts: attempts])

      assert {:ok, %{job: replayed, dispatch_event: replayed_dispatch}} =
               BackgroundAgentJobs.create_with_dispatch(attrs)

      assert replayed.id == original.id
      assert replayed.status == status
      assert replayed.attempts == attempts
      assert replayed_dispatch.id == dispatch.id
      assert replayed_dispatch.source_event_id == "background_agent_job:#{original.id}:dispatch"
    end

    assert Repo.aggregate(Job, :count) == 1
    assert Repo.aggregate(ActorEvent, :count) == 1
  end

  test "concurrent starts converge on one Job and one dispatch" do
    %{principal: agent} = agent_fixture()

    attrs = %{
      "agent_uid" => agent.uid,
      "owner_session_id" => "parent-session-concurrent-start",
      "source_tool_call_id" => "tool-concurrent-start",
      "title" => "Concurrent start",
      "task" => "Create exactly one Job.",
      "reply_route" => %{"binding_name" => "lark"}
    }

    results =
      1..8
      |> Task.async_stream(
        fn _index -> BackgroundAgentJobs.create_with_dispatch(attrs) end,
        max_concurrency: 8,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert results |> Enum.map(& &1.job.id) |> Enum.uniq() |> length() == 1
    assert results |> Enum.map(& &1.dispatch_event.id) |> Enum.uniq() |> length() == 1
    assert Repo.aggregate(Job, :count) == 1
    assert Repo.aggregate(ActorEvent, :count) == 1
  end

  test "Agent Plugin selection stores only ids and idempotent replay ignores later disablement" do
    %{principal: agent} = agent_fixture()

    attrs = %{
      "agent_uid" => agent.uid,
      "owner_session_id" => "parent-session-research",
      "source_tool_call_id" => "tool-deep-research",
      "agent_plugin_ids" => ["deep-research"],
      "title" => "Research the policy change",
      "task" => "Produce a cited research report.",
      "reply_route" => %{"binding_name" => "lark"}
    }

    assert {:ok, %{job: research}} =
             BackgroundAgentJobs.create_with_dispatch(attrs)

    assert research.agent_plugin_ids == ["deep-research"]
    refute "deep-research" in research.skill_names

    assert {:ok, _override} =
             AgentPlugins.set_agent_override(agent.uid, "deep-research", false)

    assert {:ok, %{job: retried}} =
             BackgroundAgentJobs.create_with_dispatch(attrs)

    assert retried.id == research.id
    assert retried.agent_plugin_ids == ["deep-research"]
  end

  test "success requires a completed lead Turn but does not gate on Codex child Turn state" do
    %{principal: agent} = agent_fixture()

    assert {:ok, %{job: research}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => "parent-session-trajectory-gate",
               "source_tool_call_id" => "tool-trajectory-gate",
               "agent_plugin_ids" => ["deep-research"],
               "title" => "Research with a durable trajectory",
               "task" => "Produce the report.",
               "reply_route" => %{"binding_name" => "lark"}
             })

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(research.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-trajectory"
             })

    running = running |> Ecto.Changeset.change(attempts: 1) |> Repo.update!()

    assert {:error, :background_agent_job_turn_trajectory_incomplete} =
             BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "must wait for the Turn"}
             })

    active_child =
      insert_turn!(running, 1, "thread-child", "turn-child-active", "in_progress")

    turn = insert_turn!(running, 1, "thread-trajectory", "turn-trajectory", "completed")

    assert {:ok, %{job: succeeded}} =
             BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "Lead Turn verified"}
             })

    assert succeeded.status == "succeeded"
    assert turn.status == "completed"
    assert turn.trajectory["format"] == "ankole_chatml"
    assert Repo.reload!(active_child).status == "in_progress"
  end

  test "success cannot bypass the current-attempt trajectory by omitting the runtime thread anchor" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "trajectory-gate-without-anchor")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running"
             })

    assert {:error, :background_agent_job_turn_trajectory_incomplete} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "attempt zero must not bypass the trajectory"}
             })

    _running = set_attempts!(running, 1)

    assert {:error, :background_agent_job_turn_trajectory_incomplete} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "must not bypass trajectory persistence"}
             })
  end

  test "waiting requires the interrupted Turn that contains the pending user-input request" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "waiting-trajectory-gate")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-waiting-trajectory-gate"
             })

    assert {:error, :background_agent_job_turn_trajectory_incomplete} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    _running = set_attempts!(running, 1)

    assert {:error, :background_agent_job_turn_trajectory_incomplete} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    _completed =
      insert_turn!(
        job,
        1,
        "thread-waiting-trajectory-gate",
        "turn-completed-without-question",
        "completed"
      )

    assert {:error, :background_agent_job_turn_trajectory_incomplete} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    interrupted =
      insert_turn!(
        job,
        1,
        "thread-waiting-trajectory-gate",
        "turn-interrupted-without-question",
        "interrupted"
      )

    assert {:error, :background_agent_job_turn_trajectory_incomplete} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    interrupted
    |> Turn.changeset(%{
      revision: interrupted.revision + 1,
      error: %{"code" => "request_user_input"},
      trajectory: request_user_input_trajectory(false)
    })
    |> Repo.update!()

    _child_question =
      insert_waiting_turn!(
        job,
        1,
        "thread-waiting-child",
        "turn-interrupted-with-question"
      )

    assert {:error, :background_agent_job_turn_trajectory_incomplete} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    interrupted = Repo.reload!(interrupted)

    interrupted
    |> Turn.changeset(%{
      revision: interrupted.revision + 1,
      trajectory: request_user_input_trajectory()
    })
    |> Repo.update!()

    assert {:ok, %{job: %{status: "waiting_on_user"}}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })
  end

  test "waiting cannot close an attempt while one of its runtime Turns is active" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "waiting-turn-gate")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-waiting-gate"
             })

    running = running |> Ecto.Changeset.change(attempts: 1) |> Repo.update!()

    active =
      insert_turn!(
        running,
        1,
        "thread-waiting-gate",
        "turn-waiting-gate",
        "in_progress"
      )

    assert {:error, :background_agent_job_turn_trajectory_incomplete} =
             BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    now = DateTime.utc_now(:microsecond)

    active
    |> Turn.changeset(%{
      status: "interrupted",
      revision: active.revision + 1,
      trajectory: request_user_input_trajectory(),
      error: %{"code" => "request_user_input"},
      completed_at: now
    })
    |> Repo.update!()

    assert {:ok, %{job: %{status: "waiting_on_user"}}} =
             BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })
  end

  test "creation rejects workspace mounts outside /workspace before journaling work" do
    %{principal: agent} = agent_fixture()

    assert {:error, {:invalid_workspace_mount_source, 0}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => "parent-session-invalid-workdir",
               "source_tool_call_id" => "tool-background-agent-job-invalid-workdir",
               "title" => "Invalid workdir",
               "task" => "This must never be dispatched.",
               "workspace_mounts" => [
                 %{
                   "id" => "workspace",
                   "source" => "/workspace/user-files/../../etc",
                   "access" => "read_write"
                 }
               ],
               "reply_route" => %{"binding_name" => "lark"}
             })

    assert Repo.aggregate(Job, :count) == 0
    assert Repo.aggregate(ActorEvent, :count) == 0
  end

  test "creation rejects caller-local task paths before journaling work" do
    %{principal: agent} = agent_fixture()

    for {task, path, index} <- [
          {"Read /workspace/user-files/inbox/report.pdf.", "/workspace/user-files", 1},
          {"Use /workspace/temp for intermediate pages.", "/workspace/temp", 2},
          {"Inspect /workspace/user-files, then report what exists.", "/workspace/user-files", 3}
        ] do
      assert {:error, {:background_agent_job_caller_local_task_path, message}} =
               BackgroundAgentJobs.create_with_dispatch(%{
                 "agent_uid" => agent.uid,
                 "owner_session_id" => "parent-session-invalid-task-path-#{index}",
                 "source_tool_call_id" => "tool-background-agent-job-invalid-task-path-#{index}",
                 "title" => "Invalid task path",
                 "task" => task,
                 "reply_route" => %{"binding_name" => "lark"}
               })

      assert message =~ path
      assert message =~ "workspace_mounts"
      assert message =~ "/workspace/workspaces/<mount-id>/"
    end

    assert Repo.aggregate(Job, :count) == 0
    assert Repo.aggregate(ActorEvent, :count) == 0

    attrs = %{
      "agent_uid" => agent.uid,
      "owner_session_id" => "parent-session-near-task-path",
      "source_tool_call_id" => "tool-background-agent-job-near-task-path",
      "title" => "Valid private directory",
      "task" => "Create /workspace/user-files-archive in the private Job project.",
      "reply_route" => %{"binding_name" => "lark"}
    }

    assert {:ok, %{job: %Job{} = job}} = BackgroundAgentJobs.create_with_dispatch(attrs)

    assert Repo.aggregate(Job, :count) == 1
    assert Repo.aggregate(ActorEvent, :count) == 1

    legacy_task = "Read the previously accepted input from /workspace/temp/legacy.txt."
    from(row in Job, where: row.id == ^job.id) |> Repo.update_all(set: [task: legacy_task])

    assert {:ok, %{job: replayed}} =
             attrs
             |> Map.put("task", legacy_task)
             |> BackgroundAgentJobs.create_with_dispatch()

    assert replayed.id == job.id
    assert replayed.task == legacy_task
    assert Repo.aggregate(Job, :count) == 1
    assert Repo.aggregate(ActorEvent, :count) == 1
  end

  test "status commits wake the parent only for waiting and result-bearing terminal states" do
    %{principal: agent} = agent_fixture()
    waiting = create_job!(agent.uid, "waiting")

    assert {:ok, %{job: running, wakeup_event: nil}} =
             BackgroundAgentJobs.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-waiting"
             })

    assert running.status == "running"
    running = set_attempts!(running, 1)

    _waiting_turn =
      insert_waiting_turn!(running, 1, "thread-waiting", "turn-waiting")

    pending_user_input = %{
      "questions" => [
        %{
          "id" => "audience",
          "header" => "Audience",
          "question" => "Who should this brief target?",
          "isOther" => true,
          "options" => [%{"label" => "Operators", "description" => "Console operators"}]
        }
      ]
    }

    assert {:ok, %{job: paused, wakeup_event: %ActorEvent{} = waiting_event}} =
             BackgroundAgentJobs.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => pending_user_input}
             })

    assert paused.status == "waiting_on_user"
    assert waiting_event.session_id == "parent-session-waiting"
    assert waiting_event.type == "background_agent_job.waiting"
    assert waiting_event.source_event_id == "background_agent_job:#{waiting.id}:waiting:1"
    assert get_in(waiting_event.payload, ["data", "pending_user_input"]) == pending_user_input

    assert {:ok, %{job: resumed, wakeup_event: nil}} =
             BackgroundAgentJobs.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "running"
             })

    assert resumed.status == "running"

    _completed_turn =
      insert_turn!(resumed, 1, "thread-waiting", "turn-resumed", "completed")

    assert {:ok, %{job: succeeded, wakeup_event: %ActorEvent{} = completed_event}} =
             BackgroundAgentJobs.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{
                 "summary" => "Launch brief written and verified.",
                 "project_path" =>
                   "/workspace/user-files/background-agent-jobs/#{waiting.id}/project",
                 "artifacts" => %{
                   "total_count" => 1,
                   "paths" => [
                     "/workspace/user-files/background-agent-jobs/#{waiting.id}/project/launch-brief.pdf"
                   ],
                   "truncated" => false
                 }
               }
             })

    assert succeeded.status == "succeeded"
    assert completed_event.type == "background_agent_job.completed"
    assert completed_event.source_event_id == "background_agent_job:#{waiting.id}:succeeded:1"

    assert get_in(completed_event.payload, ["data", "result_summary"]) ==
             "Launch brief written and verified."

    assert get_in(completed_event.payload, ["data", "project_path"]) ==
             "/workspace/user-files/background-agent-jobs/#{waiting.id}/project"

    assert get_in(completed_event.payload, ["data", "artifacts"]) == %{
             "total_count" => 1,
             "paths" => [
               "/workspace/user-files/background-agent-jobs/#{waiting.id}/project/launch-brief.pdf"
             ],
             "truncated" => false
           }

    failed = create_job!(agent.uid, "failed")

    assert {:ok, %{job: _running_failed}} =
             BackgroundAgentJobs.commit_status_with_wakeup(failed.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-failed"
             })

    assert {:ok, %{job: failed, wakeup_event: %ActorEvent{} = failed_event}} =
             BackgroundAgentJobs.commit_status_with_wakeup(failed.id, agent.uid, %{
               "status" => "failed",
               "error" => %{
                 "code" => "codex_turn_failed",
                 "summary" => "The provider disconnected."
               }
             })

    assert failed.status == "failed"
    assert failed_event.type == "background_agent_job.failed"
    assert get_in(failed_event.payload, ["data", "job_id"]) == failed.id
    assert get_in(failed_event.payload, ["data", "agent_plugin_ids"]) == []
    refute Map.has_key?(get_in(failed_event.payload, ["data"]), "workdir")

    stopped = create_job!(agent.uid, "stopped")

    assert {:ok, %{job: stopped, wakeup_event: nil}} =
             BackgroundAgentJobs.commit_status_with_wakeup(stopped.id, agent.uid, %{
               "status" => "stopped",
               "metadata" => %{"cancel_requested_by" => "operator:ding"}
             })

    assert stopped.status == "stopped"

    parent_wakeups =
      Repo.all(
        from event in ActorEvent,
          where:
            event.session_id in [
              "parent-session-waiting",
              "parent-session-failed",
              "parent-session-stopped"
            ],
          where:
            event.type in ^~w(background_agent_job.waiting background_agent_job.completed background_agent_job.failed)
      )

    assert Enum.map(parent_wakeups, & &1.type) |> Enum.sort() ==
             [
               "background_agent_job.completed",
               "background_agent_job.failed",
               "background_agent_job.waiting"
             ]
  end

  test "status and parent wakeup roll back together when the frozen reply route is invalid" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "invalid-route")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-invalid-route"
             })

    running = set_attempts!(running, 1)
    _turn = insert_turn!(running, 1, "thread-invalid-route", "turn-invalid-route", "completed")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [reply_route: %{}])

    assert {:error, :background_agent_job_reply_route_binding_missing} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "must not commit"}
             })

    persisted = Repo.get!(Job, job.id)
    assert persisted.status == running.status
    assert persisted.completed_at == nil

    refute Repo.exists?(
             from event in ActorEvent,
               where: event.session_id == ^job.owner_session_id,
               where: event.type == "background_agent_job.completed"
           )
  end

  test "stop is durable and idempotent while running work also receives an interrupt command" do
    %{principal: agent} = agent_fixture()
    queued = create_job!(agent.uid, "queued-stop")

    assert {:ok, %{job: stopped, command_event: nil}} =
             BackgroundAgentJobs.request_stop(queued.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:ding",
               "reason" => "No longer needed"
             })

    assert stopped.status == "stopped"
    assert stopped.metadata["cancel_requested_by"] == "operator:ding"

    dispatch =
      Repo.one!(
        from event in ActorEvent,
          where: event.session_id == ^BackgroundAgentJobs.job_session_id(queued.id),
          where: event.type == "background_agent_job.dispatch"
      )

    assert %DateTime{} = dispatch.completed_at

    assert {:ok, %{job: same_stopped, command_event: nil}} =
             BackgroundAgentJobs.request_stop(queued.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:ding"
             })

    assert same_stopped.id == stopped.id

    running = create_job!(agent.uid, "running-stop")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "running"
             })

    assert {:ok, %{job: running_stopped, command_event: %ActorEvent{} = stop_event}} =
             BackgroundAgentJobs.request_stop(running.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "agent:#{agent.uid}",
               "reason" => "Changed priorities",
               "request_id" => "stop-running-once"
             })

    assert running_stopped.status == "stopped"
    assert %DateTime{} = running_stopped.completed_at
    assert running_stopped.metadata["cancel_requested_by"] == "agent:#{agent.uid}"
    assert running_stopped.metadata["cancel_reason"] == "Changed priorities"
    assert stop_event.type == "command.stop"
    assert stop_event.session_id == BackgroundAgentJobs.job_session_id(running.id)
    assert stop_event.source_entry_id == nil
    assert get_in(stop_event.payload, ["data", "command", "argsText"]) == "Changed priorities"

    waiting = create_job!(agent.uid, "waiting-stop")

    assert {:ok, %{job: running_before_wait}} =
             BackgroundAgentJobs.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-waiting-stop"
             })

    assert running_before_wait.status == "running"
    running_before_wait = set_attempts!(running_before_wait, 1)

    _waiting_turn =
      insert_waiting_turn!(
        running_before_wait,
        1,
        "thread-waiting-stop",
        "turn-waiting-stop"
      )

    assert {:ok, %{job: waiting}} =
             BackgroundAgentJobs.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    assert {:ok, %{job: waiting_stopped, command_event: nil}} =
             BackgroundAgentJobs.request_stop(waiting.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:ding"
             })

    assert waiting_stopped.status == "stopped"
    refute Map.has_key?(waiting_stopped.metadata, "pending_user_input")

    refute Repo.exists?(
             from event in ActorEvent,
               where: event.session_id == ^BackgroundAgentJobs.job_session_id(waiting.id),
               where: event.type == "command.stop"
           )
  end

  test "steer journals text and answers and list visibility is bounded by parent session or channel" do
    %{principal: agent} = agent_fixture()
    same_session = create_job!(agent.uid, "same-session")
    same_channel = create_job!(agent.uid, "same-channel")
    other_channel = create_job!(agent.uid, "other-channel")

    from(row in Job, where: row.id == ^same_channel.id)
    |> Repo.update_all(
      set: [
        owner_session_id: "historical-session",
        reply_route: %{"binding_name" => "lark", "signal_channel_id" => "chat-same-session"}
      ]
    )

    assert {:ok, %{job: ^same_session, command_event: %ActorEvent{} = steer_event}} =
             BackgroundAgentJobs.request_steer(same_session.id, %{
               "agent_uid" => agent.uid,
               "text" => "Use the operator audience.",
               "answers" => %{"audience" => "Operators"},
               "request_id" => "steer-same-session"
             })

    assert steer_event.source_entry_id == nil

    assert steer_event.type == "command.steer"

    assert get_in(steer_event.payload, ["data", "command", "argsText"]) ==
             "Use the operator audience."

    assert get_in(steer_event.payload, ["data", "command", "answers"]) == %{
             "audience" => "Operators"
           }

    listed =
      BackgroundAgentJobs.list_for_channel(
        agent.uid,
        same_session.owner_session_id,
        "chat-same-session"
      )

    assert Enum.map(listed, & &1.id) |> MapSet.new() ==
             MapSet.new([same_session.id, same_channel.id])

    refute Enum.any?(listed, &(&1.id == other_channel.id))
  end

  test "steer queues a settled job for continuation in its existing runtime thread" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "settled-continuation")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-settled-continuation"
             })

    running = set_attempts!(running, 1)
    _turn = insert_turn!(running, 1, "thread-settled-continuation", "turn-settled", "completed")

    assert {:ok, %{job: succeeded}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "Candidate result"}
             })

    assert {:ok, %{job: queued, command_event: %ActorEvent{} = steer_event}} =
             BackgroundAgentJobs.request_steer(succeeded.id, %{
               "agent_uid" => agent.uid,
               "text" => "Complete the missing artifacts.",
               "request_id" => "continue-settled"
             })

    assert queued.status == "queued"
    assert queued.runtime_thread_id == "thread-settled-continuation"
    assert queued.result == %{"summary" => "Candidate result"}
    assert queued.completed_at == nil
    assert steer_event.type == "command.steer"
  end

  test "claiming a continuation clears the answered parent input" do
    %{principal: agent} = agent_fixture()

    waiting =
      agent.uid
      |> create_job!("answered-parent-input")
      |> Job.changeset(%{
        status: "waiting_on_user",
        metadata: %{
          "pending_user_input" => %{"questions" => [%{"id" => "answer"}]},
          "worker_route" => "worker-a"
        }
      })
      |> Repo.update!()

    assert {:ok, resumed} =
             BackgroundAgentJobs.claim_continuation_in_tx(Repo, waiting.id, agent.uid, 1)

    assert resumed.status == "running"
    assert resumed.metadata == %{"worker_route" => "worker-a"}
  end

  test "status commits reject missing status and lifecycle regression" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "status-transition")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running"
             })

    assert {:error, :background_agent_job_status_missing} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "metadata" => %{"ignored" => true}
             })

    assert {:error, {:invalid_background_agent_job_status_transition, "running", "queued"}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "queued"
             })

    assert Repo.get!(Job, job.id).status == running.status
  end

  test "parent wakeup bounds artifacts and keeps their handoff after a long summary" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "bounded-wakeup")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-bounded-wakeup"
             })

    running = set_attempts!(running, 1)
    _turn = insert_turn!(running, 1, "thread-bounded-wakeup", "turn-bounded-wakeup", "completed")

    project_path = "/workspace/user-files/background-agent-jobs/#{job.id}/project"

    artifact_paths =
      for index <- 1..50_000 do
        "#{project_path}/report/artifact-#{index}.pdf"
      end

    changed_paths =
      for index <- 1..8 do
        "#{index}-#{String.duplicate("x", 3_000)}.tmp"
      end

    assert {:ok, %{job: succeeded, wakeup_event: wakeup}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{
                 summary: String.duplicate("大", 20_000),
                 project_path: project_path,
                 files_changed: %{
                   total_count: length(changed_paths),
                   paths: changed_paths,
                   truncated: false
                 },
                 artifacts: %{
                   total_count: length(artifact_paths),
                   paths: artifact_paths,
                   truncated: false
                 },
                 artifact_roots: %{
                   total_count: 2,
                   paths: [project_path, "/workspace/user-files/research-output"],
                   truncated: false
                 }
               }
             })

    summary = get_in(wakeup.payload, ["data", "result_summary"])
    assert String.valid?(summary)
    assert byte_size(summary) <= 16_384
    assert String.ends_with?(summary, "...[truncated]")

    handoff = get_in(wakeup.payload, ["data", "artifacts"])
    assert handoff == succeeded.result["artifacts"]
    assert handoff["total_count"] == 50_000
    assert length(handoff["paths"]) == 32
    assert hd(handoff["paths"]) == hd(artifact_paths)
    assert handoff["truncated"]
    assert byte_size(Ankole.JSON.encode!(handoff["paths"])) <= 8_192

    changed = succeeded.result["files_changed"]
    assert changed["total_count"] == length(changed_paths)
    assert length(changed["paths"]) < length(changed_paths)
    assert byte_size(Ankole.JSON.encode!(changed["paths"])) <= 8_192
    assert changed["truncated"]

    roots = succeeded.result["artifact_roots"]
    assert roots == get_in(wakeup.payload, ["data", "artifact_roots"])
    assert roots["total_count"] == 2
    assert roots["paths"] == [project_path, "/workspace/user-files/research-output"]
    refute roots["truncated"]

    assert get_in(wakeup.payload, ["data", "project_path"]) == project_path
    assert byte_size(Ankole.JSON.encode!(wakeup.payload)) <= 32_768
  end

  test "only normalized ankole_chatml trajectories can be stored as Turns" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "trajectory-shape")
    now = DateTime.utc_now(:microsecond)

    changeset =
      Turn.changeset(%Turn{}, %{
        job_id: job.id,
        attempt: 1,
        runtime_thread_id: "thread-shape",
        runtime_turn_id: "turn-shape",
        kind: "agent",
        status: "completed",
        revision: 1,
        trajectory: %{"method" => "item/agentMessage/delta", "delta" => "raw frame"},
        error: %{},
        started_at: now,
        completed_at: now
      })

    refute changeset.valid?

    assert %{trajectory: ["must be an ankole_chatml v1 object with a messages array"]} =
             errors_on(changeset)

    wrapped_event =
      Turn.changeset(%Turn{}, %{
        job_id: job.id,
        attempt: 1,
        runtime_thread_id: "thread-wrapped-event",
        runtime_turn_id: "turn-wrapped-event",
        kind: "agent",
        status: "completed",
        revision: 1,
        trajectory: %{
          "format" => "ankole_chatml",
          "version" => 1,
          "messages" => [
            %{"method" => "item/agentMessage/delta", "delta" => "raw frame"}
          ]
        },
        error: %{},
        started_at: now,
        completed_at: now
      })

    refute wrapped_event.valid?
    assert %{trajectory: [message]} = errors_on(wrapped_event)
    assert message =~ "ChatML message"

    oversized =
      Turn.changeset(%Turn{}, %{
        job_id: job.id,
        attempt: 1,
        runtime_thread_id: "thread-oversized",
        runtime_turn_id: "turn-oversized",
        kind: "agent",
        status: "completed",
        revision: 1,
        trajectory: %{
          "format" => "ankole_chatml",
          "version" => 1,
          "messages" => [
            %{"role" => "assistant", "content" => String.duplicate("x", 270_000)}
          ]
        },
        error: %{},
        started_at: now,
        completed_at: now
      })

    assert oversized.valid?
  end

  test "execution projection aggregates one attempt while paginating only lead agent semantic groups" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "execution-projection")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 1, runtime_thread_id: "thread-lead", status: "running"])

    job = Repo.get!(Job, job.id)
    base = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)

    insert_custom_turn!(job, %{
      runtime_thread_id: "thread-lead",
      runtime_turn_id: "turn-lead-1",
      started_at: base,
      status: "completed",
      completed_at: DateTime.add(base, 1, :microsecond),
      trajectory:
        trajectory([
          assistant_message("lead-old"),
          tool_call_message("shell-1", "shell"),
          tool_result_message("shell-1", "shell", "done")
        ]),
      progress: progress_snapshot(2, "shell", ["a.ts"]),
      usage: usage_snapshot(100)
    })

    insert_custom_turn!(job, %{
      runtime_thread_id: "thread-child",
      runtime_turn_id: "turn-child-1",
      started_at: DateTime.add(base, 1, :second),
      status: "in_progress",
      trajectory: trajectory([assistant_message("child-report-must-not-appear")]),
      progress:
        progress_snapshot(2, "web_search", ["child.tmp"])
        |> Map.put("active_item", %{"id" => "child-search", "name" => "web_search"}),
      usage: usage_snapshot(999)
    })

    insert_custom_turn!(job, %{
      runtime_thread_id: "thread-lead",
      runtime_turn_id: "turn-compaction-1",
      kind: "compaction",
      started_at: DateTime.add(base, 2, :second),
      status: "completed",
      completed_at: DateTime.add(base, 2, :second),
      trajectory: trajectory([assistant_message("compaction-must-not-appear")]),
      progress: progress_snapshot(1, "context_compaction", [])
    })

    insert_custom_turn!(job, %{
      runtime_thread_id: "thread-lead",
      runtime_turn_id: "turn-lead-2",
      started_at: DateTime.add(base, 3, :second),
      status: "in_progress",
      trajectory:
        trajectory([
          assistant_message("lead-new-1"),
          assistant_message("lead-new-2"),
          tool_call_message("patch-1", "apply_patch"),
          tool_result_message("patch-1", "apply_patch", "patched")
        ]),
      progress:
        progress_snapshot(3, "apply_patch", ["b.ts"])
        |> Map.put("active_item", %{"id" => "patch-1", "name" => "apply_patch"})
        |> Map.put("plan", %{
          "explanation" => "Finish verification",
          "steps" => [%{"step" => "Run tests", "status" => "in_progress"}]
        }),
      usage: usage_snapshot(200)
    })

    assert {:ok, %{execution: execution}} =
             BackgroundAgentJobs.get_job_summary_for_agent(job.id, agent.uid)

    assert execution.attempt == 1

    assert execution.current == %{
             runtime_turn_id: "turn-lead-2",
             kind: "agent",
             status: "in_progress"
           }

    assert execution.lead_turn_number == 2
    assert execution.threads == %{total: 2, child: 1}
    assert execution.turns == %{lead: 2, child: 1, compaction: 1, active: 2}
    assert execution.usage == usage_snapshot(200)

    assert execution.progress.completed_items == 8
    assert execution.progress.tool_calls == 4

    assert execution.progress.tools_used == [
             %{name: "apply_patch", calls: 1},
             %{name: "context_compaction", calls: 1},
             %{name: "shell", calls: 1},
             %{name: "web_search", calls: 1}
           ]

    assert execution.progress.files_changed == ["a.ts", "b.ts", "child.tmp"]
    assert execution.progress.plan["explanation"] == "Finish verification"

    assert Enum.sort_by(execution.progress.active_items, & &1.scope) == [
             %{scope: "child", name: "web_search"},
             %{scope: "lead", name: "apply_patch"}
           ]

    assert Enum.map(execution.trajectory_page.messages, &Map.get(&1, "role")) == [
             "assistant",
             "assistant",
             "assistant",
             "tool"
           ]

    assert Ankole.JSON.encode!(execution.trajectory_page) =~ "lead-new-1"
    refute Ankole.JSON.encode!(execution.trajectory_page) =~ "child-report-must-not-appear"
    refute Ankole.JSON.encode!(execution.trajectory_page) =~ "compaction-must-not-appear"

    assert {:ok, %{execution: %{trajectory_page: newest}}} =
             BackgroundAgentJobs.get_job_summary_for_agent(job.id, agent.uid, trajectory_limit: 1)

    assert Enum.map(newest.messages, &Map.get(&1, "role")) == ["assistant", "tool"]
    assert is_binary(newest.next_cursor)

    assert {:ok, %{execution: %{trajectory_page: middle}}} =
             BackgroundAgentJobs.get_job_summary_for_agent(job.id, agent.uid,
               trajectory_limit: 2,
               trajectory_cursor: newest.next_cursor
             )

    assert Enum.map(middle.messages, &Map.get(&1, "content")) == ["lead-new-1", "lead-new-2"]
    assert is_binary(middle.next_cursor)

    assert {:ok, %{execution: %{trajectory_page: oldest}}} =
             BackgroundAgentJobs.get_job_summary_for_agent(job.id, agent.uid,
               trajectory_limit: 2,
               trajectory_cursor: middle.next_cursor
             )

    assert Enum.map(oldest.messages, &Map.get(&1, "role")) == ["assistant", "assistant", "tool"]
    refute Map.has_key?(oldest, :next_cursor)

    assert {:error, :invalid_background_agent_job_trajectory_cursor} =
             BackgroundAgentJobs.get_job_summary_for_agent(job.id, agent.uid,
               trajectory_cursor: "not-a-cursor"
             )

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [status: "failed"])

    terminal = Repo.get!(Job, job.id)
    assert {:ok, terminal_execution} = Turns.execution_projection(terminal)
    assert terminal_execution.progress.active_items == []
    assert terminal_execution.turns.active == 2

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 2])

    assert {:error, :background_agent_job_trajectory_cursor_stale} =
             BackgroundAgentJobs.get_job_summary_for_agent(job.id, agent.uid,
               trajectory_cursor: newest.next_cursor
             )
  end

  test "trajectory pages stay within 24 KiB even when one semantic message is large" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "trajectory-page-bytes")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 1, runtime_thread_id: "thread-large"])

    job = Repo.get!(Job, job.id)

    insert_custom_turn!(job, %{
      runtime_thread_id: "thread-large",
      runtime_turn_id: "turn-large",
      status: "completed",
      completed_at: DateTime.utc_now(:microsecond),
      trajectory: trajectory([assistant_message(String.duplicate("大", 80_000))])
    })

    assert {:ok, execution} = Turns.execution_projection(job)
    assert byte_size(Ankole.JSON.encode!(execution.trajectory_page)) <= 24 * 1_024
    assert execution.trajectory_page.messages != []
  end

  test "one runtime Turn id maps to one durable row" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "turn-identity")
    first = insert_turn!(job, 1, "thread-1", "turn-1", "completed")

    assert_raise Ecto.InvalidChangesetError, fn ->
      insert_turn!(job, 1, "thread-1", "turn-1", "completed")
    end

    assert [%{id: id}] = BackgroundAgentJobs.list_turns(job.id)
    assert id == first.id
  end

  test "job summary derives bounded prior-attempt context from Turn trajectories" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "attempt-history")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 4, runtime_thread_id: "thread-current-attempt"])

    base = DateTime.add(DateTime.utc_now(:microsecond), -60, :second)

    for {attempt, summary} <- [
          {1, "First attempt failed."},
          {2, "Second attempt failed."},
          {3, "Third attempt failed."}
        ] do
      started_at = DateTime.add(base, attempt * 10, :second)

      insert_custom_turn!(job, %{
        attempt: attempt,
        runtime_thread_id: "thread-lead-#{attempt}",
        runtime_turn_id: "turn-lead-#{attempt}",
        started_at: started_at,
        status: "failed",
        trajectory: trajectory([assistant_message(summary)])
      })

      insert_custom_turn!(job, %{
        attempt: attempt,
        runtime_thread_id: "thread-child-#{attempt}",
        runtime_turn_id: "turn-child-#{attempt}",
        started_at: DateTime.add(started_at, 1, :second),
        status: "failed",
        trajectory: trajectory([assistant_message("Child report must not replace #{summary}")])
      })
    end

    assert {:ok, %{execution: execution, attempt_history: history}} =
             BackgroundAgentJobs.get_job_summary_for_agent(job.id, agent.uid)

    assert execution.attempt == 4
    assert execution.trajectory_page.messages == []
    refute Map.has_key?(execution, :current)
    assert Enum.map(history, & &1.attempt) == [1, 2, 3]

    assert Enum.map(history, & &1.summary) == [
             "First attempt failed.",
             "Second attempt failed.",
             "Third attempt failed."
           ]

    assert Enum.at(history, 1).turn_statuses == ["failed"]
  end

  test "attempt history keeps the lead report when one attempt has more than one hundred child Turns" do
    %{principal: agent} = agent_fixture()
    job = create_job!(agent.uid, "large-attempt-history")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 2, runtime_thread_id: "thread-current"])

    job = Repo.get!(Job, job.id)
    base = DateTime.add(DateTime.utc_now(:microsecond), -200, :second)

    insert_custom_turn!(job, %{
      attempt: 1,
      runtime_thread_id: "thread-lead-1",
      runtime_turn_id: "turn-lead-1",
      started_at: base,
      status: "failed",
      trajectory: trajectory([assistant_message("Authoritative lead report.")])
    })

    for index <- 1..101 do
      insert_custom_turn!(job, %{
        attempt: 1,
        runtime_thread_id: "thread-child-#{index}",
        runtime_turn_id: "turn-child-#{index}",
        started_at: DateTime.add(base, index, :second),
        status: "failed",
        trajectory: trajectory([assistant_message("Passive child report #{index}.")])
      })
    end

    assert [%{attempt: 1, summary: "Authoritative lead report."}] =
             Turns.attempt_history(job)
  end

  defp insert_custom_turn!(job, attrs) do
    status = Map.get(attrs, :status, "completed")
    started_at = Map.get(attrs, :started_at, DateTime.utc_now(:microsecond))

    defaults = %{
      job_id: job.id,
      attempt: max(job.attempts, 1),
      runtime_thread_id: job.runtime_thread_id || "thread-lead",
      runtime_turn_id: "turn-#{Ecto.UUID.generate()}",
      kind: "agent",
      status: status,
      revision: 1,
      trajectory: trajectory([]),
      progress: %{
        "completed_items" => 0,
        "tool_calls" => 0,
        "tools_used" => [],
        "files_changed" => []
      },
      usage: nil,
      error: %{},
      started_at: started_at,
      completed_at: if(status in ~w(completed failed interrupted), do: started_at)
    }

    %Turn{}
    |> Turn.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp trajectory(messages) do
    %{"format" => "ankole_chatml", "version" => 1, "messages" => messages}
  end

  defp assistant_message(content), do: %{"role" => "assistant", "content" => content}

  defp tool_call_message(id, name) do
    %{
      "role" => "assistant",
      "content" => "",
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => "{}"}
        }
      ]
    }
  end

  defp tool_result_message(id, name, content) do
    %{
      "role" => "tool",
      "tool_call_id" => id,
      "name" => name,
      "content" => content
    }
  end

  defp progress_snapshot(completed_items, tool_name, files_changed) do
    %{
      "completed_items" => completed_items,
      "tool_calls" => 1,
      "tools_used" => [%{"name" => tool_name, "calls" => 1}],
      "files_changed" => Enum.sort(files_changed)
    }
  end

  defp usage_snapshot(total_tokens) do
    breakdown = %{
      "total_tokens" => total_tokens,
      "input_tokens" => max(total_tokens - 5, 0),
      "cached_input_tokens" => min(total_tokens, 5),
      "output_tokens" => min(total_tokens, 5),
      "reasoning_output_tokens" => min(total_tokens, 2)
    }

    %{
      "thread_total" => breakdown,
      "last_model_call" => breakdown,
      "model_context_window" => 200_000
    }
  end

  defp insert_turn!(
         job,
         attempt,
         runtime_thread_id,
         runtime_turn_id,
         status,
         summary \\ "Turn complete."
       ) do
    now = DateTime.utc_now(:microsecond)

    %Turn{}
    |> Turn.changeset(%{
      job_id: job.id,
      attempt: attempt,
      runtime_thread_id: runtime_thread_id,
      runtime_turn_id: runtime_turn_id,
      kind: "agent",
      status: status,
      revision: 1,
      trajectory: %{
        "format" => "ankole_chatml",
        "version" => 1,
        "messages" => [%{"role" => "assistant", "content" => summary}]
      },
      error: if(status == "failed", do: %{"summary" => summary}, else: %{}),
      started_at: now,
      completed_at: if(status in ~w(completed failed interrupted), do: now)
    })
    |> Repo.insert!()
  end

  defp request_user_input_trajectory(pending? \\ true) do
    %{
      "format" => "ankole_chatml",
      "version" => 1,
      "messages" => [
        %{
          "role" => "assistant",
          "content" => "",
          "metadata" => if(pending?, do: %{"status" => "pending_user_input"}, else: %{}),
          "tool_calls" => [
            %{
              "id" => "request-user-input",
              "type" => "function",
              "function" => %{
                "name" => "request_user_input",
                "arguments" => ~s({"questions":[]})
              }
            }
          ]
        }
      ]
    }
  end

  defp insert_waiting_turn!(job, attempt, runtime_thread_id, runtime_turn_id) do
    job
    |> insert_turn!(attempt, runtime_thread_id, runtime_turn_id, "interrupted")
    |> Turn.changeset(%{
      trajectory: request_user_input_trajectory(),
      revision: 2,
      error: %{"code" => "request_user_input"}
    })
    |> Repo.update!()
  end

  defp set_attempts!(job, attempts) do
    job
    |> Ecto.Changeset.change(attempts: attempts)
    |> Repo.update!()
  end

  defp create_job!(agent_uid, suffix) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "owner_session_id" => "parent-session-#{suffix}",
               "source_tool_call_id" => "tool-background-agent-job-#{suffix}",
               "title" => "Job #{suffix}",
               "task" => "Complete the #{suffix} job.",
               "reply_route" => %{
                 "binding_name" => "lark",
                 "signal_channel_id" => "chat-#{suffix}",
                 "provider_thread_id" => "thread-#{suffix}",
                 "source_entry_id" => "message-#{suffix}"
               }
             })

    job
  end
end
