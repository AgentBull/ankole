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
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter

  defmodule RecoveryReplyPreview do
    @moduledoc false

    @behaviour Ankole.SignalsGateway.ReplyPreviewAdapter

    @recipient_key {__MODULE__, :recipient}

    def put_recipient(pid), do: :persistent_term.put(@recipient_key, pid)
    def delete_recipient, do: :persistent_term.erase(@recipient_key)

    @impl true
    def open(_request), do: {:ok, %{}}

    @impl true
    def update(_request), do: {:ok, %{}}

    @impl true
    def finalize(_request), do: {:ok, %{}}

    @impl true
    def refresh(request) do
      send(:persistent_term.get(@recipient_key), {:recovery_refresh, request})
      {:ok, %{}}
    end
  end

  defmodule RecoverySignalProviderPlugin do
    @moduledoc false

    @behaviour Ankole.Plugins.Plugin

    alias Ankole.PluginFixtures.MockSignalProvider.Inbound
    alias Ankole.PluginFixtures.MockSignalProvider.Outbox
    alias Ankole.SignalsGatewayAIReplyPreviewTest.RecoveryReplyPreview

    @impl true
    def plugin_id, do: "recovery-signal-provider"

    @impl true
    def display_name, do: %{"default" => "Recovery Signal Provider"}

    @impl true
    def adapter_declarations do
      [
        %{
          contract_id: "signals_gateway.adapter",
          id: "mock-provider",
          plugin_id: plugin_id(),
          display_name: display_name(),
          ingress_module: Inbound,
          outbox_module: Outbox,
          reply_preview_module: RecoveryReplyPreview,
          inbound_capabilities: ["entry_receive"],
          outbound_capabilities: ["post_entry", "reply_entry", "outbound_reconciliation"]
        }
      ]
    end
  end

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

  test "preview seeds visible context from a failed BackgroundAgentJob trigger" do
    %{subject: subject, actor_event: actor_event} =
      addressed_actor_event("background-agent-job-failure")

    actor_event =
      actor_event
      |> ActorEvent.changeset(%{
        type: "background_agent_job.failed",
        payload: %{
          "data" => %{
            "title" => "第二版 deep research",
            "result_summary" => "返回 JSON Schema 少声明了必填字段"
          }
        }
      })
      |> Repo.update!()

    %{pid: pid} = start_dispatched_preview(subject.uid, actor_event)

    assert :sys.get_state(pid).presentation["trigger_context"] == %{
             "kind" => "background_agent_job_failure",
             "title" => "第二版 deep research",
             "summary" => "返回 JSON Schema 少声明了必填字段"
           }
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

  test "CardKit coalesces preview changes for one second between syncs" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("rich-sync-throttle")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, actor_event)
    owner = self()

    adapter = %ReplyPreviewAdapter{
      open_fun: fn _request -> {:ok, %{}} end,
      update_fun: fn request ->
        send(owner, {:rich_sync, request.presentation["answer"]})
        {:ok, %{}}
      end,
      finalize_fun: fn _request -> {:ok, %{}} end
    }

    :sys.replace_state(pid, fn state ->
      %{state | reply_preview_adapter: adapter, silent_rich_pending: false}
    end)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "first"})
    send(pid, :flush_edit)
    assert_receive {:rich_sync, "first"}

    assert :ok = Events.publish(response, :output_text_delta, %{text: " second"})
    refute_receive {:rich_sync, "first second"}, 700
    assert_receive {:rich_sync, "first second"}, 1_500
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

  test "stop cannot overwrite an equal-revision durable clarification checkpoint" do
    %{subject: subject, actor_event: actor_event} =
      addressed_actor_event("durable-clarification-wins")

    %{conversation: conversation, pid: pid} =
      start_dispatched_preview(subject.uid, actor_event)

    stale_working =
      ReplyPresentation.new(state: "working")
      |> Map.put("revision", 1)

    clarification =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("interaction.request", %{
        "revision" => 1,
        "prompt" => "Which option should I use?",
        "controls" => [
          %{
            "id" => "operators",
            "type" => "button",
            "label" => "Operators",
            "interaction_id" => "clarify:call-1",
            "source_actor_event_id" => actor_event.id,
            "control_id" => "clarify-choice",
            "revision" => 1
          }
        ]
      })
      |> ReplyPresentation.checkpoint()

    adapter = %ReplyPreviewAdapter{
      open_fun: fn _request -> {:ok, %{}} end,
      update_fun: fn _request -> {:ok, %{}} end,
      finalize_fun: fn _request -> {:ok, %{}} end
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | reply_preview_adapter: adapter,
          silent_rich_pending: false,
          presentation: stale_working,
          dirty: false
      }
    end)

    assert {:ok, _updated} =
             Actors.put_reply_preview_checkpoint(actor_event.id, %{
               "subject_uid" => subject.uid,
               "conversation_id" => conversation.id,
               "streaming_state" => "closed",
               "presentation" => clarification,
               "interactions" => %{
                 "clarify:call-1" => %{
                   "interaction_id" => "clarify:call-1",
                   "state" => "pending"
                 }
               }
             })

    monitor = Process.monitor(pid)
    assert :ok = AIReplyPreview.stop(actor_event.id)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    checkpoint = Repo.get!(ActorEvent, actor_event.id).reply_preview_checkpoint
    assert checkpoint["presentation"]["state"] == "awaiting_input"
    assert checkpoint["presentation"]["interaction_status"] == "pending"
    assert [%{"interaction_id" => "clarify:call-1"}] = checkpoint["presentation"]["actions"]
  end

  test "dead-letter checkpoint notifications cannot restart a working preview" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("dead-letter-recover")

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(subject.uid, actor_event.session_id)

    checkpoint = %{
      "subject_uid" => subject.uid,
      "conversation_id" => conversation.id,
      "streaming_state" => "open",
      "presentation" => ReplyPresentation.checkpoint(ReplyPresentation.new(state: "working"))
    }

    actor_event
    |> ActorEvent.changeset(%{
      input_state: "dead_letter",
      dead_letter_at: DateTime.utc_now(:microsecond),
      reply_preview_checkpoint: checkpoint
    })
    |> Repo.update!()

    assert {:error, :reply_preview_not_recoverable} = AIReplyPreview.recover(actor_event.id)
    assert Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event.id) == []
  end

  test "checkpoint notifications do not recover a preview that already has a live owner" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("live-owner-recover")
    %{pid: pid} = start_dispatched_preview(subject.uid, actor_event)

    assert :ok = AIReplyPreview.recover(actor_event.id)

    assert [{^pid, _value}] =
             Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event.id)
  end

  test "startup closes a completed event whose durable reply outlived an open preview" do
    original_state = :sys.get_state(Ankole.Plugins.Registry)
    {:ok, spec} = Spec.from_module(RecoverySignalProviderPlugin)

    :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    RecoveryReplyPreview.put_recipient(self())

    on_exit(fn ->
      RecoveryReplyPreview.delete_recipient()
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    %{subject: subject, actor_event: actor_event} = addressed_actor_event("terminal-recover")

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(subject.uid, actor_event.session_id)

    working =
      ReplyPresentation.new(state: "working")
      |> ReplyPresentation.replace_answer("partial")
      |> ReplyPresentation.checkpoint()

    terminal =
      working
      |> ReplyPresentation.terminal("completed", "durable final answer")
      |> ReplyPresentation.checkpoint()

    checkpoint = %{
      "subject_uid" => subject.uid,
      "conversation_id" => conversation.id,
      "card_id" => "card-recover",
      "message_id" => "message-recover",
      "streaming_state" => "open",
      "presentation" => working,
      "cards" => [
        %{
          "index" => 0,
          "card_id" => "card-recover",
          "message_id" => "message-recover",
          "streaming_state" => "open"
        }
      ],
      "active_card_index" => 0
    }

    actor_event =
      actor_event
      |> ActorEvent.changeset(%{
        completed_at: DateTime.utc_now(:microsecond),
        reply_preview_checkpoint: checkpoint,
        reply_preview_source_entry_id: "message-recover"
      })
      |> Repo.update!()

    Repo.insert!(%OutboxEntry{
      agent_uid: actor_event.agent_uid,
      binding_name: actor_event.binding_name,
      outbound_key: "terminal-recover:#{actor_event.id}",
      delivery_class: :durable_ai_reply,
      operation: :edit,
      status: :succeeded,
      signal_channel_id: actor_event.signal_channel_id,
      target_source_entry_id: "message-recover",
      source_actor_event_id: actor_event.id,
      payload: %{"reply_presentation" => terminal},
      fallback_visible_text: "durable final answer",
      idempotency_key: "terminal-recover:#{actor_event.id}",
      attempt_count: 1,
      max_attempts: 10,
      last_error: %{},
      recovery_state: %{}
    })

    assert Enum.any?(Actors.recoverable_reply_preview_events(), &(&1.id == actor_event.id))
    assert :ok = AIReplyPreview.recover(actor_event.id)

    assert_receive {:recovery_refresh, request}
    assert request.mode == :terminal
    assert request.presentation["state"] == "completed"
    assert request.presentation["answer"] == "durable final answer"
    assert request.checkpoint["refresh_reason"] == "terminal_recovery"
  end

  test "stop cancels an in-flight rich mutation before terminal outbox takes over" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("rich-stop-drain")
    %{pid: pid} = start_dispatched_preview(subject.uid, actor_event)
    owner = self()

    adapter = %ReplyPreviewAdapter{
      open_fun: fn _request -> {:ok, %{}} end,
      update_fun: fn _request ->
        send(owner, {:rich_update_started, self()})

        receive do
          :finish_rich_update -> {:ok, %{}}
        end
      end,
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

    assert :sys.get_state(pid).dirty
    send(pid, :flush_edit)
    assert_receive {:rich_update_started, task_pid}

    monitor = Process.monitor(pid)
    assert :ok = AIReplyPreview.stop(actor_event.id)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 500
    refute Process.alive?(task_pid)
  end

  test "terminal handoff immediately fences a hung rich mutation" do
    %{subject: subject, actor_event: actor_event} = addressed_actor_event("rich-stop-timeout")
    %{pid: pid} = start_dispatched_preview(subject.uid, actor_event)
    owner = self()

    assert {:ok, %{"sequence" => working_sequence}} =
             Actors.prepare_reply_preview_mutation(
               actor_event.id,
               "working",
               "working-digest",
               Ecto.UUID.generate()
             )

    adapter = %ReplyPreviewAdapter{
      open_fun: fn _request -> {:ok, %{}} end,
      update_fun: fn _request ->
        send(owner, {:hung_rich_update_started, self()})

        receive do
          :never_finish -> {:ok, %{}}
        end
      end,
      finalize_fun: fn _request -> {:ok, %{}} end
    }

    :sys.replace_state(pid, fn state ->
      %{state | reply_preview_adapter: adapter, silent_rich_pending: false}
    end)

    assert :ok =
             AIReplyPreview.presentation_event(actor_event.id, %{
               "kind" => "plan.snapshot",
               "payload" => %{
                 "operation_id" => "timeout",
                 "revision" => 1,
                 "items" => [
                   %{"id" => "wait", "content" => "等待慢请求", "status" => "in_progress"}
                 ]
               }
             })

    send(pid, :flush_edit)
    assert_receive {:hung_rich_update_started, task_pid}

    monitor = Process.monitor(pid)
    assert :ok = AIReplyPreview.stop(actor_event.id)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 500
    refute Process.alive?(task_pid)

    checkpoint = Repo.get!(ActorEvent, actor_event.id).reply_preview_checkpoint

    assert get_in(checkpoint, ["presentation", "plan", "items"]) == [
             %{
               "id" => "wait",
               "content" => "等待慢请求",
               "status" => "in_progress"
             }
           ]

    assert {:ok, %{"sequence" => terminal_sequence}} =
             Actors.prepare_reply_preview_mutation(
               actor_event.id,
               "terminal",
               "terminal-digest",
               Ecto.UUID.generate()
             )

    assert terminal_sequence > working_sequence
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
        enabled_ids: MapSet.new([spec.id])
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
