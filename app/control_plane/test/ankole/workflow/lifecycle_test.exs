defmodule Ankole.WorkflowTest do
  # Serial because one test leaves the sandbox with `unboxed_run` to prove the
  # admission advisory lock across two real database transactions.
  use Ankole.DataCase, async: false

  import Ankole.AIGatewayCase, only: [background_agent_fixture: 0]
  import Ankole.PrincipalsFixtures

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Workflow
  alias Ankole.Workflow.Program
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run
  alias Ecto.Adapters.SQL.Sandbox

  @memo_budget_bytes 6 * 1_024 * 1_024

  for {name, outcome} <- [
        {"success", %{"ok" => true, "value" => "done"}},
        {"retry",
         %{"ok" => false, "code" => "retry", "summary" => "Retry this call", "retryable" => true}}
      ] do
    @outcome outcome
    test "#{name} releases an Agent slot and wakes another run after commit" do
      %{principal: agent} = agent_fixture()
      %{principal: other_agent} = agent_fixture()
      run = run_fixture(agent.uid)
      waiting_run = run_fixture(agent.uid)
      other_run = run_fixture(other_agent.uid)
      {:ok, call} = insert_call(run, 0, %{"type" => "string"})
      {:ok, waiting} = insert_call(waiting_run, 0, %{"type" => "string"})
      {:ok, other} = insert_call(other_run, 0, %{"type" => "string"})

      assert {:ok, _} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 1)
               end)

      assert {:error, :workflow_agent_at_capacity} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.claim_task_in_tx(waiting.id, agent.uid, 1)
               end)

      deferred_at = DateTime.add(DateTime.utc_now(:microsecond), 30, :second)

      for waiter <- [other, waiting] do
        assert {:ok, _} =
                 Workflow.defer_task_event(dispatch_event!(waiter), deferred_at, :agent_capacity)
      end

      assert {:ok, %{released_slot?: true} = transition} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.submit_result_in_tx(
                   call.id,
                   agent.uid,
                   Workflow.task_session_id(call.id),
                   @outcome
                 )
               end)

      assert dispatch_event!(waiting).available_at == deferred_at
      assert {:ok, _} = Workflow.cleanup_terminal_transition({:ok, transition})
      assert DateTime.before?(dispatch_event!(waiting).available_at, deferred_at)
      assert dispatch_event!(other).available_at == deferred_at
      assert Repo.get!(AgentCall, waiting.id).wake_at == dispatch_event!(waiting).available_at

      assert {:ok, %{call: %{status: :running}}} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.claim_task_in_tx(waiting.id, agent.uid, 1)
               end)
    end
  end

  test "capacity wakeups skip a run whose own concurrency limit is still full" do
    %{principal: agent} = agent_fixture()
    full_run = run_fixture(agent.uid, concurrency: 1)
    releasing_run = run_fixture(agent.uid)
    waiting_run = run_fixture(agent.uid)
    {:ok, active} = insert_call(full_run, 0, %{"type" => "string"})
    {:ok, blocked} = insert_call(full_run, 1, %{"type" => "string"})
    {:ok, releasing} = insert_call(releasing_run, 0, %{"type" => "string"})
    {:ok, waiting} = insert_call(waiting_run, 0, %{"type" => "string"})

    for call <- [active, releasing] do
      assert {:ok, _} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 2)
               end)
    end

    deferred_at = DateTime.add(DateTime.utc_now(:microsecond), 30, :second)

    for call <- [blocked, waiting] do
      assert {:error, :workflow_agent_at_capacity} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 2)
               end)

      assert {:ok, _} =
               Workflow.defer_task_event(dispatch_event!(call), deferred_at, :agent_capacity)
    end

    assert {:ok, _} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 releasing.id,
                 agent.uid,
                 Workflow.task_session_id(releasing.id),
                 %{
                   "ok" => true,
                   "value" => "done"
                 }
               )
             end)
             |> Workflow.cleanup_terminal_transition()

    assert dispatch_event!(blocked).available_at == deferred_at
    assert DateTime.before?(dispatch_event!(waiting).available_at, deferred_at)
  end

  test "a native conversation dispatches Workflow tasks and receives the inherited result" do
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    id = Ecto.UUID.generate()

    assert {:ok, detail} =
             Repo.transact(fn _ ->
               Ankole.ConversationsFixtures.create(human.uid, %{
                 conversation_id: id,
                 message_id: Ecto.UUID.generate(),
                 agent_uid: agent.uid,
                 text: "Review the case."
               })
             end)

    source = Repo.get_by!(Signal, message_id: hd(detail.messages).id)

    assert {:ok, %{run: run}} =
             Workflow.create_with_dispatch(%{
               "source_signal_id" => source.id,
               "agent_uid" => agent.uid,
               "owner_session_id" => source.session_id,
               "reply_route" => %{"conversation_id" => id},
               "source_tool_call_id" => "native-workflow-create",
               "title" => "Review the case",
               "script" => "return await agent('Review the case');",
               "args" => %{},
               "concurrency" => 1,
               "max_agent_calls" => 1
             })

    assert {:ok, %{new_calls: [call]}} =
             Workflow.Replay.commit_replay_pending(
               run.id,
               [%{namespace: nil, name: "agent", arguments: %{"prompt" => "Review the case"}}],
               0
             )

    dispatch = Repo.get_by!(Signal, source_event_id: "workflow:call:#{call.id}:dispatch")
    assert dispatch.source == "control-plane://workflow"
    assert is_nil(dispatch.reply_binding_name)
    assert dispatch.human_uid == human.uid

    assert {:ok, %{call: call}} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 1)
             end)

    assert {:ok, %{accepted: true}} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 call.id,
                 agent.uid,
                 Workflow.task_session_id(call.id),
                 %{
                   "ok" => true,
                   "value" => "Reviewed"
                 }
               )
             end)

    assert {:ok, %{wakeup_event: result, run: completed, cleanup_errors: []}} =
             Workflow.Replay.complete_replay(run.id, "Reviewed", 1)

    assert %DateTime{} = completed.cleanup_completed_at
    assert result.session_id == source.session_id
    assert result.human_uid == human.uid
    assert is_nil(result.reply_binding_name)
    assert result.data["reply_route"] == %{"conversation_id" => id}
  end

  test "pending call creation applies the recursive object schema contract before insertion" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)

    arguments = %{
      "prompt" => "Return nested data.",
      "schema" => %{
        "type" => "object",
        "properties" => %{
          "details" => %{
            "type" => "object",
            "properties" => %{"count" => %{"type" => "integer"}},
            "required" => [],
            "additionalProperties" => false
          }
        },
        "required" => ["details"],
        "additionalProperties" => false
      }
    }

    assert {:ok, %{run: failed, new_calls: []}} =
             Workflow.Replay.commit_replay_pending(
               run.id,
               [%{namespace: nil, name: "agent", arguments: arguments}],
               0
             )

    assert failed.status == :failed
    assert failed.error["code"] == "workflow_agent_call_invalid"
    assert %DateTime{} = failed.cleanup_completed_at
    assert Repo.aggregate(AgentCall, :count) == 0
  end

  test "submit rejects null and type coercion, then accepts the raw JSON integer" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "integer", "minimum" => 1})

    {:ok, %{call: call}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
      end)

    session_id = Workflow.task_session_id(call.id)

    assert {:error, :workflow_result_null} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(call.id, agent.uid, session_id, %{
                 "ok" => true,
                 "value" => nil
               })
             end)

    assert {:error, {:workflow_result_type_mismatch, [], "integer"}} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(call.id, agent.uid, session_id, %{
                 "ok" => true,
                 "value" => "7"
               })
             end)

    assert {:ok, %{accepted: true, call: submitted}} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(call.id, agent.uid, session_id, %{
                 "ok" => true,
                 "value" => 7
               })
             end)

    assert submitted.status == :succeeded
    assert submitted.result == %{"ok" => true, "value" => 7}
  end

  test "submit preserves a successful JSON false value" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "boolean"})

    {:ok, %{call: call}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
      end)

    assert {:ok, %{accepted: true, call: submitted}} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 call.id,
                 agent.uid,
                 Workflow.task_session_id(call.id),
                 %{
                   "ok" => true,
                   "value" => false
                 }
               )
             end)

    assert submitted.result == %{"ok" => true, "value" => false}
  end

  test "memo byte count tracks arguments and terminal envelopes without changing on retry" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, first} = insert_call(run, 0, %{"type" => "string"})
    {:ok, second} = insert_call(run, 1, %{"type" => "string"})

    arguments_bytes =
      [first, second]
      |> Enum.map(&byte_size(Torque.encode!(&1.arguments)))
      |> Enum.sum()

    assert %Run{memo_bytes: ^arguments_bytes} = Repo.get!(Run, run.id)

    {:ok, %{call: first}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(first.id, agent.uid, 8)
      end)

    assert {:ok, %{run: %Run{memo_bytes: ^arguments_bytes}, call: requeued}} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 first.id,
                 agent.uid,
                 Workflow.task_session_id(first.id),
                 %{
                   "ok" => false,
                   "code" => "temporary",
                   "summary" => "Try again.",
                   "retryable" => true
                 }
               )
             end)

    assert requeued.status == :queued

    {:ok, %{call: first}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(first.id, agent.uid, 8)
      end)

    success_envelope = %{"ok" => true, "value" => "done"}
    after_success = arguments_bytes + byte_size(Torque.encode!(success_envelope))

    assert {:ok, %{run: %Run{memo_bytes: ^after_success}}} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 first.id,
                 agent.uid,
                 Workflow.task_session_id(first.id),
                 %{
                   "ok" => true,
                   "value" => "done"
                 }
               )
             end)

    {:ok, %{call: second}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(second.id, agent.uid, 8)
      end)

    failure_envelope = %{"ok" => false, "code" => "fatal", "summary" => "No result."}
    after_failure = after_success + byte_size(Torque.encode!(failure_envelope))

    assert {:ok, %{run: %Run{memo_bytes: ^after_failure}}} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 second.id,
                 agent.uid,
                 Workflow.task_session_id(second.id),
                 %{
                   "ok" => false,
                   "code" => "fatal",
                   "summary" => "No result.",
                   "retryable" => false
                 }
               )
             end)
             |> Workflow.cleanup_terminal_transition()

    assert Repo.get!(Run, run.id).memo_bytes == after_failure
  end

  test "a Cast rejection keeps the call running so the same task can correct its result" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string", "minLength" => 3})

    {:ok, %{call: call}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
      end)

    session_id = Workflow.task_session_id(call.id)

    assert {:error, {:workflow_result_schema_mismatch, _errors}} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(call.id, agent.uid, session_id, %{
                 "ok" => true,
                 "value" => "x"
               })
             end)

    assert %AgentCall{status: :running, attempts: 1, result: nil} =
             Repo.get!(AgentCall, call.id)

    assert {:ok, %{accepted: true, call: corrected}} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(call.id, agent.uid, session_id, %{
                 "ok" => true,
                 "value" => "fixed"
               })
             end)

    assert corrected.status == :succeeded
    assert corrected.result == %{"ok" => true, "value" => "fixed"}
  end

  test "retryable failure requeues below three attempts and finalizes on the third" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})
    {:ok, sibling} = insert_call(run, 1, %{"type" => "string"})
    session_id = Workflow.task_session_id(call.id)
    deferred_at = DateTime.add(DateTime.utc_now(:microsecond), 30, :second)

    assert {:ok, %Signal{available_at: ^deferred_at}} =
             Workflow.defer_task_event(dispatch_event!(sibling), deferred_at, :agent_capacity)

    failure = %{
      "ok" => false,
      "code" => "empty_output",
      "summary" => "No result.",
      "retryable" => true
    }

    for expected_attempt <- 1..2 do
      assert {:ok, %{call: claimed}} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
               end)

      assert claimed.attempts == expected_attempt

      assert {:ok, %{call: requeued}} =
               Ankole.Repo.transact(fn ->
                 Workflow.TaskLifecycle.submit_result_in_tx(
                   call.id,
                   agent.uid,
                   session_id,
                   failure
                 )
               end)

      assert requeued.status == :queued
      assert Repo.get!(Signal, dispatch_event!(sibling).id).available_at == deferred_at
    end

    assert {:ok, %{call: claimed}} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
             end)

    assert claimed.attempts == 3

    assert {:ok, %{call: failed} = terminal} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 call.id,
                 agent.uid,
                 session_id,
                 failure
               )
             end)

    assert {:ok, _} = Workflow.cleanup_terminal_transition({:ok, terminal})
    assert failed.status == :failed
    assert failed.result["code"] == "empty_output"

    assert DateTime.before?(
             Repo.get!(Signal, dispatch_event!(sibling).id).available_at,
             deferred_at
           )
  end

  test "submit rejects another Agent and the wrong Workflow task session" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})

    {:ok, %{call: call}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
      end)

    assert {:error, :workflow_task_not_found} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 call.id,
                 other_agent.uid,
                 Workflow.task_session_id(call.id),
                 %{"ok" => true, "value" => "stolen"}
               )
             end)

    assert {:error, :workflow_task_session_mismatch} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 call.id,
                 agent.uid,
                 "wf_task:9999",
                 %{
                   "ok" => true,
                   "value" => "wrong session"
                 }
               )
             end)

    assert Repo.get!(AgentCall, call.id).status == :running
  end

  test "turn-error compensation requeues twice and finalizes the third failed attempt" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})
    event = %{agent_uid: agent.uid, session_id: Workflow.task_session_id(call.id)}
    reason = %{"code" => "provider_failed", "message" => "Provider failed."}

    for expected_attempt <- 1..2 do
      assert {:ok, %{call: claimed}} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
               end)

      assert claimed.attempts == expected_attempt

      assert {:ok, %{call: requeued}} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.compensate_turn_error_in_tx(
                   event,
                   reason,
                   DateTime.utc_now()
                 )
               end)

      assert requeued.status == :queued
    end

    assert {:ok, %{call: claimed}} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
             end)

    assert claimed.attempts == 3

    oversized_reason = %{
      "code" => String.duplicate("c", 256),
      "message" => String.duplicate("牛", 12_000)
    }

    assert {:ok, %{call: failed}} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.compensate_turn_error_in_tx(
                 event,
                 oversized_reason,
                 DateTime.utc_now()
               )
             end)

    assert failed.status == :failed
    assert byte_size(failed.result["code"]) == 128
    assert byte_size(failed.result["summary"]) <= 2_000
    assert String.valid?(failed.result["summary"])
  end

  test "call arguments accept exactly eight compact KiB and reject the next byte" do
    %{principal: agent} = agent_fixture()
    accepted_run = run_fixture(agent.uid)
    rejected_run = run_fixture(agent.uid)
    at_limit = %{"prompt" => String.duplicate("x", 8_179)}
    over_limit = %{"prompt" => String.duplicate("x", 8_180)}

    assert byte_size(Torque.encode!(at_limit)) == 8_192
    assert byte_size(Torque.encode!(over_limit)) == 8_193

    assert {:ok, %{new_calls: [%AgentCall{}]}} =
             Workflow.Replay.commit_replay_pending(
               accepted_run.id,
               [%{namespace: nil, name: "agent", arguments: at_limit}],
               0
             )

    assert {:ok, %{run: failed, new_calls: []}} =
             Workflow.Replay.commit_replay_pending(
               rejected_run.id,
               [%{namespace: nil, name: "agent", arguments: over_limit}],
               0
             )

    assert failed.status == :failed
    assert failed.error["code"] == "workflow_agent_call_invalid"
  end

  test "cancel durably releases running capacity and rejects a late submit" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, running} = insert_call(run, 0, %{"type" => "string"})
    {:ok, queued} = insert_call(run, 1, %{"type" => "string"})

    {:ok, %{call: running}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(running.id, agent.uid, 8)
      end)

    assert {:ok, %{run: cancelled, running_session_ids: [session_id]}} =
             Repo.transact(fn ->
               Workflow.Lifecycle.cancel_in_tx(run.id, agent.uid)
             end)

    assert cancelled.status == :cancelled
    assert session_id == Workflow.task_session_id(running.id)
    assert Repo.get!(AgentCall, queued.id).status == :cancelled
    assert Repo.get!(AgentCall, running.id).status == :cancelled

    assert {:ok, %{accepted: false, call: late}} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 running.id,
                 agent.uid,
                 session_id,
                 %{
                   "ok" => true,
                   "value" => "late"
                 }
               )
             end)

    assert late.status == :cancelled

    next_run = run_fixture(agent.uid)
    {:ok, next_call} = insert_call(next_run, 0, %{"type" => "string"})

    assert {:ok, %{call: %AgentCall{status: :running}}} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.claim_task_in_tx(next_call.id, agent.uid, 1)
             end)
  end

  test "cancel stops a Job created by a running Workflow task" do
    %{principal: agent} = background_agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})

    {:ok, %{call: call}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
      end)

    assert {:ok, %{job: %Job{} = job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
               "agent_uid" => agent.uid,
               "owner_session_id" => Workflow.task_session_id(call.id),
               "source_tool_call_id" => "workflow-job-before-cancel",
               "title" => "Inspect the Workflow result",
               "task" => "Inspect the result and report any problem.",
               "reply_route" => %{"binding_name" => "bot"}
             })

    assert {:ok, %{run: %Run{status: :cancelled, cleanup_completed_at: %DateTime{}}}} =
             Repo.transact(fn ->
               Workflow.Lifecycle.cancel_in_tx(run.id, agent.uid)
             end)
             |> Workflow.cleanup_terminal_transition()

    assert %Job{status: :stopped} = Repo.get!(Job, job.id)
  end

  test "a cancelled Workflow task cannot insert a new delegated Job" do
    %{principal: agent} = background_agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})

    {:ok, %{call: call}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
      end)

    assert {:ok, %{run: %Run{status: :cancelled}}} =
             Repo.transact(fn ->
               Workflow.Lifecycle.cancel_in_tx(run.id, agent.uid)
             end)
             |> Workflow.cleanup_terminal_transition()

    assert {:error, {:workflow_run_terminal, :cancelled}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
               "agent_uid" => agent.uid,
               "owner_session_id" => Workflow.task_session_id(call.id),
               "source_tool_call_id" => "workflow-job-after-cancel",
               "title" => "Late delegated work",
               "task" => "This Job must not start after cancellation.",
               "reply_route" => %{"binding_name" => "bot"}
             })

    assert Repo.aggregate(Job, :count) == 0
  end

  test "cancel stops a respawn created by a running Workflow task" do
    %{principal: agent} = background_agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})

    {:ok, %{call: call}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
      end)

    source = terminal_delegated_job_fixture(agent.uid, call)

    assert {:ok, %{job: %Job{status: :queued} = successor}} =
             BackgroundAgentJobs.respawn_with_dispatch(source.id, %{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
               "agent_uid" => agent.uid,
               "owner_session_id" => Workflow.task_session_id(call.id),
               "source_tool_call_id" => "workflow-respawn-before-cancel",
               "message" => "Continue the delegated work.",
               "reply_route" => %{"binding_name" => "bot"}
             })

    assert {:ok, %{run: %Run{status: :cancelled, cleanup_completed_at: %DateTime{}}}} =
             Repo.transact(fn ->
               Workflow.Lifecycle.cancel_in_tx(run.id, agent.uid)
             end)
             |> Workflow.cleanup_terminal_transition()

    assert %Job{status: :stopped} = Repo.get!(Job, successor.id)
  end

  test "a cancelled Workflow task cannot respawn its terminal delegated Job" do
    %{principal: agent} = background_agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})

    {:ok, %{call: call}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
      end)

    source = terminal_delegated_job_fixture(agent.uid, call)

    assert {:ok, %{run: %Run{status: :cancelled, cleanup_completed_at: %DateTime{}}}} =
             Repo.transact(fn ->
               Workflow.Lifecycle.cancel_in_tx(run.id, agent.uid)
             end)
             |> Workflow.cleanup_terminal_transition()

    assert {:error, {:workflow_run_terminal, :cancelled}} =
             BackgroundAgentJobs.respawn_with_dispatch(source.id, %{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
               "agent_uid" => agent.uid,
               "owner_session_id" => Workflow.task_session_id(call.id),
               "source_tool_call_id" => "workflow-respawn-after-cancel",
               "message" => "This successor must not start.",
               "reply_route" => %{"binding_name" => "bot"}
             })

    refute Repo.get_by(Job, continued_from_job_id: source.id)
  end

  test "cancel blocks a succeeded delegated Job from seeding a steer successor" do
    %{principal: agent} = background_agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})

    {:ok, %{call: call}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
      end)

    {:ok, %{job: job}} =
      BackgroundAgentJobs.create_with_dispatch(%{
        "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
        "agent_uid" => agent.uid,
        "owner_session_id" => Workflow.task_session_id(call.id),
        "source_tool_call_id" => "workflow-steer-successor",
        "title" => "Delegated work with a late steer",
        "task" => "Finish the delegated work.",
        "reply_route" => %{"binding_name" => "bot"}
      })

    Repo.update!(Ecto.Changeset.change(job, status: :running, attempts: 1))

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-workflow-steer-successor"
             })

    _turn = completed_job_turn_fixture(running)

    assert {:ok, %{command_event: steer}} =
             BackgroundAgentJobs.send_message(running.id, %{
               "agent_uid" => agent.uid,
               "message" => "Apply this late instruction.",
               "request_id" => "workflow-late-steer"
             })

    assert {:ok, %{run: %Run{status: :cancelled}} = cancellation} =
             Repo.transact(fn ->
               Workflow.Lifecycle.cancel_in_tx(run.id, agent.uid)
             end)

    assert {:error, {:workflow_run_terminal, :cancelled}} =
             BackgroundAgentJobs.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "Finished before the late steer."}
             })

    assert %Job{status: :running} = Repo.get!(Job, running.id)
    assert Repo.get!(Signal, steer.id).completed_at == nil
    refute Repo.get_by(Job, continued_from_job_id: running.id)

    assert {:ok, %{run: %Run{cleanup_completed_at: %DateTime{}}}} =
             Workflow.cleanup_terminal_transition({:ok, cancellation})

    assert %Job{status: :stopped} = Repo.get!(Job, running.id)
  end

  test "terminal cleanup marks completion only after a failed stop is repaired" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})

    {:ok, %{call: call}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
      end)

    run
    |> AshPostgres.DataLayer.to_ecto()
    |> Ecto.Changeset.change(%{reply_route: %{}})
    |> Repo.update!()

    assert {:ok, %{run: %Run{status: :cancelled} = pending, cleanup_errors: [error]}} =
             Repo.transact(fn ->
               Workflow.Lifecycle.cancel_in_tx(run.id, agent.uid)
             end)
             |> Workflow.cleanup_terminal_transition()

    assert pending.cleanup_completed_at == nil
    assert error.session_id == Workflow.task_session_id(call.id)
    assert error.reason == :workflow_reply_route_binding_missing

    repaired =
      pending
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{reply_route: %{"binding_name" => "bot"}})
      |> Repo.update!()

    assert {:ok, %Run{cleanup_completed_at: %DateTime{}}} =
             Workflow.Lifecycle.cleanup_terminal_run(repaired)
  end

  test "a failed replay returns cleanup errors and a retry finishes the committed run" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})

    assert {:ok, _} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
             end)

    run
    |> AshPostgres.DataLayer.to_ecto()
    |> Ecto.Changeset.change(%{reply_route: %{}})
    |> Repo.update!()

    assert {:ok, %{run: %Run{status: :failed} = failed, cleanup_errors: [error]}} =
             Workflow.Replay.fail_replay(run.id, "program_failed", "The program failed.", 0)

    assert failed.cleanup_completed_at == nil
    assert error.session_id == Workflow.task_session_id(call.id)
    assert error.reason == :workflow_reply_route_binding_missing
    assert Repo.get!(AgentCall, call.id).status == :cancelled
    refute Repo.get_by(Signal, source_event_id: "workflow:call:#{call.id}:stop")

    failed
    |> AshPostgres.DataLayer.to_ecto()
    |> Ecto.Changeset.change(%{reply_route: %{"binding_name" => "bot"}})
    |> Repo.update!()

    assert {:ok, %{run: cleaned, cleanup_errors: []}} =
             Workflow.Replay.fail_replay(
               run.id,
               "late_error",
               "A retry cannot replace the result.",
               0
             )

    assert %DateTime{} = cleaned.cleanup_completed_at
    assert cleaned.error["code"] == "program_failed"

    assert Repo.get_by!(Signal, source_event_id: "workflow:call:#{call.id}:stop").type ==
             "command.stop"
  end

  test "the watchdog returns the completed cleanup of a terminal run" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})

    assert {:ok, _} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
             end)

    assert {:ok, %{run: %Run{cleanup_completed_at: nil}}} =
             Repo.transact(fn ->
               Workflow.Lifecycle.cancel_in_tx(run.id, agent.uid)
             end)

    now = DateTime.utc_now(:microsecond)

    assert {:ok, %{run: cleaned, reconciled: 0, cleanup_errors: []}} =
             Workflow.Recovery.reconcile_stale_tasks(
               run.id,
               DateTime.add(now, -3_600, :second),
               now
             )

    assert cleaned.status == :cancelled
    assert %DateTime{} = cleaned.cleanup_completed_at

    assert Repo.get_by!(Signal, source_event_id: "workflow:call:#{call.id}:stop").type ==
             "command.stop"
  end

  test "replay and watchdog reject a caller transaction before they change durable work" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})
    now = DateTime.utc_now(:microsecond)

    operations = [
      fn -> Workflow.Replay.commit_replay_pending(run.id, [], 0) end,
      fn -> Workflow.Replay.complete_replay(run.id, "done", 0) end,
      fn -> Workflow.Replay.fail_replay(run.id, "failed", "Failed.", 0) end,
      fn -> Workflow.Recovery.reconcile_stale_tasks(run.id, now, now) end
    ]

    for operation <- operations do
      assert_raise Ankole.Errors.Framework.NestedOperation, fn ->
        Repo.transact(fn -> operation.() end)
      end
    end

    assert Repo.get!(Run, run.id).status == :running
    assert Repo.get!(AgentCall, call.id).status == :queued
    refute Repo.get_by(Signal, source_event_id: "workflow:call:#{call.id}:stop")
  end

  test "claim enforces per-run capacity after the run and call locks" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid, concurrency: 1)
    {:ok, first} = insert_call(run, 0, %{"type" => "string"})
    {:ok, second} = insert_call(run, 1, %{"type" => "string"})

    assert {:ok, %{call: %AgentCall{status: :running}}} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.claim_task_in_tx(first.id, agent.uid, 8)
             end)

    assert {:error, :workflow_agent_at_capacity} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.claim_task_in_tx(second.id, agent.uid, 8)
             end)

    assert Repo.get!(AgentCall, second.id).status == :queued
  end

  test "concurrent claims serialize and only one occupies a capacity-one run" do
    parent = self()

    arguments = %{
      namespace: nil,
      name: "agent",
      arguments: %{"prompt" => "Research the question.", "schema" => %{"type" => "string"}}
    }

    {tenant, agent_uid, first_id, second_id} =
      Sandbox.unboxed_run(Repo, fn ->
        {:ok, {tenant, agent_uid, run_id}} =
          Repo.transact(fn ->
            tenant =
              create_committed_tenant(%{
                slug: "workflow-#{Ankole.Ecto.UUIDv7.autogenerate()}",
                display_name: "Workflow capacity race"
              })

            Repo.with_tenant(tenant.id, fn ->
              %{principal: agent} = agent_fixture()
              run = run_fixture(agent.uid, concurrency: 1)
              {:ok, {tenant, agent.uid, run.id}}
            end)
          end)

        Repo.with_tenant(tenant.id, fn ->
          {:ok, %{new_calls: [first, second]}} =
            Workflow.Replay.commit_replay_pending(run_id, [arguments, arguments], 0)

          {tenant, agent_uid, first.id, second.id}
        end)
      end)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.with_tenant(tenant.id, fn -> delete_agent_fixture_rows(agent_uid) end)
        cleanup_tenant!(tenant)
      end)
    end)

    claim = fn call_id ->
      Task.async(fn ->
        Repo.with_tenant(tenant.id, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:claim_ready, self()})

            receive do
              :claim ->
                Repo.transact(fn ->
                  Workflow.TaskLifecycle.claim_task_in_tx(call_id, agent_uid, 8)
                end)
            end
          end)
        end)
      end)
    end

    first = claim.(first_id)
    second = claim.(second_id)

    assert_receive {:claim_ready, first_pid}, 5_000
    assert_receive {:claim_ready, second_pid}, 5_000
    send(first_pid, :claim)
    send(second_pid, :claim)

    results = [Task.await(first, 5_000), Task.await(second, 5_000)]

    assert Enum.count(results, &match?({:ok, %{call: %AgentCall{status: :running}}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :workflow_agent_at_capacity})) == 1
  end

  test "a final watchdog failure wakes a capacity waiter in its after-commit work" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid, concurrency: 1)
    {:ok, stale} = insert_call(run, 0, %{"type" => "string"})
    {:ok, waiting} = insert_call(run, 1, %{"type" => "string"})
    session_id = Workflow.task_session_id(stale.id)

    for attempt <- 1..3 do
      assert {:ok, %{call: %{attempts: ^attempt}}} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.claim_task_in_tx(stale.id, agent.uid, 8)
               end)

      if attempt < 3 do
        assert {:ok, %{call: %{status: :queued}}} =
                 Repo.transact(fn ->
                   Workflow.TaskLifecycle.submit_result_in_tx(
                     stale.id,
                     agent.uid,
                     session_id,
                     %{
                       "ok" => false,
                       "code" => "retry",
                       "summary" => "Retry the task.",
                       "retryable" => true
                     }
                   )
                 end)
      end
    end

    now = DateTime.utc_now(:microsecond)
    deferred_at = DateTime.add(now, 30, :second)
    event = dispatch_event!(waiting)

    assert {:ok, %Signal{available_at: ^deferred_at}} =
             Workflow.defer_task_event(event, deferred_at, :agent_capacity)

    Repo.update_all(where(AgentCall, id: ^stale.id),
      set: [progress_at: DateTime.add(now, -3_601, :second)]
    )

    assert {:ok, %{reconciled: 1, released_slot?: true}} =
             Workflow.Recovery.reconcile_stale_tasks(
               run.id,
               DateTime.add(now, -3_600, :second),
               now
             )

    assert %{status: :failed, attempts: 3} = Repo.get!(AgentCall, stale.id)
    assert DateTime.compare(Repo.get!(Signal, event.id).available_at, deferred_at) == :lt
    assert %{status: :queued, attempts: 0} = Repo.get!(AgentCall, waiting.id)

    assert {:ok, %{call: %{status: :running, attempts: 1}}} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.claim_task_in_tx(waiting.id, agent.uid, 8)
             end)
  end

  test "an unavailable model profile fails the queued task without starting a turn" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)
    {:ok, call} = insert_call(run, 0, %{"type" => "string"})
    {:ok, sibling} = insert_call(run, 1, %{"type" => "string"})
    failed_at = DateTime.utc_now(:microsecond)
    deferred_at = DateTime.add(failed_at, 30, :second)

    assert {:ok, %Signal{available_at: ^deferred_at}} =
             Workflow.defer_task_event(dispatch_event!(sibling), deferred_at, :agent_capacity)

    assert {:ok, %{accepted: true, call: failed, run: same_run}} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.fail_unstarted_task_in_tx(
                 call.id,
                 agent.uid,
                 "workflow_model_profile_unavailable",
                 "Workflow task model profile review is unavailable.",
                 failed_at
               )
             end)
             |> Workflow.cleanup_terminal_transition()

    assert same_run.id == run.id
    assert failed.id == call.id
    assert failed.status == :failed
    assert failed.attempts == 0

    assert failed.result == %{
             "ok" => false,
             "code" => "workflow_model_profile_unavailable",
             "summary" => "Workflow task model profile review is unavailable."
           }

    assert Repo.aggregate(AgentCall, :count) == 2
    assert Repo.get!(Signal, dispatch_event!(sibling).id).available_at == deferred_at
  end

  test "memo budget failure cancels parallel siblings, stops their turns, and releases capacity" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid, max_agent_calls: 1_024)
    full_arguments = %{"prompt" => String.duplicate("x", 7_990)}
    full_size = byte_size(Torque.encode!(full_arguments))
    empty_size = byte_size(Torque.encode!(%{"prompt" => ""}))
    full_count = div(@memo_budget_bytes - 1 - empty_size, full_size)
    last_size = @memo_budget_bytes - 1 - full_count * full_size
    last_arguments = %{"prompt" => String.duplicate("x", last_size - empty_size)}
    arguments = List.duplicate(full_arguments, full_count) ++ [last_arguments]
    memo_bytes = Enum.sum(Enum.map(arguments, &byte_size(Torque.encode!(&1))))

    assert memo_bytes == @memo_budget_bytes - 1

    {:ok, run} =
      Repo.transact(fn ->
        Ankole.Ash.update(run, :update_metadata, %{memo_bytes: memo_bytes})
      end)

    rows =
      for {arguments, seq} <- Enum.with_index(arguments) do
        %{run_id: run.id, agent_uid: agent.uid, call_seq: seq, arguments: arguments}
      end

    {:ok, inserted} =
      Repo.transact(fn ->
        case Ankole.Ash.bulk_create(rows, AgentCall, :create_call,
               return_records?: true,
               return_errors?: true
             ) do
          %Ash.BulkResult{status: :success, records: records} -> {:ok, records}
          %Ash.BulkResult{errors: errors} -> {:error, Ash.Error.to_error_class(errors)}
        end
      end)

    current = Enum.find(inserted, &(&1.call_seq == 0))
    sibling = Enum.find(inserted, &(&1.call_seq == 1))
    call = Repo.get!(AgentCall, current.id)
    sibling = Repo.get!(AgentCall, sibling.id)

    {:ok, %{call: call}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
      end)

    {:ok, %{call: sibling}} =
      Repo.transact(fn ->
        Workflow.TaskLifecycle.claim_task_in_tx(sibling.id, agent.uid, 8)
      end)

    sibling_session_id = Workflow.task_session_id(sibling.id)

    assert {:ok,
            %{
              accepted: true,
              run: failed,
              call: failed_call,
              running_session_ids: [^sibling_session_id],
              cleanup_errors: []
            }} =
             Ankole.Repo.transact(fn ->
               Workflow.TaskLifecycle.submit_result_in_tx(
                 call.id,
                 agent.uid,
                 Workflow.task_session_id(call.id),
                 %{
                   "ok" => false,
                   "code" => "terminal",
                   "summary" => "Done.",
                   "retryable" => false
                 }
               )
             end)
             |> Workflow.cleanup_terminal_transition()

    assert failed.status == :failed
    assert failed.error["code"] == "workflow_memo_budget_exceeded"
    assert failed.memo_bytes == memo_bytes
    assert failed_call.status == :failed
    assert failed_call.result == nil
    assert Repo.get!(AgentCall, sibling.id).status == :cancelled
    assert Repo.get!(Run, run.id).memo_bytes == memo_bytes

    assert Ankole.Workflow.Queries.counts(run.id) == %{
             "total" => length(rows),
             "queued" => 0,
             "running" => 0,
             "sleeping" => 0,
             "succeeded" => 0,
             "failed" => 1,
             "cancelled" => length(rows) - 1
           }

    stop =
      Repo.get_by!(Signal,
        agent_uid: agent.uid,
        source_event_id: "workflow:call:#{sibling.id}:stop"
      )

    assert stop.session_id == sibling_session_id
    assert stop.type == "command.stop"

    assert get_in(stop.data, ["command", "argsText"]) ==
             "Workflow ended with status failed"

    assert %Signal{type: "workflow.run.failed"} =
             Repo.get_by!(Signal,
               agent_uid: agent.uid,
               source_event_id: "workflow:#{run.id}:failed"
             )

    next_run = run_fixture(agent.uid)
    {:ok, next_call} = insert_call(next_run, 0, %{"type" => "string"})

    assert {:ok, %{call: %AgentCall{status: :running}}} =
             Repo.transact(fn ->
               Workflow.TaskLifecycle.claim_task_in_tx(next_call.id, agent.uid, 1)
             end)
  end

  test "get returns counts, failure summaries, and UTF-8 byte windows" do
    %{principal: agent} = agent_fixture()
    run = run_fixture(agent.uid)

    {:ok, failed_call} = insert_call(run, 0, %{"type" => "string"})

    failure_envelope = %{
      "ok" => false,
      "code" => "failed_check",
      "summary" => "Check failed."
    }

    {:ok, _failed} =
      Repo.transact(fn ->
        with {:ok, claimed} <- Ankole.Ash.update(failed_call, :claim, %{attempts: 1}) do
          Ankole.Ash.update(claimed, :fail, %{
            result: failure_envelope,
            error: %{"code" => "failed_check", "summary" => "Check failed."}
          })
        end
      end)

    result_text = String.duplicate("a", 7_999) <> "牛tail"

    run = Repo.get!(Run, run.id)

    {:ok, _completed} =
      Repo.transact(fn ->
        with {:ok, updated} <-
               Ankole.Ash.update(run, :update_metadata, %{
                 memo_bytes: run.memo_bytes + byte_size(Torque.encode!(failure_envelope))
               }) do
          Ankole.Ash.update(updated, :complete, %{
            result_text: result_text,
            completed_at: DateTime.utc_now()
          })
        end
      end)

    assert {:ok, result} = Workflow.get(run.id, agent.uid, result_offset: 0)

    assert result.counts == %{
             "total" => 1,
             "queued" => 0,
             "running" => 0,
             "sleeping" => 0,
             "succeeded" => 0,
             "failed" => 1,
             "cancelled" => 0
           }

    assert [%{"code" => "failed_check", "summary" => "Check failed."}] =
             Enum.map(result.failure_summaries, &Map.take(&1, ["code", "summary"]))

    assert result.result_output_text == String.duplicate("a", 7_999)
    assert result.result_output_total_bytes == byte_size(result_text)

    assert {:error, :invalid_workflow_result_offset} =
             Workflow.get(run.id, agent.uid, result_offset: 8_000)

    assert {:ok, tail} = Workflow.get(run.id, agent.uid, result_offset: 7_999)
    assert tail.result_output_text == "牛tail"
  end

  describe "task sleep and wake" do
    test "sleep parks a running call, schedules its wake event, and resets the attempt budget" do
      %{principal: agent} = agent_fixture()
      run = run_fixture(agent.uid)
      {:ok, call} = insert_call(run, 0, %{"type" => "string"})

      {:ok, %{call: call}} =
        Repo.transact(fn ->
          Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
        end)

      session_id = Workflow.task_session_id(call.id)

      assert {:ok, %{call: sleeping}} =
               Ankole.Repo.transact(fn ->
                 Workflow.TaskLifecycle.sleep_task_in_tx(call.id, agent.uid, session_id, %{
                   wake_after_ms: 3_600_000,
                   note: "Waiting for background job 1234.",
                   attention: false
                 })
               end)

      assert sleeping.status == :sleeping
      assert sleeping.attempts == 0
      assert sleeping.wake_count == 1
      assert sleeping.sleep_note == "Waiting for background job 1234."
      assert sleeping.attention == false
      assert DateTime.after?(sleeping.wake_at, DateTime.utc_now())

      wake_event =
        Repo.get_by!(Signal,
          agent_uid: agent.uid,
          source_event_id: "workflow:call:#{call.id}:wake:1"
        )

      assert wake_event.type == "workflow.task.wakeup"
      assert wake_event.session_id == session_id
      assert DateTime.compare(wake_event.available_at, sleeping.wake_at) == :eq

      # The wake claim reuses the ordinary claim gates.
      assert {:ok, %{call: woken}} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
               end)

      assert woken.status == :running
      assert woken.attempts == 1
      assert woken.wake_count == 1
    end

    test "sleep rejects non-running calls, invalid bounds, and an exhausted wake budget" do
      %{principal: agent} = agent_fixture()
      run = run_fixture(agent.uid)
      {:ok, call} = insert_call(run, 0, %{"type" => "string"})
      session_id = Workflow.task_session_id(call.id)
      params = %{wake_after_ms: 3_600_000, note: "Waiting.", attention: false}

      assert {:error, {:workflow_task_not_running, :queued}} =
               Ankole.Repo.transact(fn ->
                 Workflow.TaskLifecycle.sleep_task_in_tx(
                   call.id,
                   agent.uid,
                   session_id,
                   params
                 )
               end)

      {:ok, %{call: call}} =
        Repo.transact(fn ->
          Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
        end)

      assert {:error, :invalid_workflow_wake_after} =
               Ankole.Repo.transact(fn ->
                 Workflow.TaskLifecycle.sleep_task_in_tx(call.id, agent.uid, session_id, %{
                   params
                   | wake_after_ms: 1
                 })
               end)

      assert {:error, :invalid_workflow_sleep_note} =
               Ankole.Repo.transact(fn ->
                 Workflow.TaskLifecycle.sleep_task_in_tx(call.id, agent.uid, session_id, %{
                   params
                   | note: "  "
                 })
               end)

      assert {:error, :workflow_task_session_mismatch} =
               Ankole.Repo.transact(fn ->
                 Workflow.TaskLifecycle.sleep_task_in_tx(
                   call.id,
                   agent.uid,
                   "wf_task:999999",
                   params
                 )
               end)

      call
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{wake_count: 16})
      |> Repo.update!()

      assert {:error, :workflow_task_wake_budget_exhausted} =
               Ankole.Repo.transact(fn ->
                 Workflow.TaskLifecycle.sleep_task_in_tx(
                   call.id,
                   agent.uid,
                   session_id,
                   params
                 )
               end)
    end

    test "an attention sleep appends one coalesced owner event per hour bucket" do
      %{principal: agent} = agent_fixture()
      run = run_fixture(agent.uid)
      {:ok, first} = insert_call(run, 0, %{"type" => "string"})
      {:ok, second} = insert_call(run, 1, %{"type" => "string"})

      for call <- [first, second] do
        {:ok, _claimed} =
          Repo.transact(fn ->
            Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
          end)

        assert {:ok, %{call: sleeping}} =
                 Ankole.Repo.transact(fn ->
                   Workflow.TaskLifecycle.sleep_task_in_tx(
                     call.id,
                     agent.uid,
                     Workflow.task_session_id(call.id),
                     %{
                       wake_after_ms: 3_600_000,
                       note: "Need a decision.",
                       attention: true
                     }
                   )
                 end)

        assert sleeping.attention == true
      end

      attention_events =
        Signal
        |> where([event], event.type == "workflow.run.attention")
        |> Repo.all()

      assert [attention] = attention_events
      assert attention.session_id == run.owner_session_id
      assert attention.data["run_id"] == run.id
    end

    test "a crashed wake turn requeues the same wake input and the attempt budget still fails it" do
      %{principal: agent} = agent_fixture()
      run = run_fixture(agent.uid)
      {:ok, call} = insert_call(run, 0, %{"type" => "string"})

      {:ok, %{call: call}} =
        Repo.transact(fn ->
          Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
        end)

      session_id = Workflow.task_session_id(call.id)

      {:ok, _sleeping} =
        Ankole.Repo.transact(fn ->
          Workflow.TaskLifecycle.sleep_task_in_tx(call.id, agent.uid, session_id, %{
            wake_after_ms: 3_600_000,
            note: "Waiting.",
            attention: false
          })
        end)

      reason = %{"code" => "worker_crash", "message" => "The Worker died."}
      event = %{agent_uid: agent.uid, session_id: session_id}

      for expected_attempts <- [1, 2] do
        {:ok, %{call: _running}} =
          Repo.transact(fn ->
            Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
          end)

        assert {:ok, %{call: compensated}} =
                 Repo.transact(fn ->
                   Workflow.TaskLifecycle.compensate_turn_error_in_tx(
                     event,
                     reason,
                     DateTime.utc_now()
                   )
                 end)

        assert compensated.status == :queued
        assert compensated.wake_kind == nil
        assert compensated.wake_at == nil
        assert compensated.attempts == expected_attempts
      end

      {:ok, %{call: _running}} =
        Repo.transact(fn ->
          Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
        end)

      assert {:ok, %{call: failed}} =
               Repo.transact(fn ->
                 Workflow.TaskLifecycle.compensate_turn_error_in_tx(
                   event,
                   reason,
                   DateTime.utc_now()
                 )
               end)

      assert failed.status == :failed
      assert failed.result["ok"] == false
    end

    test "run cancellation collects sleeping calls" do
      %{principal: agent} = agent_fixture()
      run = run_fixture(agent.uid)
      {:ok, call} = insert_call(run, 0, %{"type" => "string"})

      {:ok, %{call: call}} =
        Repo.transact(fn ->
          Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
        end)

      {:ok, _sleeping} =
        Ankole.Repo.transact(fn ->
          Workflow.TaskLifecycle.sleep_task_in_tx(
            call.id,
            agent.uid,
            Workflow.task_session_id(call.id),
            %{
              wake_after_ms: 3_600_000,
              note: "Waiting.",
              attention: false
            }
          )
        end)

      assert {:ok, %{run: cancelled}} =
               Repo.transact(fn ->
                 Workflow.Lifecycle.cancel_in_tx(run.id, agent.uid)
               end)

      assert cancelled.status == :cancelled
      assert %AgentCall{status: :cancelled} = Repo.get!(AgentCall, call.id)
    end

    test "the watchdog nudges an overdue sleeping call with an open event and fails one without" do
      %{principal: agent} = agent_fixture()
      run = run_fixture(agent.uid)
      {:ok, with_event} = insert_call(run, 0, %{"type" => "string"})
      {:ok, without_event} = insert_call(run, 1, %{"type" => "string"})

      for call <- [with_event, without_event] do
        {:ok, _claimed} =
          Repo.transact(fn ->
            Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
          end)

        {:ok, _sleeping} =
          Ankole.Repo.transact(fn ->
            Workflow.TaskLifecycle.sleep_task_in_tx(
              call.id,
              agent.uid,
              Workflow.task_session_id(call.id),
              %{
                wake_after_ms: 3_600_000,
                note: "Waiting.",
                attention: false
              }
            )
          end)
      end

      overdue = DateTime.add(DateTime.utc_now(), -2 * 3_600, :second)

      AgentCall
      |> where([call], call.id in ^[with_event.id, without_event.id])
      |> Repo.update_all(set: [wake_at: overdue])

      # In production the dispatch event completes when the first turn ends;
      # these claims never ran a turn, so close them here. Losing every open
      # mailbox event then models a lost wake for the second call.
      for call <- [with_event, without_event] do
        assert {:ok, _signal} =
                 Repo.transact(fn ->
                   Ankole.Ash.update(dispatch_event!(call), :complete, %{
                     completed_at: DateTime.utc_now(:microsecond)
                   })
                 end)
      end

      assert {:ok, _signal} =
               Repo.transact(fn ->
                 wake =
                   Repo.get_by!(Signal,
                     agent_uid: agent.uid,
                     source_event_id: "workflow:call:#{without_event.id}:wake:1"
                   )

                 Ankole.Ash.update(wake, :complete, %{
                   completed_at: DateTime.utc_now(:microsecond)
                 })
               end)

      cutoff = DateTime.add(DateTime.utc_now(), -3_600, :second)

      assert {:ok, %{reconciled: 2}} =
               Workflow.Recovery.reconcile_stale_tasks(run.id, cutoff, DateTime.utc_now())

      assert %AgentCall{status: :sleeping} = Repo.get!(AgentCall, with_event.id)

      assert %AgentCall{status: :failed, error: %{"code" => "workflow_task_wake_lost"}} =
               Repo.get!(AgentCall, without_event.id)
    end

    test "an owner message reaches a live call and is rejected for a terminal one" do
      %{principal: agent} = agent_fixture()
      run = run_fixture(agent.uid)
      {:ok, call} = insert_call(run, 0, %{"type" => "string"})

      assert {:ok, %{call: %AgentCall{}}} =
               Workflow.send_task_message(
                 run.id,
                 call.call_seq,
                 agent.uid,
                 "Focus on risk.",
                 "tool-1"
               )

      message_event =
        Repo.get_by!(Signal,
          agent_uid: agent.uid,
          source_event_id: "workflow:call:#{call.id}:msg:tool-1"
        )

      assert message_event.type == "workflow.task.message"
      assert message_event.session_id == Workflow.task_session_id(call.id)
      assert message_event.data["message"] == "Focus on risk."

      # Idempotent per source tool call.
      assert {:ok, _repeat} =
               Workflow.send_task_message(
                 run.id,
                 call.call_seq,
                 agent.uid,
                 "Focus on risk.",
                 "tool-1"
               )

      assert Signal
             |> where([event], event.type == "workflow.task.message")
             |> Repo.aggregate(:count) == 1

      {:ok, %{call: call}} =
        Repo.transact(fn ->
          Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
        end)

      {:ok, _submitted} =
        Ankole.Repo.transact(fn ->
          Workflow.TaskLifecycle.submit_result_in_tx(
            call.id,
            agent.uid,
            Workflow.task_session_id(call.id),
            %{
              "ok" => true,
              "value" => "done"
            }
          )
        end)

      assert {:error, {:workflow_task_terminal, :succeeded}} =
               Workflow.send_task_message(run.id, call.call_seq, agent.uid, "Too late.", "tool-2")

      assert {:error, :workflow_task_not_found} =
               Workflow.send_task_message(run.id, 99, agent.uid, "Missing.", "tool-3")
    end

    test "rejecting a suspended tenant input on an already running task completes the signal without failing the task" do
      %{principal: agent} = agent_fixture()
      run = run_fixture(agent.uid)
      {:ok, call} = insert_call(run, 0, %{"type" => "string"})

      assert {:ok, %{call: %AgentCall{}}} =
               Workflow.send_task_message(
                 run.id,
                 call.call_seq,
                 agent.uid,
                 "Queued before claim.",
                 "tool-suspended"
               )

      message_event =
        Repo.get_by!(Signal,
          agent_uid: agent.uid,
          source_event_id: "workflow:call:#{call.id}:msg:tool-suspended"
        )

      {:ok, %{call: claimed}} =
        Repo.transact(fn ->
          Workflow.TaskLifecycle.claim_task_in_tx(call.id, agent.uid, 8)
        end)

      assert claimed.status == :running

      now = DateTime.utc_now(:microsecond)

      assert {:ok,
              %{
                status: :tenant_suspended,
                workflow_transition: nil,
                signal: %Signal{completed_at: %DateTime{}}
              }} =
               Ankole.Sessions.Notices.finalize({:error, :tenant_suspended}, message_event, now)

      assert Repo.get!(AgentCall, call.id).status == :running
    end
  end

  defp run_fixture(agent_uid, overrides \\ []) do
    attrs =
      %{
        authorization_kind: "service",
        agent_uid: agent_uid,
        owner_session_id: "session-#{System.unique_integer([:positive])}",
        reply_route: %{"binding_name" => "bot"},
        source_tool_call_id: "tool-#{System.unique_integer([:positive])}",
        title: "Workflow",
        script: "return 'done';",
        args: %{},
        concurrency: 8,
        max_agent_calls: 256,
        error: %{}
      }
      |> Map.merge(Map.new(overrides))

    {:ok, run} = Repo.transact(fn -> Ankole.Ash.create(Run, :create_run, attrs) end)
    run
  end

  defp insert_call(run, call_seq, schema) do
    calls =
      AgentCall
      |> where([call], call.run_id == ^run.id)
      |> order_by([call], asc: call.call_seq)
      |> Repo.all()

    assert call_seq == length(calls)
    {_memo, memo_length} = Program.memo_prefix(calls)

    arguments =
      calls
      |> Enum.drop(memo_length)
      |> Enum.map(& &1.arguments)
      |> Kernel.++([
        %{
          "prompt" => "Research the question.",
          "schema" => schema
        }
      ])

    pending_calls =
      Enum.map(arguments, &%{namespace: nil, name: "agent", arguments: &1})

    # This fixture tests domain transitions. Oban stays manual; the passive
    # Driver then receives later delivery.
    case Workflow.Replay.commit_replay_pending(run.id, pending_calls, memo_length) do
      {:ok, %{new_calls: [call]}} ->
        Ankole.SessionsCase.stub_driver(%{
          agent_uid: run.agent_uid,
          session_id: Workflow.task_session_id(call.id)
        })

        {:ok, call}

      {:error, _reason} = error ->
        error
    end
  end

  defp terminal_delegated_job_fixture(agent_uid, call) do
    suffix = System.unique_integer([:positive])

    {:ok, %{job: job}} =
      BackgroundAgentJobs.create_with_dispatch(%{
        "source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
        "agent_uid" => agent_uid,
        "owner_session_id" => Workflow.task_session_id(call.id),
        "source_tool_call_id" => "workflow-terminal-job-#{suffix}",
        "title" => "Terminal delegated work",
        "task" => "Finish before a respawn.",
        "reply_route" => %{"binding_name" => "bot"}
      })

    job
    |> Ecto.Changeset.change(
      status: :failed,
      runtime_thread_id: "thread-workflow-respawn-#{suffix}",
      completed_at: DateTime.utc_now(:microsecond)
    )
    |> Repo.update!()
  end

  defp completed_job_turn_fixture(job) do
    completed_at = DateTime.utc_now(:microsecond)

    case Repo.transact(fn _ ->
           Ankole.Ash.create(Turn, :record, %{
             job_id: job.id,
             attempt: job.attempts,
             runtime_thread_id: job.runtime_thread_id,
             runtime_turn_id: "turn-workflow-steer-successor",
             kind: "agent",
             status: :completed,
             revision: 1,
             trajectory: %{"format" => "ankole_chatml", "version" => 1},
             progress: %{
               "completed_items" => 0,
               "tool_calls" => 0,
               "tools_used" => [],
               "files_changed" => []
             },
             error: %{},
             started_at: completed_at,
             completed_at: completed_at
           })
         end) do
      {:ok, record} -> record
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp dispatch_event!(call) do
    Repo.get_by!(Signal,
      agent_uid: call.agent_uid,
      source_event_id: "workflow:call:#{call.id}:dispatch"
    )
  end
end
