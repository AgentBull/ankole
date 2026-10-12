defmodule Ankole.Conversations.WorkflowAdmissionTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Conversations.{Admission, Model, Receipts, Run, Tools}
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkspace
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.Workflow
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run, as: WorkflowRun

  test "tasks use their profile precedence and independent conversation without a Worker" do
    %{principal: agent} = agent_fixture()
    worker = Repo.get!(AgentWorker, agent.uid)

    for {call_profile, run_profile, expected} <- [
          {"heavy", "light", "heavy"},
          {nil, "light", "light"},
          {nil, nil, "primary"}
        ] do
      arguments =
        if call_profile,
          do: %{"prompt" => "Work", "model_profile" => call_profile},
          else: %{"prompt" => "Work"}

      %{run: workflow, calls: [call], events: [event]} =
        workflow_fixture(agent.uid, model_profile: run_profile, arguments: [arguments])

      assert {:ok, %Run{} = run} = admit(event)
      assert run.spec.model_ref["profile"] == expected
      assert run.spec.request_context["run_id"] == workflow.id
      assert run.spec.request_context["call_id"] == call.id
      assert run.spec.request_context["attempt"] == 1
      assert run.kind == :workflow_task
      assert %AgentCall{status: "running", attempts: 1} = Repo.get!(AgentCall, call.id)
      assert %Conversation{conversation_key: session} = run.conversation
      assert session == event.session_id
    end

    assert Repo.get!(AgentWorker, agent.uid) == worker
  end

  test "releasing a run slot wakes the earliest capacity-deferred task" do
    %{principal: agent} = agent_fixture()

    %{calls: [first, second, third], events: [first_event, second_event, third_event]} =
      workflow_fixture(agent.uid,
        concurrency: 1,
        arguments: [
          %{"prompt" => "First"},
          %{"prompt" => "Second"},
          %{"prompt" => "Third"}
        ]
      )

    assert {:ok, %Run{}} = admit(first_event)
    now = DateTime.utc_now(:microsecond)
    assert {:ok, %{status: :deferred, actor_event: deferred_second}} = admit(second_event, now)
    assert {:ok, %{status: :deferred, actor_event: deferred_third}} = admit(third_event, now)
    assert deferred_second.available_at == DateTime.add(now, 30)
    assert deferred_third.available_at == deferred_second.available_at

    assert deferred_second.payload["data"]["workflow_dispatch_deferred_reason"] ==
             "agent_capacity"

    assert Repo.get!(ActorEvent, second_event.id).attempt_count == 0
    assert %AgentCall{status: "queued", attempts: 0} = Repo.get!(AgentCall, second.id)

    before_submit = DateTime.utc_now(:microsecond)

    assert {:ok, %{accepted: true}} =
             Ankole.Repo.transact(fn repo ->
               Workflow.submit_result_in_tx(
                 repo,
                 first.id,
                 agent.uid,
                 first_event.session_id,
                 %{"ok" => true, "value" => "Released"}
               )
             end)

    after_submit = DateTime.utc_now(:microsecond)
    awakened = Repo.reload!(second_event)
    assert DateTime.compare(awakened.available_at, before_submit) in [:eq, :gt]
    assert DateTime.compare(awakened.available_at, after_submit) in [:eq, :lt]
    assert Repo.reload!(third_event).available_at == deferred_third.available_at
    assert {:ok, %Run{}} = admit(awakened, after_submit)
    refute Repo.reload!(second_event).payload["data"]["workflow_dispatch_deferred_reason"]
    assert %AgentCall{status: "running", attempts: 1} = Repo.get!(AgentCall, second.id)
    assert %AgentCall{status: "queued", attempts: 0} = Repo.get!(AgentCall, third.id)
  end

  test "Driver replacement adopts a running task without a second call claim" do
    %{principal: agent} = agent_fixture()
    %{calls: [call], events: [event]} = workflow_fixture(agent.uid)
    assert {:ok, first} = admit(event)
    assert {:ok, adopted} = admit(Repo.reload!(event))
    assert adopted.epoch > first.epoch
    assert adopted.spec.request_context["attempt"] == first.spec.request_context["attempt"]
    assert %AgentCall{status: "running", attempts: 1} = Repo.get!(AgentCall, call.id)
  end

  test "suspension rejects queued tasks but still adopts an already running task" do
    %{principal: agent} = agent_fixture()

    %{calls: [running, queued], events: [running_event, queued_event]} =
      workflow_fixture(agent.uid, arguments: [%{"prompt" => "Started"}, %{"prompt" => "Queued"}])

    assert {:ok, %Run{}} = admit(running_event)

    Repo.get!(Ankole.Tenants.Tenant, Repo.tenant_id!())
    |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()

    assert {:ok, %{completed_at: %DateTime{}, last_attempt_at: nil}} =
             Admission.authorize_event(queued_event)

    assert %AgentCall{status: "failed", attempts: 0} = Repo.reload!(queued)
    assert Repo.reload!(queued_event).attempt_count == 0
    assert {:ok, %Run{}} = admit(Repo.reload!(running_event))
    assert %AgentCall{status: "running", attempts: 1} = Repo.reload!(running)
  end

  test "terminal calls and terminal runs consume their pending events without a model" do
    %{principal: agent} = agent_fixture()
    %{calls: [call], events: [event]} = workflow_fixture(agent.uid)
    assert {:ok, %Run{}} = admit(event)

    assert {:ok, %{accepted: true}} =
             Ankole.Repo.transact(fn repo ->
               Workflow.submit_result_in_tx(
                 repo,
                 call.id,
                 agent.uid,
                 event.session_id,
                 %{"ok" => true, "value" => "Done"}
               )
             end)

    assert {:ok, %{status: :completed, actor_event: completed}} = admit(Repo.reload!(event))
    assert %DateTime{} = completed.completed_at

    %{run: workflow, calls: [queued], events: [pending]} = workflow_fixture(agent.uid)
    assert {:ok, _} = Workflow.fail_replay(workflow.id, "program_execution_failed", "Stopped", 0)
    assert {:ok, %{status: :completed}} = admit(Repo.reload!(pending))
    assert %AgentCall{status: "cancelled", attempts: 0} = Repo.get!(AgentCall, queued.id)
    refute Repo.get_by(Conversation, subject_uid: agent.uid, conversation_key: pending.session_id)
    assert Repo.get!(AgentWorker, agent.uid).state == "absent"
  end

  test "a missing profile fails an unstarted task without using a Worker or attempt" do
    %{principal: agent} = agent_fixture()

    %{calls: [call], events: [event]} =
      workflow_fixture(agent.uid,
        arguments: [
          %{"prompt" => "Work", "model_profile" => "missing_profile"}
        ]
      )

    assert {:ok, %{status: :model_profile_unavailable, actor_event: completed}} = admit(event)
    assert %DateTime{} = completed.completed_at

    assert %AgentCall{status: "failed", attempts: 0, result: result} =
             Repo.get!(AgentCall, call.id)

    assert result["code"] == "workflow_task_model_profile_unavailable"
    assert result["ok"] == false
    assert Repo.get!(AgentWorker, agent.uid).state == "absent"
  end

  test "mail wakes its sleeping task while a sibling retains its wake deadline" do
    %{principal: agent} = agent_fixture()

    %{run: workflow, calls: calls, events: events} =
      workflow_fixture(agent.uid,
        arguments: [
          %{"prompt" => "Sleep first"},
          %{"prompt" => "Sleep second"}
        ]
      )

    for {call, event} <- Enum.zip(calls, events) do
      assert {:ok, run} = admit(event)

      assert {:ok, _} =
               Ankole.Repo.transact(fn repo ->
                 Workflow.sleep_task_in_tx(repo, call.id, agent.uid, event.session_id, %{
                   wake_after_ms: 3_600_000,
                   note: "Waiting",
                   attention: false
                 })
               end)

      assert {:ok, _} = Run.finalize(run, :sleeping)
    end

    [first, second] = calls
    sibling = Repo.get!(AgentCall, second.id)

    assert {:ok, _} =
             Repo.transact(fn _repo ->
               Workflow.send_task_message(
                 workflow.id,
                 0,
                 agent.uid,
                 "Continue with this message",
                 "mail-1"
               )
             end)

    message =
      Repo.get_by!(ActorEvent,
        agent_uid: agent.uid,
        source_event_id: "workflow:call:#{first.id}:msg:mail-1"
      )

    assert {:ok, run} = admit(message)
    assert run.actor_event_id == message.id
    assert run.spec.request_context["call_id"] == first.id
    assert %AgentCall{status: "running", wake_count: 1} = Repo.get!(AgentCall, first.id)
    assert Repo.get!(AgentCall, second.id) == sibling
  end

  test "six crashed admissions settle the running call and dead-letter its input" do
    %{principal: agent} = agent_fixture()
    %{calls: [call], events: [event]} = workflow_fixture(agent.uid)
    for _ <- 1..5, do: assert({:ok, %Run{}} = admit(Repo.reload!(event)))
    assert {:ok, %{status: :dead_letter}} = admit(Repo.reload!(event))
    assert %{status: "failed", attempts: 1, error: error} = Repo.reload!(call)
    assert error["code"] == "conversation_attempts_exhausted"
    assert Repo.reload!(event).input_state == "dead_letter"
    assert Repo.get!(AgentWorker, agent.uid).state == "absent"
  end

  for tool <- ["sleep", "submit_result"], recorded? <- [false, true] do
    @tag terminal_tool: tool, recorded?: recorded?
    test "#{tool} recovery from #{if recorded?, do: "tape", else: "receipt"} bypasses suspension, missing profiles and exhausted admissions",
         %{terminal_tool: tool, recorded?: recorded?} do
      %{principal: agent} = agent_fixture()
      %{run: workflow, calls: [call], events: [event]} = workflow_fixture(agent.uid)
      unstarted_snapshot = event
      {:ok, admitted} = admit(event)
      {:ok, {_state, run}} = Model.prepare(admitted)

      args =
        if tool == "sleep",
          do: %{"wake_after_ms" => 28_800_000, "note" => "Wait for input", "attention" => true},
          else: %{"result" => "Done"}

      {run, tool_call} = workflow_response(run, tool, args)
      {:ok, definition, args} = Tools.prepare(run, tool_call)
      result = Tools.execute(run, tool_call, definition, args)
      assert result.terminate
      refute result.is_error

      if recorded?,
        do:
          assert({:ok, _} = Run.record_round(%{run | results: %{tool_call["call_id"] => result}}))

      stored_call = Repo.reload!(call)
      Repo.update!(Ecto.Changeset.change(workflow, model_profile: "missing_after_commit"))
      event = Repo.update!(Ecto.Changeset.change(Repo.reload!(event), attempt_count: 6))

      Repo.get!(Ankole.Tenants.Tenant, Repo.tenant_id!())
      |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:microsecond))
      |> Repo.update!()

      assert {:ok, %{status: :completed, outcome: outcome, actor_event: completed}} = admit(event)
      assert outcome == if(tool == "sleep", do: :sleeping, else: :submitted)
      assert completed.completed_at
      assert completed.attempt_count == 6
      assert Repo.reload!(call) == stored_call
      assert Repo.aggregate(Receipts, :count) == 0
      assert Repo.get!(AgentWorker, agent.uid).state == "absent"

      workspace =
        Repo.get_by!(ActorSessionWorkspace,
          agent_uid: agent.uid,
          session_id: event.session_id
        )

      assert {:ok, %{status: :completed, actor_event: replayed} = result} = admit(event)
      refute Map.has_key?(result, :run)
      refute Map.has_key?(result, :outcome)
      assert replayed == completed
      assert Repo.reload!(event) == completed
      assert Repo.reload!(call) == stored_call
      assert Repo.aggregate(Receipts, :count) == 0
      assert Repo.reload!(workspace) == workspace

      assert {:ok, %{status: :completed, actor_event: ^completed} = result} =
               admit(unstarted_snapshot)

      refute Map.has_key?(result, :run)
      refute Map.has_key?(result, :outcome)
      assert Repo.reload!(workspace) == workspace
      assert Repo.reload!(call) == stored_call
    end
  end

  test "a rejected ending tool does not prevent the real Workflow retry claim" do
    %{principal: agent} = agent_fixture()

    %{calls: [call], events: [event]} =
      workflow_fixture(agent.uid,
        arguments: [%{"prompt" => "Return a boolean", "schema" => %{"type" => "boolean"}}]
      )

    {:ok, admitted} = admit(event)
    {:ok, {_state, run}} = Model.prepare(admitted)
    {run, tool_call} = workflow_response(run, "submit_result", %{"result" => "invalid"})

    assert {:error, %{is_error: true, failure_kind: "invalid_arguments"}} =
             Tools.prepare(run, tool_call)

    assert {:error, :receipt_not_found} =
             Receipts.fetch(Run.response_id(run.model_response), "end")

    assert {:ok, %{call: %{status: "queued"}}} =
             Ankole.Repo.transact(fn repo ->
               Workflow.submit_result_in_tx(repo, call.id, agent.uid, event.session_id, %{
                 "ok" => false,
                 "code" => "provider_failed",
                 "summary" => "Retry the request",
                 "retryable" => true
               })
             end)

    assert {:ok, %Run{} = retry} = admit(Repo.reload!(event))
    assert retry.spec.request_context["attempt"] == 2
    assert {:ok, {:preparing, restored}} = Run.restore(retry)
    refute restored.model_response
    refute Repo.reload!(event).completed_at
    assert %AgentCall{status: "running", attempts: 2} = Repo.reload!(call)
  end

  test "a real wake input does not reuse its predecessor's ending result" do
    %{principal: agent} = agent_fixture()
    %{calls: [call], events: [event]} = workflow_fixture(agent.uid)
    {:ok, admitted} = admit(event)
    {:ok, {_state, run}} = Model.prepare(admitted)

    {run, tool_call} =
      workflow_response(run, "sleep", %{
        "wake_after_ms" => 60_000,
        "note" => "Wait for the deadline",
        "attention" => false
      })

    {:ok, definition, args} = Tools.prepare(run, tool_call)
    assert Tools.execute(run, tool_call, definition, args).terminate
    assert {:ok, %{status: :completed}} = admit(Repo.reload!(event))

    wake =
      Repo.get_by!(ActorEvent,
        agent_uid: agent.uid,
        source_event_id: "workflow:call:#{call.id}:wake:1"
      )

    assert {:ok, %Run{} = resumed} = admit(wake, wake.available_at)
    assert resumed.actor_event_id == wake.id
    assert {:ok, {:preparing, _}} = Run.restore(resumed)
    refute Repo.reload!(wake).completed_at
    assert %AgentCall{status: "running", attempts: 1, wake_count: 1} = Repo.reload!(call)

    assert {:ok, %{call: %{status: "sleeping"}}} =
             Ankole.Repo.transact(fn repo ->
               Workflow.submit_result_in_tx(repo, call.id, agent.uid, wake.session_id, %{
                 "ok" => false,
                 "code" => "provider_failed",
                 "summary" => "Retry this wake input",
                 "retryable" => true
               })
             end)

    assert Repo.reload!(wake).last_attempt_at
    assert {:ok, %Run{} = retry} = admit(Repo.reload!(wake))
    assert retry.actor_event_id == wake.id
    assert retry.spec.request_context["attempt"] == 2
    assert {:ok, {:preparing, restored}} = Run.restore(retry)
    refute restored.model_response
    assert %AgentCall{status: "running", attempts: 2, wake_count: 1} = Repo.reload!(call)
  end

  @tag :b17_progress
  test "a newly committed round protects a progressing task from the watchdog" do
    {run, call} = progress_round()
    stale = stale_call(call)

    assert {:ok, %{disposition: :inserted}} = Run.record_round(run)
    current = Repo.reload!(call)
    assert DateTime.after?(current.updated_at, stale.updated_at)
    assert current.status == "running"
    assert current.attempts == 1

    now = DateTime.utc_now(:microsecond)

    assert {:ok, %{reconciled: 0}} =
             Workflow.reconcile_stale_tasks(call.run_id, DateTime.add(now, -3_600), now)

    assert {:ok, %{accepted: true, call: %{status: "succeeded"}}} =
             Repo.transact(fn repo ->
               Workflow.submit_result_in_tx(repo, call.id, run.agent_uid, run.session_id, %{
                 "ok" => true,
                 "value" => "Long work completed"
               })
             end)
  end

  @tag :b17_progress
  test "replaying an existing round cannot keep a task alive without new progress" do
    {run, call} = progress_round()
    assert {:ok, %{disposition: :inserted}} = Run.record_round(run)
    stale = stale_call(call)

    assert {:ok, %{disposition: :existing}} = Run.record_round(run)
    assert Repo.reload!(call) == stale

    now = DateTime.utc_now(:microsecond)

    assert {:ok, %{reconciled: 1}} =
             Workflow.reconcile_stale_tasks(call.run_id, DateTime.add(now, -3_600), now)

    assert Repo.reload!(call).status == "queued"
  end

  @tag :b17_progress
  test "a round rollback also rolls back its task progress timestamp" do
    {run, call} = progress_round()
    stale = stale_call(call)

    assert {:error, :round_rolled_back} =
             Repo.transact(fn repo ->
               assert {:ok, %{disposition: :inserted}} = Run.record_round_in_tx(repo, run)
               assert DateTime.after?(repo.reload!(call).updated_at, stale.updated_at)
               {:error, :round_rolled_back}
             end)

    assert Repo.reload!(call) == stale
    assert {:ok, %{disposition: :inserted}} = Run.record_round(run)
  end

  @tag :b17_progress
  test "recording a cancelled task's round does not renew or resurrect the task" do
    {run, call} = progress_round()

    assert {:ok, %{run: %{status: "cancelled"}}} =
             Repo.transact(fn repo ->
               Workflow.cancel_in_tx(repo, call.run_id, run.agent_uid)
             end)

    cancelled = Repo.reload!(call)
    assert cancelled.status == "cancelled"
    assert {:ok, %{disposition: :inserted}} = Run.record_round(run)
    assert Repo.reload!(call) == cancelled
  end

  @tag :b17_progress
  test "a late round from an earlier attempt cannot renew a reclaimed task" do
    {run, call} = progress_round()

    assert {:ok, %{call: %{status: "queued"}}} =
             Repo.transact(fn repo ->
               Workflow.submit_result_in_tx(repo, call.id, run.agent_uid, run.session_id, %{
                 "ok" => false,
                 "code" => "worker_lost",
                 "summary" => "Retry this task",
                 "retryable" => true
               })
             end)

    assert {:ok, %{call: %{attempts: 2}}} =
             Repo.transact(fn repo ->
               Workflow.claim_task_in_tx(repo, call.id, run.agent_uid, 8)
             end)

    reclaimed = Repo.reload!(call)
    assert {:ok, %{disposition: :inserted}} = Run.record_round(run)
    assert Repo.reload!(call) == reclaimed
  end

  @tag :b17_progress
  test "a replaced Driver cannot record progress for its old epoch" do
    {run, call} = progress_round()
    assert {:ok, %Run{}} = admit(Repo.reload!(run.event))
    current = Repo.reload!(call)

    assert {:error, :stale_driver} = Run.record_round(run)
    assert Repo.reload!(call) == current
  end

  defp progress_round do
    %{principal: agent} = agent_fixture()
    %{calls: [call], events: [event]} = workflow_fixture(agent.uid)
    {:ok, admitted} = admit(event)
    {:ok, {_state, run}} = Model.prepare(admitted)
    {run, tool_call} = workflow_response(run, "read_file", %{"path" => "/workspace/progress"})
    result = Tools.result(%{"status" => "read"}, text: "A completed round")
    {%{run | results: %{tool_call["call_id"] => result}}, call}
  end

  defp stale_call(call) do
    call
    |> Repo.reload!()
    |> Ecto.Changeset.change(updated_at: DateTime.add(DateTime.utc_now(:microsecond), -7_200))
    |> Repo.update!()
  end

  defp workflow_response(run, name, args) do
    call = %{
      "type" => "function_call",
      "name" => name,
      "call_id" => "end",
      "arguments" => Ankole.JSON.encode!(args),
      "status" => "completed"
    }

    run = %{run | iteration: 1}

    {:ok, response} =
      Ankole.AIGatewayCase.start_response_run(%{
        subject_uid: run.agent_uid,
        conversation_id: run.conversation.id,
        round_state: run,
        metadata: %{"request_metadata" => Ankole.Conversations.Run.metadata(run)}
      })

    {:ok, response} = ResponseCommit.commit_complete(response, [call])
    {%{run | model_response: response, round_calls: [call], calls: [call]}, call}
  end

  defp admit(event, now \\ DateTime.utc_now(:microsecond)) do
    Admission.admit(%{agent_uid: event.agent_uid, session_id: event.session_id}, event, now: now)
  end

  defp workflow_fixture(agent_uid, opts \\ []) do
    suffix = Integer.to_string(System.unique_integer([:positive]))

    run =
      Repo.insert!(
        WorkflowRun.creation_changeset(%WorkflowRun{}, %{
          authorization_kind: "service",
          agent_uid: agent_uid,
          owner_session_id: "workflow-owner-#{suffix}",
          reply_route: %{"binding_name" => "bot"},
          source_tool_call_id: "workflow-tool-#{suffix}",
          title: "Workflow #{suffix}",
          script: "return await agent('Run the task.');",
          args: %{},
          status: "running",
          concurrency: Keyword.get(opts, :concurrency, 8),
          max_agent_calls: 256,
          model_profile: Keyword.get(opts, :model_profile),
          error: %{}
        })
      )

    arguments =
      Keyword.get(opts, :arguments, [
        %{"prompt" => "Run Workflow task #{suffix}."}
      ])

    pending_calls =
      Enum.map(arguments, fn call_arguments ->
        %{namespace: nil, name: "agent", arguments: call_arguments}
      end)

    assert {:ok, %{new_calls: calls}} =
             Repo.transact(fn _repo ->
               Workflow.commit_replay_pending(run.id, pending_calls, 0)
             end)

    events =
      Enum.map(calls, fn call ->
        Repo.get_by!(ActorEvent,
          agent_uid: agent_uid,
          source_event_id: "workflow:call:#{call.id}:dispatch"
        )
      end)

    %{run: run, calls: calls, events: events}
  end
end
