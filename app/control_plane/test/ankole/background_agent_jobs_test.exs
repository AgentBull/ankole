defmodule Ankole.BackgroundAgentJobsTest do
  use Ankole.AIGatewayCase

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AgentHomePaths
  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.RuntimeProjection
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.TrajectoryGroup
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem
  alias Ankole.BackgroundAgentJobs.Text
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.Repo

  require Ankole.BackgroundAgentJobs

  describe "job session identity" do
    test "job_session_id/1 pins the persisted wire format" do
      job_id = 1000

      assert BackgroundAgentJobs.job_session_id(job_id) == "job:1000"
      assert BackgroundAgentJobs.job_session_prefix() == "job:"
    end

    test "parse_job_session_id/1 round-trips built ids and rejects everything else" do
      job_id = 1000
      session_id = BackgroundAgentJobs.job_session_id(job_id)

      assert BackgroundAgentJobs.parse_job_session_id(session_id) == {:ok, job_id}

      for other <- ["job:", "job", "", job_id, "signal-channel:lark:oc_1", nil, :job] do
        assert BackgroundAgentJobs.parse_job_session_id(other) == :error
      end
    end

    test "is_job_session_id/1 agrees with parse_job_session_id/1" do
      values = [
        BackgroundAgentJobs.job_session_id(1000),
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
      job_id: 1000,
      attempt: 1,
      runtime_thread_id: "thread-schema",
      runtime_turn_id: "turn-schema",
      kind: "agent",
      status: "completed",
      revision: 1,
      trajectory: trajectory_header(),
      progress: %{
        "completed_items" => 2,
        "tool_calls" => 1,
        "tools_used" => [%{"name" => "web_search", "calls" => 1}],
        "tool_execution_mechanisms" => [
          %{
            "name" => "web_search",
            "execution_mechanism" => "provider_hosted",
            "calls" => 1
          }
        ],
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

    invalid_execution_mechanism =
      put_in(
        attrs,
        [:progress, "tool_execution_mechanisms"],
        [%{"name" => "web_search", "execution_mechanism" => "guessed", "calls" => 1}]
      )

    refute Turn.changeset(%Turn{}, invalid_execution_mechanism).valid?
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
    %{principal: agent} = background_agent_fixture()

    attrs = %{
      "agent_uid" => agent.uid,
      "owner_session_id" => "parent-session",
      "source_tool_call_id" => "tool-background-agent-job-1",
      "title" => "Prepare the launch brief",
      "task" =>
        "\n  Read the source material, write the brief, and verify every acceptance criterion.  \n",
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
    assert job.reply_route == attrs["reply_route"]
    assert job.workspace_template_id == nil
    assert job.model_profile == "coding"

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
    refute Map.has_key?(event.payload["data"], "workspace_template_id")
    refute Map.has_key?(event.payload["data"], "workspace_mounts")
    assert get_in(event.payload, ["data", "model_profile"]) == "coding"
    assert get_in(event.payload, ["data", "attempts"]) == 0
    refute inspect(event.payload) =~ attrs["task"]

    assert {:ok, %{job: same_job, dispatch_event: same_event}} =
             BackgroundAgentJobs.create_with_dispatch(attrs)

    assert same_job.id == job.id
    assert same_event.id == event.id
    assert Repo.aggregate(Job, :count) == 1
    assert Repo.aggregate(ActorEvent, :count) == 1
  end

  test "a Worker completion arriving after an external completion keeps the stored result" do
    %{principal: agent} = background_agent_fixture()

    assert {:ok, %{job: %Job{} = job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => "parent-session",
               "source_tool_call_id" => "tool-late-worker-completion",
               "title" => "External completion wins",
               "task" => "Verify the release externally.",
               "reply_route" => %{
                 "binding_name" => "lark",
                 "signal_channel_id" => "chat-1",
                 "source_entry_id" => "message-1"
               }
             })

    assert {:ok, %{job: externally_completed}} =
             BackgroundAgentJobs.request_complete(job.id, %{
               "agent_uid" => agent.uid,
               "completed_by" => "operator:release-bot",
               "result_summary" => "EXTERNALLY-VERIFIED"
             })

    assert externally_completed.status == "succeeded"

    # A slow Worker reports its own completion for the same Job. The Job already
    # has an authoritative result, so the late write must not replace it.
    _late =
      BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
        "status" => "succeeded",
        "result" => %{"summary" => "WORKER-LATE"}
      })

    final = BackgroundAgentJobs.get_job(job.id)

    assert final.status == "succeeded"
    assert get_in(final.result, ["summary"]) == "EXTERNALLY-VERIFIED"
  end

  test "a skill-lesson reflection job wakes no session and enqueues the apply worker" do
    %{principal: agent} = background_agent_fixture()

    assert {:ok, %{job: reflection}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => "brain:skill-lessons:" <> agent.uid,
               "source_tool_call_id" => "skill-lessons:9000",
               "title" => "Skill lessons reflection",
               "task" => "Reflect over the evidence bundle.",
               "reply_route" => %{"binding_name" => "lark"},
               "metadata" => %{
                 "skill_lesson_reflection" => true,
                 "through_job_id" => 9000,
                 "evidence_job_ids" => [8999, 9000],
                 "human_input_job_ids" => [8999]
               }
             })

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(reflection.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-reflection"
             })

    running = running |> Ecto.Changeset.change(attempts: 1) |> Repo.update!()
    insert_turn!(running, 1, "thread-reflection", "turn-reflection", "completed")

    assert {:ok, %{job: succeeded, wakeup_event: nil}} =
             BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"output_text" => ~s({"adds": []})}
             })

    assert succeeded.status == "succeeded"

    # No wakeup event reached the synthetic owner session.
    refute Repo.exists?(
             from(event in ActorEvent,
               where: event.session_id == ^("brain:skill-lessons:" <> agent.uid)
             )
           )

    # The apply worker was enqueued in the terminal-commit transaction.
    assert [%Oban.Job{args: %{"job_id" => job_id}}] =
             all_enqueued(worker: Ankole.Brain.Jobs.ApplySkillLessons)

    assert job_id == succeeded.id

    # An ordinary job's terminal commit still appends its wakeup event.
    assert {:ok, %{job: plain}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => "signal-channel:plain-session",
               "source_tool_call_id" => "plain-wakeup-control",
               "title" => "Plain job",
               "task" => "Do the work.",
               "reply_route" => %{"binding_name" => "lark"}
             })

    assert {:ok, %{job: plain_running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(plain.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-plain"
             })

    plain_running = plain_running |> Ecto.Changeset.change(attempts: 1) |> Repo.update!()
    insert_turn!(plain_running, 1, "thread-plain", "turn-plain", "completed")

    assert {:ok, %{job: _plain_done, wakeup_event: %ActorEvent{} = wakeup}} =
             BackgroundAgentJobs.commit_status_with_wakeup(plain_running.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"output_text" => "done"}
             })

    assert wakeup.type == "background_agent_job.completed"
    assert wakeup.session_id == "signal-channel:plain-session"
  end

  test "Jobs do not persist AIGateway credentials or a second model-profile copy" do
    %{principal: agent} = background_agent_fixture()
    assert {:ok, profile} = ModelProfiles.get_model_profile(agent.uid, "coding")

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               provider_id: profile["provider_id"],
               model: "openai/gpt-5.6-sol",
               context_length: 262_144,
               provider_options: %{
                 "reasoningEffort" => "xhigh",
                 "strictJSONSchema" => true,
                 "textVerbosity" => "low"
               }
             })

    attrs = %{
      "agent_uid" => agent.uid,
      "owner_session_id" => "parent-session-model-snapshot",
      "source_tool_call_id" => "tool-model-snapshot",
      "title" => "Freeze the model",
      "task" => "Use the model selected when this Job is created.",
      "reply_route" => %{"binding_name" => "lark"}
    }

    assert {:ok, %{job: job}} = BackgroundAgentJobs.create_with_dispatch(attrs)
    refute Map.has_key?(job.metadata, "codex_aigateway")
    refute Map.has_key?(job.metadata, "codex_subscription")
    refute Map.has_key?(job.metadata, "codex_account_id")

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               provider_id: profile["provider_id"],
               model: "moonshotai/kimi-k2.7-code",
               provider_options: %{"reasoningEffort" => "medium"}
             })

    assert {:ok, %{job: replayed}} = BackgroundAgentJobs.create_with_dispatch(attrs)
    assert replayed.id == job.id
    assert replayed.metadata == job.metadata

    assert {:ok, %{job: next_job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               attrs
               | "source_tool_call_id" => "tool-model-snapshot-next",
                 "title" => "Freeze the next model"
             })

    refute Map.has_key?(next_job.metadata, "codex_aigateway")
    refute Map.has_key?(next_job.metadata, "codex_subscription")
  end

  test "Job creation rejects an Agent without a coding model or heavy fallback" do
    %{principal: agent} = agent_fixture()

    assert {:error, :model_profile_not_configured} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => "parent-session-no-model",
               "source_tool_call_id" => "tool-no-model",
               "title" => "No model",
               "task" => "This Job cannot execute.",
               "reply_route" => %{"binding_name" => "lark"}
             })
  end

  test "Job creation accepts only configured custom profile overrides and persists the logical name" do
    %{principal: agent} = background_agent_fixture()
    assert {:ok, coding} = ModelProfiles.get_model_profile(agent.uid, "coding")

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "kimi", %{
               description: "Long-context coding",
               provider_id: coding["provider_id"],
               model: "moonshotai/kimi-k2.7-code",
               provider_options: %{"reasoningEffort" => "high"}
             })

    attrs = %{
      "agent_uid" => agent.uid,
      "owner_session_id" => "parent-session-custom-model",
      "source_tool_call_id" => "tool-custom-model",
      "title" => "Use the custom model",
      "task" => "Complete this work with the selected profile.",
      "model_profile" => "kimi",
      "reply_route" => %{"binding_name" => "lark"}
    }

    assert {:ok, %{job: job, dispatch_event: event}} =
             BackgroundAgentJobs.create_with_dispatch(attrs)

    assert job.model_profile == "kimi"
    assert get_in(event.payload, ["data", "model_profile"]) == "kimi"

    assert {:error, :invalid_custom_model_profile} =
             attrs
             |> Map.put("source_tool_call_id", "tool-fixed-model-override")
             |> Map.put("model_profile", "coding")
             |> BackgroundAgentJobs.create_with_dispatch()

    assert {:error, :model_profile_not_configured} =
             attrs
             |> Map.put("source_tool_call_id", "tool-missing-model-override")
             |> Map.put("model_profile", "missing")
             |> BackgroundAgentJobs.create_with_dispatch()
  end

  test "start replay returns the original dispatch after attempts and lifecycle state change" do
    %{principal: agent} = background_agent_fixture()

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
    %{principal: agent} = background_agent_fixture()

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

  test "workspace template selection stores one id and idempotent replay ignores later disablement" do
    %{principal: agent} = background_agent_fixture()

    attrs = %{
      "agent_uid" => agent.uid,
      "owner_session_id" => "parent-session-research",
      "source_tool_call_id" => "tool-deep-research",
      "workspace_template_id" => "deep-research",
      "title" => "Research the policy change",
      "task" => "Produce a cited research report.",
      "reply_route" => %{"binding_name" => "lark"}
    }

    assert {:ok, %{job: research}} =
             BackgroundAgentJobs.create_with_dispatch(attrs)

    assert research.workspace_template_id == "deep-research"

    assert {:ok, _override} =
             AgentPlugins.set_agent_override(agent.uid, "deep-research", false)

    assert {:ok, %{job: retried}} =
             BackgroundAgentJobs.create_with_dispatch(attrs)

    assert retried.id == research.id
    assert retried.workspace_template_id == "deep-research"
  end

  test "success requires a completed lead Turn and interrupts active child Turns" do
    %{principal: agent} = background_agent_fixture()

    assert {:ok, %{job: research}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => "parent-session-trajectory-gate",
               "source_tool_call_id" => "tool-trajectory-gate",
               "workspace_template_id" => "deep-research",
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

    active_child = Repo.reload!(active_child)
    assert active_child.status == "interrupted"
    assert active_child.error["code"] == "background_agent_job_succeeded"
    assert %DateTime{} = active_child.completed_at
  end

  test "success rolls back when an existing successor cannot carry an open steer" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "steer-successor-conflict")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-steer-successor-conflict"
             })

    running = set_attempts!(running, 1)

    _turn =
      insert_turn!(
        running,
        1,
        "thread-steer-successor-conflict",
        "turn-steer-successor-conflict",
        "completed"
      )

    # Public lifecycle locks prevent this order. Build the durable conflict
    # directly to prove that its defensive branch does not complete the steer.
    failed_at = DateTime.utc_now(:microsecond)

    running
    |> Ecto.Changeset.change(status: "failed", completed_at: failed_at)
    |> Repo.update!()

    assert {:ok, %{job: manual_successor}} =
             BackgroundAgentJobs.respawn_with_dispatch(job.id, %{
               "agent_uid" => agent.uid,
               "owner_session_id" => job.owner_session_id,
               "source_tool_call_id" => "manual-steer-successor-conflict",
               "message" => "Continue with the manual follow-up.",
               "reply_route" => job.reply_route
             })

    job
    |> Repo.reload!()
    |> Ecto.Changeset.change(status: "running", completed_at: nil)
    |> Repo.update!()

    assert {:ok, %{command_event: steer}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => agent.uid,
               "message" => "Preserve this late instruction.",
               "request_id" => "late-steer-successor-conflict"
             })

    assert {:error, {:background_agent_job_already_respawned, successor_id}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "Done"}
             })

    assert successor_id == manual_successor.id
    assert Repo.reload!(job).status == "running"
    assert Repo.reload!(steer).completed_at == nil
    assert Repo.reload!(steer).input_state == "open"
    assert Repo.reload!(manual_successor).task == "Continue with the manual follow-up."

    refute Repo.get_by(ActorEvent,
             session_id: job.owner_session_id,
             type: "background_agent_job.completed"
           )
  end

  test "success cannot bypass the current-attempt trajectory by omitting the runtime thread anchor" do
    %{principal: agent} = background_agent_fixture()
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
    %{principal: agent} = background_agent_fixture()
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

    replace_turn_trajectory!(interrupted, request_user_input_messages(false), %{
      revision: interrupted.revision + 1,
      error: %{"code" => "request_user_input"}
    })

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

    replace_turn_trajectory!(interrupted, request_user_input_messages(), %{
      revision: interrupted.revision + 1
    })

    assert {:ok, %{job: %{status: "waiting_on_user"}}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })
  end

  test "waiting cannot close an attempt while one of its runtime Turns is active" do
    %{principal: agent} = background_agent_fixture()
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

    replace_turn_trajectory!(active, request_user_input_messages(), %{
      status: "interrupted",
      revision: active.revision + 1,
      error: %{"code" => "request_user_input"},
      completed_at: now
    })

    assert {:ok, %{job: %{status: "waiting_on_user"}}} =
             BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })
  end

  test "creation rejects the removed workspace_mounts field before journaling work" do
    %{principal: agent} = background_agent_fixture()

    assert {:error, {:unsupported_background_agent_job_create_fields, ["workspace_mounts"]}} =
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

  test "creation rejects legacy workspace paths before journaling work" do
    %{principal: agent} = background_agent_fixture()

    for {task, path, index} <- [
          {"Read /workspace/user-files/inbox/report.pdf.", "/workspace/user-files", 1},
          {"Use /workspace/temp for intermediate pages.", "/workspace/temp", 2},
          {"Inspect /workspace/user-files, then report what exists.", "/workspace/user-files", 3}
        ] do
      assert {:error, {:background_agent_job_legacy_workspace_path, message}} =
               BackgroundAgentJobs.create_with_dispatch(%{
                 "agent_uid" => agent.uid,
                 "owner_session_id" => "parent-session-invalid-task-path-#{index}",
                 "source_tool_call_id" => "tool-background-agent-job-invalid-task-path-#{index}",
                 "title" => "Invalid task path",
                 "task" => task,
                 "reply_route" => %{"binding_name" => "lark"}
               })

      assert task =~ path
      assert message =~ "/workspace is no longer a valid Agent path"
      assert message =~ "/agents/<agent-key>/"
    end

    assert Repo.aggregate(Job, :count) == 0
    assert Repo.aggregate(ActorEvent, :count) == 0

    attrs = %{
      "agent_uid" => agent.uid,
      "owner_session_id" => "parent-session-near-task-path",
      "source_tool_call_id" => "tool-background-agent-job-near-task-path",
      "title" => "Valid private directory",
      "task" => "Create artifacts/user-files-archive in the current Job workspace.",
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
    %{principal: agent} = background_agent_fixture()
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
                 "project_path" => AgentHomePaths.job_workspace(agent.uid, waiting.id),
                 "artifacts" => %{
                   "total_count" => 1,
                   "paths" => [
                     Path.join(
                       AgentHomePaths.job_workspace(agent.uid, waiting.id),
                       "launch-brief.pdf"
                     )
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
             AgentHomePaths.job_workspace(agent.uid, waiting.id)

    assert get_in(completed_event.payload, ["data", "artifacts"]) == %{
             "total_count" => 1,
             "paths" => [
               Path.join(AgentHomePaths.job_workspace(agent.uid, waiting.id), "launch-brief.pdf")
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
                 "summary" =>
                   "The provider disconnected (request 019f0000-0000-7000-8000-000000000099)."
               }
             })

    assert failed.status == "failed"
    assert failed_event.type == "background_agent_job.failed"
    assert get_in(failed_event.payload, ["data", "job_id"]) == failed.id

    assert get_in(failed_event.payload, ["data", "result_summary"]) ==
             "The provider disconnected (request [internal-id])."

    refute Map.has_key?(failed_event.payload["data"], "workspace_template_id")
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

  test "a terminal wakeup preserves frozen scheduled delivery targets" do
    %{principal: agent} = background_agent_fixture()

    delivery = %{
      "targets" => [
        %{"binding_name" => "lark", "signal_channel_id" => "chat-primary"},
        %{"binding_name" => "archive", "signal_channel_id" => "chat-archive"}
      ]
    }

    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "owner_session_id" => "parent-session-scheduled-delivery",
               "source_tool_call_id" => "tool-background-agent-job-scheduled-delivery",
               "title" => "Scheduled report",
               "task" => "Complete the scheduled report.",
               "reply_route" => %{
                 "binding_name" => "lark",
                 "signal_channel_id" => "chat-primary",
                 "delivery" => delivery
               }
             })

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-scheduled-delivery"
             })

    running = set_attempts!(running, 1)

    _turn =
      insert_turn!(
        running,
        1,
        "thread-scheduled-delivery",
        "turn-scheduled-delivery",
        "completed"
      )

    assert {:ok, %{wakeup_event: %ActorEvent{} = event}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "Scheduled report complete."}
             })

    assert get_in(event.payload, ["data", "reply_route", "delivery"]) == delivery
  end

  test "failure wakeups omit unrecognized diagnostic maps" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "opaque-failure")

    assert {:ok, %{job: _running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-opaque-failure"
             })

    assert {:ok, %{wakeup_event: %ActorEvent{} = wakeup}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "failed",
               "error" => %{
                 "provider_request_id" => "019f0000-0000-7000-8000-000000000098"
               }
             })

    refute Map.has_key?(wakeup.payload["data"], "result_summary")
    refute Ankole.JSON.encode!(wakeup.payload) =~ "019f0000-0000-7000-8000-000000000098"
  end

  test "status and parent wakeup roll back together when the frozen reply route is invalid" do
    %{principal: agent} = background_agent_fixture()
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
    %{principal: agent} = background_agent_fixture()
    queued = create_job!(agent.uid, "queued-stop")

    assert {:ok, %{command_event: queued_message}} =
             BackgroundAgentJobs.send_message(queued.id, %{
               "agent_uid" => agent.uid,
               "message" => "Include the late attachment.",
               "request_id" => "queued-stop-message"
             })

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
    assert %DateTime{} = Repo.get!(ActorEvent, queued_message.id).completed_at

    assert {:ok, %{job: same_stopped, command_event: nil}} =
             BackgroundAgentJobs.request_stop(queued.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:ding"
             })

    assert same_stopped.id == stopped.id

    running = create_job!(agent.uid, "running-stop")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-running-stop"
             })

    running = set_attempts!(running, 1)

    active_running_turn =
      insert_turn!(running, 1, "thread-running-stop", "turn-running-stop", "in_progress")

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

    active_running_turn = Repo.reload!(active_running_turn)
    assert active_running_turn.status == "interrupted"
    assert active_running_turn.error["code"] == "background_agent_job_stopped"
    assert %DateTime{} = active_running_turn.completed_at

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

  test "message send journals text once and list returns every Job owned by one Agent" do
    %{principal: agent} = background_agent_fixture()
    %{principal: other_agent} = background_agent_fixture()
    first = create_job!(agent.uid, "first")
    second = create_job!(agent.uid, "second")
    third = create_job!(agent.uid, "third")
    other_agent_job = create_job!(other_agent.uid, "other-agent")

    first =
      first
      |> Job.changeset(%{status: "running", runtime_thread_id: "thread-first"})
      |> Repo.update!()

    assert {:ok, %{job: %Job{id: first_id}, command_event: %ActorEvent{} = message_event}} =
             BackgroundAgentJobs.send_message(first.id, %{
               "agent_uid" => agent.uid,
               "message" => "Use the operator audience.",
               "request_id" => "steer-first"
             })

    assert message_event.source_entry_id == nil

    assert message_event.type == "command.steer"

    assert get_in(message_event.payload, ["data", "command", "argsText"]) ==
             "Use the operator audience."

    refute Map.has_key?(get_in(message_event.payload, ["data", "command"]), "answers")

    assert {:ok, %{command_event: %ActorEvent{id: repeated_id}}} =
             BackgroundAgentJobs.send_message(first.id, %{
               "agent_uid" => agent.uid,
               "message" => "Use the operator audience.",
               "request_id" => "steer-first"
             })

    assert repeated_id == message_event.id

    assert first_id == first.id

    assert {:ok, %{jobs: listed, next_cursor: nil}} =
             BackgroundAgentJobs.list_for_agent(agent.uid)

    assert Enum.map(listed, & &1.job_id) |> MapSet.new() ==
             MapSet.new([first.id, second.id, third.id])

    assert Enum.find(listed, &(&1.job_id == first.id)) == %{
             job_id: first.id,
             title: first.title,
             status: "running"
           }

    assert Enum.find(listed, &(&1.job_id == second.id)) == %{
             job_id: second.id,
             title: second.title,
             status: "queued"
           }

    refute Enum.any?(listed, &(&1.job_id == other_agent_job.id))
  end

  test "list uses fixed 32-item pages ordered by the latest update and grouped status" do
    %{principal: agent} = background_agent_fixture()
    base = ~U[2026-07-21 00:00:00.000000Z]

    live_jobs =
      for index <- 0..32 do
        job = create_job!(agent.uid, "list-live-#{index}")

        from(row in Job, where: row.id == ^job.id)
        |> Repo.update_all(
          set: [
            updated_at: DateTime.add(base, index, :second)
          ]
        )

        job
      end

    stop_jobs =
      for {status, index} <- Enum.with_index(~w(succeeded failed stopped), 33) do
        job = create_job!(agent.uid, "list-stop-#{status}")
        completed_at = DateTime.add(base, index, :second)

        from(row in Job, where: row.id == ^job.id)
        |> Repo.update_all(
          set: [
            status: status,
            completed_at: completed_at,
            updated_at: completed_at
          ]
        )

        {job, status}
      end

    assert {:ok, %{jobs: first_page, next_cursor: cursor}} =
             BackgroundAgentJobs.list_for_agent(agent.uid)

    assert length(first_page) == 32
    assert is_binary(cursor)

    expected_live_ids = live_jobs |> Enum.reverse() |> Enum.map(& &1.id)
    assert Enum.map(first_page, & &1.job_id) == Enum.take(expected_live_ids, 32)

    assert {:ok, %{jobs: second_page, next_cursor: nil}} =
             BackgroundAgentJobs.list_for_agent(agent.uid, cursor: cursor)

    assert Enum.map(second_page, & &1.job_id) == Enum.drop(expected_live_ids, 32)

    assert {:ok, %{jobs: stopped, next_cursor: nil}} =
             BackgroundAgentJobs.list_for_agent(agent.uid, status: "stop")

    expected_stop_jobs = Enum.reverse(stop_jobs)

    assert Enum.map(stopped, &{&1.job_id, &1.status}) ==
             Enum.map(expected_stop_jobs, &{elem(&1, 0).id, elem(&1, 1)})

    assert {:error, :invalid_background_agent_job_cursor} =
             BackgroundAgentJobs.list_for_agent(agent.uid,
               status: "stop",
               cursor: cursor
             )

    assert {:error, :invalid_background_agent_job_list_status} =
             BackgroundAgentJobs.list_for_agent(agent.uid, status: "failed")
  end

  test "message send rejects a settled job and does not create a command" do
    %{principal: agent} = background_agent_fixture()
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

    assert {:error, {:background_agent_job_message_status_invalid, "succeeded"}} =
             BackgroundAgentJobs.send_message(succeeded.id, %{
               "agent_uid" => agent.uid,
               "message" => "Complete the missing artifacts.",
               "request_id" => "continue-settled"
             })

    assert BackgroundAgentJobs.get_job_for_agent(succeeded.id, agent.uid).status == "succeeded"

    refute Repo.exists?(
             from event in ActorEvent,
               where: event.session_id == ^BackgroundAgentJobs.job_session_id(succeeded.id),
               where: event.type == "command.steer"
           )
  end

  test "claiming a continuation clears the answered parent input" do
    %{principal: agent} = background_agent_fixture()

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
             BackgroundAgentJobs.claim_continuation_in_tx(
               Repo,
               waiting.id,
               agent.uid,
               1,
               runtime_turn_start_spec(),
               agent_slot_cap()
             )

    assert resumed.status == "running"
    assert resumed.metadata == %{"worker_route" => "worker-a"}
  end

  test "the first attempt captures one immutable runtime projection" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "stable-runtime-projection")
    first_spec = runtime_turn_start_spec("openai/gpt-5.6-sol")

    assert {:ok, first_attempt} =
             BackgroundAgentJobs.claim_attempt_in_tx(
               Repo,
               job.id,
               agent.uid,
               1,
               first_spec,
               agent_slot_cap()
             )

    assert first_attempt.runtime_projection["version"] == 1
    assert first_attempt.runtime_projection["model_ref"] == first_spec.model_ref

    assert first_attempt.runtime_projection["runtime_policy"] ==
             first_spec.request_context["ai_agent"]

    assert first_attempt.runtime_projection["browser"] == %{"mode" => "persistent"}
    refute Map.has_key?(first_attempt.runtime_projection, "api_key")

    changed_spec = runtime_turn_start_spec("openai/gpt-5.6-terra")

    assert {:ok, second_attempt} =
             BackgroundAgentJobs.claim_continuation_in_tx(
               Repo,
               job.id,
               agent.uid,
               2,
               changed_spec,
               agent_slot_cap()
             )

    assert second_attempt.attempts == 2
    assert second_attempt.runtime_projection == first_attempt.runtime_projection
    assert second_attempt.runtime_projection["model_ref"]["model"] == "openai/gpt-5.6-sol"
  end

  test "a runtime projection discards the retired Codex compaction key" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "retired-compaction-key")

    assert {:ok, attempt} =
             BackgroundAgentJobs.claim_attempt_in_tx(
               Repo,
               job.id,
               agent.uid,
               1,
               runtime_turn_start_spec_for_provider("chatgpt_subscription"),
               agent_slot_cap()
             )

    refute Map.has_key?(attempt.runtime_projection, "codex")
    stop_claimed_job!(attempt)

    # AIGateway serves the compaction protocol for every Provider, so a Job
    # frozen while the retired key still existed keeps working without it.
    frozen = Map.put(attempt.runtime_projection, "codex", %{"remote_compaction_v2" => true})

    assert {:ok, overrides} = RuntimeProjection.turn_start_overrides(frozen)
    refute Map.has_key?(overrides.request_context, "codex")
  end

  test "runtime projections carry the frozen hosted tool declarations" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "hosted-tool-projection")

    spec =
      runtime_turn_start_spec()
      |> Map.put(:hosted_tools, [%{"type" => "image_generation"}, %{"type" => "web_search"}])

    assert {:ok, attempt} =
             BackgroundAgentJobs.claim_attempt_in_tx(
               Repo,
               job.id,
               agent.uid,
               1,
               spec,
               agent_slot_cap()
             )

    assert attempt.runtime_projection["hosted_tools"] == [
             %{"type" => "image_generation"},
             %{"type" => "web_search"}
           ]

    assert {:ok, overrides} =
             RuntimeProjection.turn_start_overrides(attempt.runtime_projection,
               agent_uid: agent.uid
             )

    assert overrides.hosted_tools == [
             %{"type" => "image_generation"},
             %{"type" => "web_search"}
           ]

    assert {:error, :background_agent_job_runtime_projection_invalid} =
             RuntimeProjection.turn_start_overrides(
               Map.put(attempt.runtime_projection, "hosted_tools", ["web_search"]),
               agent_uid: agent.uid
             )
  end

  test "a legacy projection freezes inferred modalities on its next claim" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "legacy-runtime-modalities")

    assert {:ok, runtime_profile} = ModelProfiles.resolve_runtime_profile(agent.uid, "coding")
    provider_id = runtime_profile["provider_id"]
    assert {:ok, provider} = ProviderConfigs.fetch_provider(provider_id)

    :ok =
      ModelMetadataCache.put(
        {:model_metadata_source, provider_id, provider.updated_at, :openrouter,
         "models?output_modalities=all"},
        [
          %{
            "id" => "openai/gpt-5.6-sol",
            "architecture" => %{"input_modalities" => ["text", "image"]}
          }
        ],
        :timer.hours(1)
      )

    legacy_spec =
      runtime_turn_start_spec("openai/gpt-5.6-sol")
      |> put_in([:model_ref, "provider_id"], provider_id)
      |> put_in([:request_context, "model_ref", "provider_id"], provider_id)
      |> update_in([:model_ref], &Map.delete(&1, "input_modalities"))
      |> update_in([:request_context, "model_ref"], &Map.delete(&1, "input_modalities"))

    assert {:ok, first_attempt} =
             BackgroundAgentJobs.claim_attempt_in_tx(
               Repo,
               job.id,
               agent.uid,
               1,
               legacy_spec,
               agent_slot_cap()
             )

    refute Map.has_key?(first_attempt.runtime_projection["model_ref"], "input_modalities")

    assert {:ok, _changed_profile} =
             ModelProfiles.put_model_profile(agent.uid, "coding", %{
               provider_id: provider_id,
               model: "different/model"
             })

    wrong_type_projection =
      put_in(
        first_attempt.runtime_projection,
        ["model_ref", "provider_kind"],
        "openai"
      )

    assert {:ok, wrong_type_overrides} =
             RuntimeProjection.turn_start_overrides(wrong_type_projection,
               agent_uid: agent.uid
             )

    assert wrong_type_overrides.model_ref["input_modalities"] == ["text"]

    assert {:ok, frozen_overrides} =
             RuntimeProjection.turn_start_overrides(first_attempt.runtime_projection,
               agent_uid: agent.uid
             )

    assert frozen_overrides.model_ref["model"] == "openai/gpt-5.6-sol"
    assert frozen_overrides.model_ref["input_modalities"] == ["text", "image"]

    current_ref =
      Map.merge(legacy_spec.model_ref, %{
        "input_modalities" => ["text"],
        "vision_fallback_model_ref" => %{
          "profile" => "vision_fallback",
          "provider_id" => "openrouter-vision",
          "provider_kind" => "openrouter",
          "model" => "google/gemini-3-flash-preview",
          "input_modalities" => ["text", "image"]
        }
      })

    assert {:ok, mismatched_overrides} =
             RuntimeProjection.turn_start_overrides(first_attempt.runtime_projection,
               current_model_ref: %{current_ref | "model" => "different/model"}
             )

    assert mismatched_overrides.model_ref["input_modalities"] == ["text"]
    refute Map.has_key?(mismatched_overrides.model_ref, "vision_fallback_model_ref")

    assert {:ok, overrides} =
             RuntimeProjection.turn_start_overrides(first_attempt.runtime_projection,
               current_model_ref: current_ref
             )

    assert overrides.model_ref["input_modalities"] == ["text"]

    assert overrides.model_ref["vision_fallback_model_ref"] ==
             current_ref["vision_fallback_model_ref"]

    upgraded_spec =
      runtime_turn_start_spec("openai/gpt-5.6-sol")
      |> Map.put(:model_ref, frozen_overrides.model_ref)
      |> put_in([:request_context, "model_ref"], frozen_overrides.model_ref)

    assert {:ok, second_attempt} =
             BackgroundAgentJobs.claim_continuation_in_tx(
               Repo,
               job.id,
               agent.uid,
               2,
               upgraded_spec,
               agent_slot_cap()
             )

    assert second_attempt.runtime_projection["model_ref"]["input_modalities"] == [
             "text",
             "image"
           ]

    refute Map.has_key?(
             second_attempt.runtime_projection["model_ref"],
             "vision_fallback_model_ref"
           )

    assert second_attempt.runtime_projection["model_ref"]["model"] ==
             first_attempt.runtime_projection["model_ref"]["model"]
  end

  test "claiming a continuation counts compaction-labeled lead failures" do
    %{principal: agent} = background_agent_fixture()

    running =
      agent.uid
      |> create_job!("repeated-turn-failures")
      |> Job.changeset(%{status: "running", runtime_thread_id: "thread-lead"})
      |> Repo.update!()

    for index <- 1..5 do
      insert_custom_turn!(running, %{
        attempt: 1,
        runtime_thread_id: "thread-lead",
        runtime_turn_id: "turn-failed-#{index}",
        kind: "compaction",
        status: "failed",
        trajectory_groups: [[assistant_message("upstream returned HTTP status 502")]],
        error: %{"summary" => "upstream returned HTTP status 502"}
      })
    end

    assert {:error, {:background_agent_job_turn_failures_exhausted, error}} =
             BackgroundAgentJobs.claim_continuation_in_tx(
               Repo,
               running.id,
               agent.uid,
               1,
               runtime_turn_start_spec(),
               agent_slot_cap()
             )

    assert error["summary"] == "upstream returned HTTP status 502"
  end

  test "a completed lead turn clears earlier continuation failures" do
    %{principal: agent} = background_agent_fixture()

    running =
      agent.uid
      |> create_job!("recovered-turn-failures")
      |> Job.changeset(%{status: "running", runtime_thread_id: "thread-lead"})
      |> Repo.update!()

    for index <- 1..5 do
      insert_turn!(running, 1, "thread-lead", "turn-failed-#{index}", "failed", "upstream failed")
    end

    insert_turn!(running, 1, "thread-lead", "turn-recovered", "completed")

    assert {:ok, resumed} =
             BackgroundAgentJobs.claim_continuation_in_tx(
               Repo,
               running.id,
               agent.uid,
               1,
               runtime_turn_start_spec(),
               agent_slot_cap()
             )

    assert resumed.status == "running"
  end

  test "status commits reject missing status and lifecycle regression" do
    %{principal: agent} = background_agent_fixture()
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
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "bounded-wakeup")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-bounded-wakeup"
             })

    running = set_attempts!(running, 1)
    _turn = insert_turn!(running, 1, "thread-bounded-wakeup", "turn-bounded-wakeup", "completed")

    project_path = AgentHomePaths.job_workspace(agent.uid, job.id)

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
                   paths: [
                     project_path,
                     Path.join(AgentHomePaths.user_files(agent.uid), "research-output")
                   ],
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

    assert roots["paths"] == [
             project_path,
             Path.join(AgentHomePaths.user_files(agent.uid), "research-output")
           ]

    refute roots["truncated"]

    assert get_in(wakeup.payload, ["data", "project_path"]) == project_path
    assert byte_size(Ankole.JSON.encode!(wakeup.payload)) <= 32_768
  end

  test "only normalized ankole_chatml headers can be stored as Turns" do
    %{principal: agent} = background_agent_fixture()
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

    assert %{trajectory: ["must be an ankole_chatml v1 header"]} =
             errors_on(changeset)

    header_with_messages =
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
          "messages" => []
        },
        error: %{},
        started_at: now,
        completed_at: now
      })

    refute header_with_messages.valid?
    assert %{trajectory: [message]} = errors_on(header_with_messages)
    assert message =~ "header metadata"

    valid_header =
      Turn.changeset(%Turn{}, %{
        job_id: job.id,
        attempt: 1,
        runtime_thread_id: "thread-header",
        runtime_turn_id: "turn-header",
        kind: "agent",
        status: "completed",
        revision: 1,
        trajectory: trajectory_header(),
        error: %{},
        started_at: now,
        completed_at: now
      })

    assert valid_header.valid?
  end

  test "execution projection paginates every lead semantic group regardless of turn kind" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "execution-projection")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 1, runtime_thread_id: "thread-lead", status: "running"])

    job = Repo.get!(Job, job.id)
    base = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)

    insert_custom_turn!(job, %{
      runtime_thread_id: "thread-lead",
      runtime_turn_id: "turn-lead-1",
      kind: "compaction",
      started_at: base,
      status: "completed",
      completed_at: DateTime.add(base, 1, :microsecond),
      trajectory_groups: [
        [assistant_message("lead-old")],
        [
          tool_call_message("shell-1", "shell"),
          tool_result_message("shell-1", "shell", "done")
        ],
        [assistant_message("context-compaction-recorded")]
      ],
      progress:
        progress_snapshot(3, "shell", ["a.ts"])
        |> Map.put("tool_calls", 2)
        |> Map.put("tools_used", [
          %{"name" => "context_compaction", "calls" => 1},
          %{"name" => "shell", "calls" => 1}
        ]),
      usage: usage_snapshot(100)
    })

    insert_custom_turn!(job, %{
      runtime_thread_id: "thread-child",
      runtime_turn_id: "turn-child-1",
      started_at: DateTime.add(base, 1, :second),
      status: "in_progress",
      trajectory_groups: [[assistant_message("child-report-must-not-appear")]],
      progress:
        progress_snapshot(2, "web_search", ["child.tmp"])
        |> Map.put("tools_used", [
          %{"namespace" => "mcp__search", "name" => "web_search", "calls" => 1}
        ])
        |> Map.put("tool_execution_mechanisms", [
          %{
            "namespace" => "mcp__search",
            "name" => "web_search",
            "execution_mechanism" => "provider_hosted",
            "calls" => 1
          }
        ])
        |> Map.put("active_item", %{
          "id" => "child-search",
          "namespace" => "mcp__search",
          "name" => "web_search"
        }),
      usage: usage_snapshot(999)
    })

    insert_custom_turn!(job, %{
      runtime_thread_id: "thread-lead",
      runtime_turn_id: "turn-lead-2",
      started_at: DateTime.add(base, 3, :second),
      status: "in_progress",
      trajectory_groups: [
        [assistant_message("lead-new-1")],
        [assistant_message("lead-new-2")],
        [
          tool_call_message("patch-1", "apply_patch"),
          tool_result_message("patch-1", "apply_patch", "patched")
        ]
      ],
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
             %{namespace: "mcp__search", name: "web_search", calls: 1}
           ]

    assert execution.progress.tool_execution_mechanisms == [
             %{
               namespace: "mcp__search",
               name: "web_search",
               execution_mechanism: "provider_hosted",
               calls: 1
             }
           ]

    assert execution.progress.files_changed == ["a.ts", "b.ts", "child.tmp"]
    assert execution.progress.plan["explanation"] == "Finish verification"

    assert Enum.sort_by(execution.progress.active_items, & &1.scope) == [
             %{scope: "child", namespace: "mcp__search", name: "web_search"},
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
               trajectory_limit: 3,
               trajectory_cursor: middle.next_cursor
             )

    assert Enum.map(oldest.messages, &Map.get(&1, "role")) == [
             "assistant",
             "assistant",
             "tool",
             "assistant"
           ]

    assert Ankole.JSON.encode!(oldest) =~ "lead-old"
    assert Ankole.JSON.encode!(oldest) =~ "context-compaction-recorded"
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
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "trajectory-page-bytes")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 1, runtime_thread_id: "thread-large"])

    job = Repo.get!(Job, job.id)

    large_turn =
      insert_custom_turn!(job, %{
        runtime_thread_id: "thread-large",
        runtime_turn_id: "turn-large",
        status: "completed",
        completed_at: DateTime.utc_now(:microsecond),
        trajectory_groups: [[assistant_message(String.duplicate("大", 80_000))]]
      })

    large_turn
    |> Turn.changeset(%{
      trajectory: %{
        "format" => "ankole_chatml",
        "version" => 1,
        "metadata" => %{"redacted" => true}
      }
    })
    |> Repo.update!()

    assert {:ok, execution} = Turns.execution_projection(job)
    assert byte_size(Ankole.JSON.encode!(execution.trajectory_page)) <= 24 * 1_024
    assert execution.trajectory_page.messages != []

    assert execution.trajectory_page.metadata == %{
             "redacted" => true,
             "content_truncated" => true
           }
  end

  test "trajectory page projects the stored item stream through a bounded window query" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "item-trajectory-page")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 1, runtime_thread_id: "thread-items"])

    job = Repo.get!(Job, job.id)

    items =
      Enum.flat_map(1..30, fn index ->
        [
          assistant_item("assistant-#{index}", "item-message-#{index}"),
          %{"type" => "reasoning", "id" => "reasoning-#{index}", "summary" => []}
        ]
      end)

    turn =
      insert_custom_turn!(job, %{
        runtime_thread_id: "thread-items",
        runtime_turn_id: "turn-items",
        status: "in_progress",
        trajectory_items: items
      })

    handler_id = "turn-item-window-#{System.unique_integer([:positive])}"
    test_pid = self()
    event = Ankole.Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, pid ->
          if String.contains?(metadata.query, ~s(FROM "background_agent_job_turn_items")) do
            send(pid, {:turn_item_query, metadata.result})
          end
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, execution} = Turns.execution_projection(job, trajectory_limit: 1)

    assert execution.trajectory_page.messages == [
             assistant_item_message("assistant-30", "item-message-30")
           ]

    assert is_binary(execution.trajectory_page.next_cursor)

    item_rows_read =
      Stream.repeatedly(fn ->
        receive do
          {:turn_item_query, {:ok, result}} -> result.num_rows
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(&is_integer/1)
      |> Enum.sum()

    assert item_rows_read < 30

    assert {:ok, second} =
             Turns.execution_projection(job,
               trajectory_limit: 2,
               trajectory_cursor: execution.trajectory_page.next_cursor
             )

    assert second.trajectory_page.messages == [
             assistant_item_message("assistant-28", "item-message-28"),
             assistant_item_message("assistant-29", "item-message-29")
           ]

    replay_only_cursor =
      %{"v" => 1, "attempt" => 1, "turn_id" => turn.id, "group_position" => 1}
      |> Ankole.JSON.encode!()
      |> Base.url_encode64(padding: false)

    assert {:error, :invalid_background_agent_job_trajectory_cursor} =
             Turns.execution_projection(job, trajectory_cursor: replay_only_cursor)
  end

  test "trajectory page merges group-only Turns with item Turns of one attempt in order" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "mixed-trajectory-page")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 1, runtime_thread_id: "thread-mixed"])

    job = Repo.get!(Job, job.id)
    base = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)

    legacy_turn =
      insert_custom_turn!(job, %{
        runtime_thread_id: "thread-mixed",
        runtime_turn_id: "turn-legacy",
        started_at: base,
        status: "completed",
        trajectory_groups: [
          [assistant_message("legacy-old-1")],
          [assistant_message("legacy-old-2")]
        ]
      })

    insert_custom_turn!(job, %{
      runtime_thread_id: "thread-mixed",
      runtime_turn_id: "turn-current",
      started_at: DateTime.add(base, 1, :second),
      status: "in_progress",
      trajectory_items: [
        assistant_item("new-1", "item-new-1"),
        assistant_item("new-2", "item-new-2")
      ]
    })

    assert {:ok, newest} = Turns.execution_projection(job, trajectory_limit: 2)

    assert newest.trajectory_page.messages == [
             assistant_item_message("new-1", "item-new-1"),
             assistant_item_message("new-2", "item-new-2")
           ]

    assert {:ok, older} =
             Turns.execution_projection(job,
               trajectory_limit: 2,
               trajectory_cursor: newest.trajectory_page.next_cursor
             )

    assert older.trajectory_page.messages == [
             assistant_message("legacy-old-1"),
             assistant_message("legacy-old-2")
           ]

    refute Map.has_key?(older.trajectory_page, :next_cursor)

    legacy_cursor =
      %{
        "v" => 1,
        "attempt" => 1,
        "turn_id" => legacy_turn.id,
        "group_position" => 1
      }
      |> Ankole.JSON.encode!()
      |> Base.url_encode64(padding: false)

    assert {:ok, before_legacy} =
             Turns.execution_projection(job, trajectory_cursor: legacy_cursor)

    assert before_legacy.trajectory_page.messages == [assistant_message("legacy-old-1")]
  end

  test "message result reads the causal Turn from its stored item stream" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "causal-item-message")

    job =
      job
      |> Job.changeset(%{
        status: "running",
        attempts: 1,
        runtime_thread_id: "thread-causal-items"
      })
      |> Repo.update!()

    assert {:ok, %{command_event: command_event}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => agent.uid,
               "message" => "Reply from the item stream.",
               "request_id" => "causal-item-message"
             })

    started_at = DateTime.utc_now(:microsecond)

    insert_custom_turn!(job, %{
      runtime_thread_id: job.runtime_thread_id,
      runtime_turn_id: "turn-causal-items",
      started_at: started_at,
      status: "completed",
      trajectory_items: [
        %{
          "type" => "userMessage",
          "id" => "client:#{command_event.id}",
          "content" => [%{"type" => "text", "text" => "Reply from the item stream."}]
        },
        assistant_item("assistant-item-reply", "Item reply recorded.")
      ]
    })

    insert_custom_turn!(job, %{
      runtime_thread_id: job.runtime_thread_id,
      runtime_turn_id: "turn-after-causal-items",
      started_at: DateTime.add(started_at, 1, :microsecond),
      status: "in_progress",
      completed_at: nil,
      trajectory_items: [assistant_item("assistant-continuing", "Continuing the report.")]
    })

    assert {:ok, result} =
             BackgroundAgentJobs.message_result(job, command_event.id, job.owner_session_id)

    assert result.ready
    refute result.earlier_trajectory_omitted

    assert Enum.map(result.last_turn_trajectory["messages"], & &1["content"]) == [
             "Reply from the item stream.",
             "Item reply recorded."
           ]

    refute Enum.any?(
             result.last_turn_trajectory["messages"],
             &(&1["content"] == "Continuing the report.")
           )
  end

  test "waiting accepts the pending user-input request recorded in the item stream" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "waiting-item-gate")

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-waiting-items"
             })

    running = set_attempts!(running, 1)

    insert_custom_turn!(running, %{
      runtime_thread_id: "thread-waiting-items",
      runtime_turn_id: "turn-waiting-items-answered",
      status: "interrupted",
      error: %{"code" => "request_user_input"},
      trajectory_items: [
        %{
          "type" => "dynamicToolCall",
          "id" => "request-user-input-answered",
          "tool" => "request_user_input",
          "arguments" => %{"questions" => []},
          "status" => "completed",
          "contentItems" => "answered",
          "success" => true
        }
      ]
    })

    assert {:error, :background_agent_job_turn_trajectory_incomplete} =
             BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    insert_custom_turn!(running, %{
      runtime_thread_id: "thread-waiting-items",
      runtime_turn_id: "turn-waiting-items-pending",
      status: "interrupted",
      error: %{"code" => "request_user_input"},
      trajectory_items: [
        %{
          "type" => "dynamicToolCall",
          "id" => "request-user-input",
          "tool" => "request_user_input",
          "arguments" => %{"questions" => []},
          "status" => "inProgress"
        }
      ]
    })

    assert {:ok, %{job: %{status: "waiting_on_user"}}} =
             BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })
  end

  test "attempt history reads prior-attempt summaries from the item stream" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "item-attempt-history")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 2, runtime_thread_id: "thread-current-items"])

    job = Repo.get!(Job, job.id)

    insert_custom_turn!(job, %{
      attempt: 1,
      runtime_thread_id: "thread-items-1",
      runtime_turn_id: "turn-items-1",
      status: "completed",
      trajectory_items: [assistant_item("summary-item", "First item attempt report.")]
    })

    assert [%{attempt: 1, summary: "First item attempt report."}] =
             Turns.attempt_history(job)
  end

  test "message result waits through the status commit window and then reports continuation" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "causal-message-continuation")

    job =
      job
      |> Job.changeset(%{
        status: "running",
        attempts: 1,
        runtime_thread_id: "thread-causal-message"
      })
      |> Repo.update!()

    assert {:ok, %{command_event: command_event}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => agent.uid,
               "message" => "Use plain language.",
               "request_id" => "causal-message"
             })

    started_at = DateTime.utc_now(:microsecond)

    causal_turn =
      insert_custom_turn!(job, %{
        runtime_thread_id: job.runtime_thread_id,
        runtime_turn_id: "turn-causal-message",
        kind: "compaction",
        started_at: started_at,
        status: "completed",
        trajectory_groups: [
          %{
            item_key: "client:#{command_event.id}",
            messages: [%{"role" => "user", "content" => "Use plain language."}]
          },
          [assistant_message("I updated the draft.")]
        ]
      })

    causal_turn =
      causal_turn
      |> Turn.changeset(%{
        trajectory: %{
          "format" => "ankole_chatml",
          "version" => 1,
          "metadata" => %{"redacted" => true, "content_truncated" => true}
        }
      })
      |> Repo.update!()

    assert {:ok, %{ready: false, status: "running"}} =
             BackgroundAgentJobs.message_result(job, command_event.id, job.owner_session_id)

    _newer_turn =
      insert_custom_turn!(job, %{
        runtime_thread_id: job.runtime_thread_id,
        runtime_turn_id: "turn-after-causal-message",
        kind: "compaction",
        started_at: DateTime.add(started_at, 1, :microsecond),
        status: "in_progress",
        completed_at: nil,
        trajectory_groups: [[assistant_message("Continuing the report.")]]
      })

    assert {:ok, result} =
             BackgroundAgentJobs.message_result(job, command_event.id, job.owner_session_id)

    assert result.ready
    assert result.status == "running"
    assert result.lifecycle_actor_event_id == nil
    assert result.last_turn_trajectory["format"] == "ankole_chatml"

    assert result.last_turn_trajectory["metadata"] == %{
             "redacted" => true,
             "content_truncated" => true
           }

    assert Enum.any?(
             result.last_turn_trajectory["messages"],
             &(&1["content"] == "I updated the draft.")
           )

    refute Enum.any?(
             result.last_turn_trajectory["messages"],
             &(&1["content"] == "Continuing the report.")
           )

    assert causal_turn.runtime_turn_id == "turn-causal-message"
  end

  test "message result exposes the matching lifecycle event only to its owner session" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "causal-message-waiting")

    job =
      job
      |> Job.changeset(%{
        status: "running",
        attempts: 1,
        runtime_thread_id: "thread-causal-waiting"
      })
      |> Repo.update!()

    assert {:ok, %{command_event: command_event}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => agent.uid,
               "message" => "Operators",
               "request_id" => "causal-waiting"
             })

    insert_custom_turn!(job, %{
      runtime_thread_id: job.runtime_thread_id,
      runtime_turn_id: "turn-causal-waiting",
      status: "interrupted",
      error: %{"code" => "request_user_input", "summary" => "Input required."},
      trajectory_groups: [
        %{
          item_key: "client:#{command_event.id}",
          messages: [%{"role" => "user", "content" => "Operators"}]
        },
        %{item_key: "request-user-input", messages: request_user_input_messages()}
      ]
    })

    assert {:ok, %{job: waiting, wakeup_event: wakeup_event}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    assert {:ok, owner_result} =
             BackgroundAgentJobs.message_result(
               waiting,
               command_event.id,
               waiting.owner_session_id
             )

    assert owner_result.ready
    assert owner_result.status == "waiting_on_user"
    assert owner_result.lifecycle_actor_event_id == wakeup_event.id

    assert {:ok, other_session_result} =
             BackgroundAgentJobs.message_result(
               waiting,
               command_event.id,
               "same-channel-other-session"
             )

    assert other_session_result.ready
    assert other_session_result.lifecycle_actor_event_id == nil
  end

  test "message result returns the causal Turn for succeeded and failed Jobs" do
    %{principal: agent} = background_agent_fixture()

    for {job_status, turn_status} <- [{"succeeded", "completed"}, {"failed", "failed"}] do
      job = create_job!(agent.uid, "causal-message-#{job_status}")

      job =
        job
        |> Job.changeset(%{
          status: "running",
          attempts: 1,
          runtime_thread_id: "thread-causal-#{job_status}"
        })
        |> Repo.update!()

      assert {:ok, %{command_event: command_event}} =
               BackgroundAgentJobs.send_message(job.id, %{
                 "agent_uid" => agent.uid,
                 "message" => "Finish this revision.",
                 "request_id" => "causal-#{job_status}"
               })

      insert_custom_turn!(job, %{
        runtime_thread_id: job.runtime_thread_id,
        runtime_turn_id: "turn-causal-#{job_status}",
        status: turn_status,
        error: if(job_status == "failed", do: %{"summary" => "Revision failed."}, else: %{}),
        trajectory_groups: [
          %{
            item_key: "client:#{command_event.id}",
            messages: [%{"role" => "user", "content" => "Finish this revision."}]
          },
          [assistant_message("Causal #{job_status} output.")]
        ]
      })

      status_attrs =
        case job_status do
          "succeeded" ->
            %{
              "status" => "succeeded",
              "result" => %{
                "summary" => "Revision complete.",
                "project_path" => AgentHomePaths.job_workspace(agent.uid, job.id),
                "artifacts" => %{"total_count" => 0, "paths" => [], "truncated" => false}
              }
            }

          "failed" ->
            %{
              "status" => "failed",
              "error" => %{"code" => "codex_turn_failed", "summary" => "Revision failed."}
            }
        end

      assert {:ok, %{job: committed, wakeup_event: wakeup_event}} =
               BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, status_attrs)

      assert {:ok, result} =
               BackgroundAgentJobs.message_result(
                 committed,
                 command_event.id,
                 committed.owner_session_id
               )

      assert result.ready
      assert result.status == job_status
      assert result.lifecycle_actor_event_id == wakeup_event.id

      assert Enum.any?(
               result.last_turn_trajectory["messages"],
               &(&1["content"] == "Causal #{job_status} output.")
             )
    end
  end

  test "message result reports delivery failure when a completed command has no trajectory" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "undelivered-message")

    job =
      job
      |> Job.changeset(%{status: "running", runtime_thread_id: "thread-undelivered"})
      |> Repo.update!()

    assert {:ok, %{command_event: command_event}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => agent.uid,
               "message" => "This will not reach Codex.",
               "request_id" => "undelivered-message"
             })

    assert {:ok, _completed} =
             Repo.transact(fn repo ->
               locked =
                 Ankole.SignalsGateway.Actors.lock_actor_event_in_tx(repo, command_event.id)

               Ankole.SignalsGateway.mark_actor_event_completed_in_tx(
                 repo,
                 locked,
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert {:error, :background_agent_job_message_delivery_failed} =
             BackgroundAgentJobs.message_result(job, command_event.id, job.owner_session_id)
  end

  test "one runtime Turn id maps to one durable row" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "turn-identity")
    first = insert_turn!(job, 1, "thread-1", "turn-1", "completed")

    assert_raise Ecto.InvalidChangesetError, fn ->
      insert_turn!(job, 1, "thread-1", "turn-1", "completed")
    end

    assert [%{id: id}] = BackgroundAgentJobs.list_turns(job.id)
    assert id == first.id
  end

  test "job summary derives bounded prior-attempt context from Turn trajectories" do
    %{principal: agent} = background_agent_fixture()
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
        trajectory_groups: [[assistant_message(summary)]],
        progress:
          progress_snapshot(1, "shell", [])
          |> then(fn progress ->
            if attempt == 2, do: Map.put(progress, "skills_used", ["pdf"]), else: progress
          end)
      })

      insert_custom_turn!(job, %{
        attempt: attempt,
        runtime_thread_id: "thread-child-#{attempt}",
        runtime_turn_id: "turn-child-#{attempt}",
        started_at: DateTime.add(started_at, 1, :second),
        status: "failed",
        trajectory_groups: [[assistant_message("Child report must not replace #{summary}")]]
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
    assert Enum.at(history, 1).used_skill_names == ["pdf"]
  end

  test "attempt history keeps the lead report when one attempt has more than one hundred child Turns" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "large-attempt-history")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 2, runtime_thread_id: "thread-current"])

    job = Repo.get!(Job, job.id)
    base = DateTime.add(DateTime.utc_now(:microsecond), -200, :second)

    insert_custom_turn!(job, %{
      attempt: 1,
      runtime_thread_id: "thread-lead-1",
      runtime_turn_id: "turn-lead-1",
      kind: "compaction",
      started_at: base,
      status: "failed",
      trajectory_groups: [[assistant_message("Authoritative lead report.")]]
    })

    for index <- 1..101 do
      insert_custom_turn!(job, %{
        attempt: 1,
        runtime_thread_id: "thread-child-#{index}",
        runtime_turn_id: "turn-child-#{index}",
        started_at: DateTime.add(base, index, :second),
        status: "failed",
        trajectory_groups: [[assistant_message("Passive child report #{index}.")]]
      })
    end

    assert [%{attempt: 1, summary: "Authoritative lead report."}] =
             Turns.attempt_history(job)
  end

  test "attempt history reports the durable failure before the last assistant text" do
    %{principal: agent} = background_agent_fixture()
    job = create_job!(agent.uid, "failed-attempt-history")

    from(row in Job, where: row.id == ^job.id)
    |> Repo.update_all(set: [attempts: 2, runtime_thread_id: "thread-current"])

    job = Repo.get!(Job, job.id)

    insert_custom_turn!(job, %{
      attempt: 1,
      runtime_thread_id: "thread-reused",
      runtime_turn_id: "turn-failed",
      status: "failed",
      error: %{
        "code" => "background_agent_job_runtime_exception",
        "summary" =>
          "codex app-server request 019f0000-0000-7000-8000-000000000099 exited with code 143"
      },
      trajectory_groups: [[assistant_message("Stage 1 indexing was in progress.")]]
    })

    assert [
             %{
               attempt: 1,
               turn_statuses: ["failed"],
               summary: "codex app-server request [internal-id] exited with code 143"
             }
           ] = Turns.attempt_history(job)
  end

  # `trajectory_groups` inserts stored group rows only, the shape of a Turn
  # recorded before the item stream existed; `trajectory_items` inserts the
  # semantic TurnItem stream that current Turns store.
  defp insert_custom_turn!(job, attrs) do
    status = Map.get(attrs, :status, "completed")
    started_at = Map.get(attrs, :started_at, DateTime.utc_now(:microsecond))
    {trajectory_groups, attrs} = Map.pop(attrs, :trajectory_groups, [])
    {trajectory_items, attrs} = Map.pop(attrs, :trajectory_items, [])

    defaults = %{
      job_id: job.id,
      attempt: max(job.attempts, 1),
      runtime_thread_id: job.runtime_thread_id || "thread-lead",
      runtime_turn_id: "turn-#{Ecto.UUID.generate()}",
      kind: "agent",
      status: status,
      revision: 1,
      trajectory: trajectory_header(),
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

    turn =
      %Turn{}
      |> Turn.changeset(Map.merge(defaults, attrs))
      |> Repo.insert!()

    Enum.with_index(trajectory_groups, fn group, position ->
      {item_key, messages} =
        case group do
          %{item_key: item_key, messages: messages} -> {item_key, messages}
          %{"item_key" => item_key, "messages" => messages} -> {item_key, messages}
          messages when is_list(messages) -> {"test:#{position}", messages}
        end

      %TrajectoryGroup{}
      |> TrajectoryGroup.changeset(%{
        turn_id: turn.id,
        position: position,
        revision: turn.revision,
        item_key: item_key,
        content: %{"messages" => messages}
      })
      |> Repo.insert!()
    end)

    Enum.with_index(trajectory_items, fn item, position ->
      %TurnItem{}
      |> TurnItem.changeset(%{
        turn_id: turn.id,
        position: position,
        revision: turn.revision,
        item_key: Map.get(item, "id", "item:#{position}"),
        item: item
      })
      |> Repo.insert!()
    end)

    turn
  end

  defp assistant_item(id, text),
    do: %{"type" => "agentMessage", "id" => id, "text" => text}

  defp assistant_item_message(id, text) do
    %{
      "id" => id,
      "role" => "assistant",
      "content" => text,
      "metadata" => %{"phase" => "assistant"}
    }
  end

  defp trajectory_header, do: %{"format" => "ankole_chatml", "version" => 1}

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
    insert_custom_turn!(job, %{
      attempt: attempt,
      runtime_thread_id: runtime_thread_id,
      runtime_turn_id: runtime_turn_id,
      status: status,
      trajectory_groups: [[assistant_message(summary)]],
      error: if(status == "failed", do: %{"summary" => summary}, else: %{}),
      started_at: DateTime.utc_now(:microsecond)
    })
  end

  defp request_user_input_messages(pending? \\ true) do
    [
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
  end

  defp replace_turn_trajectory!(turn, messages, attrs) do
    turn_id = turn.id

    TrajectoryGroup
    |> where([group], group.turn_id == ^turn_id)
    |> Repo.delete_all()

    %TrajectoryGroup{}
    |> TrajectoryGroup.changeset(%{
      turn_id: turn.id,
      position: 0,
      revision: Map.get(attrs, :revision, turn.revision),
      item_key: "test:0",
      content: %{"messages" => messages}
    })
    |> Repo.insert!()

    turn
    |> Turn.changeset(Map.put(attrs, :trajectory, trajectory_header()))
    |> Repo.update!()
  end

  defp insert_waiting_turn!(job, attempt, runtime_thread_id, runtime_turn_id) do
    insert_custom_turn!(job, %{
      attempt: attempt,
      runtime_thread_id: runtime_thread_id,
      runtime_turn_id: runtime_turn_id,
      status: "interrupted",
      revision: 2,
      trajectory_groups: [request_user_input_messages()],
      error: %{"code" => "request_user_input"},
      started_at: DateTime.utc_now(:microsecond)
    })
  end

  defp set_attempts!(job, attempts) do
    job
    |> Ecto.Changeset.change(attempts: attempts)
    |> Repo.update!()
  end

  defp stop_claimed_job!(job) do
    job
    |> Ecto.Changeset.change(status: "stopped", completed_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()
  end

  defp runtime_turn_start_spec(model \\ "openai/gpt-5.6-sol") do
    model_ref = %{
      "profile" => "coding",
      "provider_id" => "openrouter-main",
      "provider_kind" => "openrouter",
      "model" => model,
      "input_modalities" => ["text"]
    }

    %{
      model_ref: model_ref,
      hosted_tools: [%{"type" => "image_generation"}],
      request_context: %{
        "model_ref" => model_ref,
        "ai_agent" => %{
          "runtime" => "codex",
          "max_iterations" => 90,
          "inactivity_timeout_ms" => 1_800_000
        }
      }
    }
  end

  defp runtime_turn_start_spec_for_provider(provider_kind) do
    provider_id = "#{provider_kind}-main"

    runtime_turn_start_spec("gpt-5.6-sol")
    |> put_in([:model_ref, "provider_id"], provider_id)
    |> put_in([:model_ref, "provider_kind"], provider_kind)
    |> put_in([:request_context, "model_ref", "provider_id"], provider_id)
    |> put_in([:request_context, "model_ref", "provider_kind"], provider_kind)
  end

  describe "request_complete/2" do
    test "commits an externally verified completion with a succeeded wakeup and closed steers" do
      %{principal: agent} = background_agent_fixture()
      job = create_job!(agent.uid, "external-complete")

      assert {:ok, %{command_event: steer}} =
               BackgroundAgentJobs.send_message(job.id, %{
                 "agent_uid" => agent.uid,
                 "message" => "Also attach the summary.",
                 "request_id" => "external-complete-steer"
               })

      assert {:ok, %{job: completed}} =
               BackgroundAgentJobs.request_complete(job.id, %{
                 "agent_uid" => agent.uid,
                 "completed_by" => "operator:test",
                 "result_summary" => "PDF verified at /agents/jobs/manual.pdf"
               })

      assert completed.status == "succeeded"
      assert completed.result["summary"] == "PDF verified at /agents/jobs/manual.pdf"
      assert completed.result["completed_by"] == "operator:test"

      # External completion answers open steers with the completion itself and
      # never seeds a successor.
      assert Repo.get!(ActorEvent, steer.id).completed_at != nil
      refute Repo.get_by(Job, continued_from_job_id: job.id)

      wakeup =
        Repo.get_by!(ActorEvent,
          session_id: job.owner_session_id,
          type: "background_agent_job.completed"
        )

      assert get_in(wakeup.payload, ["data", "result_summary"]) ==
               "PDF verified at /agents/jobs/manual.pdf"
    end

    test "refuses to complete a failed Job and stays idempotent for a succeeded one" do
      %{principal: agent} = background_agent_fixture()
      job = create_job!(agent.uid, "external-complete-terminal")

      assert {:ok, _job} =
               job
               |> Job.changeset(%{"status" => "failed", "error" => %{"code" => "boom"}})
               |> Repo.update()

      assert {:error, :background_agent_job_terminal} =
               BackgroundAgentJobs.request_complete(job.id, %{
                 "agent_uid" => agent.uid,
                 "result_summary" => "too late"
               })

      succeeded_job = create_job!(agent.uid, "external-complete-idempotent")

      assert {:ok, %{job: %{status: "succeeded"}}} =
               BackgroundAgentJobs.request_complete(succeeded_job.id, %{
                 "agent_uid" => agent.uid,
                 "result_summary" => "verified"
               })

      assert {:ok, %{job: %{status: "succeeded"}}} =
               BackgroundAgentJobs.request_complete(succeeded_job.id, %{
                 "agent_uid" => agent.uid,
                 "result_summary" => "verified again"
               })
    end

    test "requires a result summary" do
      %{principal: agent} = background_agent_fixture()
      job = create_job!(agent.uid, "external-complete-summary")

      assert {:error, :background_agent_job_result_summary_missing} =
               BackgroundAgentJobs.request_complete(job.id, %{"agent_uid" => agent.uid})
    end
  end

  describe "turn error accounting" do
    test "infrastructure failures use the short ladder and provider failures keep the long one" do
      now = DateTime.utc_now(:microsecond)

      infrastructure = %{
        "code" => "worker_turn_failed",
        "message" => "runtime lost",
        "details_json" => %{
          "error_code" => "background_agent_job_runtime_exception",
          "retryable" => true
        }
      }

      provider = %{
        "code" => "worker_turn_failed",
        "message" => "upstream failed",
        "details_json" => %{"error_code" => "codex_job_transient", "retryable" => true}
      }

      app_server_timeout = %{
        "code" => "worker_turn_failed",
        "message" => "app-server request timed out",
        "details_json" => %{
          "error_code" => "codex_app_server_request_timeout",
          "retryable" => true
        }
      }

      assert BackgroundAgentJobs.turn_error_class(app_server_timeout) == :infrastructure

      assert DateTime.diff(BackgroundAgentJobs.turn_error_retry_at(infrastructure, 1, now), now) ==
               15

      assert DateTime.diff(
               BackgroundAgentJobs.turn_error_retry_at(app_server_timeout, 1, now),
               now
             ) == 15

      assert DateTime.diff(BackgroundAgentJobs.turn_error_retry_at(infrastructure, 5, now), now) ==
               300

      assert DateTime.diff(BackgroundAgentJobs.turn_error_retry_at(provider, 1, now), now) == 60

      assert DateTime.diff(BackgroundAgentJobs.turn_error_retry_at(provider, 5, now), now) ==
               7_200
    end
  end

  describe "health_metrics/0" do
    test "returns the four reliability signals with a bounded window" do
      %{principal: agent} = background_agent_fixture()
      _queued = create_job!(agent.uid, "health-queued")

      metrics = BackgroundAgentJobs.health_metrics()

      assert metrics.queued_count >= 1
      assert is_integer(metrics.oldest_queued_seconds)
      assert metrics.window_seconds == 86_400
      assert is_integer(metrics.claims_24h)
      assert is_integer(metrics.execution_failures_24h)
      assert is_integer(metrics.succeeded_24h)
      assert is_integer(metrics.successor_seeded_24h)
      assert is_integer(metrics.wakeups_24h)
      assert is_integer(metrics.dead_letter_notices_24h)
    end
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

  defp agent_slot_cap,
    do: Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobWorkerConfig.max_running_per_agent()
end
