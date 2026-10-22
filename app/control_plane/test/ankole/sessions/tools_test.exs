defmodule Ankole.Sessions.ToolsTest do
  use Ankole.DataCase, async: false

  alias Ankole.Sessions.ToolArguments
  alias Ankole.Sessions.Tools

  defmodule NativeWorkflowRunner do
    alias Ankole.Kernel.ProgramRunner

    def run(run_id, source, tools, memo, options) do
      send(Process.whereis(:workflow_tools_native_runner_owner), {:native_replay_started, self()})
      ProgramRunner.run(run_id, source, tools, memo, options)
    end

    def cancel(run_id) do
      status =
        Ankole.Repo.get_by!(Ankole.Workflow.Schemas.Run, title: "Cancel native replay").status

      result = ProgramRunner.cancel(run_id)

      if owner = Process.whereis(:workflow_tools_native_runner_owner) do
        send(
          owner,
          {:native_replay_cancelled, run_id, status, Ankole.Repo.in_transaction?(), result}
        )
      end

      result
    end
  end

  test "argument repair preserves explicit values and refuses to guess strings (G4)" do
    assert {:ok, %{"path" => "/tmp/a"}, :none} = ToolArguments.parse(~s({"path":"/tmp/a"}))

    assert {:ok, %{"path" => "/tmp/a"}, :code_fence} =
             ToolArguments.parse("```json\n{\"path\":\"/tmp/a\"}\n```")

    assert {:ok, %{"path" => "/tmp/a"}, :balanced_object} =
             ToolArguments.parse(~s(arguments: {"path":"/tmp/a"} thanks))

    assert {:ok, %{"path" => "/tmp/a"}, :incomplete_container} =
             ToolArguments.parse(~s({"path":"/tmp/a",))

    assert {:ok, %{"path" => "/tmp/a", "unexpected" => true}, :incomplete_container} =
             ToolArguments.parse(~s({"path":"/tmp/a","unexpected":true,))

    assert {:error, _} = ToolArguments.parse(~s({"path":"/tmp/repor))
    assert {:error, _} = ToolArguments.parse(~s({"path":) <> String.duplicate("x", 256 * 1024))
  end

  test "session declarations send strict false unless they opt in, so optional parameters stay optional" do
    declaration =
      Tools.Jobs.declarations()
      |> Enum.find(&(&1["name"] == "create_background_job"))

    assert Ankole.Sessions.Tool.new(declaration, Tools.Jobs).schema["strict"] == false

    assert Ankole.Sessions.Tool.new(Map.put(declaration, "strict", true), Tools.Jobs).schema[
             "strict"
           ] == true

    refute "model_profile" in declaration["parameters"]["required"]

    # A freeform (custom) tool has no `strict` field; the provider rejects it.
    custom = %{"type" => "custom", "name" => "apply_patch", "format" => %{"type" => "grammar"}}
    refute Map.has_key?(Ankole.Sessions.Tool.new(custom, :worker).schema, "strict")
  end

  test "model_profile declarations name the default as the Agent's standard model" do
    tool = %{
      "description" => "Delegate.",
      "parameters" => %{"type" => "object", "properties" => %{}}
    }

    assert %{"description" => description} =
             Ankole.Sessions.Tool.with_profiles(tool, [], "coding")

    assert description =~ "omit model_profile to use the default coding profile"

    profiles = [%{"name" => "fast", "description" => "Low-cost model for quick drafts"}]
    declared = Ankole.Sessions.Tool.with_profiles(tool, profiles, "coding")

    assert declared["parameters"]["properties"]["model_profile"] == %{
             "type" => "string",
             "enum" => ["fast"]
           }

    assert declared["description"] =~ "fast (Low-cost model for quick drafts)"
    assert declared["description"] =~ "unless the human asks for one of these profiles by name"
    assert declared["description"] =~ "default coding profile is the Agent's standard model"
  end

  test "clarification normalization precedes execution (G4)" do
    tool =
      Tools.Session.declarations()
      |> Enum.find(&(&1["name"] == "clarify"))
      |> Ankole.Sessions.Tool.new(Tools.Session)

    run = %{tools: [tool]}

    args = %{
      "question" => "  Choose one  ",
      "choices" => [
        %{"label" => "  Operators  ", "description" => "  Runs the system.  "},
        "  Developers  "
      ]
    }

    call = %{
      "name" => "clarify",
      "call_id" => "clarify-1",
      "arguments" => Ankole.JSON.encode!(args)
    }

    assert {:ok, ^tool, normalized} = Tools.prepare(run, call)

    assert normalized == %{
             "question" => "Choose one",
             "choices" => [
               %{"label" => "Operators", "description" => "Runs the system."},
               "Developers"
             ]
           }

    result = Tools.execute(run, call, tool, normalized)
    assert result.terminate

    assert result.details["choices"] == [
             %{"label" => "Operators", "description" => "Runs the system."},
             %{"label" => "Developers"}
           ]

    for invalid <- [
          %{"question" => "   "},
          %{"question" => "Choose", "choices" => ["One"]},
          %{"question" => "Choose", "choices" => ["  ", "Two"]},
          %{"question" => "Choose", "choices" => [%{"title" => "One"}, %{"title" => "Two"}]}
        ] do
      assert {:error, %Ankole.Sessions.ToolResult{failure_kind: "invalid_arguments"}} =
               Tools.prepare(run, Map.put(call, "arguments", Ankole.JSON.encode!(invalid)))
    end
  end

  test "page names are scoped to the result owner and reuse the same cursor (G4)" do
    run = %{pages: %{}, todo: [], web_cache: %{}}

    result =
      Tools.result(%{"items" => [1]}, cursor: {"jobs", "private-cursor"})

    {run, first} = Tools.attach(run, result)
    assert first.details["next_page"] == "page_1"
    {run, second} = Tools.attach(run, result)
    assert second.details["next_page"] == "page_1"
    assert {:ok, "private-cursor"} = Tools.cursor(run, "jobs", "page_1")
    assert {:error, _} = Tools.cursor(run, "workflow", "page_1")
  end

  test "result windows fit the encoded byte budget without splitting UTF-8 (G4)" do
    text = String.duplicate("🚀\n", 4_000)
    total = byte_size(text)

    build = fn body, next ->
      %{"result_text" => body, "next_offset" => next, "result_bytes" => total}
    end

    assert {:ok, result} = Tools.window(text, 0, total, build)
    assert byte_size(result.output) <= 8_000
    assert String.valid?(result.details["result_text"])
    assert result.details["next_offset"] == byte_size(result.details["result_text"])
    assert {:error, :invalid_result_offset} = Tools.window("", 1, total, build)
    assert {:ok, final} = Tools.window("", total, total, build)
    assert is_nil(final.details["next_offset"])
  end

  test "todo validates text and folds replace, merge, duplicate ids, and bounded plans (G4)" do
    tool =
      Tools.Session.declarations()
      |> Enum.find(&(&1["name"] == "todo"))
      |> Ankole.Sessions.Tool.new(Tools.Session)

    run = %{tools: [tool], todo: [], pages: %{}, web_cache: %{}}
    item = fn id, content -> %{"id" => id, "content" => content, "status" => "pending"} end

    write = fn run, args ->
      call = %{"name" => "todo", "call_id" => "plan", "arguments" => Ankole.JSON.encode!(args)}
      assert {:ok, _, normalized} = Tools.prepare(run, call)
      result = Tools.execute(run, call, tool, normalized)

      assert [%{"kind" => "plan.snapshot", "payload" => %{"items" => items}}] =
               result.presentation

      assert items == result.details["todos"]
      Tools.attach(run, result)
    end

    {run, _} = write.(run, %{"todos" => [item.(" a ", " First "), item.("b", "Second")]})
    assert hd(run.todo) == item.("a", "First")

    {run, _} =
      write.(run, %{"todos" => [item.("c", "Third"), item.("a", "Stale"), item.("a", "Fresh")]})

    assert run.todo == [item.("c", "Third"), item.("a", "Fresh")]

    {run, _} =
      write.(run, %{"merge" => true, "todos" => [item.("a", "Done"), item.("d", "Fourth")]})

    assert run.todo == [item.("c", "Third"), item.("a", "Done"), item.("d", "Fourth")]
    {run, _} = write.(run, %{"todos" => for(n <- 1..200, do: item.("i#{n}", "Task"))})

    {run, _} =
      write.(run, %{"merge" => true, "todos" => for(n <- 201..300, do: item.("i#{n}", "Task"))})

    assert length(run.todo) == 256
    assert List.last(run.todo)["id"] == "i256"

    for invalid <- [
          Map.delete(item.("a", "Task"), "content"),
          item.(" ", "Task"),
          item.("a", " "),
          item.("a", String.duplicate("x", 4001)),
          Map.put(item.("a", "Task"), "status", "done"),
          Map.put(item.("a", "Task"), "priority", 1)
        ] do
      assert {:error, %Ankole.Sessions.ToolResult{failure_kind: "invalid_arguments"}} =
               Tools.prepare(run, %{
                 "name" => "todo",
                 "arguments" => Ankole.JSON.encode!(%{"todos" => [invalid]})
               })
    end
  end

  describe "domain tools without a Worker" do
    setup do
      %{principal: agent} = Ankole.SessionsCase.agent_fixture()
      key = %{agent_uid: agent.uid, session_id: "tools:#{Ecto.UUID.generate()}"}

      {:ok, event} =
        Repo.transact(fn repo ->
          Ankole.Signals.accept_in_tx(
            repo,
            %{
              producer: :kernel,
              target: key,
              source: "test:tools",
              reply_route: %{binding_name: "bot"},
              authorization: Ankole.Principals.WorkAccess.service(),
              sender: agent.uid,
              id: Ecto.UUID.generate(),
              type: "conversation.message.addressed",
              data: %{},
              available_at: DateTime.utc_now(:microsecond)
            }
          )
        end)

      {:ok, run} = Ankole.Sessions.Admission.admit(key, event)
      {:ok, context} = Ankole.Sessions.Context.resolve(run.agent_uid, run.session_id)

      {:ok, response} =
        Ankole.AIGatewayCase.start_response_run(%{
          subject_uid: run.agent_uid,
          conversation_id: run.conversation.id,
          round_state: run,
          metadata: %{"request_metadata" => Ankole.Sessions.Run.metadata(run)}
        })

      run = %{run | context: context, model_response: response}
      {tools, _} = Ankole.Sessions.ToolCatalog.for_run(run)
      %{run: %{run | tools: tools}}
    end

    test "Skill reads return the image root without a Worker or provider (G1, G2)", %{run: run} do
      alias Ankole.AgentWorkers.AgentWorker
      Repo.delete_all(from(worker in AgentWorker, where: worker.agent_uid == ^run.agent_uid))

      skill =
        Enum.find(
          run.context.skills,
          &(get_in(&1, ["metadata", "ankole-runtime"]) in [nil, "main", "any"] and
              &1["source_kind"] == "builtin")
        )

      result = invoke(run, "skill_view", %{"name" => skill["skill_name"]}, "view")
      refute result.is_error
      assert result.output =~ "directory=\"/repo/app/library/#{skill["relative_path"]}\""
      assert Repo.get(AgentWorker, run.agent_uid) == nil
      unavailable = invoke(run, "skill_view", %{"name" => "not-enabled"}, "missing")
      assert unavailable.is_error
      assert unavailable.output =~ "skill is not enabled for this turn: not-enabled"
    end

    test "creating a Job stores its source and sending, listing, stopping keep the domain owner (G1, G4)",
         %{run: run} do
      worker = Repo.get!(Ankole.AgentWorkers.AgentWorker, run.agent_uid)

      created =
        invoke(
          run,
          "create_background_job",
          %{"title" => " Report ", "task" => "Finish the report."},
          "job"
        )

      refute created.is_error, inspect(created)
      id = created.details["job_id"]
      job = Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, id)
      assert job.owner_session_id == run.session_id
      assert job.source_signal_id == run.signal_id

      assert job.source_tool_call_id ==
               "#{Ankole.Sessions.Run.response_id(run.model_response)}:job"

      repeated =
        invoke(run, "create_background_job", %{"title" => "Other", "task" => "Other."}, "job")

      assert repeated == created

      sent =
        invoke(
          run,
          "send_message_to_background_job",
          %{
            "job_id" => id,
            "message" => "Add the runbook."
          },
          "steer"
        )

      assert {:await, %Ankole.Sessions.Wait{timeout_ms: 30_000}} = sent
      listed = invoke(run, "list_background_jobs", %{}, "list")
      refute listed.is_error, inspect(listed)
      assert Enum.any?(listed.details["jobs"], &(&1["job_id"] == id))
      shown = invoke(run, "show_background_job_details", %{"job_id" => id}, "show")
      refute shown.is_error, inspect(shown)
      assert shown.details["status"] == "queued"
      assert shown.details["current_turn_status"] == nil
      assert shown.details["error"] == nil
      stopped = invoke(run, "stop_background_job", %{"job_id" => id}, "stop")
      refute stopped.is_error, inspect(stopped)
      assert Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, id).status == :stopped

      assert Repo.get!(Ankole.AgentWorkers.AgentWorker, run.agent_uid) ==
               worker
    end

    test "stop_background_job sends a stop to the admitted Worker turn", %{run: run} do
      alias Ankole.AgentWorkers.WorkerRoute
      route = Ankole.SessionsCase.unique_route()
      :ok = WorkerRoute.register_local_worker(route, self())
      on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)

      assert {:ok, _} =
               Ankole.SessionsCase.admit_worker(route, %{
                 worker_id: run.agent_uid
               })

      created =
        invoke(
          run,
          "create_background_job",
          %{"title" => "Stop live work", "task" => "Inspect the report."},
          "live-job"
        )

      id = created.details["job_id"]
      job = Ankole.BackgroundAgentJobs.get_job(id)
      key = %{agent_uid: run.agent_uid, session_id: Ankole.BackgroundAgentJobs.job_session_id(id)}

      assert {:ok, %{event: event}} =
               Ankole.Sessions.Run.rebuild(key, DateTime.add(job.queued_at, 1))

      assert {:ok, job_run} = Ankole.Sessions.Admission.admit(key, event)
      assert {:ok, _} = Ankole.Sessions.CodexJob.start(job_run)
      assert_receive {:actor_lane, %Ankole.RuntimeFabric.V1.Envelope{body: {:turn_start, _}}}
      stopped = invoke(run, "stop_background_job", %{"job_id" => id}, "stop-live")
      refute stopped.is_error, inspect(stopped)
      assert stopped.details == %{"job_id" => id, "status" => "stopped"}

      assert_receive {:actor_lane,
                      %Ankole.RuntimeFabric.V1.Envelope{body: {:turn_control, control}}},
                     1_000

      assert control.command == "stop"
      assert control.turn == Ankole.Sessions.JobTurnRef.to_proto(job_run.job_ref)
    end

    test "a scheduled Job freezes all delivery targets from its durable source", %{run: run} do
      targets = [
        %{
          "binding_name" => "bot",
          "conversation_id" =>
            Ankole.ExternalConversationsFixtures.external_conversation_id("primary")
        },
        %{
          "binding_name" => "archive",
          "conversation_id" =>
            Ankole.ExternalConversationsFixtures.external_conversation_id("secondary")
        }
      ]

      Repo.update!(
        change(run.event,
          type: "cron.fire",
          data: %{"wake_payload" => %{"delivery" => %{"targets" => targets}}}
        )
      )

      created =
        invoke(
          run,
          "create_background_job",
          %{"title" => "Scheduled report", "task" => "Write the report."},
          "scheduled-job"
        )

      refute created.is_error, inspect(created)
      job = Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, created.details["job_id"])
      assert job.reply_route["delivery"] == %{"targets" => targets}
      assert job.metadata["owner_conversation_id"] == run.conversation.id
    end

    test "Job continuation uses one terminal source and captures the current parent route", %{
      run: run
    } do
      created =
        invoke(
          run,
          "create_background_job",
          %{"title" => "Report", "task" => "Write the report."},
          "original-job"
        )

      id = created.details["job_id"]
      args = %{"source_job_id" => id, "message" => "Improve the report."}
      live = invoke_error(run, "respawn_background_job", args, "live-continuation")
      assert live.is_error
      assert live.output =~ "background_agent_job_not_terminal"
      source = Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, id)

      source =
        Repo.update!(
          change(source,
            status: :failed,
            runtime_thread_id: "thread-to-continue",
            owner_session_id: "historical-session",
            reply_route: %{"binding_name" => "historical-binding"},
            completed_at: DateTime.utc_now(:microsecond)
          )
        )

      resumed = invoke(run, "respawn_background_job", args, "continuation")
      refute resumed.is_error, inspect(resumed)
      successor = Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, resumed.details["job_id"])
      assert successor.continued_from_job_id == id
      assert successor.workspace_owner_job_id == source.workspace_owner_job_id
      assert successor.runtime_thread_id == source.runtime_thread_id
      assert successor.model_profile == source.model_profile
      assert successor.owner_session_id == run.session_id
      assert successor.reply_route["binding_name"] == run.event.reply_binding_name
      assert invoke(run, "respawn_background_job", args, "continuation") == resumed
      again = invoke_error(run, "respawn_background_job", args, "second-continuation")
      assert again.is_error
      assert again.output =~ "background_agent_job_already_respawned"

      created =
        invoke(
          run,
          "create_background_job",
          %{"title" => "Unstarted report", "task" => "Write the report."},
          "unstarted-job"
        )

      id = created.details["job_id"]
      job = Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, id)
      Repo.update!(change(job, status: :stopped, completed_at: DateTime.utc_now(:microsecond)))

      missing =
        invoke_error(
          run,
          "respawn_background_job",
          %{"source_job_id" => id, "message" => "Continue."},
          "missing-thread"
        )

      assert missing.is_error
      assert missing.output =~ "background_agent_job_runtime_thread_missing"
    end

    test "Job result reads keep encoded output bounded and reject split UTF-8 offsets", %{
      run: run
    } do
      created =
        invoke(
          run,
          "create_background_job",
          %{"title" => "Report", "task" => "Write the report."},
          "result-job"
        )

      id = created.details["job_id"]
      text = String.duplicate("季😀\"\\\n", 4_000)
      job = Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, id)

      Repo.update!(
        change(job,
          status: :succeeded,
          result: %{
            "output_text" => text,
            "project_path" => "/agents/report",
            "artifacts" => %{
              "paths" => ["/agents/report/report.md"],
              "total_count" => 1,
              "truncated" => false
            }
          },
          completed_at: DateTime.utc_now(:microsecond)
        )
      )

      first =
        invoke(
          run,
          "show_background_job_details",
          %{"job_id" => id, "result_offset" => 0},
          "first-window"
        )

      refute first.is_error, inspect(first)
      assert byte_size(first.output) <= 8_000
      refute Map.has_key?(first.details, "recent_trajectory")
      content = first.details["result"]["output_text"]
      assert String.valid?(content)
      offset = first.details["result"]["next_offset"]
      assert offset == byte_size(content)

      second =
        invoke(
          run,
          "show_background_job_details",
          %{"job_id" => id, "result_offset" => offset},
          "second-window"
        )

      refute second.is_error, inspect(second)
      assert byte_size(second.output) <= 8_000

      assert String.starts_with?(
               binary_part(text, offset, byte_size(text) - offset),
               second.details["result"]["output_text"]
             )

      invalid =
        invoke(
          run,
          "show_background_job_details",
          %{"job_id" => id, "result_offset" => 1},
          "split-character"
        )

      assert invalid.is_error
    end

    test "Workflow parent tools and schema submission use durable task facts without a Worker (G1, G3, G4)",
         %{run: run} do
      created =
        invoke(
          run,
          "workflow",
          %{
            "title" => " Check facts ",
            "script" => "return await agent('Check facts');",
            "args" => %{}
          },
          "workflow"
        )

      refute created.is_error, inspect(created)
      id = created.details["run_id"]
      assert is_integer(id)
      listed = invoke(run, "list_workflows", %{}, "workflows")
      refute listed.is_error, inspect(listed)
      assert Enum.any?(listed.details["runs"], &(&1["run_id"] == id))

      {task, call} = task_run(run, id)
      shown = invoke(run, "show_workflow", %{"run_id" => id}, "show-workflow")
      refute shown.is_error, inspect(shown)
      assert length(shown.details["live_tasks"]) == 1

      sent =
        invoke(
          run,
          "send_message_to_workflow_task",
          %{"run_id" => id, "call_seq" => call.call_seq, "message" => "Use the latest facts."},
          "message-task"
        )

      refute sent.is_error, inspect(sent)

      submitted = invoke(task, "submit_result", %{"result" => false}, "submitted")
      refute submitted.is_error, inspect(submitted)
      assert submitted.terminate

      assert Repo.get!(Ankole.Workflow.Schemas.AgentCall, call.id).result == %{
               "ok" => true,
               "value" => false
             }

      assert invoke(task, "submit_result", %{"result" => true}, "submitted") == submitted
      cancelled = invoke(run, "cancel_workflow", %{"run_id" => id}, "cancelled")
      refute cancelled.is_error, inspect(cancelled)
    end

    test "cancel_workflow commits its receipt before it stops native replay", %{
      run: run
    } do
      alias Ankole.Kernel.ProgramRunner
      alias Ankole.Workflow.RunServer
      alias Ankole.Workflow.Schemas.Run

      created =
        invoke(
          run,
          "workflow",
          %{"title" => "Cancel native replay", "script" => "while (true) {}", "args" => %{}},
          "native-workflow"
        )

      refute created.is_error, inspect(created)
      id = created.details["run_id"]
      true = Process.register(self(), :workflow_tools_native_runner_owner)

      on_exit(fn ->
        RunServer.stop_replay(id)
      end)

      assert :ok = RunServer.poke(id, runner: NativeWorkflowRunner, runtime_busy_retry_ms: 20)
      assert_receive {:native_replay_started, _task}, 1_000
      assert wait_for(fn -> ProgramRunner.active_runs() == 1 end)
      server = RunServer.whereis(id)
      %{handle: native_id, replay: %{pid: task}} = :sys.get_state(server)
      server_monitor = Process.monitor(server)
      task_monitor = Process.monitor(task)

      call = %{
        "name" => "cancel_workflow",
        "call_id" => "native-cancel",
        "arguments" => Ankole.JSON.encode!(%{"run_id" => id})
      }

      assert {:ok, tool, args} = Tools.prepare(run, call)
      started_at = System.monotonic_time(:millisecond)
      result = Tools.execute(run, call, tool, args)
      refute result.is_error, inspect(result)
      assert result.details == %{"run_id" => id, "status" => "cancelled"}

      assert %Run{status: :cancelled, result_text: nil, cleanup_completed_at: %DateTime{}} =
               Repo.get!(Run, id)

      assert {:ok, receipt} =
               Ankole.Sessions.Receipts.fetch(
                 Ankole.Sessions.Run.response_id(run.model_response),
                 call["call_id"]
               )

      assert receipt.result["details"] == result.details

      assert_receive {:native_replay_cancelled, ^native_id, :cancelled, false, :ok}, 2_000
      assert_receive {:DOWN, ^server_monitor, :process, ^server, :normal}, 2_000
      assert_receive {:DOWN, ^task_monitor, :process, ^task, _reason}, 2_000
      assert RunServer.whereis(id) == nil

      assert wait_for(fn -> ProgramRunner.active_runs() == 0 end)

      assert {:ok, %{status: :completed, output: [%{value: "released"}]}} =
               ProgramRunner.run(~s|text("released");|, [], [])

      assert System.monotonic_time(:millisecond) - started_at < 2_000

      assert Tools.execute(run, call, tool, args) == result
      refute_receive {:native_replay_cancelled, ^native_id, _, _, _}, 50
    end

    test "Workflow sleep holds an open scheduled wake and reports its waiting note (G1, G2, G4)",
         %{run: run} do
      created =
        invoke(
          run,
          "workflow",
          %{
            "title" => "Wait for a condition",
            "script" => "return await agent('Wait for a condition');",
            "args" => %{}
          },
          "sleeping-workflow"
        )

      id = created.details["run_id"]
      {task, call} = task_run(run, id)

      slept =
        invoke(
          task,
          "sleep",
          %{
            "wake_after_ms" => 60_000,
            "note" => "Wait for the delegated work.",
            "attention" => false
          },
          "sleep"
        )

      refute slept.is_error, inspect(slept)
      assert slept.terminate
      stored = Repo.get!(Ankole.Workflow.Schemas.AgentCall, call.id)
      assert stored.status == :sleeping
      assert stored.wake_count == 1
      assert stored.sleep_note == "Wait for the delegated work."

      wake =
        Repo.get_by!(Ankole.Signals.Signal,
          agent_uid: task.agent_uid,
          session_id: task.session_id,
          type: "workflow.task.wakeup"
        )

      assert wake.status == :queued
      assert wake.available_at == stored.wake_at
      shown = invoke(run, "show_workflow", %{"run_id" => id}, "sleep-status")

      assert Enum.any?(
               shown.details["live_tasks"],
               &(&1["status"] == "sleeping" and &1["note"] == stored.sleep_note)
             )
    end

    test "Workflow tools reject oversized values and keep nested ownership closed", %{run: run} do
      args = %{
        "title" => "Check facts",
        "script" => "return await agent('Check facts');",
        "args" => %{"text" => String.duplicate("界", 22_000)}
      }

      rejected = invoke_error(run, "workflow", args, "oversized-workflow")
      assert rejected.is_error

      assert rejected.output ==
               "Error: [{\"message\":\"is too large\",\"path\":\"args\"}]\n" <>
                 "Analyze the error above and try a different approach."

      created = invoke(run, "workflow", Map.put(args, "args", %{}), "workflow-limits")
      refute created.is_error, inspect(created)
      {task, call} = task_run(run, created.details["run_id"], %{"type" => "string"})
      nested = %{"name" => "workflow", "call_id" => "nested", "arguments" => "{}"}

      assert {:error, %Ankole.Sessions.ToolResult{failure_kind: "unknown_tool"}} =
               Tools.prepare(task, nested)

      rejected =
        invoke_error(
          task,
          "submit_result",
          %{"result" => String.duplicate("😀", 8_000)},
          "oversized-result"
        )

      assert rejected.is_error
      assert rejected.output =~ "workflow_result_too_large"
      assert Repo.get!(Ankole.Workflow.Schemas.AgentCall, call.id).status == :running
      accepted = invoke(task, "submit_result", %{"result" => "Complete"}, "bounded-result")
      refute accepted.is_error, inspect(accepted)
    end
  end

  defp task_run(parent, workflow_id, schema \\ %{"type" => "boolean"}) do
    {:ok, %{new_calls: [call]}} =
      Repo.transact(fn _ ->
        Ankole.Workflow.commit_replay_pending(
          workflow_id,
          [
            %{
              namespace: nil,
              name: "agent",
              arguments: %{"prompt" => "Check the facts.", "schema" => schema}
            }
          ],
          0
        )
      end)

    event =
      Repo.get_by!(Ankole.Signals.Signal,
        agent_uid: parent.agent_uid,
        source_event_id: "workflow:call:#{call.id}:dispatch"
      )

    {:ok, task} =
      Ankole.Sessions.Admission.admit(
        %{agent_uid: parent.agent_uid, session_id: event.session_id},
        event
      )

    {:ok, response} =
      Ankole.AIGatewayCase.start_response_run(%{
        subject_uid: task.agent_uid,
        conversation_id: task.conversation.id,
        round_state: task,
        metadata: %{"request_metadata" => Ankole.Sessions.Run.metadata(task)}
      })

    task = %{task | context: parent.context, model_response: response}
    {tools, _} = Ankole.Sessions.ToolCatalog.for_run(task)
    {%{task | tools: tools}, call}
  end

  defp wait_for(fun, attempts \\ 200)
  defp wait_for(_fun, 0), do: flunk("condition did not become true")

  defp wait_for(fun, attempts) do
    case fun.() do
      value when value in [nil, false] ->
        receive do
        after
          10 -> wait_for(fun, attempts - 1)
        end

      value ->
        value
    end
  end

  defp invoke_error(run, name, args, id) do
    call = %{"name" => name, "call_id" => id, "arguments" => Ankole.JSON.encode!(args)}
    assert {:ok, tool, args} = Tools.prepare(run, call)
    result = Tools.execute(run, call, tool, args)
    assert result.is_error, inspect(result)
    result
  end

  defp invoke(run, name, args, id) do
    call = %{"name" => name, "call_id" => id, "arguments" => Ankole.JSON.encode!(args)}
    assert {:ok, tool, args} = Tools.prepare(run, call)
    Tools.execute(run, call, tool, args)
  end
end
