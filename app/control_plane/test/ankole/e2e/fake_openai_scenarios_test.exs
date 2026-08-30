defmodule Ankole.E2E.FakeOpenAIScenariosTest do
  use ExUnit.Case, async: true

  alias Ankole.E2E.FakeOpenAIScenarios

  describe "compaction scenario classification" do
    test "returns a structurally valid summary for the dedicated summarizer prompt" do
      request = %{
        "messages" => [
          %{
            "role" => "system",
            "content" =>
              "You are a context summarization assistant. ONLY output the structured summary."
          },
          %{
            "role" => "user",
            "content" => "Use this EXACT format:\n\n## Active Task\n[task]"
          }
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :compaction_summary

      assert {:completion, "## Active Task\n(none)", []} =
               FakeOpenAIScenarios.action_for(:compaction_summary, 1, request)
    end
  end

  describe "ambient scenario classification" do
    test "uses the latest ambient marker when observed history contains an older ignore marker" do
      request = %{
        "response_format" => %{"type" => "json_schema"},
        "messages" => [
          %{
            "role" => "user",
            "content" =>
              "Earlier observation: CHAOS_AMBIENT_IGNORE\nLatest observation: CHAOS_AMBIENT_OK"
          }
        ]
      }

      assert FakeOpenAIScenarios.classify(request) == :ambient_decision

      assert {:completion, decision_json, []} =
               FakeOpenAIScenarios.action_for(:ambient_decision, 1, request)

      assert %{"action" => "FOREGROUND_REPLY", "authority" => "NONE"} =
               Ankole.JSON.decode!(decision_json)
    end

    test "keeps the latest ignore-only ambient observation silent" do
      request = %{
        "response_format" => %{"type" => "json_schema"},
        "messages" => [%{"role" => "user", "content" => "CHAOS_AMBIENT_IGNORE"}]
      }

      assert FakeOpenAIScenarios.classify(request) == :ambient_noop_decision

      assert {:completion, decision_json, [split_text?: false]} =
               FakeOpenAIScenarios.action_for(:ambient_noop_decision, 1, request)

      assert %{"action" => "NOOP", "authority" => "NONE"} =
               Ankole.JSON.decode!(decision_json)
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
            "content" => "exit_code=0\ncreated ~/user-files/reports/chaos-report.txt"
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
end
