defmodule Ankole.BackgroundAgentJobs.ExecutionLogTest do
  use Ankole.AIGatewayCase

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.ExecutionLog
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.Repo

  @opaque_prefix "ankole-aigateway-opaque-v1:"

  test "pages lineage execution logs newest-page-first while preserving intra-page chronology, 16 KiB outputs, and unrevealed opaque values" do
    %{principal: agent} = background_agent_fixture()
    base = DateTime.add(DateTime.utc_now(:microsecond), -60, :second)

    root =
      create_job!(agent.uid, "lineage-root", %{
        "title" => "Build Q3 revenue workspace",
        "task" => "Create the Q3 Pod Page and Base table with verified totals."
      })
      |> Ecto.Changeset.change(
        status: :running,
        attempts: 1,
        runtime_thread_id: "thread-root"
      )
      |> Repo.update!()

    mid_id_output =
      String.duplicate("A", 5_500) <>
        "\ncreated_page_id=pg_mid_7788\nbase_id=bs_mid_9900\n" <>
        String.duplicate("Z", 5_500)

    assert byte_size(mid_id_output) > 11_000

    opaque_secret = "Bearer secret-upstream-value"
    encoded_opaque = @opaque_prefix <> Base.url_encode64(opaque_secret, padding: false)

    _root_turn_1 =
      record_turn!(root, %{
        turn_id: "root-turn-1",
        started_at: base,
        header: %{
          "format" => "ankole_chatml",
          "version" => 1,
          "metadata" => %{"redacted" => true}
        },
        items: [
          %{
            "type" => "userMessage",
            "id" => "turn-input-root",
            "content" => [
              %{
                "type" => "text",
                "text" => "Create the Q3 Pod Page and Base table with verified totals."
              }
            ]
          },
          %{"type" => "reasoning", "id" => "r-1", "summary" => ["thinking"]},
          %{"type" => "hookPrompt", "id" => "h-1", "text" => "internal hook"},
          %{
            "type" => "commandExecution",
            "id" => "cmd-1",
            "command" => "bun run provision-q3.ts",
            "cwd" => "/workspace",
            "status" => "completed",
            "exitCode" => 0,
            "aggregatedOutput" => mid_id_output
          },
          %{
            "type" => "dynamicToolCall",
            "id" => "dyn-opaque",
            "tool" => "connector.fetch",
            "status" => "completed",
            "success" => true,
            "arguments" => %{"endpoint" => "/v1/deals"},
            "contentItems" => [%{"type" => "inputText", "text" => encoded_opaque}]
          }
        ]
      })

    # Non-lead subagent turn in the same attempt must not pollute the root thread log.
    _subagent_turn =
      record_turn!(root, %{
        turn_id: "root-subagent-turn",
        thread: "thread-subagent",
        started_at: DateTime.add(base, 2, :second),
        items: [
          %{
            "type" => "agentMessage",
            "id" => "subagent-noise",
            "text" => "subagent internal chatter"
          }
        ]
      })

    _root_turn_2 =
      record_turn!(root, %{
        turn_id: "root-turn-2",
        started_at: DateTime.add(base, 5, :second),
        items: [
          %{
            "type" => "userMessage",
            "id" => "client:steer-sig-1",
            "clientId" => "steer-sig-1",
            "content" => [
              %{
                "type" => "text",
                "text" => "Exclude sandbox test accounts from the Q3 totals."
              }
            ]
          },
          %{
            "type" => "agentMessage",
            "id" => "root-msg-2",
            "text" => "Applying the sandbox account exclusion filter."
          }
        ]
      })

    root =
      root
      |> Ecto.Changeset.change(
        status: :failed,
        completed_at: DateTime.add(base, 15, :second),
        error: %{"code" => "turn_interrupted", "summary" => "Worker restarted mid-verification."}
      )
      |> Repo.update!()

    source_signal_id = Ankole.WorkFixtures.service_source(agent.uid).id

    assert {:ok, %{job: successor}} =
             Repo.transact(fn ->
               BackgroundAgentJobs.Dispatch.respawn_with_dispatch_in_tx(root.id, %{
                 "source_signal_id" => source_signal_id,
                 "agent_uid" => agent.uid,
                 "owner_session_id" => root.owner_session_id,
                 "source_tool_call_id" => "respawn-lineage-1",
                 "message" => "Finish verifying the Q3 Base rows and write the summary.",
                 "reply_route" => root.reply_route
               })
             end)

    successor =
      successor
      |> Ecto.Changeset.change(
        status: :running,
        attempts: 1,
        runtime_thread_id: "thread-root"
      )
      |> Repo.update!()

    pad_items =
      for idx <- 1..8 do
        %{
          "type" => "commandExecution",
          "id" => "succ-cmd-#{idx}",
          "command" => "echo step-#{idx}",
          "cwd" => "/workspace",
          "status" => "completed",
          "exitCode" => 0,
          "aggregatedOutput" => "step-#{idx}:" <> String.duplicate("B", 10_000)
        }
      end

    _succ_turn =
      record_turn!(successor, %{
        turn_id: "succ-turn-1",
        started_at: DateTime.add(base, 20, :second),
        items: pad_items
      })

    {pages_newest_first, lineage_payloads} = collect_all_pages!(successor)
    assert length(pages_newest_first) >= 2
    assert [head_lineage_bytes | older_lineage_bytes] = lineage_payloads
    assert Enum.all?(older_lineage_bytes, &(&1 == ""))

    lineage = Ankole.JSON.decode!(head_lineage_bytes)
    assert lineage["format"] == "ankole_job_task_lineage"
    assert lineage["workspace_owner_job_id"] == root.id
    assert lineage["current_job_id"] == successor.id

    assert [
             %{
               "job_id" => root_id,
               "status" => "failed",
               "task" => "Create the Q3 Pod Page and Base table with verified totals.",
               "error" => %{
                 "code" => "turn_interrupted",
                 "summary" => "Worker restarted mid-verification."
               }
             },
             %{
               "job_id" => succ_id,
               "continued_from_job_id" => root_id,
               "task" => "Finish verifying the Q3 Base rows and write the summary."
             }
           ] = lineage["jobs"]

    assert root_id == root.id
    assert succ_id == successor.id

    assert [
             %{
               "job_id" => ^root_id,
               "kind" => "user_message",
               "text" => "Exclude sandbox test accounts from the Q3 totals."
             }
           ] = lineage["user_messages"]

    # Reversing page order while preserving intra-page order reconstructs strict chronology.
    chronological =
      pages_newest_first
      |> Enum.reverse()
      |> List.flatten()

    refute Enum.any?(chronological, &(&1["type"] in ["reasoning", "hookPrompt"]))
    refute Enum.any?(chronological, &(&1["text"] == "subagent internal chatter"))

    turn_positions = Enum.map(chronological, &{&1["job_id"], &1["turn_id"], &1["position"]})

    assert turn_positions ==
             Enum.sort_by(turn_positions, fn {jid, tid, pos} ->
               {jid == successor.id, tid, pos}
             end)

    cmd_entry = Enum.find(chronological, &(&1["command"] == "bun run provision-q3.ts"))
    assert cmd_entry["redacted"] == true
    assert cmd_entry["output"] == mid_id_output
    assert cmd_entry["output"] =~ "created_page_id=pg_mid_7788"

    opaque_entry = Enum.find(chronological, &(&1["tool"] == "connector.fetch"))
    encoded_json = Ankole.JSON.encode!(opaque_entry)
    assert encoded_json =~ encoded_opaque
    refute encoded_json =~ opaque_secret
  end

  test "marks content_truncated when an oversized item exceeds the single-page byte budget and rejects empty cursors" do
    %{principal: agent} = background_agent_fixture()

    job =
      create_job!(agent.uid, "oversized-log")
      |> Ecto.Changeset.change(status: :running, attempts: 1, runtime_thread_id: "thread-over")
      |> Repo.update!()

    huge_changes =
      for idx <- 1..20 do
        %{"path" => "src/module_#{idx}.ts", "diff" => String.duplicate("D", 6_000)}
      end

    _turn =
      record_turn!(job, %{
        turn_id: "turn-oversized",
        items: [
          %{
            "type" => "fileChange",
            "id" => "fc-huge",
            "status" => "completed",
            "changes" => huge_changes
          }
        ]
      })

    assert {:ok, page} = ExecutionLog.page(job, "head")
    assert byte_size(page.jsonl) <= 65_536

    assert [decoded] =
             page.jsonl |> String.split("\n", trim: true) |> Enum.map(&Ankole.JSON.decode!/1)

    assert decoded["type"] == "fileChange"
    assert decoded["content_truncated"] == true

    assert {:error, :invalid_background_agent_job_trajectory_cursor} = ExecutionLog.page(job, "")

    assert {:error, :invalid_background_agent_job_trajectory_cursor} =
             ExecutionLog.page(job, "bad-cursor")
  end

  defp collect_all_pages!(job) do
    Stream.unfold("head", fn
      nil ->
        nil

      cursor ->
        assert {:ok, page} = ExecutionLog.page(job, cursor)

        items =
          page.jsonl
          |> String.split("\n", trim: true)
          |> Enum.map(&Ankole.JSON.decode!/1)

        {{items, page.task_lineage_json}, page.next_cursor}
    end)
    |> Enum.unzip()
  end

  defp create_job!(agent_uid, suffix, overrides \\ %{}) do
    source_signal_id = Ankole.WorkFixtures.service_source(agent_uid).id

    attrs =
      Map.merge(
        %{
          "source_signal_id" => source_signal_id,
          "agent_uid" => agent_uid,
          "owner_session_id" => "parent-session-#{suffix}",
          "source_tool_call_id" => "tool-job-#{suffix}",
          "title" => "Job #{suffix}",
          "task" => "Complete the #{suffix} job.",
          "reply_route" => %{
            "binding_name" => "lark",
            "conversation_id" =>
              Ankole.ExternalConversationsFixtures.external_conversation_id("chat-#{suffix}"),
            "provider_thread_id" => "thread-#{suffix}",
            "provider_message_id" => "message-#{suffix}"
          }
        },
        overrides
      )

    assert {:ok, %{job: job}} =
             Repo.transact(fn ->
               BackgroundAgentJobs.Dispatch.create_with_dispatch_in_tx(attrs)
             end)

    job
  end

  defp record_turn!(%Job{} = job, attrs) do
    started_at = Map.get(attrs, :started_at, DateTime.utc_now(:microsecond))

    worker_attrs = %{
      "attempt" => job.attempts,
      "runtime_thread_id" => Map.get(attrs, :thread, job.runtime_thread_id),
      "runtime_turn_id" => Map.fetch!(attrs, :turn_id),
      "kind" => Map.get(attrs, :kind, "agent"),
      "status" => "completed",
      "revision" => 0,
      "trajectory" => Map.get(attrs, :header, %{"format" => "ankole_chatml", "version" => 1}),
      "error" => %{},
      "started_at" => DateTime.to_iso8601(started_at),
      "completed_at" => DateTime.to_iso8601(started_at),
      "turn_items" =>
        attrs
        |> Map.fetch!(:items)
        |> Enum.with_index(fn item, position ->
          %{"position" => position, "item_key" => Map.fetch!(item, "id"), "item" => item}
        end)
    }

    assert {:ok, turn} =
             Repo.transact(fn -> Turns.upsert_from_worker_in_tx(job, worker_attrs) end)

    turn
  end
end
