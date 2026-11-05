defmodule AnkoleWeb.PodExecutionLogTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  alias Ankole.{BackgroundAgentJobs, Repo, Workflow}
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.Signals.Signal

  @moduletag host: :pod

  setup %{conn: conn} do
    {conn, uid} = console_conn_with_principal(conn)
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: uid}).principal
    Ankole.ConversationsFixtures.grant_chat(uid, agent.uid)
    room = create_room!(uid, agent.uid)
    source = Repo.get_by!(Signal, message_id: hd(room.messages).id)
    %{conn: conn, uid: uid, agent: agent, room: room, source: source}
  end

  test "the room API walks every Job trajectory page, strips skill bodies, omits empty outcomes, and keeps human steers",
       ctx do
    assert {:ok, %{job: job}} =
             Ankole.SessionsCase.create_job_with_stub_driver(%{
               "source_signal_id" => ctx.source.id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => ctx.source.session_id,
               "source_tool_call_id" => "room-log-job",
               "title" => "Read all recorded steps",
               "task" => "Read the report.",
               "reply_route" => %{"conversation_id" => ctx.room.conversation.id}
             })

    claim_and_start_job!(job, ctx)
    job = BackgroundAgentJobs.get_job(job.id)
    now = DateTime.utc_now(:microsecond)

    visible_items =
      for index <- 1..45 do
        %{"type" => "agentMessage", "id" => "step-#{index}", "text" => "Visible step #{index}."}
      end

    items =
      [
        %{
          "type" => "userMessage",
          "id" => "private-context",
          "content" => [%{"type" => "text", "text" => "Private model context must not appear"}]
        },
        %{
          "type" => "userMessage",
          "id" => "client:steer-1",
          "content" => [%{"type" => "text", "text" => "Focus on HMAC webhook verification"}]
        },
        %{
          "type" => "dynamicToolCall",
          "id" => "skill-call-1",
          "tool" => "skill_view",
          "status" => "completed",
          "arguments" => ~s({"name":"pod-content"}),
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" =>
                "<skill name=\"pod-content\" location=\"/drive/Skills/pod-content/SKILL.md\">\nConfidential skill system prompt\n</skill>"
            }
          ]
        },
        %{
          "type" => "dynamicToolCall",
          "id" => "write-skill-fail",
          "tool" => "write_file",
          "status" => "failed",
          "success" => false,
          "arguments" => ~s({"path":"/drive/Skills/pod-content/SKILL.md","content":"# nope"}),
          "contentItems" => "Permission denied writing SKILL.md"
        },
        %{
          "type" => "commandExecution",
          "id" => "compound-skill-cmd",
          "command" => "/bin/zsh -lc 'cat /drive/Skills/pod-content/SKILL.md && exit 2'",
          "status" => "completed",
          "exitCode" => 2,
          "aggregatedOutput" => "Command failed after reading SKILL.md"
        }
      ] ++ visible_items

    assert {:ok, _turn} =
             Repo.transact_top_level(fn ->
               Turns.upsert_from_worker_in_tx(job, %{
                 "attempt" => 1,
                 "runtime_thread_id" => "room-log",
                 "runtime_turn_id" => "all-steps",
                 "kind" => "agent",
                 "status" => "completed",
                 "revision" => 0,
                 "started_at" => DateTime.to_iso8601(now),
                 "completed_at" => DateTime.to_iso8601(now),
                 "trajectory" => %{"format" => "ankole_chatml", "version" => 1},
                 "turn_items" =>
                   Enum.with_index(items, fn item, index ->
                     %{"position" => index, "item_key" => item["id"], "item" => item}
                   end)
               })
             end)

    path =
      "/api/v2/pod/conversations/#{ctx.room.conversation.id}/executions/background_agent_job/#{job.id}"

    first = api_response(api_get(ctx.conn, path), 200)
    assert is_nil(first["outcomeText"])
    assert first["task"] == "Read the report."
    assert first["stoppable"] == true
    assert first["canMessage"] == true
    assert is_binary(first["nextCursor"])

    pages = collect_pages(ctx.conn, path, first)
    assert length(pages) > 1

    projected =
      pages
      |> Enum.reverse()
      |> Enum.flat_map(& &1["items"])

    encoded = Ankole.JSON.encode!(projected)
    refute encoded =~ "Private model context must not appear"
    refute encoded =~ "Confidential skill system prompt"
    refute encoded =~ "<skill"

    assert Enum.any?(projected, fn item ->
             item["kind"] == "steer_message" and
               item["text"] == "Focus on HMAC webhook verification"
           end)

    skill_item = Enum.find(projected, &(&1["id"] == "skill-call-1"))
    assert skill_item["toolKind"] == "skill"
    assert skill_item["skillName"] == "pod-content"
    assert is_nil(skill_item["input"])
    assert is_nil(skill_item["output"])

    write_fail_item = Enum.find(projected, &(&1["id"] == "write-skill-fail"))
    assert write_fail_item["toolKind"] == "tool"
    assert write_fail_item["tool"] == "write_file"
    assert write_fail_item["status"] == "failed"
    assert write_fail_item["output"] == "Permission denied writing SKILL.md"

    compound_cmd_item = Enum.find(projected, &(&1["id"] == "compound-skill-cmd"))
    assert compound_cmd_item["toolKind"] == "command"
    assert compound_cmd_item["status"] == "failed"
    assert compound_cmd_item["command"]["exitCode"] == 2
    assert compound_cmd_item["command"]["output"] == "Command failed after reading SKILL.md"

    for index <- 1..45 do
      assert Enum.any?(projected, fn item ->
               item["kind"] == "message" and item["text"] == "Visible step #{index}."
             end)
    end

    other = create_room!(ctx.uid, ctx.agent.uid)

    other_path =
      "/api/v2/pod/conversations/#{other.conversation.id}/executions/background_agent_job/#{job.id}"

    assert api_error(api_get(ctx.conn, other_path), 404)["code"] == "execution_not_found"

    assert api_error(api_get(ctx.conn, path, %{cursor: "invalid"}), 422)["code"] ==
             "invalid_execution_cursor"
  end

  test "Workflow logs continue beyond the first hundred calls through the room API", ctx do
    assert {:ok, _} =
             Ankole.AppConfigure.put_tenant_by_key("workflow.max_agent_calls_per_run", 128)

    assert {:ok, %{run: run}} =
             Workflow.create_with_dispatch(%{
               "source_signal_id" => ctx.source.id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => ctx.source.session_id,
               "source_tool_call_id" => "room-log-workflow",
               "reply_route" => %{"conversation_id" => ctx.room.conversation.id},
               "title" => "Review every child",
               "script" => "return null;",
               "concurrency" => 1,
               "max_agent_calls" => 128
             })

    # The room API reads queued calls; passive task Drivers keep them from starting.
    Ankole.SessionsCase.stub_workflow_drivers(run)

    pending =
      for index <- 0..104,
          do: %{
            namespace: nil,
            name: "agent",
            arguments: %{"prompt" => "Review #{index}", "label" => "Child #{index}"}
          }

    assert {:ok, %{new_calls: calls}} = Workflow.Replay.commit_replay_pending(run.id, pending, 0)
    assert length(calls) == 105
    path = "/api/v2/pod/conversations/#{ctx.room.conversation.id}/executions/workflow/#{run.id}"
    first = api_response(api_get(ctx.conn, path), 200)
    assert first["workflowCounts"]["total"] == 105
    assert first["workflowCounts"]["queued"] == 105

    pages = collect_pages(ctx.conn, path, first)
    assert length(pages) == 3

    items = Enum.flat_map(pages, & &1["items"])
    assert length(items) == 105

    for index <- 0..104 do
      assert Enum.any?(items, fn item ->
               item["kind"] == "workflow_call" and item["title"] == "Child #{index}" and
                 item["status"] == "queued"
             end)
    end
  end

  test "the room API stops live executions and steers or respawns background jobs in the same workspace",
       ctx do
    assert {:ok, %{job: job}} =
             Ankole.SessionsCase.create_job_with_stub_driver(%{
               "source_signal_id" => ctx.source.id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => ctx.source.session_id,
               "source_tool_call_id" => "interactive-job",
               "title" => "Build waitlist app",
               "task" => "Create the waitlist Base and webhook job.",
               "created_by" => %{"type" => "human", "uid" => ctx.uid},
               "reply_route" => %{"conversation_id" => ctx.room.conversation.id}
             })

    claim_and_start_job!(job, ctx)

    msg_path =
      "/api/v2/pod/conversations/#{ctx.room.conversation.id}/executions/background_agent_job/#{job.id}/messages"

    steered =
      api_response(
        api_post(ctx.conn, msg_path, %{
          requestID: Ecto.UUID.generate(),
          text: "Deduplicate by lowercase email."
        }),
        200
      )

    assert steered == %{
             "runID" => to_string(job.id),
             "status" => "running",
             "respawned" => false
           }

    stop_path =
      "/api/v2/pod/conversations/#{ctx.room.conversation.id}/executions/background_agent_job/#{job.id}/stop"

    stopped = api_response(api_post(ctx.conn, stop_path, %{}), 200)
    assert stopped["runID"] == to_string(job.id)
    assert stopped["status"] == "stopped"

    respawned =
      api_response(
        api_post(ctx.conn, msg_path, %{
          requestID: Ecto.UUID.generate(),
          text: "Continue and add webhook signature verification."
        }),
        200
      )

    assert respawned["respawned"] == true
    refute respawned["runID"] == to_string(job.id)

    predecessor_detail =
      api_response(
        api_get(
          ctx.conn,
          "/api/v2/pod/conversations/#{ctx.room.conversation.id}/executions/background_agent_job/#{job.id}"
        ),
        200
      )

    assert predecessor_detail["successorJobID"] == respawned["runID"]
    assert predecessor_detail["canMessage"] == false

    successor_detail =
      api_response(
        api_get(
          ctx.conn,
          "/api/v2/pod/conversations/#{ctx.room.conversation.id}/executions/background_agent_job/#{respawned["runID"]}"
        ),
        200
      )

    assert successor_detail["continuedFromJobID"] == to_string(job.id)

    assert {:ok, %{run: workflow}} =
             Workflow.create_with_dispatch(%{
               "source_signal_id" => ctx.source.id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => ctx.source.session_id,
               "source_tool_call_id" => "interactive-workflow",
               "reply_route" => %{"conversation_id" => ctx.room.conversation.id},
               "title" => "Stoppable workflow",
               "script" => "return null;",
               "concurrency" => 1,
               "max_agent_calls" => 4
             })

    Ankole.SessionsCase.stub_workflow_drivers(workflow)

    stopped_wf =
      api_response(
        api_post(
          ctx.conn,
          "/api/v2/pod/conversations/#{ctx.room.conversation.id}/executions/workflow/#{workflow.id}/stop",
          %{}
        ),
        200
      )

    assert stopped_wf["runID"] == to_string(workflow.id)
    assert stopped_wf["status"] == "cancelled"
  end

  test "older message windows keep all retained execution cards beyond twenty per kind", ctx do
    jobs =
      for index <- 1..21 do
        assert {:ok, %{job: job}} =
                 Ankole.SessionsCase.create_job_with_stub_driver(%{
                   "source_signal_id" => ctx.source.id,
                   "agent_uid" => ctx.agent.uid,
                   "owner_session_id" => ctx.source.session_id,
                   "source_tool_call_id" => "retained-job-#{index}",
                   "title" => "Retained job #{index}",
                   "task" => "Read the report.",
                   "reply_route" => %{"conversation_id" => ctx.room.conversation.id}
                 })

        to_string(job.id)
      end

    workflows =
      for index <- 1..21 do
        assert {:ok, %{run: run}} =
                 Workflow.create_with_dispatch(%{
                   "source_signal_id" => ctx.source.id,
                   "agent_uid" => ctx.agent.uid,
                   "owner_session_id" => ctx.source.session_id,
                   "source_tool_call_id" => "retained-workflow-#{index}",
                   "title" => "Retained workflow #{index}",
                   "script" => "return null;",
                   "concurrency" => 1,
                   "max_agent_calls" => 1,
                   "reply_route" => %{"conversation_id" => ctx.room.conversation.id}
                 })

        to_string(run.id)
      end

    path = "/api/v2/pod/conversations/#{ctx.room.conversation.id}"
    newest = api_response(api_get(ctx.conn, path), 200)
    older = api_response(api_get(ctx.conn, path, %{beforeSeq: 1}), 200)

    for detail <- [newest, older] do
      assert length(detail["linkedRuns"]) == 42
      assert Enum.all?(detail["linkedRuns"], &(&1["sourceMessageID"] == ctx.source.message_id))

      assert Enum.filter(detail["linkedRuns"], &(&1["kind"] == "background_agent_job"))
             |> Enum.map(& &1["id"])
             |> MapSet.new() == MapSet.new(jobs)

      assert Enum.filter(detail["linkedRuns"], &(&1["kind"] == "workflow"))
             |> Enum.map(& &1["id"])
             |> MapSet.new() == MapSet.new(workflows)

      assert Enum.all?(detail["linkedRuns"], &is_nil(&1["text"]))
    end
  end

  defp claim_and_start_job!(job, ctx) do
    key = %{agent_uid: ctx.agent.uid, session_id: ctx.source.session_id}
    {:ok, run} = Ankole.Sessions.Admission.admit(key, ctx.source)

    {:ok, {:preparing, prepared}} = Ankole.Sessions.Model.prepare(run)

    assert {:ok, _} =
             Repo.transact_top_level(fn ->
               BackgroundAgentJobs.Lifecycle.claim_attempt_in_tx(
                 job.id,
                 ctx.agent.uid,
                 1,
                 prepared.spec,
                 10
               )
             end)

    assert {:ok, _} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, ctx.agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "room-log"
             })
  end

  defp collect_pages(conn, path, %{"nextCursor" => cursor} = page) when is_binary(cursor) do
    next = api_response(api_get(conn, path, %{cursor: cursor}), 200)
    [page | collect_pages(conn, path, next)]
  end

  defp collect_pages(_conn, _path, page), do: [page]

  defp create_room!(uid, agent_uid) do
    assert {:ok, room} =
             Ankole.ConversationsFixtures.create(uid, %{
               room_mode: :group,
               conversation_id: Ecto.UUID.generate(),
               message_id: Ecto.UUID.generate(),
               agent_uid: agent_uid,
               text: "Read execution evidence"
             })

    room
  end
end
