defmodule Ankole.Conversations.Delivery.ReplyPreviewRouteTest do
  @moduledoc false
  # Conversations.Delivery owns the terminal reply route: a durable AI reply row on a
  # provider that declares a reply-preview module finalizes through that module,
  # and a provider without one still delivers through `send/1`.
  use Ankole.SessionsCase

  alias Ankole.PluginFixtures.MockSignalProvider.Delivery, as: MockDelivery
  alias Ankole.PluginFixtures.MockSignalProvider.ReplyPreview, as: MockReplyPreview
  alias Ankole.Signals.Adapters
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.PreviewAdapter.Request

  setup {Ankole.SessionsCase, :use_mock_signal_provider_plugin}

  setup do
    MockDelivery.put_recipient(self())
    MockReplyPreview.put_recipient(self())

    on_exit(fn ->
      MockDelivery.delete_recipient()
      MockReplyPreview.delete_recipient()
      MockReplyPreview.delete_finalize_result()
    end)

    :ok
  end

  test "a rich provider finalizes the durable AI reply through its preview module" do
    %{agent: agent, event: event} = signal_on("mock-rich-provider")
    {:ok, intent} = commit_ai_reply(agent, event, "final answer")
    {:ok, adapter} = Adapters.fetch_delivery("mock-rich-provider")

    assert {:ok, %Intent{status: :sent} = delivered} =
             Ankole.Conversations.Delivery.dispatch(
               agent.uid,
               "rich",
               intent.outbound_key,
               adapter
             )

    assert_receive {:mock_provider_preview, :finalize, %Request{} = request}
    assert request.signal.id == event.id
    assert request.mode == :terminal
    assert request.presentation["answer"] == "final answer"
    assert request.delivery.outbound_key == intent.outbound_key
    assert request.checkpoint == %{}
    assert request.previous_presentation == nil
    refute_received {:mock_provider_intent_sent, _intent}

    assert delivered.created_provider_message_id == "mock-preview-#{event.id}"

    assert %Ankole.Conversations.Delivery.PreviewState{
             checkpoint: %{"streaming_state" => "closed"}
           } = Ankole.Conversations.Delivery.PreviewStates.get(event.id)
  end

  test "an unknown finalize result parks the row as unknown_after_send" do
    MockReplyPreview.put_finalize_result(:unknown)
    %{agent: agent, event: event} = signal_on("mock-rich-provider")
    {:ok, intent} = commit_ai_reply(agent, event, "uncertain answer")
    {:ok, adapter} = Adapters.fetch_delivery("mock-rich-provider")

    assert {:ok, %Intent{status: :unknown}} =
             Ankole.Conversations.Delivery.dispatch(
               agent.uid,
               "rich",
               intent.outbound_key,
               adapter
             )

    assert_receive {:mock_provider_preview, :finalize, %Request{}}
    refute_received {:mock_provider_intent_sent, _intent}
  end

  test "a provider without a preview module delivers the durable AI reply through send/1" do
    %{agent: agent, event: event} = signal_on("mock-provider")
    {:ok, intent} = commit_ai_reply(agent, event, "plain final answer")
    {:ok, adapter} = Adapters.fetch_delivery("mock-provider")

    assert {:ok, %Intent{status: :sent}} =
             Ankole.Conversations.Delivery.dispatch(
               agent.uid,
               "rich",
               intent.outbound_key,
               adapter
             )

    key = intent.outbound_key
    assert_receive {:mock_provider_intent_sent, %Intent{outbound_key: ^key}}
    refute_received {:mock_provider_preview, _kind, _request}
  end

  defp signal_on(adapter_id) do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "rich", :ignore, adapter: adapter_id)

    assert {:ok, %{signal: event}} =
             emit_entry(
               agent.uid,
               "rich",
               group_entry(%{
                 explicit: true,
                 source_event_id: "evt-#{System.unique_integer([:positive])}",
                 provider_message_id: "msg-#{System.unique_integer([:positive])}"
               }),
               now: @base_time
             )

    %{agent: agent, event: event}
  end

  defp commit_ai_reply(agent, event, answer) do
    presentation = ReplyPresentation.new() |> ReplyPresentation.terminal("completed", answer)
    outbound_key = "ai-reply:#{event.id}"

    Ankole.SignalsFixtures.commit_delivery(%{
      agent_uid: agent.uid,
      binding_name: "rich",
      outbound_key: outbound_key,
      delivery_class: :durable_ai_reply,
      operation: :reply,
      conversation_id: event.conversation_id,
      reply_to_provider_message_id: event.provider_message_id,
      source_signal_id: event.id,
      payload: %{"reply_presentation" => presentation},
      fallback_visible_text: answer,
      idempotency_key: outbound_key
    })
  end
end
