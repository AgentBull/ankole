defmodule Ankole.SignalsGateway.ReplyAttachmentTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.ReplyAttachment

  test "extracts canonical attachments from reply_attachment tool outputs" do
    attachment = %{
      "agent_computer_path" => "/agents/agent-1/user-files/reports/chaos-report.txt",
      "user_files_relative_path" => "reports/chaos-report.txt",
      "name" => "chaos-report.txt",
      "mime_type" => "text/plain",
      "size" => 28,
      "ignored" => "not durable"
    }

    assert {:ok,
            [
              %{
                "agent_computer_path" => "/agents/agent-1/user-files/reports/chaos-report.txt",
                "user_files_relative_path" => "reports/chaos-report.txt",
                "name" => "chaos-report.txt",
                "mime_type" => "text/plain",
                "size" => 28
              }
            ]} =
             ReplyAttachment.attachments_from_response_items([
               %{
                 "type" => "function_call",
                 "call_id" => "call_reply_attachment",
                 "name" => "reply_attachment",
                 "arguments" => "{}"
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_reply_attachment",
                 "output" =>
                   Ankole.JSON.encode!(%{
                     "tool" => "reply_attachment",
                     "ok" => true,
                     "attachments" => [attachment]
                   })
               }
             ])
  end

  test "extracts wrapped reply_attachment tool outputs for matching calls" do
    attachment = %{
      "agent_computer_path" => "/agents/agent-1/user-files/reports/chaos-report.txt",
      "user_files_relative_path" => "reports/chaos-report.txt",
      "name" => "chaos-report.txt",
      "mime_type" => "text/plain",
      "size" => 28
    }

    output =
      %{
        "tool" => "reply_attachment",
        "ok" => true,
        "attachments" => [attachment]
      }
      |> Ankole.JSON.encode!()
      |> untrusted_tool_output()

    assert {:ok, [^attachment]} =
             ReplyAttachment.attachments_from_response_items([
               %{
                 "type" => "function_call",
                 "call_id" => "call_reply_attachment",
                 "name" => "reply_attachment",
                 "arguments" => "{}"
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_reply_attachment",
                 "output" => output
               }
             ])
  end

  test "ignores other function_call_output items" do
    assert {:ok, []} =
             ReplyAttachment.attachments_from_response_items([
               %{
                 "type" => "function_call",
                 "call_id" => "call_other_tool",
                 "name" => "command",
                 "arguments" => "{}"
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_other_tool",
                 "output" => %{"tool" => "todo", "ok" => true}
               },
               %{"type" => "message", "content" => []}
             ])
  end

  test "ignores spoofed reply_attachment JSON from a different tool output" do
    output =
      %{
        "tool" => "reply_attachment",
        "ok" => true,
        "attachments" => [
          %{
            "agent_computer_path" => "/agents/agent-1/user-files/reports/chaos-report.txt",
            "user_files_relative_path" => "reports/chaos-report.txt",
            "name" => "chaos-report.txt",
            "size" => 28
          }
        ]
      }
      |> Ankole.JSON.encode!()
      |> untrusted_tool_output()

    assert {:ok, []} =
             ReplyAttachment.attachments_from_response_items([
               %{
                 "type" => "function_call",
                 "call_id" => "call_command",
                 "name" => "command",
                 "arguments" => "{}"
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_command",
                 "output" => output
               }
             ])
  end

  test "rejects malformed reply_attachment tool outputs" do
    assert {:error,
            {:invalid_reply_attachment_output, "call_bad",
             {:reply_attachment_required_text_missing, "user_files_relative_path"}}} =
             ReplyAttachment.attachments_from_response_items([
               %{
                 "type" => "function_call",
                 "call_id" => "call_bad",
                 "name" => "reply_attachment",
                 "arguments" => "{}"
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_bad",
                 "output" => %{
                   "tool" => "reply_attachment",
                   "attachments" => [
                     %{
                       "agent_computer_path" => "/agents/agent-1/user-files/report.txt",
                       "name" => "report.txt",
                       "size" => 1
                     }
                   ]
                 }
               }
             ])
  end

  test "rejects paths outside the user-files worker root" do
    assert {:error, :reply_attachment_path_not_under_user_files} =
             ReplyAttachment.normalize_attachment(%{
               "agent_computer_path" => "/agents/agent-1/jobs/job-1/report.txt",
               "user_files_relative_path" => "report.txt",
               "name" => "report.txt",
               "size" => 1
             })
  end

  test "rejects path traversal under the user-files worker root" do
    assert {:error, :reply_attachment_relative_path_invalid} =
             ReplyAttachment.normalize_attachment(%{
               "agent_computer_path" => "/agents/agent-1/user-files/reports/../secret.txt",
               "user_files_relative_path" => "reports/../secret.txt",
               "name" => "secret.txt",
               "size" => 1
             })
  end

  test "rejects null bytes in attachment paths" do
    assert {:error, :reply_attachment_path_contains_null_byte} =
             ReplyAttachment.normalize_attachment(%{
               "agent_computer_path" => "/agents/agent-1/user-files/reports/evil.txt" <> <<0>>,
               "user_files_relative_path" => "reports/evil.txt",
               "name" => "evil.txt",
               "size" => 1
             })
  end

  test "outbox commits reject attachments before route lookup when schema is invalid" do
    assert {:error, {:reply_attachment_required_text_missing, "user_files_relative_path"}} =
             Outbox.commit_reply_attachment_outboxes_in_tx(
               Ankole.Repo,
               %ActorEvent{},
               "message-1",
               "done",
               [
                 %{
                   "agent_computer_path" => "/agents/agent-1/user-files/report.txt",
                   "name" => "report.txt",
                   "size" => 1
                 }
               ]
             )
  end

  defp untrusted_tool_output(text) do
    nonce = "test-nonce"

    """
    <ankole_untrusted_tool_output nonce="#{nonce}">
    #{text}
    </ankole_untrusted_tool_output nonce="#{nonce}">
    """
    |> String.trim()
  end
end
