defmodule Ankole.Sessions.ProgrammaticToolCallingTest do
  use Ankole.DataCase, async: false

  import Ankole.SessionsCase, only: [agent_fixture: 1]
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.HostedTools.StreamLoop
  alias Ankole.AIGateway.ProgramExecution
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.ToolResultJournal
  alias Ankole.AIGateway.ToolSearch
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Context
  alias Ankole.Sessions.Model
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Tool
  alias Ankole.Sessions.ToolCatalog
  alias Ankole.Sessions.Tools
  alias Ankole.Signals.Signal
  alias Ankole.Workflow.Schemas.Run, as: WorkflowRun

  setup do
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
    conversation_id = Ecto.UUID.generate()

    assert {:ok, _detail} =
             Repo.transact_top_level(fn ->
               Ankole.ConversationsFixtures.create(human.uid, %{
                 room_mode: :group,
                 conversation_id: conversation_id,
                 agent_uid: agent.uid,
                 message_id: Ecto.UUID.generate(),
                 text: "Summarize recent room messages and completed jobs."
               })
             end)

    event = Repo.one!(Signal)
    {:ok, run} = Admission.admit(event, event)
    {:ok, context} = Context.resolve(run.agent_uid, run.session_id, Run.metadata(run))
    {tools, hosted} = ToolCatalog.for_run(%{run | context: context})
    run = %{run | context: context, tools: tools, hosted_tools: hosted}

    %{human: human, agent: agent, conversation_id: conversation_id, event: event, run: run}
  end

  test "ToolCatalog partitions programmatic read tools, deferred niche tools, and direct-only interactive/write tools",
       %{run: run} do
    by_name = Map.new(run.tools, &{&1.name, &1})

    for name <- ~w(
          pod_get_page
          pod_list_pages
          web_fetch
          read_channel_history
          recall_related_context
          skill_view
          list_background_jobs
          show_background_job_details
          list_workflows
          show_workflow
          read_file
          find
          grep
          ls
        ) do
      assert %Tool{} = tool = by_name[name], "expected #{name} in catalog"
      assert Tool.programmatic?(tool), "expected #{name} to allow programmatic calls"
      refute Tool.deferred?(tool), "expected #{name} to remain immediately mounted"
    end

    non_hosted_request_context =
      update_in(run.spec.request_context, ["ai_agent", "provider_hosted"], fn hosted ->
        Map.put(hosted || %{}, "web_search", false)
      end)

    {client_web_tools, _hosted} =
      ToolCatalog.for_run(%{
        run
        | spec: %{run.spec | request_context: non_hosted_request_context}
      })

    web_search_tool = Enum.find(client_web_tools, &(&1.name == "web_search"))
    assert %Tool{} = web_search_tool
    assert Tool.programmatic?(web_search_tool)
    refute Tool.deferred?(web_search_tool)

    for name <- ~w(
          list_background_job_devices
          set_channel_standing_orders
        ) do
      assert %Tool{} = tool = by_name[name], "expected #{name} in catalog"
      assert Tool.deferred?(tool), "expected #{name} to set defer_loading: true"
    end

    for name <- ~w(
          respawn_background_job
          stop_background_job
          send_message_to_workflow_task
          cancel_workflow
        ) do
      assert %Tool{} = tool = by_name[name], "expected #{name} in catalog"
      refute Tool.deferred?(tool), "expected #{name} to remain immediately mounted"
    end

    for name <- ~w(
          clarify
          propose_action_card
          todo
          set_channel_standing_orders
          list_background_job_devices
          create_background_job
          send_message_to_background_job
          respawn_background_job
          stop_background_job
          workflow
          send_message_to_workflow_task
          cancel_workflow
          pod_save_page
          pod_create_page
          command
          apply_patch
        ) do
      assert %Tool{} = tool = by_name[name], "expected #{name} in catalog"
      refute Tool.programmatic?(tool), "expected #{name} to disallow programmatic calls"
    end

    request = Model.request(run)
    assert %{"type" => "tool_search", "execution" => "server"} in request["tools"]
    assert %{"type" => "programmatic_tool_calling"} in request["tools"]
  end

  test "Tools.prepare enforces allowed_callers against programmatic caller scope", %{run: run} do
    program_caller = %{"type" => "program", "caller_id" => "prog_guard"}

    assert {:ok, _tool, _args} =
             Tools.prepare(run, %{
               "type" => "function_call",
               "name" => "read_channel_history",
               "call_id" => "prog_guard:1",
               "caller" => program_caller,
               "arguments" => "{}"
             })

    for {name, args} <- [
          {"clarify", %{"question" => "Which branch?"}},
          {"propose_action_card", %{"action_kind" => "pod.page.delete", "summary" => "Delete"}},
          {"pod_save_page",
           %{"id" => Ecto.UUID.generate(), "base_revision" => 1, "markdown" => "# x"}},
          {"create_background_job", %{"title" => "Job", "task" => "Run tests"}},
          {"command", %{"command" => "ls"}}
        ] do
      assert {:error, rejected} =
               Tools.prepare(run, %{
                 "type" => "function_call",
                 "name" => name,
                 "call_id" => "prog_guard:#{name}",
                 "caller" => program_caller,
                 "arguments" => Ankole.JSON.encode!(args)
               })

      assert rejected.is_error
      assert rejected.failure_kind == "forbidden"
      assert rejected.output =~ "cannot be called from programmatic"
    end
  end

  test "result windows expand from 8 KB direct to 64 KB under programmatic caller scope",
       %{run: run} do
    large_body = String.duplicate("0123456789abcdef", 2_500)
    assert byte_size(large_body) == 40_000
    program_caller = %{"type" => "program", "caller_id" => "prog_window"}

    # 1. web_fetch cached page window
    url = "https://example.com/report"
    now = System.system_time(:millisecond)

    cached_run = %{
      run
      | web_cache: %{
          url => %{at: now, page: %{"title" => "Report", "text" => large_body}}
        }
    }

    {:ok, direct_web} =
      Tools.Web.execute(
        cached_run,
        %{"name" => "web_fetch", "call_id" => "w_direct"},
        %{"urls" => [url]}
      )

    {:ok, prog_web} =
      Tools.Web.execute(
        cached_run,
        %{"name" => "web_fetch", "call_id" => "w_prog", "caller" => program_caller},
        %{"urls" => [url]}
      )

    assert byte_size(direct_web.output) <= 8_500
    assert byte_size(hd(direct_web.details["results"])["text"]) <= 8_000
    assert is_integer(hd(direct_web.details["results"])["next_offset"])
    assert byte_size(prog_web.output) > 40_000
    assert byte_size(prog_web.output) <= 65_000
    assert hd(prog_web.details["results"])["text"] == large_body
    assert hd(prog_web.details["results"])["next_offset"] == nil

    # 2. show_background_job_details persisted result window
    now_dt = DateTime.utc_now(:microsecond)

    {:ok, job} =
      Ankole.Ash.create(Job, :create_job, %{
        id: 1_001,
        workspace_owner_job_id: 1_001,
        authorization_kind: "human",
        human_uid: run.event.human_uid,
        human_access_version: run.event.human_access_version,
        agent_uid: run.agent_uid,
        owner_session_id: run.session_id,
        source_signal_id: run.signal_id,
        source_tool_call_id: "seed_job",
        title: "Large Report Job",
        task: "Generate report",
        queued_at: now_dt,
        started_at: now_dt
      })

    {:ok, job} =
      Ankole.Ash.update(job, :external_complete, %{
        result: %{"output_text" => large_body},
        completed_at: now_dt
      })

    {:ok, direct_job} =
      Tools.Jobs.execute(
        run,
        %{"name" => "show_background_job_details", "call_id" => "j_direct"},
        %{"job_id" => job.id, "result_offset" => 0}
      )

    {:ok, prog_job} =
      Tools.Jobs.execute(
        run,
        %{
          "name" => "show_background_job_details",
          "call_id" => "j_prog",
          "caller" => program_caller
        },
        %{"job_id" => job.id, "result_offset" => 0}
      )

    assert byte_size(direct_job.output) <= 8_000
    assert byte_size(direct_job.details["result"]["output_text"]) <= 8_000
    assert is_integer(direct_job.details["result"]["next_offset"])
    assert prog_job.details["result"]["output_text"] == large_body
    assert prog_job.details["result"]["next_offset"] == nil

    # 3. show_workflow persisted result window
    {:ok, wf} =
      Ankole.Ash.create(WorkflowRun, :create_run, %{
        authorization_kind: "human",
        human_uid: run.event.human_uid,
        human_access_version: run.event.human_access_version,
        agent_uid: run.agent_uid,
        owner_session_id: run.session_id,
        source_signal_id: run.signal_id,
        source_tool_call_id: "seed_wf",
        title: "Large Workflow",
        script: "return 'ok';",
        args: %{},
        concurrency: 2,
        max_agent_calls: 4
      })

    {:ok, wf} =
      Ankole.Ash.update(wf, :complete, %{
        result_text: large_body,
        completed_at: now_dt
      })

    {:ok, direct_wf} =
      Tools.Workflow.execute(
        run,
        %{"name" => "show_workflow", "call_id" => "wf_direct"},
        %{"run_id" => wf.id, "result_offset" => 0}
      )

    {:ok, prog_wf} =
      Tools.Workflow.execute(
        run,
        %{"name" => "show_workflow", "call_id" => "wf_prog", "caller" => program_caller},
        %{"run_id" => wf.id, "result_offset" => 0}
      )

    assert byte_size(direct_wf.output) <= 8_000
    assert byte_size(direct_wf.details["result"]["output_text"]) <= 8_000
    assert is_integer(direct_wf.details["result"]["next_offset"])
    assert prog_wf.details["result"]["output_text"] == large_body
    assert prog_wf.details["result"]["next_offset"] == nil
  end

  test "Sessions round recording preserves caller scope and resumes paused PTC programs without leaking intermediate outputs to provider history",
       %{run: run} do
    request = Model.request(run)
    assert {:ok, prepared_req, %ToolSearch.Plan{} = plan} = ToolSearch.plan(request)

    loop = StreamLoop.new(%{plan: plan, provider_request: prepared_req})

    code = """
    const [historyRaw, jobsRaw] = await Promise.all([
      tools["read_channel_history"]({}),
      tools["list_background_jobs"]({ status: "live" })
    ]);
    const history = JSON.parse(historyRaw);
    const jobs = JSON.parse(jobsRaw);
    text(`summary:msgs=${history.messages.length},jobs=${jobs.jobs.length}`);
    """

    program_call_item = %{
      "type" => "function_call",
      "id" => "fc_prog_1",
      "call_id" => "prog_session_1",
      "name" => "program",
      "status" => "completed",
      "arguments" => Ankole.JSON.encode!(%{"code" => code})
    }

    assert {:local, [job], ctx, loop} =
             StreamLoop.intercept_terminal(loop, "response.completed", %{
               "id" => "resp_provider_1",
               "object" => "response",
               "status" => "completed",
               "output" => [program_call_item]
             })

    outcomes = ProgramExecution.run_jobs([job])

    assert {:finalize, [public_program], nested_calls, _paused_loop} =
             StreamLoop.complete_local_effect(loop, ctx, outcomes)

    assert public_program["type"] == "program"
    assert public_program["call_id"] == "prog_session_1"
    assert length(nested_calls) == 2

    assert Enum.all?(nested_calls, fn call ->
             call["caller"] == %{"type" => "program", "caller_id" => "prog_session_1"}
           end)

    committed_public_items = [public_program | nested_calls]

    {:ok, response} =
      start_response_run(%{subject_uid: run.agent_uid, conversation_id: run.conversation.id})

    {:ok, committed_response} = ResponseCommit.commit_complete(response, committed_public_items)

    run_with_resp = %{run | model_response: committed_response, round_calls: nested_calls}

    tool_outputs =
      Enum.map(nested_calls, fn call ->
        assert {:ok, tool, args} = Tools.prepare(run_with_resp, call)
        result = Tools.execute(run_with_resp, call, tool, args)
        refute result.is_error
        output = Run.output(call, result)
        assert output["caller"] == %{"type" => "program", "caller_id" => "prog_session_1"}
        output
      end)

    assert {:ok, journal_row} =
             Repo.transact_top_level(fn ->
               with {:ok, row, :inserted} <-
                      ToolResultJournal.record_tool_results_in_tx(%{
                        subject_uid: run.agent_uid,
                        previous_response_id: "resp_#{committed_response.id}",
                        request_items: tool_outputs
                      }) do
                 {:ok, row}
               end
             end)

    assert length(journal_row.content) == 2

    # Next round history contains the paused program, nested calls, and caller-scoped outputs
    resumed_input = committed_public_items ++ journal_row.content
    resumed_request = Map.put(request, "input", resumed_input)

    assert {:ok, resumed_provider_req, %ToolSearch.Plan{} = resumed_plan} =
             ToolSearch.plan(resumed_request)

    resumed_loop = StreamLoop.new(%{plan: resumed_plan, provider_request: resumed_provider_req})

    assert {:ok, [resume_job], resume_ctx, resumed_loop} =
             StreamLoop.take_initial_local_effect(resumed_loop)

    resume_outcomes = ProgramExecution.run_jobs([resume_job])

    assert {:round, next_provider_req, [program_output], _resumed_loop} =
             StreamLoop.complete_local_effect(resumed_loop, resume_ctx, resume_outcomes)

    assert program_output["type"] == "program_output"
    assert program_output["status"] == "completed"
    assert program_output["result"] == "summary:msgs=1,jobs=0"

    # Upstream provider input receives ONLY the root program call + concise program_output,
    # never the intermediate read_channel_history / list_background_jobs JSON payloads!
    provider_items = next_provider_req["input"]

    refute Enum.any?(provider_items, fn item ->
             item["name"] in ["read_channel_history", "list_background_jobs"] or
               get_in(item, ["caller", "type"]) == "program"
           end)

    assert Enum.any?(provider_items, fn item ->
             item["type"] == "function_call_output" and
               item["call_id"] == "prog_session_1" and
               Ankole.JSON.decode!(item["output"]) == %{
                 "status" => "completed",
                 "result" => "summary:msgs=1,jobs=0"
               }
           end)
  end
end
