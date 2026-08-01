defmodule Ankole.E2E.SlackMainFlowTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.E2E.FakeSlack.{Server, State}
  alias Ankole.Plugins.SlackAdapter.{Config, Outbox}
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.OutboxEntry

  import Ankole.E2E.Harness, only: [put_slack_test_client_opts!: 1]
  import Ankole.PrincipalsFixtures

  test "durable outbox adapter posts, edits, reacts, and reconciles against Web API" do
    fake = Server.start!()
    put_slack_test_client_opts!(base_url: fake.base_url)
    %{principal: agent} = agent_fixture()
    binding_name = "slack-main-flow"

    config = %{
      "botToken" => "xoxb-fake",
      "appToken" => "xapp-fake",
      "platformSubjectNamespace" => "slack-main",
      "userName" => "Slack"
    }

    assert {:ok, _stored} =
             AppConfigure.put_global_by_key(Config.chat_config_key(binding_name), config)

    assert {:ok, _binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent.uid,
               name: binding_name,
               adapter: "slack",
               config_ref: "app-config://#{Config.chat_config_key(binding_name)}",
               filters: %{},
               unaddressed_group_message_policy: :ignore
             })

    base = %OutboxEntry{
      agent_uid: agent.uid,
      binding_name: binding_name,
      outbound_key: "reply-1",
      operation: :reply,
      signal_channel_id: "slack:C1",
      reply_to_source_entry_id: "1699999999.000001",
      fallback_visible_text: "**hello** from Ankole",
      payload: %{}
    }

    assert {:ok, %{created_source_entry_id: ts}} = Outbox.send(base)
    assert State.messages(fake.state)[ts]["text"] == "*hello* from Ankole"
    assert State.messages(fake.state)[ts]["thread_ts"] == "1699999999.000001"

    assert {:ok, %{raw_payload: %{"ok" => true}}} =
             Outbox.send(%{
               base
               | outbound_key: "edit-1",
                 operation: :edit,
                 target_source_entry_id: ts,
                 fallback_visible_text: "updated"
             })

    assert State.messages(fake.state)[ts]["text"] == "updated"

    assert {:ok, _result} =
             Outbox.send(%{
               base
               | outbound_key: "react-1",
                 operation: :reaction_add,
                 target_source_entry_id: ts,
                 payload: %{"reaction_key" => "thumbs_up"}
             })

    assert {:ok, %{created_source_entry_id: ^ts, recovery_state: %{"exists" => true}}} =
             Outbox.reconcile(%{base | created_source_entry_id: ts})

    client = Config.client(config)

    assert {:ok, %{"files" => [%{"id" => file_id}]}} =
             SlackOpenAPI.upload_external(client,
               filename: "outbound.txt",
               content: "outbound-content",
               channel_id: "C1",
               initial_comment: "attached"
             )

    assert State.uploaded_file(fake.state, file_id).content == "outbound-content"

    :ok = State.put_inbound_file(fake.state, "F1", "inbound.txt", "inbound-content")

    assert {:ok, %{body: "inbound-content", filename: "inbound.txt"}} =
             SlackOpenAPI.download(client, "http://127.0.0.1:#{fake.port}/files/F1")
  end
end
