defmodule Ankole.Conversations.Delivery.ReplyAttachmentTest do
  use Ankole.DataCase, async: true

  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures

  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery
  alias Ankole.Conversations.Delivery.Attachment

  @object_id "019a39d2-72d8-7f77-a2bd-1f44b9458eba"
  @node_id "019a39d2-72d8-7f77-a2bd-1f44b9458ebb"

  test "extracts canonical attachments from reply_attachment tool outputs" do
    attachment = %{
      "path" => "sent/0123456789abcdef/chaos-report.txt",
      "object_id" => @object_id,
      "node_id" => @node_id,
      "name" => "chaos-report.txt",
      "mime_type" => "text/plain",
      "size" => 28,
      "ignored" => "not durable"
    }

    assert {:ok,
            [
              %{
                "path" => "sent/0123456789abcdef/chaos-report.txt",
                "object_id" => @object_id,
                "node_id" => @node_id,
                "name" => "chaos-report.txt",
                "mime_type" => "text/plain",
                "size" => 28
              } = extracted
            ]} =
             Attachment.attachments_from_response_items([
               reply_attachment_call("call_reply_attachment"),
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

    refute Map.has_key?(extracted, "ignored")
  end

  test "ignores other function_call_output items" do
    assert {:ok, []} =
             Attachment.attachments_from_response_items([
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
      Ankole.JSON.encode!(%{
        "tool" => "reply_attachment",
        "ok" => true,
        "attachments" => [attachment("report.txt")]
      })

    assert {:ok, []} =
             Attachment.attachments_from_response_items([
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
             {:reply_attachment_required_text_missing, "path"}}} =
             Attachment.attachments_from_response_items([
               reply_attachment_call("call_bad"),
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_bad",
                 "output" => %{
                   "tool" => "reply_attachment",
                   "attachments" => [
                     %{
                       "object_id" => @object_id,
                       "node_id" => @node_id,
                       "name" => "a.txt",
                       "size" => 1
                     }
                   ]
                 }
               }
             ])
  end

  test "rejects invalid drive paths and object identifiers" do
    for path <- ["/agents/agent-1/user-files/a.txt", "reports/../secret.txt", "a//b"] do
      assert {:error, :reply_attachment_path_invalid} =
               Attachment.normalize_attachment(%{attachment("a.txt") | "path" => path})
    end

    for object_id <- [nil, "abc", String.duplicate("a", 64)] do
      assert {:error, {:reply_attachment_identifier_invalid, "object_id"}} =
               Attachment.normalize_attachment(%{
                 attachment("a.txt")
                 | "object_id" => object_id
               })
    end
  end

  test "rejects null bytes in attachment paths" do
    assert {:error, :unsupported_nul_byte} =
             Attachment.normalize_attachment(%{
               attachment("evil.txt")
               | "path" => "sent/0123456789abcdef/evil.txt" <> <<0>>
             })
  end

  test "verify_in_drive requires the content at the path in the Agent's drive" do
    %{principal: agent} = agent_fixture()
    %{principal: other} = agent_fixture()
    file = drive_file_fixture(agent.uid, "sent/abc/report.txt", "report", "sent")
    object_id = file.object_id

    sent = %{
      attachment("report.txt")
      | "path" => file.path,
        "object_id" => object_id,
        "node_id" => file.id
    }

    assert :ok = Attachment.verify_in_drive(agent.uid, [sent])

    assert {:error, {:reply_attachment_not_in_drive, "sent/abc/report.txt"}} =
             Attachment.verify_in_drive(other.uid, [sent])

    assert {:error, {:reply_attachment_not_in_drive, "sent/abc/report.txt"}} =
             Attachment.verify_in_drive(agent.uid, [
               %{sent | "object_id" => @object_id, "node_id" => @node_id}
             ])
  end

  test "intent commits reject attachments before route lookup when schema is invalid" do
    assert {:error, {:reply_attachment_required_text_missing, "path"}} =
             Delivery.commit_reply_attachments_in_tx(
               %Signal{},
               "message-1",
               [
                 %{
                   "object_id" => @object_id,
                   "node_id" => @node_id,
                   "name" => "report.txt",
                   "size" => 1
                 }
               ]
             )
  end

  defp reply_attachment_call(call_id) do
    %{
      "type" => "function_call",
      "call_id" => call_id,
      "name" => "reply_attachment",
      "arguments" => "{}"
    }
  end

  defp attachment(name) do
    %{
      "path" => "sent/0123456789abcdef/" <> name,
      "object_id" => @object_id,
      "node_id" => @node_id,
      "name" => name,
      "size" => 1
    }
  end
end
