defmodule Ankole.SubagentDelegationsTest do
  use Ankole.AIGatewayCase

  import Ecto.Query, warn: false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SubagentDelegations
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.SubagentDelegations.Schemas.Turn
  alias Ankole.SubagentDelegations.Text
  alias Ankole.SubagentDelegations.Turns
  alias Ankole.Repo

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
      delegation_id: Ecto.UUID.generate(),
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
        AND table_name = 'subagent_delegation_turns'
        AND column_name IN ('progress', 'usage', 'last_activity_at')
      ORDER BY column_name
      """).rows

    assert [
             ["progress", "NO", progress_default],
             ["usage", "YES", nil]
           ] = columns

    assert progress_default =~ "completed_items"

    assert [["subagent_delegation_turns_progress_object"]] =
             Repo.query!("""
             SELECT constraint_name
             FROM information_schema.table_constraints
             WHERE table_schema = current_schema()
               AND table_name = 'subagent_delegation_turns'
               AND constraint_name = 'subagent_delegation_turns_progress_object'
             """).rows
  end

  test "create_with_dispatch durably creates one queued work item and one isolated dispatch event" do
    assert Delegation.runtimes() == ["task_worker", "deep_research"]
    assert Delegation.modes() == ["general", "forecast", "retrospect"]

    %{principal: agent} = agent_fixture()

    attrs = %{
      "agent_uid" => agent.uid,
      "session_id" => "parent-session",
      "tool_call_id" => "tool-subagent-1",
      "title" => "Prepare the launch brief",
      "task" =>
        "\n  Read the source material, write the brief, and verify every acceptance criterion.  \n",
      "background" => "The brief is for the operations team.",
      "notes" => "Keep the handoff concise.",
      "workdir" => "/workspace/user-files/subagent/019f",
      "reply_route" => %{
        "binding_name" => "lark",
        "signal_channel_id" => "chat-1",
        "provider_thread_id" => "thread-1",
        "source_entry_id" => "message-1"
      }
    }

    assert {:ok, %{delegation: %Delegation{} = delegation, dispatch_event: %ActorEvent{} = event}} =
             SubagentDelegations.create_with_dispatch(attrs)

    assert delegation.runtime == "task_worker"
    assert delegation.status == "queued"
    assert delegation.attempts == 0
    assert delegation.title == attrs["title"]
    assert delegation.task == attrs["task"]
    assert delegation.background == attrs["background"]
    assert delegation.notes == attrs["notes"]
    assert delegation.reply_route == attrs["reply_route"]

    assert event.agent_uid == agent.uid
    assert event.binding_name == "lark"
    assert event.session_id == "subagent:#{delegation.id}"
    assert event.signal_channel_id == "chat-1"
    assert event.provider_thread_id == "thread-1"
    assert event.source_entry_id == "message-1"
    assert event.type == "subagent.delegation.dispatch"
    assert event.source_event_id == "subagent_delegation:#{delegation.id}:dispatch:0"

    assert get_in(event.payload, ["data", "delegation_id"]) == delegation.id
    assert get_in(event.payload, ["data", "parent_session_id"]) == "parent-session"
    assert get_in(event.payload, ["data", "workdir"]) == attrs["workdir"]
    assert get_in(event.payload, ["data", "attempts"]) == 0
    refute inspect(event.payload) =~ attrs["task"]

    assert {:ok, %{delegation: same_delegation, dispatch_event: same_event}} =
             SubagentDelegations.create_with_dispatch(attrs)

    assert same_delegation.id == delegation.id
    assert same_event.id == event.id
    assert Repo.aggregate(Delegation, :count) == 1
    assert Repo.aggregate(ActorEvent, :count) == 1
  end

  test "deep research contracts default mode and workdir while task workers reject research fields" do
    %{principal: agent} = agent_fixture()

    attrs = %{
      "agent_uid" => agent.uid,
      "session_id" => "parent-session-research",
      "tool_call_id" => "tool-deep-research",
      "runtime" => "deep_research",
      "title" => "Research the policy change",
      "task" => "Produce a cited research report.",
      "reply_route" => %{"binding_name" => "lark"}
    }

    assert {:ok, %{delegation: research}} =
             SubagentDelegations.create_with_dispatch(attrs)

    assert research.mode == "general"
    assert research.workdir == "/workspace/user-files/research/#{research.id}"

    assert {:error, changeset} =
             SubagentDelegations.create_with_dispatch(
               Map.merge(attrs, %{
                 "session_id" => "parent-session-task-worker-research-fields",
                 "tool_call_id" => "tool-task-worker-research-fields",
                 "runtime" => "task_worker",
                 "mode" => "forecast"
               })
             )

    assert %{runtime: ["task_worker does not accept research fields"]} = errors_on(changeset)
  end

  test "retrospect only accepts a succeeded forecast owned by the same agent" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()

    assert {:ok, %{delegation: forecast}} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "session_id" => "parent-session-forecast-source",
               "tool_call_id" => "tool-forecast-source",
               "runtime" => "deep_research",
               "mode" => "forecast",
               "title" => "Forecast a policy outcome",
               "task" => "Produce the forecast dossier.",
               "reply_route" => %{"binding_name" => "lark"}
             })

    forecast
    |> Delegation.changeset(%{
      status: "succeeded",
      started_at: DateTime.utc_now(:microsecond),
      completed_at: DateTime.utc_now(:microsecond),
      result: %{
        "dossier" => %{"question" => "Will it pass?"},
        "conclusion" => %{"verdict" => "estimate"},
        "output_text" => "must not be injected into retrospect",
        "verification" => %{"private" => "must not be injected into retrospect"}
      }
    })
    |> Repo.update!()

    retrospect_attrs = %{
      "agent_uid" => agent.uid,
      "session_id" => "parent-session-retrospect",
      "tool_call_id" => "tool-retrospect",
      "runtime" => "deep_research",
      "mode" => "retrospect",
      "source_delegation_id" => forecast.id,
      "actual_outcome" => false,
      "title" => "Retrospect the forecast",
      "task" => "Audit the forecast against the outcome.",
      "reply_route" => %{"binding_name" => "lark"}
    }

    assert {:ok, %{delegation: retrospect}} =
             SubagentDelegations.create_with_dispatch(retrospect_attrs)

    assert retrospect.source_delegation_id == forecast.id
    assert retrospect.actual_outcome == false

    assert {:ok, %{source_forecast: source_forecast}} =
             SubagentDelegations.get_delegation_summary_for_agent(retrospect.id, agent.uid)

    assert source_forecast.result == %{
             "dossier" => %{"question" => "Will it pass?"},
             "conclusion" => %{"verdict" => "estimate"}
           }

    refute inspect(source_forecast) =~ "must not be injected"

    assert {:error, :retrospect_source_delegation_not_found} =
             SubagentDelegations.create_with_dispatch(%{
               retrospect_attrs
               | "agent_uid" => other_agent.uid,
                 "session_id" => "other-retrospect",
                 "tool_call_id" => "other-retrospect"
             })

    assert {:ok, %{delegation: wrong_mode_source}} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "session_id" => "wrong-mode-source",
               "tool_call_id" => "wrong-mode-source",
               "runtime" => "deep_research",
               "mode" => "general",
               "title" => "General research is not a forecast source",
               "task" => "Produce general research.",
               "reply_route" => %{"binding_name" => "lark"}
             })

    wrong_mode_source
    |> Delegation.changeset(%{
      status: "succeeded",
      started_at: DateTime.utc_now(:microsecond),
      completed_at: DateTime.utc_now(:microsecond)
    })
    |> Repo.update!()

    assert {:error, :invalid_retrospect_source_delegation} =
             SubagentDelegations.create_with_dispatch(%{
               retrospect_attrs
               | "session_id" => "wrong-mode-retrospect",
                 "tool_call_id" => "wrong-mode-retrospect",
                 "source_delegation_id" => wrong_mode_source.id
             })

    assert {:ok, %{delegation: failed_source}} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "session_id" => "failed-forecast-source",
               "tool_call_id" => "failed-forecast-source",
               "runtime" => "deep_research",
               "mode" => "forecast",
               "title" => "Failed forecast source",
               "task" => "This forecast fails.",
               "reply_route" => %{"binding_name" => "lark"}
             })

    failed_source
    |> Delegation.changeset(%{
      status: "failed",
      started_at: DateTime.utc_now(:microsecond),
      completed_at: DateTime.utc_now(:microsecond)
    })
    |> Repo.update!()

    assert {:error, :invalid_retrospect_source_delegation} =
             SubagentDelegations.create_with_dispatch(%{
               retrospect_attrs
               | "session_id" => "failed-source-retrospect",
                 "tool_call_id" => "failed-source-retrospect",
                 "source_delegation_id" => failed_source.id
             })
  end

  test "success requires a completed lead Turn but does not gate on Codex child Turn state" do
    %{principal: agent} = agent_fixture()

    assert {:ok, %{delegation: research}} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "session_id" => "parent-session-trajectory-gate",
               "tool_call_id" => "tool-trajectory-gate",
               "runtime" => "deep_research",
               "title" => "Research with a durable trajectory",
               "task" => "Produce the report.",
               "reply_route" => %{"binding_name" => "lark"}
             })

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(research.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-trajectory"
             })

    running = running |> Ecto.Changeset.change(attempts: 1) |> Repo.update!()

    assert {:error, :subagent_turn_trajectory_incomplete} =
             SubagentDelegations.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "must wait for the Turn"}
             })

    active_child =
      insert_turn!(running, 1, "thread-child", "turn-child-active", "in_progress")

    turn = insert_turn!(running, 1, "thread-trajectory", "turn-trajectory", "completed")

    assert {:ok, %{delegation: succeeded}} =
             SubagentDelegations.commit_status_with_wakeup(running.id, agent.uid, %{
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
    delegation = create_delegation!(agent.uid, "trajectory-gate-without-anchor")

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "running"
             })

    assert {:error, :subagent_turn_trajectory_incomplete} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "attempt zero must not bypass the trajectory"}
             })

    _running = set_attempts!(running, 1)

    assert {:error, :subagent_turn_trajectory_incomplete} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "must not bypass trajectory persistence"}
             })
  end

  test "waiting requires the interrupted Turn that contains the pending user-input request" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "waiting-trajectory-gate")

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-waiting-trajectory-gate"
             })

    assert {:error, :subagent_turn_trajectory_incomplete} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    _running = set_attempts!(running, 1)

    assert {:error, :subagent_turn_trajectory_incomplete} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    _completed =
      insert_turn!(
        delegation,
        1,
        "thread-waiting-trajectory-gate",
        "turn-completed-without-question",
        "completed"
      )

    assert {:error, :subagent_turn_trajectory_incomplete} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    interrupted =
      insert_turn!(
        delegation,
        1,
        "thread-waiting-trajectory-gate",
        "turn-interrupted-without-question",
        "interrupted"
      )

    assert {:error, :subagent_turn_trajectory_incomplete} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
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
        delegation,
        1,
        "thread-waiting-child",
        "turn-interrupted-with-question"
      )

    assert {:error, :subagent_turn_trajectory_incomplete} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
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

    assert {:ok, %{delegation: %{status: "waiting_on_user"}}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })
  end

  test "waiting cannot close an attempt while one of its runtime Turns is active" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "waiting-turn-gate")

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
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

    assert {:error, :subagent_turn_trajectory_incomplete} =
             SubagentDelegations.commit_status_with_wakeup(running.id, agent.uid, %{
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

    assert {:ok, %{delegation: %{status: "waiting_on_user"}}} =
             SubagentDelegations.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })
  end

  test "creation rejects workdirs outside the delegated workspace before journaling work" do
    %{principal: agent} = agent_fixture()

    assert {:error, changeset} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "session_id" => "parent-session-invalid-workdir",
               "tool_call_id" => "tool-subagent-invalid-workdir",
               "title" => "Invalid workdir",
               "task" => "This must never be dispatched.",
               "workdir" => "/workspace/user-files/../../etc",
               "reply_route" => %{"binding_name" => "lark"}
             })

    assert %{workdir: ["must stay under /workspace"]} = errors_on(changeset)
    assert Repo.aggregate(Delegation, :count) == 0
    assert Repo.aggregate(ActorEvent, :count) == 0
  end

  test "status commits wake the parent only for waiting and result-bearing terminal states" do
    %{principal: agent} = agent_fixture()
    waiting = create_delegation!(agent.uid, "waiting")

    assert {:ok, %{delegation: running, wakeup_event: nil}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
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

    assert {:ok, %{delegation: paused, wakeup_event: %ActorEvent{} = waiting_event}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => pending_user_input}
             })

    assert paused.status == "waiting_on_user"
    assert waiting_event.session_id == "parent-session-waiting"
    assert waiting_event.type == "subagent.delegation.waiting"
    assert waiting_event.source_event_id == "subagent_delegation:#{waiting.id}:waiting:1"
    assert get_in(waiting_event.payload, ["data", "pending_user_input"]) == pending_user_input

    assert {:ok, %{delegation: resumed, wakeup_event: nil}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "running"
             })

    assert resumed.status == "running"

    _completed_turn =
      insert_turn!(resumed, 1, "thread-waiting", "turn-resumed", "completed")

    assert {:ok, %{delegation: succeeded, wakeup_event: %ActorEvent{} = completed_event}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "Launch brief written and verified."}
             })

    assert succeeded.status == "succeeded"
    assert completed_event.type == "subagent.delegation.completed"
    assert completed_event.source_event_id == "subagent_delegation:#{waiting.id}:succeeded:1"

    assert get_in(completed_event.payload, ["data", "result_summary"]) ==
             "Launch brief written and verified."

    failed = create_delegation!(agent.uid, "failed")

    assert {:ok, %{delegation: _running_failed}} =
             SubagentDelegations.commit_status_with_wakeup(failed.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-failed"
             })

    assert {:ok, %{delegation: failed, wakeup_event: %ActorEvent{} = failed_event}} =
             SubagentDelegations.commit_status_with_wakeup(failed.id, agent.uid, %{
               "status" => "failed",
               "error" => %{
                 "code" => "codex_turn_failed",
                 "summary" => "The provider disconnected."
               }
             })

    assert failed.status == "failed"
    assert failed_event.type == "subagent.delegation.failed"
    assert get_in(failed_event.payload, ["data", "delegation_id"]) == failed.id
    assert get_in(failed_event.payload, ["data", "runtime"]) == "task_worker"
    assert get_in(failed_event.payload, ["data", "workdir"]) == failed.workdir

    stopped = create_delegation!(agent.uid, "stopped")

    assert {:ok, %{delegation: stopped, wakeup_event: nil}} =
             SubagentDelegations.commit_status_with_wakeup(stopped.id, agent.uid, %{
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
            event.type in ^~w(subagent.delegation.waiting subagent.delegation.completed subagent.delegation.failed)
      )

    assert Enum.map(parent_wakeups, & &1.type) |> Enum.sort() ==
             [
               "subagent.delegation.completed",
               "subagent.delegation.failed",
               "subagent.delegation.waiting"
             ]
  end

  test "status and parent wakeup roll back together when the frozen reply route is invalid" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "invalid-route")

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-invalid-route"
             })

    running = set_attempts!(running, 1)
    _turn = insert_turn!(running, 1, "thread-invalid-route", "turn-invalid-route", "completed")

    from(row in Delegation, where: row.id == ^delegation.id)
    |> Repo.update_all(set: [reply_route: %{}])

    assert {:error, :subagent_reply_route_binding_missing} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "must not commit"}
             })

    persisted = Repo.get!(Delegation, delegation.id)
    assert persisted.status == running.status
    assert persisted.completed_at == nil

    refute Repo.exists?(
             from event in ActorEvent,
               where: event.session_id == ^delegation.session_id,
               where: event.type == "subagent.delegation.completed"
           )
  end

  test "stop is durable and idempotent while running work also receives an interrupt command" do
    %{principal: agent} = agent_fixture()
    queued = create_delegation!(agent.uid, "queued-stop")

    assert {:ok, %{delegation: stopped, command_event: nil}} =
             SubagentDelegations.request_stop(queued.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:ding",
               "reason" => "No longer needed"
             })

    assert stopped.status == "stopped"
    assert stopped.metadata["cancel_requested_by"] == "operator:ding"

    dispatch =
      Repo.one!(
        from event in ActorEvent,
          where: event.session_id == ^"subagent:#{queued.id}",
          where: event.type == "subagent.delegation.dispatch"
      )

    assert %DateTime{} = dispatch.completed_at

    assert {:ok, %{delegation: same_stopped, command_event: nil}} =
             SubagentDelegations.request_stop(queued.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:ding"
             })

    assert same_stopped.id == stopped.id

    running = create_delegation!(agent.uid, "running-stop")

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "running"
             })

    assert {:ok, %{delegation: running_stopped, command_event: %ActorEvent{} = stop_event}} =
             SubagentDelegations.request_stop(running.id, %{
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
    assert stop_event.session_id == "subagent:#{running.id}"
    assert get_in(stop_event.payload, ["data", "command", "argsText"]) == "Changed priorities"

    waiting = create_delegation!(agent.uid, "waiting-stop")

    assert {:ok, %{delegation: running_before_wait}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
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

    assert {:ok, %{delegation: waiting}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    assert {:ok, %{delegation: waiting_stopped, command_event: nil}} =
             SubagentDelegations.request_stop(waiting.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:ding"
             })

    assert waiting_stopped.status == "stopped"

    refute Repo.exists?(
             from event in ActorEvent,
               where: event.session_id == ^"subagent:#{waiting.id}",
               where: event.type == "command.stop"
           )
  end

  test "steer journals text and answers and list visibility is bounded by parent session or channel" do
    %{principal: agent} = agent_fixture()
    same_session = create_delegation!(agent.uid, "same-session")
    same_channel = create_delegation!(agent.uid, "same-channel")
    other_channel = create_delegation!(agent.uid, "other-channel")

    from(row in Delegation, where: row.id == ^same_channel.id)
    |> Repo.update_all(
      set: [
        session_id: "historical-session",
        reply_route: %{"binding_name" => "lark", "signal_channel_id" => "chat-same-session"}
      ]
    )

    assert {:ok, %{delegation: ^same_session, command_event: %ActorEvent{} = steer_event}} =
             SubagentDelegations.request_steer(same_session.id, %{
               "agent_uid" => agent.uid,
               "text" => "Use the operator audience.",
               "answers" => %{"audience" => "Operators"},
               "request_id" => "steer-same-session"
             })

    assert steer_event.type == "command.steer"

    assert get_in(steer_event.payload, ["data", "command", "argsText"]) ==
             "Use the operator audience."

    assert get_in(steer_event.payload, ["data", "command", "answers"]) == %{
             "audience" => "Operators"
           }

    listed =
      SubagentDelegations.list_for_channel(
        agent.uid,
        same_session.session_id,
        "chat-same-session"
      )

    assert Enum.map(listed, & &1.id) |> MapSet.new() ==
             MapSet.new([same_session.id, same_channel.id])

    refute Enum.any?(listed, &(&1.id == other_channel.id))
  end

  test "steer queues a settled delegation for continuation in its existing runtime thread" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "settled-continuation")

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-settled-continuation"
             })

    running = set_attempts!(running, 1)
    _turn = insert_turn!(running, 1, "thread-settled-continuation", "turn-settled", "completed")

    assert {:ok, %{delegation: succeeded}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "Candidate result"}
             })

    assert {:ok, %{delegation: queued, command_event: %ActorEvent{} = steer_event}} =
             SubagentDelegations.request_steer(succeeded.id, %{
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

  test "status commits reject missing status and lifecycle regression" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "status-transition")

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "running"
             })

    assert {:error, :subagent_delegation_status_missing} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "metadata" => %{"ignored" => true}
             })

    assert {:error, {:invalid_subagent_status_transition, "running", "queued"}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "queued"
             })

    assert Repo.get!(Delegation, delegation.id).status == running.status
  end

  test "parent wakeup summaries are bounded to 16KB of valid UTF-8" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "bounded-wakeup")

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-bounded-wakeup"
             })

    running = set_attempts!(running, 1)
    _turn = insert_turn!(running, 1, "thread-bounded-wakeup", "turn-bounded-wakeup", "completed")

    assert {:ok, %{wakeup_event: wakeup}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => String.duplicate("大", 20_000)}
             })

    summary = get_in(wakeup.payload, ["data", "result_summary"])
    assert String.valid?(summary)
    assert byte_size(summary) <= 16_384
    assert String.ends_with?(summary, "...[truncated]")
  end

  test "only normalized ankole_chatml trajectories can be stored as Turns" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "trajectory-shape")
    now = DateTime.utc_now(:microsecond)

    changeset =
      Turn.changeset(%Turn{}, %{
        delegation_id: delegation.id,
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
        delegation_id: delegation.id,
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
        delegation_id: delegation.id,
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

    refute oversized.valid?
    assert %{trajectory: [size_error]} = errors_on(oversized)
    assert size_error =~ "encoded bytes"
  end

  test "execution projection aggregates one attempt while paginating only lead agent semantic groups" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "execution-projection")

    from(row in Delegation, where: row.id == ^delegation.id)
    |> Repo.update_all(set: [attempts: 1, runtime_thread_id: "thread-lead", status: "running"])

    delegation = Repo.get!(Delegation, delegation.id)
    base = DateTime.add(DateTime.utc_now(:microsecond), -10, :second)

    insert_custom_turn!(delegation, %{
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

    insert_custom_turn!(delegation, %{
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

    insert_custom_turn!(delegation, %{
      runtime_thread_id: "thread-lead",
      runtime_turn_id: "turn-compaction-1",
      kind: "compaction",
      started_at: DateTime.add(base, 2, :second),
      status: "completed",
      completed_at: DateTime.add(base, 2, :second),
      trajectory: trajectory([assistant_message("compaction-must-not-appear")]),
      progress: progress_snapshot(1, "context_compaction", [])
    })

    insert_custom_turn!(delegation, %{
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
             SubagentDelegations.get_delegation_summary_for_agent(delegation.id, agent.uid)

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
             SubagentDelegations.get_delegation_summary_for_agent(delegation.id, agent.uid,
               trajectory_limit: 1
             )

    assert Enum.map(newest.messages, &Map.get(&1, "role")) == ["assistant", "tool"]
    assert is_binary(newest.next_cursor)

    assert {:ok, %{execution: %{trajectory_page: middle}}} =
             SubagentDelegations.get_delegation_summary_for_agent(delegation.id, agent.uid,
               trajectory_limit: 2,
               trajectory_cursor: newest.next_cursor
             )

    assert Enum.map(middle.messages, &Map.get(&1, "content")) == ["lead-new-1", "lead-new-2"]
    assert is_binary(middle.next_cursor)

    assert {:ok, %{execution: %{trajectory_page: oldest}}} =
             SubagentDelegations.get_delegation_summary_for_agent(delegation.id, agent.uid,
               trajectory_limit: 2,
               trajectory_cursor: middle.next_cursor
             )

    assert Enum.map(oldest.messages, &Map.get(&1, "role")) == ["assistant", "assistant", "tool"]
    refute Map.has_key?(oldest, :next_cursor)

    assert {:error, :invalid_subagent_trajectory_cursor} =
             SubagentDelegations.get_delegation_summary_for_agent(delegation.id, agent.uid,
               trajectory_cursor: "not-a-cursor"
             )

    from(row in Delegation, where: row.id == ^delegation.id)
    |> Repo.update_all(set: [status: "failed"])

    terminal = Repo.get!(Delegation, delegation.id)
    assert {:ok, terminal_execution} = Turns.execution_projection(terminal)
    assert terminal_execution.progress.active_items == []
    assert terminal_execution.turns.active == 2

    from(row in Delegation, where: row.id == ^delegation.id)
    |> Repo.update_all(set: [attempts: 2])

    assert {:error, :subagent_trajectory_cursor_stale} =
             SubagentDelegations.get_delegation_summary_for_agent(delegation.id, agent.uid,
               trajectory_cursor: newest.next_cursor
             )
  end

  test "trajectory pages stay within 24 KiB even when one semantic message is large" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "trajectory-page-bytes")

    from(row in Delegation, where: row.id == ^delegation.id)
    |> Repo.update_all(set: [attempts: 1, runtime_thread_id: "thread-large"])

    delegation = Repo.get!(Delegation, delegation.id)

    insert_custom_turn!(delegation, %{
      runtime_thread_id: "thread-large",
      runtime_turn_id: "turn-large",
      status: "completed",
      completed_at: DateTime.utc_now(:microsecond),
      trajectory: trajectory([assistant_message(String.duplicate("大", 80_000))])
    })

    assert {:ok, execution} = Turns.execution_projection(delegation)
    assert byte_size(Ankole.JSON.encode!(execution.trajectory_page)) <= 24 * 1_024
    assert execution.trajectory_page.messages != []
  end

  test "one runtime Turn id maps to one durable row" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "turn-identity")
    first = insert_turn!(delegation, 1, "thread-1", "turn-1", "completed")

    assert_raise Ecto.InvalidChangesetError, fn ->
      insert_turn!(delegation, 1, "thread-1", "turn-1", "completed")
    end

    assert [%{id: id}] = SubagentDelegations.list_turns(delegation.id)
    assert id == first.id
  end

  test "delegation summary derives bounded prior-attempt context from Turn trajectories" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "attempt-history")

    from(row in Delegation, where: row.id == ^delegation.id)
    |> Repo.update_all(set: [attempts: 4, runtime_thread_id: "thread-current-attempt"])

    base = DateTime.add(DateTime.utc_now(:microsecond), -60, :second)

    for {attempt, summary} <- [
          {1, "First attempt failed."},
          {2, "Second attempt failed."},
          {3, "Third attempt failed."}
        ] do
      started_at = DateTime.add(base, attempt * 10, :second)

      insert_custom_turn!(delegation, %{
        attempt: attempt,
        runtime_thread_id: "thread-lead-#{attempt}",
        runtime_turn_id: "turn-lead-#{attempt}",
        started_at: started_at,
        status: "failed",
        trajectory: trajectory([assistant_message(summary)])
      })

      insert_custom_turn!(delegation, %{
        attempt: attempt,
        runtime_thread_id: "thread-child-#{attempt}",
        runtime_turn_id: "turn-child-#{attempt}",
        started_at: DateTime.add(started_at, 1, :second),
        status: "failed",
        trajectory: trajectory([assistant_message("Child report must not replace #{summary}")])
      })
    end

    assert {:ok, %{execution: execution, attempt_history: history}} =
             SubagentDelegations.get_delegation_summary_for_agent(delegation.id, agent.uid)

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
    delegation = create_delegation!(agent.uid, "large-attempt-history")

    from(row in Delegation, where: row.id == ^delegation.id)
    |> Repo.update_all(set: [attempts: 2, runtime_thread_id: "thread-current"])

    delegation = Repo.get!(Delegation, delegation.id)
    base = DateTime.add(DateTime.utc_now(:microsecond), -200, :second)

    insert_custom_turn!(delegation, %{
      attempt: 1,
      runtime_thread_id: "thread-lead-1",
      runtime_turn_id: "turn-lead-1",
      started_at: base,
      status: "failed",
      trajectory: trajectory([assistant_message("Authoritative lead report.")])
    })

    for index <- 1..101 do
      insert_custom_turn!(delegation, %{
        attempt: 1,
        runtime_thread_id: "thread-child-#{index}",
        runtime_turn_id: "turn-child-#{index}",
        started_at: DateTime.add(base, index, :second),
        status: "failed",
        trajectory: trajectory([assistant_message("Passive child report #{index}.")])
      })
    end

    assert [%{attempt: 1, summary: "Authoritative lead report."}] =
             Turns.attempt_history(delegation)
  end

  defp insert_custom_turn!(delegation, attrs) do
    status = Map.get(attrs, :status, "completed")
    started_at = Map.get(attrs, :started_at, DateTime.utc_now(:microsecond))

    defaults = %{
      delegation_id: delegation.id,
      attempt: max(delegation.attempts, 1),
      runtime_thread_id: delegation.runtime_thread_id || "thread-lead",
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
         delegation,
         attempt,
         runtime_thread_id,
         runtime_turn_id,
         status,
         summary \\ "Turn complete."
       ) do
    now = DateTime.utc_now(:microsecond)

    %Turn{}
    |> Turn.changeset(%{
      delegation_id: delegation.id,
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

  defp insert_waiting_turn!(delegation, attempt, runtime_thread_id, runtime_turn_id) do
    delegation
    |> insert_turn!(attempt, runtime_thread_id, runtime_turn_id, "interrupted")
    |> Turn.changeset(%{
      trajectory: request_user_input_trajectory(),
      revision: 2,
      error: %{"code" => "request_user_input"}
    })
    |> Repo.update!()
  end

  defp set_attempts!(delegation, attempts) do
    delegation
    |> Ecto.Changeset.change(attempts: attempts)
    |> Repo.update!()
  end

  defp create_delegation!(agent_uid, suffix) do
    assert {:ok, %{delegation: delegation}} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "session_id" => "parent-session-#{suffix}",
               "tool_call_id" => "tool-subagent-#{suffix}",
               "title" => "Delegation #{suffix}",
               "task" => "Complete the #{suffix} delegation.",
               "workdir" => "/workspace/user-files/subagent/#{suffix}",
               "reply_route" => %{
                 "binding_name" => "lark",
                 "signal_channel_id" => "chat-#{suffix}",
                 "provider_thread_id" => "thread-#{suffix}",
                 "source_entry_id" => "message-#{suffix}"
               }
             })

    delegation
  end
end
