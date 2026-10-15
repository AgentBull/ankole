defmodule Ankole.E2E.SlackMainFlowTest do
  use Ankole.DataCase, async: false

  alias Ankole.E2E.FakeSlack.Server
  alias Ankole.E2E.FakeSlack.State
  alias Ankole.Plugins.SlackAdapter.Config
  alias Ankole.Plugins.SlackAdapter.ConnectionReconciler
  alias Ankole.Plugins.SlackAdapter.Delivery

  alias Ankole.Repo
  alias Ankole.Conversations.Delivery.PreviewState
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.PreviewAdapter
  alias Ankole.Conversations.Delivery.PreviewAdapter.Request

  import Ankole.E2E.Harness,
    only: [put_slack_test_client_opts!: 1, observe_external_conversation!: 3]

  import Ankole.PrincipalsFixtures

  test "durable intent adapter posts, edits, reacts, and reconciles against Web API" do
    fake = Server.start!()
    put_slack_test_client_opts!(base_url: fake.base_url)
    %{principal: agent} = agent_fixture()
    binding_name = "slack-main-flow"

    config = %{
      "botToken" => "xoxb-fake",
      "appToken" => "xapp-fake",
      "userName" => "Slack"
    }

    on_exit(fn -> ConnectionReconciler.stop(Config.connection_key(config)) end)

    assert {:ok, _binding} =
             Ankole.Signals.Bindings.put_binding(agent.uid, "slack", binding_name, %{
               "config" => config,
               "unmatched_sender_policy" => "create_standalone"
             })

    conversation = observe_external_conversation!(agent.uid, binding_name, "slack:C1")

    base = %Intent{
      agent_uid: agent.uid,
      binding_name: binding_name,
      outbound_key: "reply-1",
      operation: :reply,
      conversation_id: conversation.id,
      reply_to_provider_message_id: "1699999999.000001",
      fallback_visible_text: "**hello** from Ankole",
      payload: %{}
    }

    assert {:ok,
            %{
              created_provider_message_id: ts,
              provider_thread_id: "slack:C1:1699999999.000001"
            }} = Delivery.deliver(base)

    assert State.messages(fake.state)[ts]["text"] == "*hello* from Ankole"
    assert State.messages(fake.state)[ts]["thread_ts"] == "1699999999.000001"

    assert {:ok, %{raw_payload: %{"ok" => true}}} =
             Delivery.deliver(%{
               base
               | outbound_key: "edit-1",
                 operation: :edit,
                 target_provider_message_id: ts,
                 fallback_visible_text: "updated"
             })

    assert State.messages(fake.state)[ts]["text"] == "updated"

    assert {:ok, _result} =
             Delivery.deliver(%{
               base
               | outbound_key: "react-1",
                 operation: :reaction_add,
                 target_provider_message_id: ts,
                 payload: %{"reaction_key" => "thumbs_up"}
             })

    assert {:ok, %{created_provider_message_id: ^ts, recovery_state: %{"exists" => true}}} =
             Delivery.reconcile(%{base | created_provider_message_id: ts})

    assert {:ok, %Signal{} = signal} =
             Ankole.Signals.accept(%{
               source: "test://slack/preview",
               id: "reply-preview-source",
               target: %{agent_uid: agent.uid, conversation_id: conversation.id},
               authorization: Ankole.Principals.WorkAccess.service(),
               type: "conversation.message.addressed",
               time: DateTime.utc_now(:microsecond),
               data: %{"text" => "Reply preview source"},
               reply_route: %{
                 binding_name: binding_name,
                 conversation_id: conversation.id,
                 provider_message_id: "1699999999.000001"
               }
             })

    preview_adapter = PreviewAdapter.for_event(signal)
    assert %PreviewAdapter{} = preview_adapter

    working = %{
      "state" => "working",
      "revision" => 1,
      "answer" => "draft answer",
      "activities" => %{},
      "results" => [],
      "receipts" => [],
      "actions" => [],
      "meta" => %{"status" => "Working"}
    }

    assert {:ok,
            %{
              created_provider_message_id: preview_ts,
              provider_thread_id: "slack:C1:1699999999.000001",
              reply_preview_checkpoint: %{
                "adapter" => "slack",
                "message_id" => preview_ts,
                "streaming_state" => "open"
              }
            }} =
             PreviewAdapter.update(preview_adapter, %Request{
               signal: signal,
               presentation: working,
               subject_uid: "u1",
               conversation_id: Ecto.UUID.generate(),
               mode: :working
             })

    assert State.messages(fake.state)[preview_ts]["thread_ts"] == "1699999999.000001"
    assert State.messages(fake.state)[preview_ts]["text"] == "draft answer"
    assert is_list(State.messages(fake.state)[preview_ts]["blocks"])

    assert Repo.get!(Signal, signal.id).provider_thread_id ==
             "slack:C1:1699999999.000001"

    terminal = %{working | "state" => "completed", "revision" => 2, "answer" => "final answer"}

    assert {:ok, %{created_provider_message_id: ^preview_ts}} =
             PreviewAdapter.finalize_intent(preview_adapter, %{
               base
               | outbound_key: "terminal-reply",
                 source_signal_id: signal.id,
                 payload: %{"reply_presentation" => terminal},
                 fallback_visible_text: "final answer"
             })

    assert State.messages(fake.state)[preview_ts]["text"] == "final answer"

    assert PreviewState.get(signal.id).checkpoint["streaming_state"] ==
             "closed"

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
