defmodule Ankole.E2E.Scenarios.Lifecycle do
  @moduledoc """
  Cancellation, command, steering, ambient, and entry-lifecycle scenarios.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      deadline: 1,
      wait_for_signal_dead_letter: 3,
      wait_for_signal_completed: 3,
      wait_for_completed_final_reply: 3,
      wait_for_turn_status: 4,
      wait_for_worker: 2,
      ai_messages_for_signal: 1
    ]

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Signals.Signal
  alias Ankole.Repo

  alias Ankole.Conversations.Delivery.Intent

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  def run_malformed_stream_failure(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_malformed_stream_1",
               message_id: "om_malformed_stream_1",
               chat_id: "oc_chaos_malformed",
               text:
                 "@_user_1 Trigger CHAOS_MALFORMED_STREAM and verify the worker fails the turn instead of hanging.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5, :second), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_malformed_stream_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, %Message{status: :error} = failed_message} =
             wait_for_turn_status(container, input.id, "failed", deadline(45_000))

    assert {:ok, %Signal{status: :dead_letter, dead_letter_at: %DateTime{}}} =
             wait_for_signal_dead_letter(container, input.id, deadline(5_000))

    expected_notice =
      Ankole.I18n.t("conversations.delivery.reply.dead_letter", %{"ref" => input.id})

    refute expected_notice == "conversations.delivery.reply.dead_letter"

    notice =
      Repo.get_by!(Intent,
        source_signal_id: input.id,
        outbound_key: "ai-dead-letter:#{input.id}"
      )

    assert notice.fallback_visible_text == expected_notice

    dispatch_and_assert_lark_intent(
      fake_feishu,
      notice,
      expected_notice,
      :reply,
      "om_malformed_stream_1"
    )

    %{input: input, message: failed_message}
  end

  def run_recall_during_generation(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_recall_slow_1",
               message_id: "om_recall_slow_1",
               chat_id: "oc_chaos_recall_active",
               chat_type: "p2p",
               text: "@_user_1 Trigger CHAOS_RECALL_SLOW and keep streaming until recalled.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_500, :millisecond), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_recall_slow_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert_receive {:fake_llm_request, :slow_recall_stream, 1, _request}, 15_000

    assert :ok =
             FakeFeishu.State.user_recalls_message(fake_feishu.state,
               event_id: "evt_recall_active_1",
               message_id: "om_recall_slow_1",
               chat_id: "oc_chaos_recall_active",
               chat_type: "p2p",
               recall_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_800, :millisecond), :millisecond)
             )

    assert {:ok, %Message{status: :error} = cancelled_message} =
             wait_for_turn_status(container, input.id, "cancelled", deadline(30_000))

    assert [] =
             Intent
             |> where([intent], intent.source_signal_id == ^input.id)
             |> Repo.all()

    assert_signal_finished!(input.id)

    assert {:ok, _worker} = wait_for_worker(container, deadline(30_000))
    %{input: input, message: cancelled_message}
  end

  def run_stop_command_abort(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_stop_slow_1",
               message_id: "om_stop_slow_1",
               chat_id: "oc_chaos_stop",
               chat_type: "p2p",
               text: "@_user_1 Trigger CHAOS_SLOW_STOP and keep streaming until I send /stop.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 6, :second), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_stop_slow_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert_receive {:fake_llm_request, :slow_stop_stream, 1, _request}, 15_000

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_stop_1",
               message_id: "om_stop_1",
               chat_id: "oc_chaos_stop",
               chat_type: "p2p",
               text: "/stop",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 7, :second), :millisecond)
             )

    stop_input = signal_by_provider_message_id!(agent.uid, "om_stop_1")
    assert stop_input.type == "command.stop"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               stop_input,
               DateTime.add(stop_input.available_at, 1, :second)
             )

    assert {:ok, _worker} = wait_for_worker(container, deadline(15_000))

    assert {:ok, %Message{status: :error} = cancelled_message} =
             wait_for_turn_status(container, input.id, "cancelled", deadline(30_000))

    assert [] =
             Intent
             |> where([intent], intent.source_signal_id == ^input.id)
             |> Repo.all()

    assert_signal_finished!(input.id)
    assert_signal_finished!(stop_input.id)

    intent = Repo.get_by!(Intent, source_signal_id: stop_input.id)
    assert intent.payload == %{"text" => "Stopped."}

    dispatch_and_assert_lark_intent(fake_feishu, intent, "Stopped.", :reply, "om_stop_1")
    %{input: input, stop_input: stop_input, message: cancelled_message}
  end

  def run_new_during_generation(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_new_slow_1",
               message_id: "om_new_slow_1",
               chat_id: "oc_chaos_new_active",
               chat_type: "p2p",
               text: "@_user_1 Trigger CHAOS_SLOW_NEW and keep streaming until I send /new.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 7_100, :millisecond), :millisecond)
             )

    old_input = signal_by_provider_message_id!(agent.uid, "om_new_slow_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               old_input,
               DateTime.add(old_input.available_at, 1, :second)
             )

    assert_receive {:fake_llm_request, :slow_new_stream, 1, _request}, 15_000

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_new_active_1",
               message_id: "om_new_active_1",
               chat_id: "oc_chaos_new_active",
               chat_type: "p2p",
               text: "/new Reply exactly CHAOS_NEW_AFTER_OK and do not call tools.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 7_200, :millisecond), :millisecond)
             )

    new_input = signal_by_provider_message_id!(agent.uid, "om_new_active_1")
    assert new_input.type == "command.new"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               new_input,
               DateTime.add(new_input.available_at, 1, :second)
             )

    assert {:ok, %Message{status: :error} = old_message} =
             wait_for_turn_status(container, old_input.id, "cancelled", deadline(30_000))

    assert [] =
             Intent
             |> where([intent], intent.source_signal_id == ^old_input.id)
             |> Repo.all()

    assert_signal_finished!(old_input.id)

    assert {:ok, new_reply, new_message} =
             wait_for_completed_final_reply(container, new_input.id, deadline(60_000))

    assert new_reply.message.text =~ "CHAOS_NEW_AFTER_OK"
    assert new_message.conversation_id != old_message.conversation_id
    assert_signal_completed!(new_input.id)

    assert_lark_final_reply(
      fake_feishu,
      new_reply,
      "CHAOS_NEW_AFTER_OK",
      :reply,
      "om_new_active_1"
    )

    %{input: new_input, reply: new_reply, message: new_message}
  end

  def run_steer_during_tool_boundary(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_steer_tool_1",
               message_id: "om_steer_tool_1",
               chat_id: "oc_chaos_steer",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_STEER_TOOL, then wait for my steering instruction before replying.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 7_500, :millisecond), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_steer_tool_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert_receive {:fake_llm_request, :steer_tool, 1, _request}, 15_000

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_steer_1",
               message_id: "om_steer_1",
               chat_id: "oc_chaos_steer",
               chat_type: "p2p",
               text: "/steer Reply exactly CHAOS_STEERED_OK and do not call any more tools.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 7_750, :millisecond), :millisecond)
             )

    steer_input = signal_by_provider_message_id!(agent.uid, "om_steer_1")
    assert steer_input.type == "command.steer"

    assert {:ok, %{status: :driving, pid: steer_driver}} =
             ensure_input_driver!(steer_input, DateTime.add(steer_input.available_at, 1, :second))

    assert steer_driver == Ankole.Sessions.driver_pid(input)

    # A steer injected by the Driver owns the final reply and its intent, so the
    # completion is observed on the steer event rather than the event that opened
    # the Turn. That is also the reply target asserted below.
    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, steer_input.id, deadline(90_000))

    assert reply.message.text =~ "CHAOS_STEERED_OK"

    messages = ai_messages_for_signal(input.id)
    assert command_tool_succeeded?(messages)
    assert_signal_completed!(input.id)
    assert_signal_finished!(steer_input.id)
    assert {:ok, _worker} = wait_for_worker(container, deadline(30_000))

    assert_lark_final_reply(
      fake_feishu,
      reply,
      "CHAOS_STEERED_OK",
      :reply,
      "om_steer_1"
    )

    %{input: input, reply: reply}
  end

  def run_idle_steer_generation(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_idle_steer_1",
               message_id: "om_idle_steer_1",
               chat_id: "oc_chaos_steer",
               chat_type: "p2p",
               text: "/steer Reply exactly CHAOS_IDLE_STEER_OK without tools.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 8, :second), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_idle_steer_1")
    assert input.type == "command.steer"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(60_000))

    assert reply.message.text =~ "CHAOS_IDLE_STEER_OK"
    assert_signal_completed!(input.id)

    assert_lark_final_reply(
      fake_feishu,
      reply,
      "CHAOS_IDLE_STEER_OK",
      :reply,
      "om_idle_steer_1"
    )

    %{input: input, reply: reply, message: message}
  end

  def run_ambient_intervention(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    now = DateTime.add(@base_time, 10, :second)

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_ambient_1",
               message_id: "om_ambient_1",
               chat_id: "oc_chaos_ambient",
               text:
                 "Could the agent handle this release handoff for the group? Reply exactly CHAOS_AMBIENT_OK.",
               mentions: [],
               to_app: ambient_app_id(),
               create_time_ms: DateTime.to_unix(now, :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_ambient_1")
    assert input.type == "im.message.may_intervene"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(60_000))

    assert reply.message.text =~ "CHAOS_AMBIENT_OK"

    assert {:ok, _event} =
             wait_for_signal_completed(container, input.id, deadline(30_000))

    assert_lark_final_reply(
      fake_feishu,
      reply,
      "CHAOS_AMBIENT_OK",
      :post,
      "oc_chaos_ambient"
    )

    %{input: input, reply: reply}
  end

  def run_ambient_silent_batch(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    first_at = DateTime.add(@base_time, 8, :second)
    second_at = DateTime.add(first_at, 400, :millisecond)

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_ambient_silent_1",
               message_id: "om_ambient_silent_1",
               chat_id: "oc_chaos_ambient_silent",
               text: "CHAOS_AMBIENT_IGNORE FYI only: deploy finished.",
               mentions: [],
               to_app: ambient_app_id(),
               create_time_ms: DateTime.to_unix(first_at, :millisecond)
             )

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_ambient_silent_2",
               message_id: "om_ambient_silent_2",
               chat_id: "oc_chaos_ambient_silent",
               text: "CHAOS_AMBIENT_IGNORE Acknowledged by the team; no reply needed.",
               mentions: [],
               to_app: ambient_app_id(),
               create_time_ms: DateTime.to_unix(second_at, :millisecond)
             )

    assert 200 = wait_for_event_ack!(fake_feishu, "evt_ambient_silent_1")
    assert 200 = wait_for_event_ack!(fake_feishu, "evt_ambient_silent_2")
    wait_for_message_observation!("lark:oc_chaos_ambient_silent", "om_ambient_silent_1")
    wait_for_message_observation!("lark:oc_chaos_ambient_silent", "om_ambient_silent_2")

    input = signal_by_provider_message_id!(agent.uid, "om_ambient_silent_2")
    assert input.type == "im.message.may_intervene"

    assert [
             %{"text" => first_text},
             %{"text" => second_text}
           ] = get_in(input.data, ["observed_messages"])

    assert first_text =~ "deploy finished"
    assert second_text =~ "no reply needed"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert_receive {:fake_llm_request, :ambient_noop_decision, 1, _request}, 15_000

    # The ambient recognizer decides to stay silent: the event completes with
    # no provider-visible intent.
    assert {:ok, completed_event} =
             wait_for_signal_completed(container, input.id, deadline(60_000))

    assert [] =
             Intent
             |> where([intent], intent.source_signal_id == ^input.id)
             |> Repo.all()

    %{input: completed_event}
  end

  def run_new_command(%{fake_feishu: fake_feishu, agent: agent}, old_conversation_id) do
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_new_1",
               message_id: "om_new_1",
               chat_id: "oc_chaos_direct",
               chat_type: "p2p",
               text: "/new",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 11, :second), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_new_1")
    assert input.type == "command.new"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert_signal_finished!(input.id)
    assert Repo.get!(Conversation, old_conversation_id).ended_at

    intent = Repo.get_by!(Intent, source_signal_id: input.id)
    assert intent.payload == %{"text" => "Started a new conversation."}

    dispatch_and_assert_lark_intent(
      fake_feishu,
      intent,
      "Started a new conversation.",
      :reply,
      "om_new_1"
    )

    %{input: input, intent: intent}
  end

  def run_recalled_entry_lifecycle(%{fake_feishu: fake_feishu, agent: agent}, conversation_id) do
    assert :ok =
             FakeFeishu.State.user_recalls_message(fake_feishu.state,
               event_id: "evt_recall_direct_1",
               message_id: "om_direct_1",
               chat_id: "oc_chaos_direct",
               chat_type: "group",
               recall_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 12, :second), :millisecond)
             )

    wait_for_message_removed!("lark:oc_chaos_direct", "om_direct_1")

    input = signal_by_provider_message_id!(agent.uid, "om_direct_1")
    assert input.type == "conversation.message.removed"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert_signal_finished!(input.id)

    refute Repo.exists?(
             Message
             |> where([message], message.conversation_id == ^conversation_id)
             |> where(
               [message],
               fragment("? #>> '{lifecycle,provider_kind}'", message.metadata) == "recalled"
             )
             |> where(
               [message],
               fragment("?->>'provider_message_id'", message.metadata) == "om_direct_1"
             )
           )

    # A late duplicate of the recalled entry must stay tombstoned.
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_late_after_recall_1",
               message_id: "om_direct_1",
               chat_id: "oc_chaos_direct",
               text: "@_user_1 This late duplicate must stay tombstoned.",
               mentions: [lark_bot_mention()],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 13, :second), :millisecond)
             )

    wait_for_event_ack!(fake_feishu, "evt_late_after_recall_1")
    finalize_due_inbound_batch_events!()

    refute message_observation("lark:oc_chaos_direct", "om_direct_1")

    refute pending_signal(agent.uid, "om_direct_1")
  end

  def run_old_conversation_recall_after_new(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_old_recall_1",
               message_id: "om_old_recall_1",
               chat_id: "oc_chaos_old_recall",
               chat_type: "p2p",
               text: "@_user_1 Reply exactly CHAOS_OLD_RECALL_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 13_500, :millisecond), :millisecond)
             )

    old_input = signal_by_provider_message_id!(agent.uid, "om_old_recall_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               old_input,
               DateTime.add(old_input.available_at, 1, :second)
             )

    assert {:ok, old_reply, old_message} =
             wait_for_completed_final_reply(container, old_input.id, deadline(60_000))

    assert old_reply.message.text =~ "CHAOS_OLD_RECALL_OK"
    assert_signal_completed!(old_input.id)

    assert_lark_final_reply(
      fake_feishu,
      old_reply,
      "CHAOS_OLD_RECALL_OK",
      :reply,
      "om_old_recall_1"
    )

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_old_recall_new_1",
               message_id: "om_old_recall_new_1",
               chat_id: "oc_chaos_old_recall",
               chat_type: "p2p",
               text: "/new Reply exactly CHAOS_AFTER_NEW_RECALL_OK.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 13_700, :millisecond), :millisecond)
             )

    new_input = signal_by_provider_message_id!(agent.uid, "om_old_recall_new_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               new_input,
               DateTime.add(new_input.available_at, 1, :second)
             )

    assert {:ok, new_reply, new_message} =
             wait_for_completed_final_reply(container, new_input.id, deadline(60_000))

    assert new_reply.message.text =~ "CHAOS_AFTER_NEW_RECALL_OK"
    assert new_message.conversation_id != old_message.conversation_id
    assert Repo.get!(Conversation, old_message.conversation_id).ended_at
    assert_signal_completed!(new_input.id)

    assert_lark_final_reply(
      fake_feishu,
      new_reply,
      "CHAOS_AFTER_NEW_RECALL_OK",
      :reply,
      "om_old_recall_new_1"
    )

    message_count_before_recall = Repo.aggregate(Message, :count)
    intent_count_before_recall = Repo.aggregate(Intent, :count)

    assert :ok =
             FakeFeishu.State.user_recalls_message(fake_feishu.state,
               event_id: "evt_old_recall_removed_1",
               message_id: "om_old_recall_1",
               chat_id: "oc_chaos_old_recall",
               chat_type: "p2p",
               recall_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 13_900, :millisecond), :millisecond)
             )

    lifecycle_event = signal_by_provider_message_id!(agent.uid, "om_old_recall_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               lifecycle_event,
               DateTime.add(lifecycle_event.available_at, 1, :second)
             )

    assert_signal_finished!(lifecycle_event.id)

    # Recalling an entry of an already-ended conversation must not rewrite any
    # durable transcript or intent facts.
    assert Repo.aggregate(Message, :count) == message_count_before_recall
    assert Repo.aggregate(Intent, :count) == intent_count_before_recall

    refute Repo.exists?(
             Message
             |> where([message], message.conversation_id == ^new_message.conversation_id)
             |> where(
               [message],
               fragment("?->>'event_id'", message.metadata) == "evt_old_recall_removed_1"
             )
           )

    %{old: old_message, new: new_message}
  end

  @doc """
  Ages a completed IM conversation past `im_max_idle_seconds` and verifies the
  next message rotates onto a successor `AIGateway` conversation with a wake briefing.
  """
  def run_cold_wake_session_recycle(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_cold_wake_seed_1",
               message_id: "om_cold_wake_seed_1",
               chat_id: "oc_chaos_cold_wake",
               chat_type: "p2p",
               text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 14_100, :millisecond), :millisecond)
             )

    seed_input = signal_by_provider_message_id!(agent.uid, "om_cold_wake_seed_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               seed_input,
               DateTime.add(seed_input.available_at, 1, :second)
             )

    assert {:ok, seed_reply, seed_message} =
             wait_for_completed_final_reply(container, seed_input.id, deadline(60_000))

    assert seed_reply.message.text =~ "CHAOS_DIRECT_OK"
    assert_signal_completed!(seed_input.id)

    assert_lark_final_reply(
      fake_feishu,
      seed_reply,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_cold_wake_seed_1"
    )

    aged_at = DateTime.add(DateTime.utc_now(:microsecond), -4 * 86_400, :second)

    {_, nil} =
      from(m in Message, where: m.conversation_id == ^seed_message.conversation_id)
      |> Repo.update_all(set: [inserted_at: aged_at, updated_at: aged_at])

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_cold_wake_after_1",
               message_id: "om_cold_wake_after_1",
               chat_id: "oc_chaos_cold_wake",
               chat_type: "p2p",
               text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 14_300, :millisecond), :millisecond)
             )

    after_input = signal_by_provider_message_id!(agent.uid, "om_cold_wake_after_1")
    assert after_input.session_id == seed_input.session_id

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               after_input,
               DateTime.add(after_input.available_at, 1, :second)
             )

    assert {:ok, after_reply, after_message} =
             wait_for_completed_final_reply(container, after_input.id, deadline(60_000))

    closed_conversation = Repo.get!(Conversation, seed_message.conversation_id)
    next_conversation = Repo.get!(Conversation, after_message.conversation_id)

    assert closed_conversation.ended_at != nil
    assert next_conversation.id != closed_conversation.id

    assert next_conversation.metadata["wake_briefing"]["previous_conversation_id"] ==
             closed_conversation.id

    assert next_conversation.metadata["wake_briefing"]["reason"] == "im_extended_idle"
    assert after_reply.message.text =~ "CHAOS_DIRECT_OK"
    assert_signal_completed!(after_input.id)

    assert_lark_final_reply(
      fake_feishu,
      after_reply,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_cold_wake_after_1"
    )

    %{seed: seed_message, after: after_message}
  end
end
