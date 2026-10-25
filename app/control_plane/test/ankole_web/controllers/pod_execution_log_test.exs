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

  test "the room API walks every Job log page and excludes model context", ctx do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => ctx.source.id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => ctx.source.session_id,
               "source_tool_call_id" => "room-log-job",
               "title" => "Read all recorded steps",
               "task" => "Read the report.",
               "reply_route" => %{"conversation_id" => ctx.room.conversation.id}
             })

    key = %{agent_uid: ctx.agent.uid, session_id: ctx.source.session_id}
    assert {:ok, run} = Ankole.Sessions.Admission.admit(key, ctx.source)
    assert {:ok, {:preparing, run}} = Ankole.Sessions.Model.prepare(run)

    assert {:ok, _} =
             Repo.transact(fn ->
               BackgroundAgentJobs.Lifecycle.claim_attempt_in_tx(
                 job.id,
                 ctx.agent.uid,
                 1,
                 run.spec,
                 10
               )
             end)

    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, ctx.agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "room-log"
             })

    now = DateTime.utc_now(:microsecond)

    visible_items =
      for index <- 1..45 do
        %{"type" => "agentMessage", "id" => "step-#{index}", "text" => "Visible step #{index}."}
      end

    items = [
      %{
        "type" => "userMessage",
        "id" => "private-context",
        "content" => [%{"type" => "text", "text" => "Private model context must not appear"}]
      }
      | visible_items
    ]

    assert {:ok, _turn} =
             Repo.transact(fn ->
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
    assert is_binary(first["nextCursor"])
    pages = collect_pages(ctx.conn, path, first)
    text = Enum.map_join(pages, "\n", & &1["text"])
    assert length(pages) > 1
    assert text =~ "UTC · Agent · Completed"

    for index <- 1..45, do: assert(text =~ "Visible step #{index}.")
    refute text =~ "Private model context must not appear"

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
    pages = collect_pages(ctx.conn, path, first)
    assert length(pages) == 3
    text = Enum.map_join(pages, "\n", & &1["text"])
    for index <- 0..104, do: assert(text =~ "Child #{index} · Queued")
  end

  test "older message windows keep all retained execution cards beyond twenty per kind", ctx do
    jobs =
      for index <- 1..21 do
        assert {:ok, %{job: job}} =
                 BackgroundAgentJobs.create_with_dispatch(%{
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

  defp collect_pages(conn, path, %{"nextCursor" => cursor} = page) when is_binary(cursor) do
    next = api_response(api_get(conn, path, %{cursor: cursor}), 200)
    [page | collect_pages(conn, path, next)]
  end

  defp collect_pages(_conn, _path, page), do: [page]

  defp create_room!(uid, agent_uid) do
    assert {:ok, room} =
             Ankole.ConversationsFixtures.create(uid, %{
               conversation_id: Ecto.UUID.generate(),
               message_id: Ecto.UUID.generate(),
               agent_uid: agent_uid,
               text: "Read execution evidence"
             })

    room
  end
end
