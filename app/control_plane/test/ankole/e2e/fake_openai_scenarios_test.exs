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
end
