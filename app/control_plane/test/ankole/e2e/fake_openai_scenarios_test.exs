defmodule Ankole.E2E.FakeOpenAIScenariosTest do
  use ExUnit.Case, async: true

  alias Ankole.E2E.FakeOpenAIScenarios

  describe "background lifecycle tool routing" do
    test "extracts backgroundId from structured tool output JSON" do
      request = %{
        "messages" => [
          %{
            "role" => "tool",
            "content" =>
              ~s({"result":{"details":{"backgroundId":"bg_lifecycle_123","status":"running"}}})
          }
        ]
      }

      assert {:tool_call,
              %{
                name: "command",
                arguments: %{
                  "action" => "status",
                  "backgroundId" => "bg_lifecycle_123"
                }
              }} = FakeOpenAIScenarios.action_for(:background_lifecycle_tool, 2, request)
    end

    test "fails closed when a lifecycle follow-up is missing backgroundId" do
      assert {:completion, "CHAOS_BACKGROUND_LIFECYCLE_MISSING_BACKGROUND_ID", []} =
               FakeOpenAIScenarios.action_for(:background_lifecycle_tool, 2, %{
                 "messages" => [%{"role" => "tool", "content" => ~s({"ok":true})}]
               })
    end
  end

  describe "schedule scenario classification" do
    test "classifies checkback tool follow-up before wakeup prose in older context" do
      request = %{
        "messages" => [
          %{"role" => "system", "content" => "Tool docs mention Scheduled checkback wakeup."},
          %{
            "role" => "user",
            "content" =>
              "@_user_1 Run CHAOS_CHECKBACK_TOOL. Use the schedule tool, then reply exactly CHAOS_CHECKBACK_OK."
          },
          %{
            "role" => "assistant",
            "tool_calls" => [
              %{
                "function" => %{
                  "arguments" => ~s({"check":"Confirm CHAOS_CHECKBACK_WAKE_OK"})
                }
              }
            ]
          },
          %{"role" => "tool", "content" => ~s({"ok":true})}
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :checkback_tool
    end

    test "classifies stateful checkback continuations without the original user marker" do
      request = %{
        "messages" => [
          %{
            "role" => "tool",
            "tool_call_id" => "call_lark_chaos_checkback",
            "content" =>
              ~s({"ok":true,"idempotency_key":"lark-chaos-checkback-1","wake_payload":{"check":"Confirm CHAOS_CHECKBACK_WAKE_OK"}})
          }
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :checkback_tool
    end

    test "classifies scheduled checkback wakeups by the latest user turn" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" =>
              "@_user_1 Run CHAOS_CHECKBACK_TOOL. Use the schedule tool, then reply exactly CHAOS_CHECKBACK_OK."
          },
          %{"role" => "assistant", "content" => "CHAOS_CHECKBACK_OK"},
          %{
            "role" => "user",
            "content" => "Scheduled checkback wakeup. Confirm CHAOS_CHECKBACK_WAKE_OK."
          }
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :checkback_wakeup
    end

    test "classifies cron tool follow-up before wakeup prose in older context" do
      request = %{
        "messages" => [
          %{"role" => "system", "content" => "Tool docs mention Recurring schedule fire."},
          %{
            "role" => "user",
            "content" =>
              "@_user_1 Run CHAOS_CRON_TOOL. Use the cron tool, then reply exactly CHAOS_CRON_OK."
          },
          %{
            "role" => "assistant",
            "tool_calls" => [
              %{
                "function" => %{
                  "arguments" => ~s({"payload":{"task":"CHAOS_CRON_WAKE_OK"}})
                }
              }
            ]
          },
          %{"role" => "tool", "content" => ~s({"ok":true})}
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :cron_tool
    end

    test "prefers the latest user chaos marker over older request text markers" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" =>
              "@_user_1 Run CHAOS_CHECKBACK_TOOL. Use the schedule tool, then reply exactly CHAOS_CHECKBACK_OK."
          },
          %{
            "role" => "assistant",
            "content" => "CHAOS_CHECKBACK_OK"
          },
          %{
            "role" => "user",
            "content" =>
              "@_user_1 Run CHAOS_CRON_TOOL. Use the cron tool, then reply exactly CHAOS_CRON_OK."
          }
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :cron_tool
    end

    test "classifies stateful cron continuations without the original user marker" do
      request = %{
        "messages" => [
          %{
            "role" => "tool",
            "tool_call_id" => "call_lark_chaos_cron",
            "content" => ~s({"ok":true,"idempotency_key":"lark-chaos-cron-1"})
          }
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :cron_tool
    end

    test "classifies cron wakeups by the latest user turn" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" =>
              "@_user_1 Run CHAOS_CRON_TOOL. Use the cron tool, then reply exactly CHAOS_CRON_OK."
          },
          %{"role" => "assistant", "content" => "CHAOS_CRON_OK"},
          %{"role" => "user", "content" => "Recurring schedule fire. Run CHAOS_CRON_WAKE_OK."}
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :cron_wakeup
    end
  end

  describe "reply attachment scenario classification" do
    test "classifies stateful command follow-up before reply_attachment tool call" do
      request = %{
        "messages" => [
          %{
            "role" => "tool",
            "tool_call_id" => "call_lark_chaos_reply_attachment_command",
            "content" => "exit_code=0\ncreated /workspace/user-files/reports/chaos-report.txt"
          }
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :reply_attachment
    end

    test "classifies stateful reply_attachment tool result follow-up" do
      request = %{
        "messages" => [
          %{
            "role" => "tool",
            "tool_call_id" => "call_lark_chaos_reply_attachment",
            "content" =>
              ~s({"attachments":[{"name":"chaos-report.txt","user_files_relative_path":"reports/chaos-report.txt"}]})
          }
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :reply_attachment
    end
  end

  describe "background lifecycle scenario actions" do
    test "extracts wrapped background ids from command tool output" do
      request = %{
        "messages" => [
          %{
            "role" => "tool",
            "tool_call_id" => "call_lark_chaos_background_lifecycle_start",
            "content" =>
              untrusted_tool_output("""
              background_id=bg_e2e_123
              status=running
              """)
          }
        ]
      }

      assert {:tool_call,
              %{
                name: "command",
                arguments: %{"action" => "status", "backgroundId" => "bg_e2e_123"}
              }} = FakeOpenAIScenarios.action_for(:background_lifecycle_tool, 2, request)
    end
  end

  describe "installed skill scenario classification" do
    test "routes installed skill scenarios through skill_view tool calls" do
      assert {:tool_call,
              %{
                name: "skill_view",
                arguments: %{"name" => "e2e-installed"}
              }} = FakeOpenAIScenarios.action_for(:installed_skill_tool, 1, %{})

      assert {:tool_call,
              %{
                name: "skill_view",
                arguments: %{"name" => "e2e-installed"}
              }} = FakeOpenAIScenarios.action_for(:installed_skill_deleted_tool, 1, %{})
    end

    test "keeps installed skill classification after the skill_view tool result" do
      request = %{
        "messages" => [
          %{
            "role" => "user",
            "content" =>
              "@_user_1 Run CHAOS_INSTALLED_SKILL. Use skill_view for e2e-installed once, then reply exactly CHAOS_INSTALLED_SKILL_OK."
          },
          %{
            "role" => "tool",
            "tool_call_id" => "call_lark_chaos_installed_skill_view",
            "content" => ~s({"content":"E2E_INSTALLED_SKILL_BODY"})
          }
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :installed_skill_tool
    end
  end

  defp untrusted_tool_output(text) do
    nonce = "test-nonce"

    """
    <ankole_untrusted_tool_output nonce="#{nonce}">
    #{String.trim(text)}
    </ankole_untrusted_tool_output nonce="#{nonce}">
    """
    |> String.trim()
  end
end
