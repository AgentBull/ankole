defmodule Ankole.SignalsGatewayAIReplyPreviewTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.PluginFixtures.MockSignalProvider.Outbox, as: MockSignalProviderOutbox
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.ReplyPreviewAdapter

  setup :use_mock_signal_provider_plugin

  setup do
    MockSignalProviderOutbox.put_recipient(self())

    on_exit(fn ->
      MockSignalProviderOutbox.delete_recipient()
      MockSignalProviderOutbox.delete_send_result()
    end)

    :ok
  end

  test "preview starts only for a dispatched turn and consumes opaque actor metadata" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("dispatch")

    assert Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event.id) == []

    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, actor_event)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "draft answer"})

    assert_receive {:mock_provider_outbox_sent, initial}
    assert initial.operation == :reply
    assert initial.fallback_visible_text == "draft answer"
    assert initial.idempotency_key == "ai-preview:#{actor_event.id}"

    state = :sys.get_state(pid)
    assert state.subject_uid == subject.uid
    assert state.actor_event.id == actor_event.id

    recorded = Repo.get!(ActorEvent, actor_event.id)
    assert recorded.reply_preview_source_entry_id =~ "mock-reply-"
  end

  test "preview ignores another opaque actor_event_id in the same conversation" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("metadata-filter")

    %{conversation: conversation, response: response} =
      start_dispatched_preview(subject.uid, actor_event)

    {:ok, unrelated_response} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        metadata: request_metadata(%{"actor_event_id" => Ecto.UUID.generate()})
      })

    assert :ok =
             Events.publish(unrelated_response, :output_text_delta, %{text: "wrong turn"})

    refute_receive {:mock_provider_outbox_sent, _outbox}, 100

    assert :ok = Events.publish(response, :output_text_delta, %{text: "right turn"})

    assert_receive {:mock_provider_outbox_sent, initial}
    assert initial.fallback_visible_text == "right turn"
  end

  test "response_started resets the round buffer without ending or recreating the preview" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("round-reset")

    %{response: first_round, pid: pid} =
      start_dispatched_preview(subject.uid, actor_event)

    assert :ok =
             Events.publish(first_round, :output_text_delta, %{text: "checking the tool"})

    assert_receive {:mock_provider_outbox_sent, initial}
    assert initial.operation == :reply
    assert initial.fallback_visible_text == "checking the tool"

    function_call = %{
      "type" => "function_call",
      "call_id" => "call_round_reset",
      "name" => "lookup",
      "arguments" => "{}"
    }

    assert {:ok, first_round} =
             StatefulResponses.commit_complete(first_round, [function_call])

    assert Process.alive?(pid)
    refute_receive {:mock_provider_outbox_sent, _terminal_reply}, 100

    {:ok, second_round} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first_round.id}",
        request_items: [
          %{
            "type" => "function_call_output",
            "call_id" => "call_round_reset",
            "output" => "done"
          }
        ],
        metadata: request_metadata(%{"actor_event_id" => actor_event.id})
      })

    state = :sys.get_state(pid)
    assert state.text_buffer == ""
    assert state.preview_established

    assert state.preview_entry_id ==
             Repo.get!(ActorEvent, actor_event.id).reply_preview_source_entry_id

    assert :ok = Events.publish(second_round, :output_text_delta, %{text: "final round"})
    assert :sys.get_state(pid).text_buffer == "final round"

    send(pid, :flush_edit)

    assert_receive {:mock_provider_outbox_sent, edit}
    assert edit.operation == :edit
    assert edit.fallback_visible_text == "final round"
    assert edit.target_source_entry_id == state.preview_entry_id
  end

  test "tool activity establishes and updates preview before assistant text" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("tool-activity")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, actor_event)

    assert :ok =
             Events.publish(response, :tool_call_started, %{
               "call_id" => "call_web_fetch",
               "name" => "web_fetch"
             })

    assert_receive {:mock_provider_outbox_sent, initial}
    assert initial.operation == :reply
    assert initial.fallback_visible_text == "Calling tool: web_fetch"

    assert :ok =
             Events.publish(response, :tool_call_completed, %{
               "call_id" => "call_web_fetch",
               "output" => "page content"
             })

    assert_receive {:mock_provider_outbox_sent, completed_edit}
    assert completed_edit.operation == :edit
    assert completed_edit.fallback_visible_text == "Finished tool: web_fetch. Reading results."
    assert is_binary(completed_edit.target_source_entry_id)
    assert Process.alive?(pid)
  end

  test "tool activity preview uses the current locale" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("tool-activity-i18n")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, actor_event)

    :sys.replace_state(pid, fn state ->
      {:ok, _tag} = Ankole.I18n.put_locale("zh-Hans-CN")
      state
    end)

    assert :ok =
             Events.publish(response, :tool_call_started, %{
               "call_id" => "call_web_fetch_i18n",
               "name" => "web_fetch"
             })

    assert_receive {:mock_provider_outbox_sent, initial}
    assert initial.fallback_visible_text == "正在调用工具：web_fetch"
  end

  test "response terminal events neither terminate preview nor send a final reply" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("terminal-events")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, actor_event)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "draft"})
    assert_receive {:mock_provider_outbox_sent, initial}
    assert initial.operation == :reply

    for event_type <- [:response_completed, :response_failed, :response_incomplete] do
      assert :ok = Events.publish(response, event_type, %{content: []})
      assert Process.alive?(pid)
      refute_receive {:mock_provider_outbox_sent, _terminal_reply}, 100
    end
  end

  test "blank leading deltas do not create preview noise" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("blank-delta")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, actor_event)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "   "})
    send(pid, :flush_edit)
    refute_receive {:mock_provider_outbox_sent, _outbox}, 100

    assert :ok = Events.publish(response, :output_text_delta, %{text: " answer "})

    assert_receive {:mock_provider_outbox_sent, initial}
    assert initial.operation == :reply
    assert initial.fallback_visible_text == "answer"
  end

  test "an initial provider rejection disables preview retries for later deltas" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("provider-rejection")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, actor_event)

    MockSignalProviderOutbox.put_send_result({:error, :provider_rejected})

    assert :ok = Events.publish(response, :output_text_delta, %{text: "first"})
    assert_receive {:mock_provider_outbox_sent, first_attempt}
    assert first_attempt.fallback_visible_text == "first"

    assert :ok = Events.publish(response, :output_text_delta, %{text: " second"})
    refute_receive {:mock_provider_outbox_sent, _retry}, 100

    state = :sys.get_state(pid)
    assert state.preview_disabled
    refute state.preview_established
  end

  test "an edit rejection disables later preview edits for the turn" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("edit-rejection")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, actor_event)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "first"})
    assert_receive {:mock_provider_outbox_sent, initial}
    assert initial.operation == :reply

    MockSignalProviderOutbox.put_send_result({:error, :provider_rejected})

    assert :ok = Events.publish(response, :output_text_delta, %{text: " second"})
    send(pid, :flush_edit)

    assert_receive {:mock_provider_outbox_sent, failed_edit}
    assert failed_edit.operation == :edit
    assert failed_edit.fallback_visible_text == "first second"

    state = :sys.get_state(pid)
    assert state.preview_disabled
    assert state.preview_established

    assert :ok = Events.publish(response, :output_text_delta, %{text: " third"})
    send(pid, :flush_edit)
    refute_receive {:mock_provider_outbox_sent, _retry}, 100
  end

  test "quiet scheduled CardKit work suppresses phase, tool, reasoning, and noop output" do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    actor_event =
      scheduled_actor_event_fixture(subject.uid,
        payload: %{"data" => %{"wake_payload" => %{"quiet_success" => true}}}
      )

    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, actor_event)

    adapter = %ReplyPreviewAdapter{
      open_fun: fn _request -> {:ok, %{}} end,
      update_fun: fn _request -> {:ok, %{}} end,
      finalize_fun: fn _request -> {:ok, %{}} end
    }

    :sys.replace_state(pid, fn state ->
      %{state | reply_preview_adapter: adapter, silent_rich_pending: true}
    end)

    assert :ok =
             AIReplyPreview.presentation_event(actor_event.id, %{
               "kind" => "turn.phase",
               "payload" => %{"revision" => 1, "state" => "working"}
             })

    assert :ok =
             AIReplyPreview.presentation_event(actor_event.id, %{
               "kind" => "tool.activity",
               "payload" => %{
                 "operation_id" => "quiet-tool",
                 "revision" => 2,
                 "phase" => "running",
                 "label" => "检查状态"
               }
             })

    assert :ok = Events.publish(response, :reasoning_delta, %{text: "过程思考"})

    state = :sys.get_state(pid)
    assert state.silent_rich_pending
    refute state.dirty
    assert state.presentation["revision"] == 0
    refute state.presentation["thought"]

    assert :ok = Events.publish(response, :output_text_delta, %{text: "<silent_"})
    assert :ok = Events.publish(response, :output_text_delta, %{text: "success/>"})
    refute_receive {:mock_provider_outbox_sent, _outbox}, 100

    state = :sys.get_state(pid)
    assert state.silent_rich_pending
    refute state.dirty

    assert :ok = Events.publish(response, :response_completed, %{content: []})
    assert Process.alive?(pid)
    refute_receive {:mock_provider_outbox_sent, _terminal_reply}, 100

    monitor = Process.monitor(pid)
    assert :ok = AIReplyPreview.stop(actor_event.id)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "lifecycle stop returns while the preview process is busy" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("nonblocking-stop")
    %{pid: pid} = start_dispatched_preview(subject.uid, actor_event)
    parent = self()
    monitor = Process.monitor(pid)

    :ok = :sys.suspend(pid)

    spawn(fn ->
      send(parent, {:stop_returned, AIReplyPreview.stop(actor_event.id)})
    end)

    assert_receive {:stop_returned, :ok}, 500
    assert Process.alive?(pid)

    :ok = :sys.resume(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "stop checkpoints unsynced rich metadata before terminal outbox takes over" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("rich-stop-checkpoint")
    %{pid: pid} = start_dispatched_preview(subject.uid, actor_event)

    adapter = %ReplyPreviewAdapter{
      open_fun: fn _request -> {:ok, %{}} end,
      update_fun: fn _request -> {:ok, %{}} end,
      finalize_fun: fn _request -> {:ok, %{}} end
    }

    :sys.replace_state(pid, fn state ->
      %{state | reply_preview_adapter: adapter, silent_rich_pending: false}
    end)

    assert :ok =
             AIReplyPreview.presentation_event(actor_event.id, %{
               "kind" => "plan.snapshot",
               "payload" => %{
                 "operation_id" => "todo",
                 "revision" => 1,
                 "items" => [
                   %{"id" => "inspect", "content" => "检查卡片", "status" => "in_progress"}
                 ]
               }
             })

    monitor = Process.monitor(pid)
    assert :ok = AIReplyPreview.stop(actor_event.id)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    checkpoint = Repo.get!(ActorEvent, actor_event.id).reply_preview_checkpoint

    assert get_in(checkpoint, ["presentation", "plan", "items"]) == [
             %{
               "id" => "inspect",
               "content" => "检查卡片",
               "status" => "in_progress"
             }
           ]

    assert checkpoint["subject_uid"] == subject.uid
    assert is_binary(checkpoint["conversation_id"])
  end

  defp addressed_actor_event(suffix) do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: actor_event} =
      emit_addressed_actor_event(
        subject.uid,
        "mock",
        group_entry(%{
          source_event_id: "preview-#{suffix}-event",
          signal_channel_id: "mock:chat:preview-#{suffix}",
          source_entry_id: "human-message-#{suffix}",
          provider_thread_id: "mock-thread-#{suffix}",
          explicit: true,
          text: "ping"
        })
      )

    %{subject: subject, actor_event: actor_event}
  end

  defp start_dispatched_preview(subject_uid, actor_event) do
    {:ok, conversation} =
      StatefulResponses.ensure_conversation(subject_uid, actor_event.session_id)

    assert :ok =
             AIReplyPreview.maybe_start_for(actor_event, subject_uid, conversation.id)

    on_exit(fn -> stop_preview_and_wait(actor_event.id) end)

    {:ok, response} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject_uid,
        conversation_id: conversation.id,
        request_items: [%{"role" => "user", "content" => "ping"}],
        metadata: request_metadata(%{"actor_event_id" => actor_event.id})
      })

    assert [{pid, _value}] =
             Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event.id)

    %{conversation: conversation, response: response, pid: pid}
  end

  defp request_metadata(metadata), do: %{"request_metadata" => metadata}

  defp stop_preview_and_wait(actor_event_id) do
    case Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event_id) do
      [{pid, _value}] ->
        monitor = Process.monitor(pid)
        :ok = AIReplyPreview.stop(actor_event_id)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          1_000 -> Process.exit(pid, :kill)
        end

      [] ->
        :ok
    end
  end

  defp use_mock_signal_provider_plugin(_context) do
    original_state = :sys.get_state(Ankole.Plugins.Registry)
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        disabled_ids: MapSet.new()
      }
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    :ok
  end

  defp scheduled_actor_event_fixture(agent_uid, opts) do
    now = DateTime.utc_now(:microsecond)

    attrs =
      %{
        agent_uid: agent_uid,
        binding_name: "mock",
        session_id: "mock:chat:schedule-silent",
        source_event_id: "schedule-silent-#{System.unique_integer([:positive])}",
        signal_channel_id: "mock:chat:schedule-silent",
        provider_thread_id: "mock-thread-schedule-silent",
        source_entry_id: "schedule-source-entry",
        type: "check_back_later.wakeup",
        available_at: now,
        queue_sequence: System.unique_integer([:positive]),
        input_state: "open",
        payload: %{"data" => %{"wake_payload" => %{}}}
      }
      |> Map.merge(Map.new(opts))

    %ActorEvent{}
    |> ActorEvent.changeset(attrs)
    |> Repo.insert!()
  end
end
