defmodule Ankole.SignalsGateway.OutboxReplyPreviewRouteTest do
  @moduledoc false
  # SignalsGateway owns the terminal reply route: a durable AI reply row on a
  # provider that declares a reply-preview module finalizes through that module,
  # and a provider without one still delivers through `send/1`.
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.PluginFixtures.MockSignalProvider.Outbox, as: MockOutbox
  alias Ankole.PluginFixtures.MockSignalProvider.ReplyPreview, as: MockReplyPreview
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  setup do
    MockOutbox.put_recipient(self())
    MockReplyPreview.put_recipient(self())

    on_exit(fn ->
      MockOutbox.delete_recipient()
      MockReplyPreview.delete_recipient()
      MockReplyPreview.delete_finalize_result()
    end)

    :ok
  end

  test "a rich provider finalizes the durable AI reply through its preview module" do
    %{agent: agent, event: event} = actor_event_on("mock-rich-provider")
    {:ok, outbox} = commit_ai_reply(agent, event, "final answer")
    {:ok, adapter} = Adapters.fetch_outbox("mock-rich-provider")

    assert {:ok, %OutboxEntry{status: :succeeded} = delivered} =
             SignalsGateway.dispatch_outbox(agent.uid, "rich", outbox.outbound_key, adapter)

    assert_receive {:mock_provider_preview, :finalize, %Request{} = request}
    assert request.actor_event.id == event.id
    assert request.mode == :terminal
    assert request.presentation["answer"] == "final answer"
    assert request.outbox.outbound_key == outbox.outbound_key
    assert request.checkpoint == %{}
    assert request.previous_presentation == nil
    refute_received {:mock_provider_outbox_sent, _outbox}

    assert delivered.created_source_entry_id == "mock-preview-#{event.id}"

    assert %ActorEvent{reply_preview_checkpoint: %{"streaming_state" => "closed"}} =
             Repo.get!(ActorEvent, event.id)
  end

  test "an unknown finalize result parks the row as unknown_after_send" do
    MockReplyPreview.put_finalize_result(:unknown)
    %{agent: agent, event: event} = actor_event_on("mock-rich-provider")
    {:ok, outbox} = commit_ai_reply(agent, event, "uncertain answer")
    {:ok, adapter} = Adapters.fetch_outbox("mock-rich-provider")

    assert {:ok, %OutboxEntry{status: :unknown_after_send}} =
             SignalsGateway.dispatch_outbox(agent.uid, "rich", outbox.outbound_key, adapter)

    assert_receive {:mock_provider_preview, :finalize, %Request{}}
    refute_received {:mock_provider_outbox_sent, _outbox}
  end

  test "a provider without a preview module delivers the durable AI reply through send/1" do
    %{agent: agent, event: event} = actor_event_on("mock-provider")
    {:ok, outbox} = commit_ai_reply(agent, event, "plain final answer")
    {:ok, adapter} = Adapters.fetch_outbox("mock-provider")

    assert {:ok, %OutboxEntry{status: :succeeded}} =
             SignalsGateway.dispatch_outbox(agent.uid, "rich", outbox.outbound_key, adapter)

    key = outbox.outbound_key
    assert_receive {:mock_provider_outbox_sent, %OutboxEntry{outbound_key: ^key}}
    refute_received {:mock_provider_preview, _kind, _request}
  end

  defp actor_event_on(adapter_id) do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "rich", :ignore, adapter: adapter_id)

    assert {:ok, %{actor_event: event}} =
             emit_entry(
               agent.uid,
               "rich",
               group_entry(%{
                 explicit: true,
                 source_event_id: "evt-#{System.unique_integer([:positive])}",
                 source_entry_id: "msg-#{System.unique_integer([:positive])}"
               }),
               now: @base_time
             )

    %{agent: agent, event: event}
  end

  defp commit_ai_reply(agent, event, answer) do
    presentation = ReplyPresentation.new() |> ReplyPresentation.terminal("completed", answer)
    outbound_key = "ai-reply:#{event.id}"

    SignalsGateway.commit_outbox(%{
      agent_uid: agent.uid,
      binding_name: "rich",
      outbound_key: outbound_key,
      delivery_class: :durable_ai_reply,
      operation: :reply,
      signal_channel_id: event.signal_channel_id,
      reply_to_source_entry_id: event.source_entry_id,
      source_actor_event_id: event.id,
      payload: %{"reply_presentation" => presentation},
      fallback_visible_text: answer,
      idempotency_key: outbound_key
    })
  end
end
