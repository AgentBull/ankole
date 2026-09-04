defmodule Ankole.BackgroundAgentJobs.TurnItemProjectionTest do
  use ExUnit.Case, async: true

  alias Ankole.BackgroundAgentJobs.TurnItemProjection

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

    test "projects a namespaced tool without flattening its identity" do
      {messages, _truncated} =
        TurnItemProjection.project(%{
          "type" => "dynamicToolCall",
          "id" => "collab-1",
          "namespace" => "collaboration",
          "tool" => "spawn_agent",
          "arguments" => %{"message" => "audit"},
          "status" => "completed",
          "contentItems" => "spawned",
          "success" => true,
          "durationMs" => 1
        })

      assert [call, result] = messages

      assert [%{"function" => function}] = call["tool_calls"]
      assert function["namespace"] == "collaboration"
      assert function["name"] == "spawn_agent"
      assert result["namespace"] == "collaboration"
      assert result["name"] == "spawn_agent"
    end

    test "reconstructs a legacy MCP identity with the Codex name sanitizer" do
      {messages, _truncated} =
        TurnItemProjection.project(%{
          "type" => "mcpToolCall",
          "id" => "mcp-legacy",
          "server" => "my-server",
          "tool" => "get-price",
          "arguments" => %{},
          "result" => "42",
          "status" => "completed"
        })

      assert [call, result] = messages
      assert [%{"function" => function}] = call["tool_calls"]
      assert function["namespace"] == "mcp__my_server"
      assert function["name"] == "get_price"
      assert result["namespace"] == "mcp__my_server"
      assert result["name"] == "get_price"
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
end
