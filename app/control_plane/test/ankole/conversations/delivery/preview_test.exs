defmodule Ankole.Conversations.Delivery.PreviewTest do
  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.Events
  alias Ankole.PluginFixtures.MockSignalProvider.Delivery, as: MockSignalProviderDelivery
  alias Ankole.PluginFixtures.MockSignalProvider.ReplyPreview, as: MockReplyPreview
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery.Preview
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.PreviewAdapter

  defmodule RecoveryReplyPreview do
    @moduledoc false

    @behaviour Ankole.Conversations.Delivery.PreviewAdapter

    alias Ankole.PluginFixtures.MockSignalProvider.ReplyPreview, as: MockReplyPreview

    @recipient_key {__MODULE__, :recipient}
    @refresh_result_key {__MODULE__, :refresh_result}

    def put_recipient(pid), do: :persistent_term.put(@recipient_key, pid)
    def delete_recipient, do: :persistent_term.erase(@recipient_key)

    def put_refresh_result(result), do: :persistent_term.put(@refresh_result_key, result)
    def delete_refresh_result, do: :persistent_term.erase(@refresh_result_key)

    @impl true
    def update(_request), do: {:ok, %{}}

    @impl true
    def finalize(_request), do: {:ok, %{}}

    @impl true
    def refresh(request) do
      send(:persistent_term.get(@recipient_key), {:recovery_refresh, request})
      :persistent_term.get(@refresh_result_key, {:ok, %{}})
    end

    @impl true
    def surface_ids(checkpoint) do
      [{:handle, checkpoint["card_id"]} | MockReplyPreview.surface_ids(checkpoint)]
      |> Enum.filter(fn {_kind, id} -> is_binary(id) and id != "" end)
    end

    @impl true
    def surface_open?(checkpoint), do: MockReplyPreview.surface_open?(checkpoint)
  end

  defmodule PostOnlySignalProviderPlugin do
    @moduledoc """
    Mirrors an adapter that can post and edit but cannot thread.
    """

    @behaviour Ankole.Plugins.Plugin

    alias Ankole.PluginFixtures.MockSignalProvider.Inbound
    alias Ankole.PluginFixtures.MockSignalProvider.Delivery

    @impl true
    def plugin_id, do: "post-only-signal-provider"

    @impl true
    def display_name, do: %{"default" => "Post Only Signal Provider"}

    @impl true
    def adapter_declarations do
      [
        %{
          contract_id: "signals.adapter",
          id: "mock-provider",
          adapter_category: "enterprise_im",
          plugin_id: plugin_id(),
          display_name: display_name(),
          observe_module: Inbound,
          deliver_module: Delivery,
          inbound_capabilities: ["entry_receive"],
          outbound_capabilities: ["post_entry", "edit_entry"]
        }
      ]
    end
  end

  defmodule ImmutableSignalProviderPlugin do
    @moduledoc """
    Mirrors an adapter whose sent entries cannot change, like Email.
    """

    @behaviour Ankole.Plugins.Plugin

    alias Ankole.PluginFixtures.MockSignalProvider.Inbound
    alias Ankole.PluginFixtures.MockSignalProvider.Delivery

    @impl true
    def plugin_id, do: "immutable-signal-provider"

    @impl true
    def display_name, do: %{"default" => "Immutable Signal Provider"}

    @impl true
    def adapter_declarations do
      [
        %{
          contract_id: "signals.adapter",
          id: "mock-provider",
          adapter_category: "email",
          plugin_id: plugin_id(),
          display_name: display_name(),
          observe_module: Inbound,
          deliver_module: Delivery,
          inbound_capabilities: ["entry_receive"],
          outbound_capabilities: ["post_entry", "reply_entry"]
        }
      ]
    end
  end

  defmodule RecoverySignalProviderPlugin do
    @moduledoc false

    @behaviour Ankole.Plugins.Plugin

    alias Ankole.PluginFixtures.MockSignalProvider.Inbound
    alias Ankole.PluginFixtures.MockSignalProvider.Delivery
    alias Ankole.Conversations.Delivery.PreviewTest.RecoveryReplyPreview

    @impl true
    def plugin_id, do: "recovery-signal-provider"

    @impl true
    def display_name, do: %{"default" => "Recovery Signal Provider"}

    @impl true
    def adapter_declarations do
      [
        %{
          contract_id: "signals.adapter",
          id: "mock-provider",
          adapter_category: "enterprise_im",
          plugin_id: plugin_id(),
          display_name: display_name(),
          observe_module: Inbound,
          deliver_module: Delivery,
          preview_module: RecoveryReplyPreview,
          inbound_capabilities: ["entry_receive"],
          outbound_capabilities: ["post_entry", "reply_entry", "outbound_reconciliation"]
        }
      ]
    end
  end

  setup :use_mock_signal_provider_plugin

  setup do
    MockSignalProviderDelivery.put_recipient(self())

    on_exit(fn ->
      MockSignalProviderDelivery.delete_recipient()
      MockSignalProviderDelivery.delete_send_result()
    end)

    :ok
  end

  test "preview starts only for a dispatched turn and consumes opaque actor metadata" do
    %{subject: subject, signal: signal} = addressed_signal("dispatch")

    assert Preview.lookup(signal.id) == []

    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "draft answer"})

    assert_receive {:mock_provider_intent_sent, initial}
    assert initial.operation == :reply
    assert initial.fallback_visible_text == "draft answer"
    assert initial.idempotency_key == "ai-preview:#{signal.id}"

    state = :sys.get_state(pid)
    assert state.subject_uid == subject.uid
    assert state.signal.id == signal.id

    recorded = Repo.get!(Signal, signal.id)

    assert Ankole.Conversations.Delivery.PreviewStates.get(recorded).provider_message_id =~
             "mock-reply-"
  end

  test "preview seeds visible context from a failed BackgroundAgentJob trigger" do
    %{subject: subject, signal: signal} =
      addressed_signal("background-agent-job-failure")

    signal =
      signal
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{
        type: "background_agent_job.failed",
        data: %{
          "title" => "第二版 deep research",
          "result_summary" => "返回 JSON Schema 少声明了必填字段"
        }
      })
      |> Repo.update!()

    %{pid: pid} = start_dispatched_preview(subject.uid, signal)

    assert :sys.get_state(pid).presentation["trigger_context"] == %{
             "kind" => "background_agent_job_failure",
             "title" => "第二版 deep research",
             "summary" => "返回 JSON Schema 少声明了必填字段"
           }
  end

  test "preview identifies an automatic cron wake" do
    %{subject: subject, signal: signal} = addressed_signal("scheduled-task")

    signal =
      signal
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{
        type: "cron.fire",
        data: %{"wake_payload" => %{"trigger" => "scheduled"}}
      })
      |> Repo.update!()

    %{pid: pid} = start_dispatched_preview(subject.uid, signal)

    assert :sys.get_state(pid).presentation["trigger_context"] == %{
             "kind" => "scheduled_task"
           }
  end

  test "preview ignores another opaque signal_id in the same conversation" do
    %{subject: subject, signal: signal} = addressed_signal("metadata-filter")

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(subject.uid, signal.session_id)

    {:ok, root} =
      start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        metadata: request_metadata(%{"signal_id" => Ecto.UUID.generate()})
      })

    {:ok, root} = ResponseCommit.commit_complete(root, [])

    %{response: response} = start_dispatched_preview(subject.uid, signal)

    # Implicit admission allows one generating run per conversation; the
    # unrelated in-flight run exists only through an explicit anchor.
    {:ok, unrelated_response} =
      start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{root.id}",
        metadata: request_metadata(%{"signal_id" => Ecto.UUID.generate()})
      })

    assert :ok =
             Events.publish(unrelated_response, :output_text_delta, %{text: "wrong turn"})

    refute_receive {:mock_provider_intent_sent, _intent}, 100

    assert :ok = Events.publish(response, :output_text_delta, %{text: "right turn"})

    assert_receive {:mock_provider_intent_sent, initial}
    assert initial.fallback_visible_text == "right turn"
  end

  test "response_started resets the round buffer without ending or recreating the preview" do
    %{subject: subject, signal: signal} = addressed_signal("round-reset")

    %{response: first_round, pid: pid} =
      start_dispatched_preview(subject.uid, signal)

    assert :ok =
             Events.publish(first_round, :output_text_delta, %{text: "checking the tool"})

    assert_receive {:mock_provider_intent_sent, initial}
    assert initial.operation == :reply
    assert initial.fallback_visible_text == "checking the tool"

    function_call = %{
      "type" => "function_call",
      "call_id" => "call_round_reset",
      "name" => "lookup",
      "arguments" => "{}"
    }

    assert {:ok, first_round} =
             ResponseCommit.commit_complete(first_round, [function_call])

    assert Process.alive?(pid)
    refute_receive {:mock_provider_intent_sent, _terminal_reply}, 100

    {:ok, second_round} =
      start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first_round.id}",
        request_items: [
          %{
            "type" => "function_call_output",
            "call_id" => "call_round_reset",
            "output" => "done"
          }
        ],
        metadata: request_metadata(%{"signal_id" => signal.id})
      })

    state = :sys.get_state(pid)
    assert state.text_buffer == ""
    assert state.preview_established

    assert state.preview_entry_id ==
             Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).provider_message_id

    assert :ok = Events.publish(second_round, :output_text_delta, %{text: "final round"})
    assert :sys.get_state(pid).text_buffer == "final round"

    send(pid, :flush_edit)

    assert_receive {:mock_provider_intent_sent, edit}
    assert edit.operation == :edit
    assert edit.fallback_visible_text == "final round"
    assert edit.target_provider_message_id == state.preview_entry_id
  end

  test "input supersession edits the same preview and replaces the status on new output" do
    %{subject: subject, signal: signal} = addressed_signal("input-superseded")

    %{response: response, pid: pid} =
      start_dispatched_preview(subject.uid, signal)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "obsolete partial"})

    assert_receive {:mock_provider_intent_sent, initial}
    assert initial.operation == :reply
    preview_entry_id = :sys.get_state(pid).preview_entry_id

    assert :ok = Preview.input_superseded(signal)

    assert_receive {:mock_provider_intent_sent, superseded_edit}
    assert superseded_edit.operation == :edit
    assert superseded_edit.target_provider_message_id == preview_entry_id

    assert superseded_edit.fallback_visible_text ==
             Ankole.I18n.t("conversations.delivery.reply.input_superseded")

    assert :ok = Events.publish(response, :response_started, %{})
    assert :sys.get_state(pid).input_superseded

    assert :ok = Events.publish(response, :output_text_delta, %{text: "replacement answer"})
    send(pid, :flush_edit)

    assert_receive {:mock_provider_intent_sent, replacement_edit}
    assert replacement_edit.operation == :edit
    assert replacement_edit.target_provider_message_id == preview_entry_id
    assert replacement_edit.fallback_visible_text == "replacement answer"
  end

  test "tool activity establishes and updates preview before assistant text" do
    %{subject: subject, signal: signal} = addressed_signal("tool-activity")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)

    assert :ok =
             Events.publish(response, :tool_call_started, %{
               "call_id" => "call_web_fetch",
               "name" => "web_fetch"
             })

    assert_receive {:mock_provider_intent_sent, initial}
    assert initial.operation == :reply
    assert initial.fallback_visible_text == "Calling tool: web_fetch"

    assert :ok =
             Events.publish(response, :tool_call_completed, %{
               "call_id" => "call_web_fetch",
               "output" => "page content"
             })

    assert_receive {:mock_provider_intent_sent, completed_edit}
    assert completed_edit.operation == :edit
    assert completed_edit.fallback_visible_text == "Finished tool: web_fetch. Reading results."
    assert is_binary(completed_edit.target_provider_message_id)
    assert Process.alive?(pid)
  end

  test "tool activity preview uses the current locale" do
    %{subject: subject, signal: signal} = addressed_signal("tool-activity-i18n")
    %{response: response} = start_dispatched_preview(subject.uid, signal)

    {:ok, _locale} = Ankole.I18n.put_default_locale("zh-Hans-CN")

    assert :ok =
             Events.publish(response, :tool_call_started, %{
               "call_id" => "call_web_fetch_i18n",
               "name" => "web_fetch"
             })

    assert_receive {:mock_provider_intent_sent, initial}
    assert initial.fallback_visible_text == "正在调用工具：web_fetch"
  end

  test "response terminal events neither terminate preview nor send a final reply" do
    %{subject: subject, signal: signal} = addressed_signal("terminal-events")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "draft"})
    assert_receive {:mock_provider_intent_sent, initial}
    assert initial.operation == :reply

    for event_type <- [:response_completed, :response_failed, :response_incomplete] do
      assert :ok = Events.publish(response, event_type, %{content: []})
      assert Process.alive?(pid)
      refute_receive {:mock_provider_intent_sent, _terminal_reply}, 100
    end
  end

  test "blank leading deltas do not create preview noise" do
    %{subject: subject, signal: signal} = addressed_signal("blank-delta")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "   "})
    send(pid, :flush_edit)
    refute_receive {:mock_provider_intent_sent, _intent}, 100

    assert :ok = Events.publish(response, :output_text_delta, %{text: " answer "})

    assert_receive {:mock_provider_intent_sent, initial}
    assert initial.operation == :reply
    assert initial.fallback_visible_text == "answer"
  end

  test "background-job silent-success output stays private until the full marker is known" do
    %{subject: subject, signal: signal} =
      addressed_signal("background-job-silent-success")

    signal =
      signal
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{type: "background_agent_job.completed"})
      |> Repo.update!()

    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)
    marker = ~s({"outcome":"silent_success","reply":null})

    for codepoint <- String.codepoints(marker) do
      assert :ok = Events.publish(response, :output_text_delta, %{text: codepoint})
      refute_receive {:mock_provider_intent_sent, _intent}, 20
    end

    assert :sys.get_state(pid).text_buffer == marker
    refute :sys.get_state(pid).preview_established

    assert :ok = Events.publish(response, :response_completed, %{content: []})
    refute_receive {:mock_provider_intent_sent, _intent}, 100
  end

  test "an initial provider rejection disables preview retries for later deltas" do
    %{subject: subject, signal: signal} = addressed_signal("provider-rejection")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)

    MockSignalProviderDelivery.put_send_result({:error, :provider_rejected})

    assert :ok = Events.publish(response, :output_text_delta, %{text: "first"})
    assert_receive {:mock_provider_intent_sent, first_attempt}
    assert first_attempt.fallback_visible_text == "first"

    assert :ok = Events.publish(response, :output_text_delta, %{text: " second"})
    refute_receive {:mock_provider_intent_sent, _retry}, 100

    state = :sys.get_state(pid)
    assert state.preview_disabled
    refute state.preview_established
  end

  test "an edit rejection disables later preview edits for the turn" do
    %{subject: subject, signal: signal} = addressed_signal("edit-rejection")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "first"})
    assert_receive {:mock_provider_intent_sent, initial}
    assert initial.operation == :reply

    MockSignalProviderDelivery.put_send_result({:error, :provider_rejected})

    assert :ok = Events.publish(response, :output_text_delta, %{text: " second"})
    send(pid, :flush_edit)

    assert_receive {:mock_provider_intent_sent, failed_edit}
    assert failed_edit.operation == :edit
    assert failed_edit.fallback_visible_text == "first second"

    state = :sys.get_state(pid)
    assert state.preview_disabled
    assert state.preview_established

    assert :ok = Events.publish(response, :output_text_delta, %{text: " third"})
    send(pid, :flush_edit)
    refute_receive {:mock_provider_intent_sent, _retry}, 100
  end

  test "quiet scheduled CardKit work suppresses phase, tool, reasoning, and noop output" do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    signal =
      scheduled_signal_fixture(subject.uid,
        data: %{"wake_payload" => %{"quiet_success" => true}}
      )

    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn _request -> {:ok, %{}} end,
      finalize_fun: fn _request -> {:ok, %{}} end
    }

    :sys.replace_state(pid, fn state ->
      %{state | preview_adapter: adapter, silent_rich_pending: true}
    end)

    assert :ok =
             Preview.presentation_event(signal, %{
               "kind" => "turn.phase",
               "payload" => %{"revision" => 1, "state" => "working"}
             })

    assert :ok =
             Preview.presentation_event(signal, %{
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

    for text <- [
          "<sাইলent_success/>",
          "arbitrary raw output",
          ~s({"outcome":"silent_success","reply":null})
        ] do
      for part <- String.codepoints(text) do
        assert :ok = Events.publish(response, :output_text_delta, %{text: part})
        state = :sys.get_state(pid)
        assert state.silent_rich_pending
        refute state.dirty
        assert state.text_buffer == ""
      end
    end

    refute_receive {:mock_provider_intent_sent, _intent}, 100

    state = :sys.get_state(pid)
    assert state.silent_rich_pending
    refute state.dirty

    assert :ok = Events.publish(response, :response_completed, %{content: []})
    assert Process.alive?(pid)
    refute_receive {:mock_provider_intent_sent, _terminal_reply}, 100

    monitor = Process.monitor(pid)
    assert :ok = Preview.stop(signal)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "scheduled raw text stays private for plain previews and after a rich owner handoff" do
    %{subject: subject, signal: signal} = addressed_signal("scheduled-handoff")

    signal =
      signal
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{
        type: "check_back_later.wakeup",
        data: %{"wake_payload" => %{"quiet_success" => false}}
      })
      |> Repo.update!()

    %{response: response, pid: pid, conversation: conversation} =
      start_dispatched_preview(subject.uid, signal)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "<sাইলent_success/>"})
    send(pid, :flush_edit)
    refute_receive {:mock_provider_intent_sent, _}, 100
    refute :sys.get_state(pid).preview_established

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn _ -> {:ok, %{}} end,
      finalize_fun: fn _ -> {:ok, %{}} end
    }

    :sys.replace_state(pid, &%{&1 | preview_adapter: adapter})
    steer = steer_signal(subject.uid, signal, "scheduled-steer")
    assert :ok = Preview.continue_on(signal.id, steer)

    assert :ok =
             Events.publish(response, :output_text_delta, %{
               text: ~s({"outcome":"reply","reply":"final report"})
             })

    state = :sys.get_state(pid)
    assert state.structured_reply
    assert state.text_buffer == ""
    assert state.presentation["answer"] in [nil, ""]
    stop_preview_and_wait(signal.id)

    driver_name = Ankole.Sessions.driver_name(signal)
    :ok = :global.unregister_name(driver_name)
    assert :yes = :global.register_name(driver_name, self())
    on_exit(fn -> :global.unregister_name(driver_name) end)
    assert :ok = Preview.recover(steer.id)
    stream_id = signal.id
    assert_receive {:recover_preview, ^stream_id}
    assert Preview.lookup(signal.id) == []
    :global.unregister_name(driver_name)
    assert :ok = Preview.maybe_start_for(signal, subject.uid, conversation.id)

    assert [{recovered_pid, _}] =
             Preview.lookup(signal.id)

    assert :sys.get_state(recovered_pid).structured_reply
  end

  test "CardKit coalesces preview changes for one second between syncs" do
    %{subject: subject, signal: signal} = addressed_signal("rich-sync-throttle")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)
    owner = self()

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn request ->
        send(owner, {:rich_sync, request.presentation["answer"]})
        {:ok, %{}}
      end,
      finalize_fun: fn _request -> {:ok, %{}} end
    }

    :sys.replace_state(pid, fn state ->
      %{state | preview_adapter: adapter, silent_rich_pending: false}
    end)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "first"})
    send(pid, :flush_edit)
    assert_receive {:rich_sync, "first"}

    assert :ok = Events.publish(response, :output_text_delta, %{text: " second"})
    refute_receive {:rich_sync, "first second"}, 700
    assert_receive {:rich_sync, "first second"}, 1_500
  end

  test "steer freezes the old card before switching the presentation owner" do
    %{subject: subject, signal: signal} = addressed_signal("steer-handoff")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)
    steer_event = steer_signal(subject.uid, signal, "steer-handoff-next")
    owner = self()

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn request ->
        send(owner, {:rich_owner_update, request.signal.id, request.presentation})
        persist_preview_request(request, "open")
      end,
      finalize_fun: fn request ->
        send(owner, {:rich_owner_finalize, request.signal.id, request.presentation})
        persist_preview_request(request, "closed")
      end
    }

    :sys.replace_state(pid, fn state ->
      %{state | preview_adapter: adapter, silent_rich_pending: false}
    end)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "旧卡片已展示的答案"})
    send(pid, :flush_edit)

    assert_receive {:rich_owner_update, old_owner_id, old_presentation}
    assert old_owner_id == signal.id
    assert old_presentation["answer"] == "旧卡片已展示的答案"

    assert :ok = Preview.continue_on(signal.id, steer_event)

    assert_receive {:rich_owner_finalize, finalized_owner_id, continued}
    assert finalized_owner_id == signal.id
    assert continued["state"] == "continued"
    assert continued["answer"] == "旧卡片已展示的答案"
    refute Map.has_key?(continued, "thought")

    old_checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint

    assert old_checkpoint["presentation_owner"] == false
    assert old_checkpoint["continued_to_signal_id"] == steer_event.id
    assert old_checkpoint["presentation"]["state"] == "continued"

    new_checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, steer_event.id)).checkpoint

    assert new_checkpoint["presentation_owner"] == true
    assert new_checkpoint["stream_signal_id"] == signal.id
    assert new_checkpoint["owner_generation"] == old_checkpoint["owner_generation"] + 1

    state = :sys.get_state(pid)
    assert state.stream_signal_id == signal.id
    assert state.signal.id == steer_event.id
    assert state.owner_generation == new_checkpoint["owner_generation"]

    assert :ok = Preview.continue_on(signal.id, steer_event)
    refute_receive {:rich_owner_finalize, _owner_id, _presentation}, 100

    assert :ok = Events.publish(response, :response_started, %{})
    assert :ok = Events.publish(response, :output_text_delta, %{text: "新卡片续接"})
    send(pid, :flush_edit)

    assert_receive {:rich_owner_update, new_owner_id, new_presentation}
    assert new_owner_id == steer_event.id
    assert new_presentation["answer"] == "新卡片续接"

    next_steer_event = steer_signal(subject.uid, steer_event, "steer-handoff-third")
    assert :ok = Preview.continue_on(signal.id, next_steer_event)

    assert_receive {:rich_owner_finalize, second_owner_id, second_continued}
    assert second_owner_id == steer_event.id
    assert second_continued["state"] == "continued"
    assert second_continued["answer"] == "新卡片续接"

    second_checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, steer_event.id)).checkpoint

    assert second_checkpoint["presentation_owner"] == false
    assert second_checkpoint["continued_to_signal_id"] == next_steer_event.id

    next_checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, next_steer_event.id)).checkpoint

    assert next_checkpoint["presentation_owner"] == true
    assert next_checkpoint["stream_signal_id"] == signal.id
    assert next_checkpoint["owner_generation"] == new_checkpoint["owner_generation"] + 1

    assert :ok = Events.publish(response, :response_started, %{})
    assert :ok = Events.publish(response, :output_text_delta, %{text: "第三张卡片续接"})
    send(pid, :flush_edit)

    assert_receive {:rich_owner_update, third_owner_id, third_presentation}
    assert third_owner_id == next_steer_event.id
    assert third_presentation["answer"] == "第三张卡片续接"
    stop_preview_and_wait(signal.id)
  end

  test "steer switches ownership without creating an empty paused card" do
    %{subject: subject, signal: signal} = addressed_signal("steer-no-card")
    %{pid: pid} = start_dispatched_preview(subject.uid, signal)
    steer_event = steer_signal(subject.uid, signal, "steer-no-card-next")
    owner = self()

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn _request -> {:ok, %{}} end,
      finalize_fun: fn _request ->
        send(owner, :unexpected_empty_card_finalize)
        {:ok, %{}}
      end
    }

    :sys.replace_state(pid, fn state ->
      %{state | preview_adapter: adapter, silent_rich_pending: false, dirty: false}
    end)

    assert :ok = Preview.continue_on(signal.id, steer_event)
    refute_receive :unexpected_empty_card_finalize, 100

    old_checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint

    assert old_checkpoint["presentation_owner"] == false
    refute Map.has_key?(old_checkpoint, "presentation")

    state = :sys.get_state(pid)
    assert state.signal.id == steer_event.id
    assert state.owner_generation == old_checkpoint["owner_generation"] + 1

    monitor = Process.monitor(pid)
    assert :ok = Preview.stop(signal)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    next_steer_event = steer_signal(subject.uid, steer_event, "steer-no-card-recovered")
    assert :ok = Preview.continue_on(signal.id, next_steer_event)

    assert [{recovered_pid, _value}] =
             Preview.lookup(signal.id)

    recovered_state = :sys.get_state(recovered_pid)
    assert recovered_state.signal.id == next_steer_event.id
    assert recovered_state.owner_generation == state.owner_generation + 2
  end

  test "a failed old-card finalization keeps a recoverable continued checkpoint" do
    %{subject: subject, signal: signal} = addressed_signal("steer-handoff-retry")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)
    steer_event = steer_signal(subject.uid, signal, "steer-handoff-retry-next")
    owner = self()

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn request ->
        result = persist_preview_request(request, "open")
        send(owner, :old_card_opened)
        result
      end,
      finalize_fun: fn _request -> {:error, :temporary_provider_failure} end
    }

    :sys.replace_state(pid, fn state ->
      %{state | preview_adapter: adapter, silent_rich_pending: false}
    end)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "已展示内容"})
    send(pid, :flush_edit)
    assert_receive :old_card_opened

    assert {:error, :temporary_provider_failure} =
             Preview.continue_on(signal.id, steer_event)

    old_checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint

    assert old_checkpoint["presentation_owner"] == false
    assert old_checkpoint["presentation"]["state"] == "continued"
    assert old_checkpoint["refresh_pending"] == true
    assert old_checkpoint["refresh_reason"] == "owner_handoff"

    state = :sys.get_state(pid)
    assert state.signal.id == steer_event.id
    assert state.owner_generation == 2
  end

  test "lifecycle stop returns while the preview process is busy" do
    %{subject: subject, signal: signal} = addressed_signal("nonblocking-stop")
    %{pid: pid} = start_dispatched_preview(subject.uid, signal)
    parent = self()
    monitor = Process.monitor(pid)

    :ok = :sys.suspend(pid)

    spawn(fn ->
      send(parent, {:stop_returned, Preview.stop(signal)})
    end)

    assert_receive {:stop_returned, :ok}, 500
    assert Process.alive?(pid)

    :ok = :sys.resume(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
  end

  test "stop checkpoints unsynced rich metadata before terminal intent takes over" do
    %{subject: subject, signal: signal} = addressed_signal("rich-stop-checkpoint")
    %{pid: pid} = start_dispatched_preview(subject.uid, signal)

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn _request -> {:ok, %{}} end,
      finalize_fun: fn _request -> {:ok, %{}} end
    }

    :sys.replace_state(pid, fn state ->
      %{state | preview_adapter: adapter, silent_rich_pending: false}
    end)

    assert :ok =
             Preview.presentation_event(signal, %{
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
    assert :ok = Preview.stop(signal)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint

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
    %{subject: subject, signal: signal} =
      addressed_signal("durable-clarification-wins")

    %{conversation: conversation, pid: pid} =
      start_dispatched_preview(subject.uid, signal)

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
            "source_signal_id" => signal.id,
            "control_id" => "clarify-choice",
            "revision" => 1
          }
        ]
      })
      |> ReplyPresentation.checkpoint()

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn _request -> {:ok, %{}} end,
      finalize_fun: fn _request -> {:ok, %{}} end
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | preview_adapter: adapter,
          silent_rich_pending: false,
          presentation: stale_working,
          dirty: false
      }
    end)

    assert {:ok, _updated} =
             PreviewStates.put_checkpoint(signal.id, %{
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
    assert :ok = Preview.stop(signal)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint

    assert checkpoint["presentation"]["state"] == "awaiting_input"
    assert checkpoint["presentation"]["interaction_status"] == "pending"
    assert [%{"interaction_id" => "clarify:call-1"}] = checkpoint["presentation"]["actions"]
  end

  test "dead-letter checkpoint notifications cannot restart a working preview" do
    %{subject: subject, signal: signal} = addressed_signal("dead-letter-recover")

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(subject.uid, signal.session_id)

    checkpoint = %{
      "subject_uid" => subject.uid,
      "conversation_id" => conversation.id,
      "streaming_state" => "open",
      "presentation" => ReplyPresentation.checkpoint(ReplyPresentation.new(state: "working"))
    }

    signal
    |> Ankole.PreviewFixtures.update!(%{
      status: :dead_letter,
      dead_letter_reason: %{"reason" => "fixture poison"},
      dead_letter_at: DateTime.utc_now(:microsecond),
      checkpoint: checkpoint
    })

    assert {:error, :reply_preview_not_recoverable} = Preview.recover(signal.id)
    assert Preview.lookup(signal.id) == []
  end

  test "checkpoint notifications do not recover a preview that already has a live owner" do
    %{subject: subject, signal: signal} = addressed_signal("live-owner-recover")
    %{pid: pid} = start_dispatched_preview(subject.uid, signal)

    assert :ok = Preview.recover(signal.id)

    assert [{^pid, _value}] =
             Preview.lookup(signal.id)
  end

  test "preview posts its first message when the adapter cannot thread replies" do
    original_state = Ankole.Plugins.Registry.snapshot_for_test()
    {:ok, spec} = Spec.from_module(PostOnlySignalProviderPlugin)

    Ankole.Plugins.Registry.update_for_test(fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    on_exit(fn ->
      Ankole.Plugins.Registry.update_for_test(fn _state -> original_state end)
    end)

    %{subject: subject, signal: signal} = addressed_signal("post-only")

    %{response: response} = start_dispatched_preview(subject.uid, signal)

    assert :ok = Events.publish(response, :output_text_delta, %{text: "no thread here"})

    # A preview message never becomes an intent row, so nothing downstream can
    # degrade it later. The conversation asks for a threaded reply and the adapter
    # cannot thread, so the preview goes out as a top-level post.
    assert_receive {:mock_provider_intent_sent, initial}
    assert initial.operation == :post
    assert is_nil(initial.reply_to_provider_message_id)
    assert initial.fallback_visible_text == "no thread here"
  end

  test "an adapter that cannot edit gets no streaming preview" do
    original_state = Ankole.Plugins.Registry.snapshot_for_test()
    {:ok, spec} = Spec.from_module(ImmutableSignalProviderPlugin)

    Ankole.Plugins.Registry.update_for_test(fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    on_exit(fn ->
      Ankole.Plugins.Registry.update_for_test(fn _state -> original_state end)
    end)

    %{subject: subject, signal: signal} = addressed_signal("immutable")
    %{response: response, pid: pid} = start_dispatched_preview(subject.uid, signal)

    assert :ok =
             Events.publish(response, :tool_call_started, %{
               "call_id" => "call_read_file",
               "name" => "read_file"
             })

    assert :ok = Events.publish(response, :output_text_delta, %{text: "MAIL"})
    assert :ok = Events.publish(response, :output_text_delta, %{text: "-ACCEPTANCE-READY"})

    # No fragment reaches the provider, so the final reply stays a fresh
    # message instead of an edit the adapter would refuse.
    refute_receive {:mock_provider_intent_sent, _sent}, 300
    assert Process.alive?(pid)

    assert is_nil(
             Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).provider_message_id
           )
  end

  test "startup closes a completed event whose durable reply outlived an open preview" do
    original_state = Ankole.Plugins.Registry.snapshot_for_test()
    {:ok, spec} = Spec.from_module(RecoverySignalProviderPlugin)

    Ankole.Plugins.Registry.update_for_test(fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    RecoveryReplyPreview.put_recipient(self())

    on_exit(fn ->
      RecoveryReplyPreview.delete_recipient()
      Ankole.Plugins.Registry.update_for_test(fn _state -> original_state end)
    end)

    %{subject: subject, signal: signal} = addressed_signal("terminal-recover")

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(subject.uid, signal.session_id)

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

    signal =
      signal
      |> Ankole.PreviewFixtures.update!(%{
        completed_at: DateTime.utc_now(:microsecond),
        checkpoint: checkpoint,
        provider_message_id: "message-recover"
      })

    Ankole.SignalsFixtures.delivery_fixture!(%{
      agent_uid: signal.agent_uid,
      binding_name: signal.reply_binding_name,
      outbound_key: "terminal-recover:#{signal.id}",
      delivery_class: :durable_ai_reply,
      operation: :edit,
      status: :sent,
      conversation_id: signal.conversation_id,
      target_provider_message_id: "message-recover",
      source_signal_id: signal.id,
      payload: %{"reply_presentation" => terminal},
      fallback_visible_text: "durable final answer",
      idempotency_key: "terminal-recover:#{signal.id}",
      attempt_count: 1,
      max_attempts: 10,
      last_error: %{},
      recovery_state: %{}
    })

    assert :ok = Preview.recover(signal.id)

    assert_receive {:recovery_refresh, request}
    assert request.mode == :terminal
    assert request.presentation["state"] == "completed"
    assert request.presentation["answer"] == "durable final answer"
    assert request.checkpoint["refresh_reason"] == "terminal_recovery"
  end

  test "a not-retryable refresh distinguishes operator repair from a permanent stop" do
    original_state = Ankole.Plugins.Registry.snapshot_for_test()
    {:ok, spec} = Spec.from_module(RecoverySignalProviderPlugin)

    Ankole.Plugins.Registry.update_for_test(fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    RecoveryReplyPreview.put_recipient(self())

    RecoveryReplyPreview.put_refresh_result(
      {:error,
       {:reply_delivery, :operator_action_required,
        %{"code" => 230_099, "message" => "card table number over limit"}}}
    )

    on_exit(fn ->
      RecoveryReplyPreview.delete_recipient()
      RecoveryReplyPreview.delete_refresh_result()
      Ankole.Plugins.Registry.update_for_test(fn _state -> original_state end)
    end)

    %{subject: subject, signal: signal} = addressed_signal("blocked-recover")

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(subject.uid, signal.session_id)

    terminal =
      ReplyPresentation.new(state: "working")
      |> ReplyPresentation.terminal("completed", "六张表的最终结论")
      |> ReplyPresentation.checkpoint()

    checkpoint = %{
      "subject_uid" => subject.uid,
      "conversation_id" => conversation.id,
      "card_id" => "card-blocked",
      "message_id" => "message-blocked",
      "streaming_state" => "open",
      "presentation" => terminal,
      "cards" => [
        %{
          "index" => 0,
          "card_id" => "card-blocked",
          "message_id" => "message-blocked",
          "streaming_state" => "open"
        }
      ],
      "active_card_index" => 0
    }

    signal =
      signal
      |> Ankole.PreviewFixtures.update!(%{
        completed_at: DateTime.utc_now(:microsecond),
        checkpoint: checkpoint,
        provider_message_id: "message-blocked"
      })

    Ankole.SignalsFixtures.delivery_fixture!(%{
      agent_uid: signal.agent_uid,
      binding_name: signal.reply_binding_name,
      outbound_key: "blocked-recover:#{signal.id}",
      delivery_class: :durable_ai_reply,
      operation: :edit,
      status: :failed,
      conversation_id: signal.conversation_id,
      target_provider_message_id: "message-blocked",
      source_signal_id: signal.id,
      payload: %{"reply_presentation" => terminal},
      fallback_visible_text: "六张表的最终结论",
      idempotency_key: "blocked-recover:#{signal.id}",
      attempt_count: 1,
      max_attempts: 10,
      last_error: %{},
      recovery_state: %{}
    })

    assert {:error, {:reply_delivery, :operator_action_required, _detail}} =
             Preview.recover(signal.id)

    assert_receive {:recovery_refresh, _request}

    blocked =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint

    assert blocked["recovery_state"]["state"] == "blocked"
    assert blocked["recovery_state"]["reason"] == "operator_action_required"
    assert blocked["recovery_state"]["detail"]["code"] == 230_099
    refute Map.has_key?(blocked, "refresh_pending")

    assert {:error, :reply_preview_not_recoverable} = Preview.recover(signal.id)
    refute_receive {:recovery_refresh, _request}

    assert :ok =
             PreviewStates.wake_blocked(
               signal.agent_uid,
               signal.reply_binding_name
             )

    woken =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint

    refute Map.has_key?(woken, "recovery_state")

    RecoveryReplyPreview.put_refresh_result(
      {:error,
       {:reply_delivery, :permanent,
        %{"code" => 40_201, "message" => "message blocked by anti-spam policy"}}}
    )

    assert {:error, {:reply_delivery, :permanent, _detail}} =
             Preview.recover(signal.id)

    assert_receive {:recovery_refresh, _request}

    permanent =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint

    assert permanent["recovery_state"]["state"] == "permanent"
    assert permanent["recovery_state"]["reason"] == "permanent_failure"
    assert permanent["recovery_state"]["detail"]["code"] == 40_201

    assert :ok =
             PreviewStates.wake_blocked(
               signal.agent_uid,
               signal.reply_binding_name
             )

    assert Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint ==
             permanent
  end

  test "an atom-valued adapter detail still persists the blocked recovery state" do
    original_state = Ankole.Plugins.Registry.snapshot_for_test()
    {:ok, spec} = Spec.from_module(RecoverySignalProviderPlugin)

    Ankole.Plugins.Registry.update_for_test(fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    RecoveryReplyPreview.put_recipient(self())

    # DingTalk and WeCom adapters emit atom-keyed details with atom reason
    # values. The checkpoint JSONPayload gate rejects raw atoms, so the
    # blocked state must be sanitized before it is stored.
    RecoveryReplyPreview.put_refresh_result(
      {:error,
       {:reply_delivery, :operator_action_required,
        %{reason: :auth, code: "token.notExisted", message: "invalid token"}}}
    )

    on_exit(fn ->
      RecoveryReplyPreview.delete_recipient()
      RecoveryReplyPreview.delete_refresh_result()
      Ankole.Plugins.Registry.update_for_test(fn _state -> original_state end)
    end)

    %{subject: subject, signal: signal} = addressed_signal("atom-blocked")

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(subject.uid, signal.session_id)

    terminal =
      ReplyPresentation.new(state: "working")
      |> ReplyPresentation.terminal("completed", "final answer")
      |> ReplyPresentation.checkpoint()

    checkpoint = %{
      "subject_uid" => subject.uid,
      "conversation_id" => conversation.id,
      "card_id" => "card-atom-blocked",
      "message_id" => "message-atom-blocked",
      "streaming_state" => "open",
      "presentation" => terminal,
      "cards" => [
        %{
          "index" => 0,
          "card_id" => "card-atom-blocked",
          "message_id" => "message-atom-blocked",
          "streaming_state" => "open"
        }
      ],
      "active_card_index" => 0
    }

    signal =
      signal
      |> Ankole.PreviewFixtures.update!(%{
        completed_at: DateTime.utc_now(:microsecond),
        checkpoint: checkpoint,
        provider_message_id: "message-atom-blocked"
      })

    Ankole.SignalsFixtures.delivery_fixture!(%{
      agent_uid: signal.agent_uid,
      binding_name: signal.reply_binding_name,
      outbound_key: "atom-blocked:#{signal.id}",
      delivery_class: :durable_ai_reply,
      operation: :edit,
      status: :failed,
      conversation_id: signal.conversation_id,
      target_provider_message_id: "message-atom-blocked",
      source_signal_id: signal.id,
      payload: %{"reply_presentation" => terminal},
      fallback_visible_text: "final answer",
      idempotency_key: "atom-blocked:#{signal.id}",
      attempt_count: 1,
      max_attempts: 10,
      last_error: %{},
      recovery_state: %{}
    })

    assert {:error, {:reply_delivery, :operator_action_required, _detail}} =
             Preview.recover(signal.id)

    assert_receive {:recovery_refresh, _request}

    blocked =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint

    assert blocked["recovery_state"]["state"] == "blocked"
    assert blocked["recovery_state"]["detail"]["reason"] == "auth"
    assert blocked["recovery_state"]["detail"]["code"] == "token.notExisted"
  end

  test "a plain-text fallback delegates preview recovery to durable intent ownership" do
    original_state = Ankole.Plugins.Registry.snapshot_for_test()
    {:ok, spec} = Spec.from_module(RecoverySignalProviderPlugin)

    Ankole.Plugins.Registry.update_for_test(fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    RecoveryReplyPreview.put_recipient(self())

    RecoveryReplyPreview.put_refresh_result(
      {:error,
       {:degraded, :plain_text,
        %{
          "code" => 230_099,
          "message" =>
            "Failed to create card content; ErrCode: 200780; ErrMsg: card binding biz count over limit"
        }}}
    )

    on_exit(fn ->
      RecoveryReplyPreview.delete_recipient()
      RecoveryReplyPreview.delete_refresh_result()
      Ankole.Plugins.Registry.update_for_test(fn _state -> original_state end)
    end)

    %{subject: subject, signal: signal} = addressed_signal("fallback-recover")

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(subject.uid, signal.session_id)

    terminal =
      ReplyPresentation.new(state: "working")
      |> ReplyPresentation.terminal("completed", "六张表的最终结论")
      |> ReplyPresentation.checkpoint()

    checkpoint = %{
      "subject_uid" => subject.uid,
      "conversation_id" => conversation.id,
      "card_id" => "card-fallback",
      "message_id" => "message-fallback",
      "streaming_state" => "open",
      "presentation_owner" => true,
      "presentation" => terminal,
      "cards" => [
        %{
          "index" => 0,
          "card_id" => "card-fallback",
          "message_id" => "message-fallback",
          "streaming_state" => "open"
        }
      ],
      "active_card_index" => 0
    }

    signal =
      signal
      |> Ankole.PreviewFixtures.update!(%{
        completed_at: DateTime.utc_now(:microsecond),
        checkpoint: checkpoint,
        provider_message_id: "message-fallback"
      })

    intent =
      Ankole.SignalsFixtures.delivery_fixture!(%{
        agent_uid: signal.agent_uid,
        binding_name: signal.reply_binding_name,
        outbound_key: "fallback-recover:#{signal.id}",
        delivery_class: :durable_ai_reply,
        operation: :edit,
        status: :pending,
        conversation_id: signal.conversation_id,
        target_provider_message_id: "message-fallback",
        source_signal_id: signal.id,
        payload: %{
          "reply_presentation" => terminal,
          "metadata" => %{"source" => "ai_gateway_final_reply"}
        },
        fallback_visible_text: "六张表的最终结论",
        idempotency_key: "fallback-recover:#{signal.id}",
        attempt_count: 0,
        max_attempts: 10,
        last_error: %{},
        recovery_state: %{}
      })

    assert :ok = Preview.recover(signal.id)

    assert_receive {:recovery_refresh, request}
    assert request.mode == :terminal
    assert request.checkpoint["refresh_reason"] == "terminal_recovery"

    delegated =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint

    assert delegated["presentation_owner"] == false
    assert delegated["streaming_state"] == "open"
    assert delegated["recovery_state"]["state"] == "delegated"
    assert delegated["recovery_state"]["reason"] == "plain_text_fallback"
    assert delegated["recovery_state"]["detail"]["code"] == 230_099
    refute Map.has_key?(delegated, "refresh_pending")

    assert Repo.get_by!(Intent,
             agent_uid: intent.agent_uid,
             binding_name: intent.binding_name,
             outbound_key: intent.outbound_key
           ).status == :pending

    assert {:error, :reply_preview_not_recoverable} = Preview.recover(signal.id)
    refute_receive {:recovery_refresh, _request}

    %{subject: open_subject, signal: open_event} =
      addressed_signal("fallback-open-recover")

    {:ok, open_conversation} =
      Ankole.AIGatewayCase.ensure_conversation(open_subject.uid, open_event.session_id)

    working =
      ReplyPresentation.new(state: "working")
      |> ReplyPresentation.replace_answer("仍在生成")
      |> ReplyPresentation.checkpoint()

    open_event =
      open_event
      |> Ankole.PreviewFixtures.update!(%{
        checkpoint: %{
          "subject_uid" => open_subject.uid,
          "conversation_id" => open_conversation.id,
          "card_id" => "card-open-fallback",
          "message_id" => "message-open-fallback",
          "streaming_state" => "open",
          "presentation_owner" => true,
          "presentation" => working
        },
        provider_message_id: "message-open-fallback"
      })

    assert :ok = Preview.recover(open_event.id)
    assert_receive {:recovery_refresh, open_request}
    assert open_request.mode == :working
    assert Preview.lookup(open_event.id) == []

    open_delegated =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, open_event.id)).checkpoint

    assert open_delegated["presentation_owner"] == false
    assert open_delegated["recovery_state"]["state"] == "delegated"
  end

  test "stop drains an in-flight rich mutation before terminal intent takes over" do
    %{subject: subject, signal: signal} = addressed_signal("rich-stop-drain")
    %{pid: pid} = start_dispatched_preview(subject.uid, signal)
    owner = self()

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn _request ->
        Repo.checkout(fn ->
          send(owner, {:rich_update_started, self()})

          receive do
            :finish_rich_update -> {:ok, %{}}
          end
        end)
      end,
      finalize_fun: fn _request -> {:ok, %{}} end
    }

    :sys.replace_state(pid, fn state ->
      %{state | preview_adapter: adapter, silent_rich_pending: false}
    end)

    assert :ok =
             Preview.presentation_event(signal, %{
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
    assert :ok = Preview.stop(signal)
    refute_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 100
    assert Process.alive?(task_pid)

    send(task_pid, :finish_rich_update)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 500
    refute Process.alive?(task_pid)
    assert %{rows: [[1]]} = Repo.query!("SELECT 1")
  end

  test "terminal handoff checkpoints after the bounded rich mutation settles" do
    %{subject: subject, signal: signal} = addressed_signal("rich-stop-timeout")
    %{pid: pid} = start_dispatched_preview(subject.uid, signal)
    owner = self()

    assert {:ok, %{"sequence" => working_sequence}} =
             PreviewStates.prepare_mutation(
               signal.id,
               "working",
               "working-digest",
               Ecto.UUID.generate()
             )

    adapter = %PreviewAdapter{
      surface_ids_fun: &MockReplyPreview.surface_ids/1,
      surface_open_fun: &MockReplyPreview.surface_open?/1,
      update_fun: fn _request ->
        send(owner, {:hung_rich_update_started, self()})

        receive do
          :never_finish -> {:ok, %{}}
        end
      end,
      finalize_fun: fn _request -> {:ok, %{}} end
    }

    :sys.replace_state(pid, fn state ->
      %{state | preview_adapter: adapter, silent_rich_pending: false}
    end)

    assert :ok =
             Preview.presentation_event(signal, %{
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
    assert :ok = Preview.stop(signal)
    refute_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 100
    assert Process.alive?(task_pid)

    send(task_pid, :never_finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 500
    refute Process.alive?(task_pid)

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, signal.id)).checkpoint

    assert get_in(checkpoint, ["presentation", "plan", "items"]) == [
             %{
               "id" => "wait",
               "content" => "等待慢请求",
               "status" => "in_progress"
             }
           ]

    assert {:ok, %{"sequence" => terminal_sequence}} =
             PreviewStates.prepare_mutation(
               signal.id,
               "terminal",
               "terminal-digest",
               Ecto.UUID.generate()
             )

    assert terminal_sequence > working_sequence
  end

  defp addressed_signal(suffix) do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    {:ok, %{signal: signal}} =
      Ankole.SessionsCase.emit_entry(
        subject.uid,
        "mock",
        group_entry(%{
          source_event_id: "preview-#{suffix}-event",
          conversation_id: "mock:chat:preview-#{suffix}",
          provider_message_id: "human-message-#{suffix}",
          provider_thread_id: "mock-thread-#{suffix}",
          explicit: true,
          text: "ping"
        }),
        now: base_time()
      )

    %{subject: subject, signal: signal}
  end

  defp start_dispatched_preview(subject_uid, signal) do
    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(subject_uid, signal.session_id)

    assert :ok =
             Preview.maybe_start_for(signal, subject_uid, conversation.id)

    on_exit(fn ->
      Repo.with_tenant(signal.tenant_id, fn -> stop_preview_and_wait(signal.id) end)
    end)

    {:ok, response} =
      start_response_run(%{
        subject_uid: subject_uid,
        conversation_id: conversation.id,
        request_items: [%{"role" => "user", "content" => "ping"}],
        metadata: request_metadata(%{"signal_id" => signal.id})
      })

    assert [{pid, _value}] =
             Preview.lookup(signal.id)

    %{conversation: conversation, response: response, pid: pid}
  end

  defp steer_signal(subject_uid, source_event, suffix) do
    assert {:ok, %{status: :accepted, signal: %Signal{} = steer_event}} =
             Ankole.Conversations.Observe.emit_entry(
               subject_uid,
               source_event.reply_binding_name,
               group_entry(%{
                 source_event_id: "preview-#{suffix}-event",
                 conversation_id: source_event.conversation_id,
                 provider_message_id: "human-message-#{suffix}",
                 provider_thread_id: source_event.provider_thread_id,
                 explicit: true,
                 text: "/steer 继续"
               }),
               now: DateTime.add(base_time(), 1, :second)
             )

    steer_event
  end

  defp persist_preview_request(request, streaming_state) do
    event = Repo.get!(Signal, request.signal.id)

    checkpoint =
      (Ankole.Conversations.Delivery.PreviewStates.get(event).checkpoint || %{})
      |> Map.put("card_id", "card-#{event.id}")
      |> Map.put("message_id", "message-#{event.id}")
      |> Map.put("streaming_state", streaming_state)
      |> Map.put("subject_uid", request.subject_uid)
      |> Map.put("conversation_id", request.conversation_id)
      |> Map.put("presentation", ReplyPresentation.checkpoint(request.presentation))

    {:ok, event} = PreviewStates.put_checkpoint(event.id, checkpoint)

    {:ok,
     %{
       reply_preview_checkpoint:
         Ankole.Conversations.Delivery.PreviewStates.get(event).checkpoint,
       created_provider_message_id: "message-#{event.id}"
     }}
  end

  defp request_metadata(metadata), do: %{"request_metadata" => metadata}

  defp stop_preview_and_wait(signal_id) do
    case Preview.lookup(signal_id) do
      [{pid, _value}] ->
        monitor = Process.monitor(pid)
        :ok = Preview.stop(signal_id)

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
    original_state = Ankole.Plugins.Registry.snapshot_for_test()
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    Ankole.Plugins.Registry.update_for_test(fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    on_exit(fn ->
      Ankole.Plugins.Registry.update_for_test(fn _state -> original_state end)
    end)

    :ok
  end

  defp scheduled_signal_fixture(agent_uid, opts) do
    signal =
      external_session_signal_fixture(agent_uid,
        binding_name: "mock",
        type: "check_back_later.wakeup"
      )

    Ankole.PreviewFixtures.update!(
      signal,
      Map.merge(%{data: %{"wake_payload" => %{}}}, Map.new(opts))
    )
  end

  # The owner Session receives the Workflow outcome only through these wakeup
  # turns; a type missing from the eligibility list silences the whole run.
  test "Workflow run wakeups are conversation-reply eligible like Job wakeups" do
    base = %Signal{
      conversation_id: Ecto.UUID.generate(),
      reply_binding_name: "lark",
      type: "workflow.run.completed"
    }

    for type <- ["workflow.run.completed", "workflow.run.failed", "workflow.run.attention"] do
      assert Preview.channel_reply_eligible?(%{base | type: type})
    end

    refute Preview.channel_reply_eligible?(%{base | type: "workflow.task.dispatch"})
    refute Preview.channel_reply_eligible?(%{base | conversation_id: nil})
  end
end
