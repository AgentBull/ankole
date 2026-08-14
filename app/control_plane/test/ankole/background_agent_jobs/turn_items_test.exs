defmodule Ankole.BackgroundAgentJobs.TurnItemsTest do
  use Ankole.AIGatewayCase

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Schemas.Turn
  alias Ankole.BackgroundAgentJobs.Schemas.TurnItem
  alias Ankole.BackgroundAgentJobs.TurnItemProjection
  alias Ankole.Repo

  describe "TurnItemProjection.project/1" do
    test "projects a user item into one client-keyed chatml message" do
      {messages, truncated} =
        TurnItemProjection.project(%{
          "type" => "userMessage",
          "id" => "user-1",
          "clientId" => "event-9",
          "content" => [
            %{"type" => "text", "text" => "第一段"},
            %{"type" => "text", "text" => "第二段"}
          ]
        })

      assert messages == [%{"id" => "event-9", "role" => "user", "content" => "第一段第二段"}]
      refute truncated
    end

    test "projects a command execution into a call and result pair" do
      {messages, truncated} =
        TurnItemProjection.project(%{
          "type" => "commandExecution",
          "id" => "cmd-1",
          "command" => "printf hi",
          "cwd" => "/workdir",
          "status" => "completed",
          "aggregatedOutput" => "hi",
          "exitCode" => 0,
          "durationMs" => 4
        })

      assert [call, result] = messages
      refute truncated

      assert call["role"] == "assistant"

      assert call["tool_calls"] == [
               %{
                 "id" => "cmd-1",
                 "type" => "function",
                 "function" => %{
                   "name" => "shell",
                   "arguments" => ~s({"command":"printf hi","cwd":"/workdir"})
                 }
               }
             ]

      assert result == %{
               "id" => "cmd-1:result",
               "role" => "tool",
               "tool_call_id" => "cmd-1",
               "name" => "shell",
               "content" => "hi",
               "metadata" => %{"status" => "completed", "exit_code" => 0, "duration_ms" => 4}
             }
    end

    test "projects a pending user-input request as one unmatched tool call" do
      {messages, _truncated} =
        TurnItemProjection.project(%{
          "type" => "dynamicToolCall",
          "id" => "ask-1",
          "namespace" => nil,
          "tool" => "request_user_input",
          "arguments" => %{"questions" => []},
          "status" => "inProgress",
          "contentItems" => nil
        })

      assert [call] = messages
      assert call["metadata"] == %{"status" => "pending_user_input"}
      assert [%{"function" => %{"name" => "request_user_input"}}] = call["tool_calls"]
    end

    test "keeps replay-only items out of the projection" do
      assert {[], false} =
               TurnItemProjection.project(%{
                 "type" => "reasoning",
                 "id" => "r-1",
                 "summary" => []
               })
    end

    test "bounds oversized tool arguments and reports the truncation" do
      {messages, truncated} =
        TurnItemProjection.project(%{
          "type" => "dynamicToolCall",
          "id" => "big-1",
          "namespace" => nil,
          "tool" => "bulk_tool",
          "arguments" => %{"payload" => String.duplicate("大", 80_000)},
          "status" => "completed",
          "contentItems" => "",
          "success" => true,
          "durationMs" => 1
        })

      assert truncated
      [call, _result] = messages
      [%{"function" => %{"arguments" => arguments}}] = call["tool_calls"]
      assert byte_size(arguments) < 70_000
      assert %{"truncated" => true, "preview" => _preview} = Ankole.JSON.decode!(arguments)
    end
  end

  describe "replay_items_page/2" do
    test "walks the workspace lineage lead threads chronologically and skips child threads" do
      %{principal: agent} = background_agent_fixture()
      source = create_job!(agent.uid, "replay-source")

      source =
        source
        |> Ecto.Changeset.change(status: "succeeded", runtime_thread_id: "thread-lead-2")
        |> Repo.update!()

      base = DateTime.utc_now(:microsecond)

      lead_one = insert_turn!(source, 1, "thread-lead-1", "turn-lead-1", DateTime.add(base, -50))
      insert_items!(lead_one, [{0, "u-1", user_item("源任务")}, {1, "a-1", assistant_item("第一步完成")}])

      child = insert_turn!(source, 1, "thread-child", "turn-child", DateTime.add(base, -40))
      insert_items!(child, [{0, "c-1", assistant_item("child noise")}])

      lead_two = insert_turn!(source, 2, "thread-lead-2", "turn-lead-2", DateTime.add(base, -30))
      insert_items!(lead_two, [{0, "a-2", assistant_item("重建后继续")}])

      respawn = create_job!(agent.uid, "replay-respawn")

      respawn =
        respawn
        |> Ecto.Changeset.change(
          continued_from_job_id: source.id,
          workspace_owner_job_id: source.workspace_owner_job_id,
          runtime_thread_id: "thread-lead-3"
        )
        |> Repo.update!()

      respawn_turn =
        insert_turn!(respawn, 1, "thread-lead-3", "turn-lead-3", DateTime.add(base, -20))

      insert_items!(respawn_turn, [{0, "a-3", assistant_item("续接补充")}])

      assert {:ok, %{items: items, next_cursor: nil}} =
               BackgroundAgentJobs.replay_items_page(respawn, nil)

      assert Enum.map(items, & &1.item_key) == ["u-1", "a-1", "a-2", "a-3"]

      assert Enum.map(items, & &1.runtime_thread_id) ==
               ["thread-lead-1", "thread-lead-1", "thread-lead-2", "thread-lead-3"]

      assert %{"type" => "userMessage"} = hd(items).item
    end

    test "pages the stream with an opaque cursor" do
      %{principal: agent} = background_agent_fixture()
      job = create_job!(agent.uid, "replay-paging")

      job =
        job
        |> Ecto.Changeset.change(status: "succeeded", runtime_thread_id: "thread-page")
        |> Repo.update!()

      turn = insert_turn!(job, 1, "thread-page", "turn-page", DateTime.utc_now(:microsecond))

      now = DateTime.utc_now(:microsecond)

      Repo.insert_all(
        TurnItem,
        Enum.map(0..204, fn position ->
          %{
            turn_id: turn.id,
            position: position,
            revision: 0,
            item_key: "item-#{position}",
            item: assistant_item("消息 #{position}"),
            inserted_at: now
          }
        end)
      )

      assert {:ok, %{items: first_page, next_cursor: cursor}} =
               BackgroundAgentJobs.replay_items_page(job, nil)

      assert length(first_page) == 200
      assert is_binary(cursor)

      assert {:ok, %{items: second_page, next_cursor: nil}} =
               BackgroundAgentJobs.replay_items_page(job, cursor)

      assert Enum.map(second_page, & &1.position) == Enum.to_list(200..204)

      assert {:error, :invalid_background_agent_job_replay_cursor} =
               BackgroundAgentJobs.replay_items_page(job, "not-a-cursor")
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

  defp insert_turn!(%Job{} = job, attempt, thread_id, turn_id, started_at) do
    %Turn{}
    |> Turn.changeset(%{
      job_id: job.id,
      attempt: attempt,
      runtime_thread_id: thread_id,
      runtime_turn_id: turn_id,
      kind: "agent",
      status: "completed",
      revision: 0,
      trajectory: %{"format" => "ankole_chatml", "version" => 1},
      progress: %{
        "completed_items" => 0,
        "tool_calls" => 0,
        "tools_used" => [],
        "files_changed" => []
      },
      usage: nil,
      error: %{},
      started_at: started_at,
      completed_at: started_at
    })
    |> Repo.insert!()
  end

  defp insert_items!(%Turn{} = turn, entries) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(
      TurnItem,
      Enum.map(entries, fn {position, item_key, item} ->
        %{
          turn_id: turn.id,
          position: position,
          revision: turn.revision,
          item_key: item_key,
          item: item,
          inserted_at: now
        }
      end)
    )
  end

  defp user_item(text) do
    %{
      "type" => "userMessage",
      "id" => "user-#{text}",
      "content" => [%{"type" => "text", "text" => text}]
    }
  end

  defp assistant_item(text) do
    %{"type" => "agentMessage", "id" => "assistant-#{text}", "text" => text}
  end
end
