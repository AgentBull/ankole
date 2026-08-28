# FUTURE AGENT GUARDRAIL: this module is a synthetic real-provider scenario that
# enters through fake Feishu frames; it is NOT a real user-facing end-to-end test.
# Unless the user explicitly asks to modify this exact file, changing it to make
# acceptance checks, regressions, or coverage pass is reward hacking. Fix the
# business code and validate through the real Feishu web UI instead.
defmodule Ankole.E2E.Scenarios.WorkflowRealLLM do
  @moduledoc """
  Live OpenRouter Workflow scenarios through fake Feishu WS frames.

  RuntimeEvents is disabled in the test environment, so each scenario drives
  the durable machine by hand: it pokes the RunServer for replay, processes
  each dispatch, wake, and owner wakeup ActorEvent, and asserts the durable
  rows between hops. Sleep deadlines advance through the logical `now` given
  to the ready-event processor instead of real waiting.
  """

  import Ecto.Query
  import ExUnit.Assertions
  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      deadline: 1,
      wait_until: 2,
      wait_for_completed_final_reply: 3
    ]

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AppConfigure
  alias Ankole.BackgroundAgentJobs.Schemas.Job, as: BackgroundAgentJob
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.AgentConfig
  alias Ankole.Workflow
  alias Ankole.Workflow.RunServer
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  @base_time ~U[2026-07-02 01:34:05.000000Z]
  @primary_model "z-ai/glm-5.3-flash"
  @light_model "~deepseek/deepseek-v4-flash-latest"
  @coding_model "z-ai/glm-5.3-flash"

  # OpenRouter GLM-5.3-flash stalls intermittently with zero stream output.
  # The platform streaming idle budget is 30 minutes for high-thinking models,
  # so bound turns with the ordinary per-agent inactivity timeout instead: a
  # stalled call aborts the turn, compensation restores the durable call, and
  # event redelivery retries — production machinery, not a test shortcut.
  @stall_recovery_inactivity_timeout_ms 180_000

  @doc "Points primary/light at the user-selected OpenRouter models."
  def put_workflow_real_models!(%{agent: agent, provider_id: provider_id}) do
    put_profile!(agent.uid, provider_id, "primary", @primary_model)
    put_profile!(agent.uid, provider_id, "light", @light_model)

    assert {:ok, _timeout} =
             AppConfigure.put_for_agent(
               agent.uid,
               AgentConfig.inactivity_timeout_ms_definition(),
               @stall_recovery_inactivity_timeout_ms
             )
  end

  @doc "Adds the coding/heavy profiles a delegated BackgroundAgentJob needs."
  def put_workflow_coding_models!(%{agent: agent, provider_id: provider_id}) do
    put_profile!(agent.uid, provider_id, "heavy", @coding_model)
    put_profile!(agent.uid, provider_id, "coding", @coding_model)
  end

  # -- W1: parallel fanout, structured results, one owner wakeup ---------------

  def run_real_workflow_fanout(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    script =
      "const [a, b] = await Promise.all([" <>
        "agent(\"Call submit_result exactly once with exactly the string alpha. Do not call any other tool.\", {label: \"a\"}), " <>
        "agent(\"Call submit_result exactly once with exactly the string beta. Do not call any other tool.\", {label: \"b\"})" <>
        "]); return {a: a, b: b};"

    input =
      send_workflow_request!(fake_feishu, agent, %{
        event_id: "evt_wf_fanout_1",
        message_id: "om_wf_fanout_1",
        chat_id: "oc_wf_fanout",
        offset_seconds: 20,
        arguments: %{"title" => "e2e fanout", "script" => script},
        started_marker: "ANKOLE_WF_FANOUT_STARTED",
        completion_instructions: """
        When the Workflow completion notification wakes this conversation, reply with
        ANKOLE_WF_FANOUT_OK followed by the two result words separated by one space.
        Do not call any tools in that turn unless the notification preview is missing the words.
        """
      })

    {run, _start_reply} = start_run!(container, agent, input)

    calls = drive_task_dispatches!(run, container, expected: 2)
    assert Enum.all?(calls, &(&1.status == "succeeded"))

    completion = drive_run_to_completion!(run, agent)
    {reply, _message} = process_owner_wakeup!(container, completion)

    assert reply_text!(reply) =~ "ANKOLE_WF_FANOUT_OK"
    assert reply_text!(reply) =~ "alpha"
    assert reply_text!(reply) =~ "beta"

    run = Repo.get!(Run, run.id)
    assert run.status == "completed"
    assert run.result_text =~ "alpha"
    assert run.result_text =~ "beta"

    %{input: input, run: run, reply: reply, completion_event: completion}
  end

  # -- W2: sleep on a deadline, wake, submit ------------------------------------

  def run_real_workflow_sleep_timer(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    task_prompt =
      "First call sleep exactly once with wake_after_ms 60000 and note exactly timer-test. " <>
        "After an event wakes you, call submit_result exactly once with exactly the string woke. " <>
        "Do not call any other tool."

    script = "return await agent(#{Ankole.JSON.encode!(task_prompt)}, {label: \"sleeper\"});"

    input =
      send_workflow_request!(fake_feishu, agent, %{
        event_id: "evt_wf_sleep_1",
        message_id: "om_wf_sleep_1",
        chat_id: "oc_wf_sleep",
        offset_seconds: 40,
        arguments: %{"title" => "e2e sleep timer", "script" => script},
        started_marker: "ANKOLE_WF_SLEEP_STARTED",
        completion_instructions: """
        When the Workflow completion notification wakes this conversation, reply with
        ANKOLE_WF_SLEEP_OK followed by the one-word workflow result.
        """
      })

    {run, _start_reply} = start_run!(container, agent, input)

    [dispatch_event] = task_dispatch_events!(run, expected: 1)
    process_ready!(dispatch_event)

    call = wait_for_call_status!(run, 0, "sleeping", deadline(420_000))
    assert call.sleep_note == "timer-test"
    assert call.wake_count == 1
    assert call.attempts == 0
    assert call.attention == false
    assert Workflow.counts(Repo, run.id)["sleeping"] == 1

    wake_event = task_event!(call, "workflow:call:#{call.id}:wake:1")
    assert wake_event.type == "workflow.task.wakeup"
    assert DateTime.after?(wake_event.available_at, DateTime.utc_now())

    # Advance the logical clock past the sleep deadline instead of waiting.
    process_ready!(wake_event, DateTime.add(wake_event.available_at, 1, :second))

    call = wait_for_call_status!(run, 0, "succeeded", deadline(420_000))
    assert call.result == %{"ok" => true, "value" => "woke"}

    completion = drive_run_to_completion!(run, agent)
    {reply, _message} = process_owner_wakeup!(container, completion)

    assert reply_text!(reply) =~ "ANKOLE_WF_SLEEP_OK"
    assert reply_text!(reply) =~ "woke"

    %{input: input, run: Repo.get!(Run, run.id), reply: reply}
  end

  # -- W3: attention escalation, owner answer, wake through the message --------

  def run_real_workflow_attention(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    task_prompt =
      "You do not know the codeword and must not invent one. " <>
        "Step 1: call sleep exactly once with attention true, wake_after_ms 3600000, " <>
        "and note exactly: Need the launch codeword from the owner. " <>
        "Step 2: when a message from the main Agent gives you a codeword, call submit_result " <>
        "exactly once with exactly that codeword. Do not call any other tool."

    script = "return await agent(#{Ankole.JSON.encode!(task_prompt)}, {label: \"asker\"});"

    input =
      send_workflow_request!(fake_feishu, agent, %{
        event_id: "evt_wf_attention_1",
        message_id: "om_wf_attention_1",
        chat_id: "oc_wf_attention",
        offset_seconds: 60,
        arguments: %{"title" => "e2e attention", "script" => script},
        started_marker: "ANKOLE_WF_ATT_STARTED",
        completion_instructions: """
        If a Workflow attention notification says a task is waiting for your input:
        call show_workflow once with that run_id to read the waiting task's call_seq and note,
        then call send_message_to_workflow_task exactly once with that run_id, that call_seq,
        and message exactly ANKOLE_WF_CODEWORD_7, then reply exactly ANKOLE_WF_ATT_ANSWERED.
        When the Workflow completion notification arrives later, reply with
        ANKOLE_WF_ATT_OK followed by the workflow result string.
        """
      })

    {run, _start_reply} = start_run!(container, agent, input)

    [dispatch_event] = task_dispatch_events!(run, expected: 1)
    process_ready!(dispatch_event)

    call = wait_for_call_status!(run, 0, "sleeping", deadline(420_000))
    assert call.attention == true
    assert call.sleep_note =~ "codeword"

    attention_event =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.session_id == ^input.session_id,
          where: event.type == "workflow.run.attention"
        )
      )

    assert attention_event.payload["data"]["run_id"] == run.id

    # The owner turn must answer through send_message_to_workflow_task.
    process_ready!(attention_event)

    assert {:ok, answer_reply, _message} =
             wait_for_completed_final_reply(container, attention_event.id, deadline(420_000))

    assert reply_text!(answer_reply) =~ "ANKOLE_WF_ATT_ANSWERED"

    message_event =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.type == "workflow.task.message",
          where: event.session_id == ^Workflow.task_session_id(call.id)
        )
      )

    assert message_event.payload["data"]["message"] =~ "ANKOLE_WF_CODEWORD_7"

    process_ready!(message_event)

    call = wait_for_call_status!(run, 0, "succeeded", deadline(420_000))
    assert call.result == %{"ok" => true, "value" => "ANKOLE_WF_CODEWORD_7"}
    assert call.attention == false

    completion = drive_run_to_completion!(run, agent)
    {reply, _message} = process_owner_wakeup!(container, completion)

    assert reply_text!(reply) =~ "ANKOLE_WF_ATT_OK"
    assert reply_text!(reply) =~ "ANKOLE_WF_CODEWORD_7"

    %{input: input, run: Repo.get!(Run, run.id), reply: reply}
  end

  # -- W4: task delegates a BackgroundAgentJob, sleeps, wakes on its completion -

  def run_real_workflow_job_delegation(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    task_prompt =
      "Step 1: call create_background_job exactly once with title exactly wf-delegate and task exactly: " <>
        "Reply with exactly ANKOLE_WF_JOB_PAYLOAD as your complete final answer. Do not create files and do not run commands. " <>
        "Step 2: after the job tool returns, call sleep exactly once with wake_after_ms 3600000 and note exactly: waiting for job. " <>
        "Step 3: when a background job completion event wakes you, call submit_result exactly once " <>
        "with exactly the string ANKOLE_WF_JOB_PAYLOAD. Do not call any other tool."

    script = "return await agent(#{Ankole.JSON.encode!(task_prompt)}, {label: \"delegator\"});"

    input =
      send_workflow_request!(fake_feishu, agent, %{
        event_id: "evt_wf_delegate_1",
        message_id: "om_wf_delegate_1",
        chat_id: "oc_wf_delegate",
        offset_seconds: 80,
        arguments: %{"title" => "e2e delegation", "script" => script},
        started_marker: "ANKOLE_WF_DELEGATE_STARTED",
        completion_instructions: """
        When the Workflow completion notification wakes this conversation, reply with
        ANKOLE_WF_DELEGATE_OK followed by the workflow result string.
        """
      })

    {run, _start_reply} = start_run!(container, agent, input)

    [dispatch_event] = task_dispatch_events!(run, expected: 1)
    process_ready!(dispatch_event)

    call = wait_for_call_status!(run, 0, "sleeping", deadline(420_000))
    assert call.sleep_note =~ "waiting for job"

    task_session_id = Workflow.task_session_id(call.id)

    job =
      Repo.one!(
        from(job in BackgroundAgentJob,
          where: job.agent_uid == ^agent.uid,
          where: job.owner_session_id == ^task_session_id
        )
      )

    assert job.title == "wf-delegate"

    job_dispatch =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.session_id == ^"job:#{job.id}",
          where: event.type == "background_agent_job.dispatch"
        )
      )

    process_ready!(job_dispatch)

    assert {:ok, %BackgroundAgentJob{} = job} =
             wait_until(deadline(420_000), fn ->
               case Repo.get!(BackgroundAgentJob, job.id) do
                 %BackgroundAgentJob{status: "succeeded"} = done ->
                   {:ok, done}

                 %BackgroundAgentJob{status: status} when status in ["failed", "stopped"] ->
                   {:ok, Repo.get!(BackgroundAgentJob, job.id)}

                 _pending ->
                   nil
               end
             end)

    assert job.status == "succeeded",
           "delegated job ended #{job.status}: #{inspect(job.error, limit: 5)}"

    assert get_in(job.result, ["output_text"]) =~ "ANKOLE_WF_JOB_PAYLOAD"

    # The lifecycle wakeup must reach the task session, never the owner session.
    job_wakeup =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.type == "background_agent_job.completed",
          where:
            event.source_event_id == ^"background_agent_job:#{job.id}:succeeded:#{job.attempts}"
        )
      )

    assert job_wakeup.session_id == task_session_id

    assert Repo.aggregate(
             from(event in ActorEvent,
               where: event.session_id == ^input.session_id,
               where: event.type == "background_agent_job.completed"
             ),
             :count
           ) == 0

    process_ready!(job_wakeup)

    call = wait_for_call_status!(run, 0, "succeeded", deadline(420_000))
    assert call.result == %{"ok" => true, "value" => "ANKOLE_WF_JOB_PAYLOAD"}

    completion = drive_run_to_completion!(run, agent)
    {reply, _message} = process_owner_wakeup!(container, completion)

    assert reply_text!(reply) =~ "ANKOLE_WF_DELEGATE_OK"
    assert reply_text!(reply) =~ "ANKOLE_WF_JOB_PAYLOAD"

    %{input: input, run: Repo.get!(Run, run.id), job: job, reply: reply}
  end

  # -- W5: owner cancel stops the run, its sleeping task, and its delegated job -

  def run_real_workflow_cancel_with_delegated_job(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    task_prompt =
      "Step 1: call create_background_job exactly once with title exactly wf-cancel-target and task exactly: " <>
        "Run the shell command sleep 240 and after it finishes reply DONE. " <>
        "Step 2: after the job tool returns, call sleep exactly once with wake_after_ms 3600000 " <>
        "and note exactly: waiting for cancel test job. Do not call any other tool."

    script = "return await agent(#{Ankole.JSON.encode!(task_prompt)}, {label: \"target\"});"

    input =
      send_workflow_request!(fake_feishu, agent, %{
        event_id: "evt_wf_cancel_1",
        message_id: "om_wf_cancel_1",
        chat_id: "oc_wf_cancel",
        offset_seconds: 100,
        arguments: %{"title" => "e2e cancel", "script" => script},
        started_marker: "ANKOLE_WF_CANCEL_STARTED",
        completion_instructions: ""
      })

    {run, _start_reply} = start_run!(container, agent, input)

    [dispatch_event] = task_dispatch_events!(run, expected: 1)
    process_ready!(dispatch_event)

    call = wait_for_call_status!(run, 0, "sleeping", deadline(420_000))
    task_session_id = Workflow.task_session_id(call.id)

    job =
      Repo.one!(
        from(job in BackgroundAgentJob,
          where: job.agent_uid == ^agent.uid,
          where: job.owner_session_id == ^task_session_id
        )
      )

    job_dispatch =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.session_id == ^"job:#{job.id}",
          where: event.type == "background_agent_job.dispatch"
        )
      )

    process_ready!(job_dispatch)

    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_wf_cancel_2",
               message_id: "om_wf_cancel_2",
               chat_id: "oc_wf_cancel",
               text: """
               @_user_1 Cancel the Workflow you started.
               1. Call list_workflows with status live to find the run whose title is exactly "e2e cancel".
               2. Call cancel_workflow exactly once with that run_id.
               3. Reply with exactly ANKOLE_WF_CANCEL_OK. Do not call any other tool.
               """,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 110, :second), :millisecond)
             )

    cancel_input = actor_event_by_source_entry_id!(agent.uid, "om_wf_cancel_2")
    process_ready!(cancel_input)

    assert {:ok, cancel_reply, _message} =
             wait_for_completed_final_reply(container, cancel_input.id, deadline(420_000))

    assert reply_text!(cancel_reply) =~ "ANKOLE_WF_CANCEL_OK"

    run = Repo.get!(Run, run.id)
    assert run.status == "cancelled"
    assert %AgentCall{status: "cancelled"} = Repo.get!(AgentCall, call.id)

    # Terminal cleanup must stop the delegated job through its owner session.
    assert {:ok, %BackgroundAgentJob{status: "stopped"}} =
             wait_until(deadline(60_000), fn ->
               case Repo.get!(BackgroundAgentJob, job.id) do
                 %BackgroundAgentJob{status: "stopped"} = stopped -> {:ok, stopped}
                 _live -> nil
               end
             end)

    # Cancellation sends no completion wakeup.
    assert Repo.aggregate(
             from(event in ActorEvent,
               where:
                 event.source_event_id in ^[
                   "workflow:#{run.id}:completed",
                   "workflow:#{run.id}:failed"
                 ]
             ),
             :count
           ) == 0

    %{input: input, run: run, job: Repo.get!(BackgroundAgentJob, job.id), reply: cancel_reply}
  end

  # -- W6: a failed task resolves to null inside the script ---------------------

  def run_real_workflow_task_failure_null(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    # Asking a real model to refuse submit_result fights the task contract and
    # its one repair nudge. An unavailable model profile fails the queued call
    # on the real dispatch path, so the script sees null without a model turn.
    script =
      "const a = await agent(\"unused\", {label: \"failing\", model_profile: \"missing_workflow_profile\"}); " <>
        "return {failed: a === null};"

    input =
      send_workflow_request!(fake_feishu, agent, %{
        event_id: "evt_wf_null_1",
        message_id: "om_wf_null_1",
        chat_id: "oc_wf_null",
        offset_seconds: 130,
        arguments: %{"title" => "e2e null contract", "script" => script},
        started_marker: "ANKOLE_WF_NULL_STARTED",
        completion_instructions: """
        When the Workflow completion notification wakes this conversation, reply with
        ANKOLE_WF_NULL_OK followed by the JSON result preview.
        """
      })

    {run, _start_reply} = start_run!(container, agent, input)

    [dispatch_event] = task_dispatch_events!(run, expected: 1)
    process_ready!(dispatch_event)

    call = wait_for_terminal_call!(run, 0, deadline(60_000))
    assert call.status == "failed"
    assert call.result["ok"] == false
    assert call.result["code"] == "workflow_model_profile_unavailable"

    completion = drive_run_to_completion!(run, agent)
    {reply, _message} = process_owner_wakeup!(container, completion)

    assert reply_text!(reply) =~ "ANKOLE_WF_NULL_OK"
    run = Repo.get!(Run, run.id)
    assert run.status == "completed"
    assert run.result_text =~ "true"

    %{input: input, run: run, call: call, reply: reply}
  end

  # -- W7: a failed run wakes the owner and the failure reply reaches the channel

  def run_real_workflow_failed_run_reply(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    input =
      send_workflow_request!(fake_feishu, agent, %{
        event_id: "evt_wf_boom_1",
        message_id: "om_wf_boom_1",
        chat_id: "oc_wf_boom",
        offset_seconds: 140,
        arguments: %{
          "title" => "e2e failing script",
          "script" => "throw new Error(\"ANKOLE_WF_BOOM\");"
        },
        started_marker: "ANKOLE_WF_BOOM_STARTED",
        completion_instructions: """
        If a Workflow failure notification wakes this conversation, reply with exactly
        ANKOLE_WF_FAIL_OK followed by the reported error summary. Do not call any tool.
        """
      })

    {run, _start_reply} = start_run!(container, agent, input)
    poke_run!(run.id)

    assert {:ok, %Run{} = run} =
             wait_until(deadline(60_000), fn ->
               case Repo.get!(Run, run.id) do
                 %Run{status: "running"} -> nil
                 %Run{} = terminal -> {:ok, terminal}
               end
             end)

    assert run.status == "failed"
    assert run.error["summary"] =~ "ANKOLE_WF_BOOM"

    failure_event =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.source_event_id == ^"workflow:#{run.id}:failed"
        )
      )

    {reply, _message} = process_owner_wakeup!(container, failure_event)
    assert reply_text!(reply) =~ "ANKOLE_WF_FAIL_OK"

    %{input: input, run: run, reply: reply, failure_event: failure_event}
  end

  # -- W8: free-form orchestration written by the model itself ------------------

  @doc """
  The only steering is the business shape: classify four tickers in one
  Workflow, group by industry inside the script, and make each industry task
  delegate one BackgroundAgentJob, sleep, and submit the job's summary. The
  model writes the script and every task prompt itself.
  """
  def run_real_workflow_free_orchestration(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    text = """
    @_user_1 Research these four tickers: NVDA, AMD, XOM, CVX.
    Call the workflow tool exactly once and orchestrate everything inside that one Workflow:
    1. First stage: one agent() call per ticker, in parallel, that returns the ticker's industry as one lowercase word. The tasks answer from their own knowledge and must not use any tool except submit_result.
    2. The script groups the tickers by industry.
    3. Second stage: one agent() call per industry. Each of these task prompts must tell the task to create exactly one background job that writes a one-sentence summary of investing in that industry, then sleep until the job completes, then submit the job's summary sentence.
    4. Return from the script one object that maps each industry to its summary sentence.
    After the workflow tool returns, reply with exactly ANKOLE_WF_ORCH_STARTED and end the turn. Do not poll with show_workflow or list_workflows.
    When the Workflow completion notification wakes this conversation, reply with ANKOLE_WF_ORCH_OK followed by each industry and its summary sentence.
    """

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_wf_orch_1",
               message_id: "om_wf_orch_1",
               chat_id: "oc_wf_orch",
               text: text,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 160, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_wf_orch_1")
    {run, start_reply} = start_run!(container, agent, input)
    assert reply_text!(start_reply) =~ "ANKOLE_WF_ORCH_STARTED"

    run = pump_run_to_terminal!(run, agent, deadline(900_000))

    assert run.status == "completed",
           "free orchestration run ended #{run.status}: #{inspect(run.error, limit: 10)}"

    # Each industry task must have delegated one Job and slept for it.
    task_session_prefix = "wf_task:%"

    jobs =
      Repo.all(
        from(job in BackgroundAgentJob,
          where: job.agent_uid == ^agent.uid,
          where: like(job.owner_session_id, ^task_session_prefix)
        )
      )

    assert jobs != [], "no BackgroundAgentJob was delegated from any Workflow task"

    assert Enum.all?(jobs, &(&1.status == "succeeded")),
           "delegated jobs did not all succeed: " <>
             inspect(
               Enum.map(jobs, &{&1.id, &1.status, &1.execution_failures, &1.error}),
               limit: 30,
               printable_limit: 4_000
             )

    slept_calls =
      Repo.all(
        from(call in AgentCall,
          where: call.run_id == ^run.id,
          where: call.wake_count > 0
        )
      )

    assert slept_calls != [], "no Workflow task slept during the delegation stage"

    # Job lifecycle wakeups belong to the task sessions, never the owner.
    assert Repo.aggregate(
             from(event in ActorEvent,
               where: event.session_id == ^input.session_id,
               where: event.type == "background_agent_job.completed"
             ),
             :count
           ) == 0

    completion = drive_run_to_completion!(run, agent)
    {reply, _message} = process_owner_wakeup!(container, completion)

    assert reply_text!(reply) =~ "ANKOLE_WF_ORCH_OK"

    %{input: input, run: Repo.get!(Run, run.id), jobs: jobs, reply: reply}
  end

  # Drives the durable machine the way production RuntimeEvents does: poke the
  # RunServer, process every due wf_task:/job: session event, and repeat until
  # the run leaves `running`. Owner-session events stay untouched for the
  # caller, so the owner wakes exactly once at the end.
  defp pump_run_to_terminal!(run, agent, deadline) do
    case Repo.get!(Run, run.id) do
      %Run{status: "running"} ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("workflow run #{run.id} did not reach a terminal status in time")
        end

        poke_run!(run.id)
        process_due_worker_session_events!(agent)
        Process.sleep(500)
        pump_run_to_terminal!(run, agent, deadline)

      %Run{} = terminal ->
        terminal
    end
  end

  defp process_due_worker_session_events!(agent) do
    now = DateTime.utc_now(:microsecond)

    events =
      Repo.all(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: is_nil(event.completed_at),
          where: event.input_state == "open",
          where: event.available_at <= ^now,
          where: like(event.session_id, "wf_task:%") or like(event.session_id, "job:%"),
          order_by: [asc: event.available_at]
        )
      )

    # A busy session defers its event; only redeliver, never assert progress.
    Enum.each(events, fn event ->
      process_ready_event_for_actor!(event, DateTime.add(now, 1, :second))
    end)
  end

  # -- shared driving helpers ----------------------------------------------------

  defp send_workflow_request!(fake_feishu, agent, opts) do
    mention = lark_bot_mention()

    text = """
    @_user_1 Run this Workflow test.
    Initial-turn state machine:
    1. Call the workflow tool exactly once. Its decoded arguments must equal the JSON object below. Copy the complete strings exactly; do not summarize, shorten, repair, or regenerate any field.
    2. After the tool returns, reply with exactly #{opts.started_marker} and end the turn. Do not call any other tool in this turn and never call show_workflow or list_workflows to poll.

    <workflow_arguments_json>
    #{Ankole.JSON.encode!(opts.arguments)}
    </workflow_arguments_json>

    #{opts.completion_instructions}
    """

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: opts.event_id,
               message_id: opts.message_id,
               chat_id: opts.chat_id,
               text: text,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(
                   DateTime.add(@base_time, opts.offset_seconds, :second),
                   :millisecond
                 )
             )

    actor_event_by_source_entry_id!(agent.uid, opts.message_id)
  end

  defp start_run!(container, agent, input) do
    assert {:ok, %{send_outcome: "sent_or_queued"}} = process_ready!(input)

    assert {:ok, start_reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(420_000))

    run =
      Repo.one!(
        from(run in Run,
          where: run.agent_uid == ^agent.uid,
          where: run.source_actor_event_id == ^input.id
        )
      )

    assert run.status == "running"
    {run, start_reply}
  end

  # RuntimeEvents is disabled under MIX_ENV=test, so replay advances only when
  # the scenario pokes the RunServer.
  defp poke_run!(run_id) do
    assert :ok = RunServer.poke(run_id)
  end

  defp task_dispatch_events!(run, expected: expected) do
    poke_run!(run.id)

    assert {:ok, calls} =
             wait_until(deadline(60_000), fn ->
               calls = run_calls(run.id)
               if length(calls) == expected, do: {:ok, calls}
             end)

    Enum.map(calls, fn call ->
      task_event!(call, "workflow:call:#{call.id}:dispatch")
    end)
  end

  defp drive_task_dispatches!(run, _container, expected: expected) do
    events = task_dispatch_events!(run, expected: expected)
    Enum.each(events, &process_ready!/1)

    assert {:ok, calls} =
             wait_until(deadline(360_000), fn ->
               calls = run_calls(run.id)

               if Enum.all?(calls, &(&1.status in ["succeeded", "failed", "cancelled"])),
                 do: {:ok, calls}
             end)

    calls
  end

  defp drive_run_to_completion!(run, agent) do
    poke_run!(run.id)

    assert {:ok, %Run{} = run} =
             wait_until(deadline(60_000), fn ->
               case Repo.get!(Run, run.id) do
                 %Run{status: "running"} ->
                   nil

                 %Run{} = terminal ->
                   {:ok, terminal}
               end
             end)

    assert run.status == "completed",
           "workflow run ended #{run.status}: #{inspect(run.error, limit: 5)}"

    Repo.one!(
      from(event in ActorEvent,
        where: event.agent_uid == ^agent.uid,
        where: event.source_event_id == ^"workflow:#{run.id}:completed"
      )
    )
  end

  defp process_owner_wakeup!(container, completion_event) do
    process_ready!(completion_event)

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, completion_event.id, deadline(420_000))

    {reply, message}
  end

  defp wait_for_terminal_call!(run, call_seq, deadline) do
    result =
      wait_until(deadline, fn ->
        call =
          Repo.one(
            from(call in AgentCall,
              where: call.run_id == ^run.id and call.call_seq == ^call_seq
            )
          )

        case call do
          %AgentCall{status: status} = call when status in ["succeeded", "failed", "cancelled"] ->
            {:ok, call}

          _call ->
            nil
        end
      end)

    assert {:ok, %AgentCall{} = call} = result
    call
  end

  defp wait_for_call_status!(run, call_seq, status, deadline) do
    result =
      wait_until(deadline, fn ->
        call =
          Repo.one(
            from(call in AgentCall,
              where: call.run_id == ^run.id and call.call_seq == ^call_seq
            )
          )

        case call do
          %AgentCall{status: ^status} = call -> {:ok, call}
          %AgentCall{status: other} when other in ["failed", "cancelled"] -> {:ok, call}
          _call -> nil
        end
      end)

    assert {:ok, %AgentCall{} = call} = result

    assert call.status == status,
           "call #{call_seq} ended #{call.status}: #{inspect(call.error, limit: 5)} result=#{inspect(call.result, limit: 5)}"

    call
  end

  defp run_calls(run_id) do
    AgentCall
    |> where([call], call.run_id == ^run_id)
    |> order_by([call], asc: call.call_seq)
    |> Repo.all()
  end

  defp task_event!(call, source_event_id) do
    session_id = Workflow.task_session_id(call.id)

    Repo.one!(
      from(event in ActorEvent,
        where: event.agent_uid == ^call.agent_uid,
        where: event.session_id == ^session_id,
        where: event.source_event_id == ^source_event_id
      )
    )
  end

  defp process_ready!(%ActorEvent{} = event),
    do: process_ready!(event, DateTime.add(event.available_at, 1, :second))

  defp process_ready!(%ActorEvent{} = event, now),
    do: process_ready_event_for_actor!(event, now)

  defp reply_text!(reply), do: reply.text || ""

  defp put_profile!(agent_uid, provider_id, profile, model) do
    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, profile, %{
               provider_id: provider_id,
               model: model,
               provider_options: %{}
             })
  end
end
