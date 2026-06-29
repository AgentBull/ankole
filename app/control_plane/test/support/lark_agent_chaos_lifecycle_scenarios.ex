defmodule Ankole.LarkAgentChaos.E2E.LifecycleScenarios do
  @moduledoc """
  Cancellation, command, steering, ambient, and entry-lifecycle scenarios.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.ActorRuntimeWorkerE2E.Scenarios,
    only: [
      command_tool_succeeded?: 1,
      deadline: 1,
      wait_for_outbox_for_input: 4,
      wait_for_outbox_matching_or_turn_terminal: 4,
      wait_for_turn_status: 4,
      wait_for_worker_projection: 3
    ]

  import Ankole.LarkAgentChaos.E2E.Harness

  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.OutboxDispatcher
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.LarkAgentChaos.FakeLarkOutbox
  alias Ankole.LarkAgentChaos.FeishuServer
  alias Ankole.Repo
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalEntry

  @base_time ~U[2026-06-24 08:00:00.000000Z]

  def run_malformed_stream_failure(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_malformed_stream_1",
               message_id: "om_malformed_stream_1",
               chat_id: "oc_chaos_malformed",
               text:
                 "@_user_1 Trigger CHAOS_MALFORMED_STREAM and verify the worker fails the turn instead of hanging.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5, :second), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_malformed_stream_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, %LlmTurn{status: "failed"} = failed_turn} =
             wait_for_turn_status(container, turn.id, "failed", deadline(45_000))

    assert [] = OutboxEntry |> where([outbox], outbox.llm_turn_id == ^turn.id) |> Repo.all()

    if input = Repo.get(ActorInput, input.id), do: Repo.delete!(input)
    failed_turn
  end

  def run_recall_during_generation(agent_uid, dispatcher, worker_id, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_recall_slow_1",
               message_id: "om_recall_slow_1",
               chat_id: "oc_chaos_recall_active",
               chat_type: "p2p",
               text: "@_user_1 Trigger CHAOS_RECALL_SLOW and keep streaming until recalled.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_500, :millisecond), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_recall_slow_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert_receive {:fake_llm_request, :slow_recall_stream, 1, _request}, 15_000

    assert {:ok, :ok} =
             FeishuServer.push_message_recalled(dispatcher,
               event_id: "evt_recall_active_1",
               message_id: "om_recall_slow_1",
               chat_id: "oc_chaos_recall_active",
               chat_type: "p2p",
               recall_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_800, :millisecond), :millisecond)
             )

    assert {:ok, %LlmTurn{status: "cancelled"} = cancelled_turn} =
             wait_for_turn_status(container, turn.id, "cancelled", deadline(30_000))

    assert [] = OutboxEntry |> where([outbox], outbox.llm_turn_id == ^turn.id) |> Repo.all()
    refute Repo.get(ActorInput, input.id)

    assert {:ok, %AgentComputerWorker{worker_id: ^worker_id}} =
             wait_for_worker_projection(worker_id, container, deadline(30_000))

    cancelled_turn
  end

  def run_stop_command_abort(agent_uid, dispatcher, worker_id, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_stop_slow_1",
               message_id: "om_stop_slow_1",
               chat_id: "oc_chaos_stop",
               chat_type: "p2p",
               text: "@_user_1 Trigger CHAOS_SLOW_STOP and keep streaming until I send /stop.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 6, :second), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_stop_slow_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert_receive {:fake_llm_request, :slow_stop_stream, 1, _request}, 15_000

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_stop_1",
               message_id: "om_stop_1",
               chat_id: "oc_chaos_stop",
               chat_type: "p2p",
               text: "/stop",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 7, :second), :millisecond)
             )

    stop_input = actor_input_by_provider_entry_id!(agent_uid, "om_stop_1")
    assert stop_input.type == "command.stop"

    assert {:ok,
            %{
              status: :command_consumed,
              feedback: "Stopped.",
              stop_control_outcomes: [%{send_outcome: "sent_or_queued"}]
            }} =
             process_ready_input_for_actor!(
               stop_input,
               DateTime.add(stop_input.available_at, 1, :second)
             )

    assert {:ok, %AgentComputerWorker{worker_id: ^worker_id}} =
             wait_for_worker_projection(worker_id, container, deadline(15_000))

    assert %LlmTurn{status: "cancelled"} = cancelled_turn = Repo.get!(LlmTurn, turn.id)
    assert [] = OutboxEntry |> where([outbox], outbox.llm_turn_id == ^turn.id) |> Repo.all()
    refute Repo.get(ActorInput, input.id)
    refute Repo.get(ActorInput, stop_input.id)

    outbox = Repo.get_by!(OutboxEntry, source_actor_input_id: stop_input.id)
    assert outbox.payload == %{"text" => "Stopped."}

    assert [{:ok, %OutboxEntry{status: :succeeded}}] =
             OutboxDispatcher.run_once(
               adapter_resolver: fn _outbox -> {:ok, FakeLarkOutbox} end,
               limit: 20
             )

    outbound_key = outbox.outbound_key
    assert_receive {:fake_lark_outbox_send, ^outbound_key, request, sent_outbox}, 2_000
    assert_lark_request_shape(request, sent_outbox, :reply, "om_stop_1")
    assert request.body.msg_type == "text"
    assert request.body.content =~ "Stopped."

    cancelled_turn
  end

  def run_new_during_generation(agent_uid, dispatcher, worker_id, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_new_slow_1",
               message_id: "om_new_slow_1",
               chat_id: "oc_chaos_new_active",
               chat_type: "p2p",
               text: "@_user_1 Trigger CHAOS_SLOW_NEW and keep streaming until I send /new.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 7_100, :millisecond), :millisecond)
             )

    old_input = actor_input_by_provider_entry_id!(agent_uid, "om_new_slow_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: old_turn}} =
             process_ready_input_for_actor!(
               old_input,
               DateTime.add(old_input.available_at, 1, :second)
             )

    assert_receive {:fake_llm_request, :slow_new_stream, 1, _request}, 15_000

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_new_active_1",
               message_id: "om_new_active_1",
               chat_id: "oc_chaos_new_active",
               chat_type: "p2p",
               text: "/new Reply exactly CHAOS_NEW_AFTER_OK and do not call tools.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 7_200, :millisecond), :millisecond)
             )

    new_input = actor_input_by_provider_entry_id!(agent_uid, "om_new_active_1")
    assert new_input.type == "command.new"

    new_turn =
      case process_ready_input_for_actor!(
             new_input,
             DateTime.add(new_input.available_at, 1, :second)
           ) do
        {:ok, %{send_outcome: "sent_or_queued", llm_turn: new_turn}} ->
          new_turn

        {:ok,
         %{
           status: :waiting_for_worker,
           command: "command.new",
           stop_control_outcomes: [%{send_outcome: "sent_or_queued"}]
         }} ->
          assert {:ok, %AgentComputerWorker{worker_id: ^worker_id}} =
                   wait_for_worker_projection(worker_id, container, deadline(30_000))

          assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: new_turn}} =
                   process_ready_input_for_actor!(
                     new_input,
                     DateTime.add(new_input.available_at, 2, :second)
                   )

          new_turn
      end

    assert Repo.get!(LlmTurn, old_turn.id).status == "cancelled"
    assert [] = OutboxEntry |> where([outbox], outbox.llm_turn_id == ^old_turn.id) |> Repo.all()
    refute Repo.get(ActorInput, old_input.id)

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, new_input.id, deadline(60_000), new_turn.id)

    assert outbox.payload["text"] =~ "CHAOS_NEW_AFTER_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_new_turn} =
             wait_for_turn_status(container, new_turn.id, "succeeded", deadline(10_000))

    assert persisted_new_turn.conversation_id != old_turn.conversation_id
    refute Repo.get(ActorInput, new_input.id)
    dispatch_and_assert_lark_outbox(new_turn, "CHAOS_NEW_AFTER_OK", :reply, "om_new_active_1")
    persisted_new_turn
  end

  def run_steer_during_tool_boundary(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
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

    input = actor_input_by_provider_entry_id!(agent_uid, "om_steer_tool_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert_receive {:fake_llm_request, :steer_tool, 1, _request}, 15_000

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_steer_1",
               message_id: "om_steer_1",
               chat_id: "oc_chaos_steer",
               chat_type: "p2p",
               text: "/steer Reply exactly CHAOS_STEERED_OK and do not call any more tools.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 7_750, :millisecond), :millisecond)
             )

    steer_input = actor_input_by_provider_entry_id!(agent_uid, "om_steer_1")
    assert steer_input.type == "command.steer"

    assert {:ok,
            %{
              status: :active_steer_nudged,
              send_outcome: "sent_or_queued",
              turn_ref: steered_turn_ref
            }} =
             process_ready_input_for_actor!(
               steer_input,
               DateTime.add(steer_input.available_at, 1, :second)
             )

    assert steered_turn_ref["llm_turn_id"] == turn.id

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_STEERED_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert command_tool_succeeded?(persisted_turn.tool_results)
    refute Repo.get(ActorInput, input.id)
    refute Repo.get(ActorInput, steer_input.id)
    persisted_turn
  end

  def run_idle_steer_generation(agent_uid, dispatcher, container) do
    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_idle_steer_1",
               message_id: "om_idle_steer_1",
               chat_id: "oc_chaos_steer",
               chat_type: "p2p",
               text: "/steer Reply exactly CHAOS_IDLE_STEER_OK without tools.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 8, :second), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_idle_steer_1")
    assert input.type == "command.steer"

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(60_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_IDLE_STEER_OK"
    assert outbox.source_provider_entry_id == "om_idle_steer_1"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  def run_ambient_intervention(agent_uid, dispatcher, container) do
    now = DateTime.add(@base_time, 10, :second)

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_ambient_1",
               message_id: "om_ambient_1",
               chat_id: "oc_chaos_ambient",
               text:
                 "Could the agent handle this release handoff for the group? Reply exactly CHAOS_AMBIENT_OK.",
               mentions: [],
               create_time_ms: DateTime.to_unix(now, :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_ambient_1")
    assert input.type == "im.message.may_intervene"

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_matching_or_turn_terminal(
               container,
               turn.id,
               deadline(60_000),
               fn outbox ->
                 outbox.source_provider_entry_id == "om_ambient_1" and
                   String.contains?(outbox.payload["text"] || "", "CHAOS_AMBIENT_OK")
               end
             )

    assert outbox.payload["text"] =~ "CHAOS_AMBIENT_OK"

    assert {:ok, %LlmTurn{status: "succeeded"}} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, input.id)
    turn
  end

  def run_ambient_silent_batch(agent_uid, dispatcher, container) do
    first_at = DateTime.add(@base_time, 8, :second)
    second_at = DateTime.add(first_at, 400, :millisecond)

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_ambient_silent_1",
               message_id: "om_ambient_silent_1",
               chat_id: "oc_chaos_ambient_silent",
               text: "CHAOS_AMBIENT_IGNORE FYI only: deploy finished.",
               mentions: [],
               create_time_ms: DateTime.to_unix(first_at, :millisecond)
             )

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_ambient_silent_2",
               message_id: "om_ambient_silent_2",
               root_id: "om_ambient_silent_1",
               chat_id: "oc_chaos_ambient_silent",
               text: "CHAOS_AMBIENT_IGNORE Acknowledged by the team; no reply needed.",
               mentions: [],
               create_time_ms: DateTime.to_unix(second_at, :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_ambient_silent_2")
    assert input.type == "im.message.may_intervene"

    assert [
             %{"text" => first_text},
             %{"text" => second_text}
           ] = get_in(input.payload, ["data", "observed_messages"])

    assert first_text =~ "deploy finished"
    assert second_text =~ "no reply needed"

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert_receive {:fake_llm_request, :ambient_noop_decision, 1, _request}, 15_000

    assert {:ok, %LlmTurn{status: "succeeded"} = succeeded_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(60_000))

    assert [] = OutboxEntry |> where([outbox], outbox.llm_turn_id == ^turn.id) |> Repo.all()
    refute Repo.get(ActorInput, input.id)
    succeeded_turn
  end

  def run_new_command(agent_uid, dispatcher, old_conversation_id) do
    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_new_1",
               message_id: "om_new_1",
               chat_id: "oc_chaos_direct",
               chat_type: "p2p",
               text: "/new",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 11, :second), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_new_1")
    assert input.type == "command.new"

    assert {:ok, %{status: :command_consumed, feedback: "Started a new conversation."}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert Repo.get!(Conversation, old_conversation_id).ended_at
    refute Repo.get(ActorInput, input.id)

    outbox = Repo.get_by!(OutboxEntry, source_actor_input_id: input.id)
    assert outbox.payload == %{"text" => "Started a new conversation."}

    assert [{:ok, %OutboxEntry{status: :succeeded}}] =
             OutboxDispatcher.run_once(
               adapter_resolver: fn _outbox -> {:ok, FakeLarkOutbox} end,
               limit: 20
             )

    assert_receive {:fake_lark_outbox_send, outbound_key, request, sent_outbox}, 2_000
    assert outbound_key == outbox.outbound_key
    assert_lark_request_shape(request, sent_outbox, :reply, "om_new_1")
    assert request.body.msg_type == "text"
    assert request.body.content =~ "Started a new conversation."
  end

  def run_recalled_entry_lifecycle(agent_uid, dispatcher, conversation_id) do
    assert {:ok, :ok} =
             FeishuServer.push_message_recalled(dispatcher,
               event_id: "evt_recall_direct_1",
               message_id: "om_direct_1",
               chat_id: "oc_chaos_direct",
               chat_type: "group",
               recall_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 12, :second), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_direct_1")
    assert input.type == "signal.entry.removed"

    refute Repo.get_by(SignalEntry,
             signal_channel_id: "lark:oc_chaos_direct",
             provider_entry_id: "om_direct_1"
           )

    assert {:ok, %{status: :entry_lifecycle_recorded, cancelled_checkbacks: 0}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert %Message{role: "user", kind: "introspection", metadata: metadata} =
             Message
             |> where([message], message.conversation_id == ^conversation_id)
             |> where([message], message.role == "user")
             |> where([message], message.kind == "introspection")
             |> where([message], message.metadata["lifecycle"]["provider_kind"] == "recalled")
             |> where([message], message.metadata["provider_entry_id"] == "om_direct_1")
             |> Repo.one()

    assert metadata["signal_channel_id"] == "lark:oc_chaos_direct"
    assert metadata["provider_thread_id"] == "lark:oc_chaos_direct:om_direct_1"
    refute Repo.get(ActorInput, input.id)

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_late_after_recall_1",
               message_id: "om_direct_1",
               chat_id: "oc_chaos_direct",
               text: "@_user_1 This late duplicate must stay tombstoned.",
               mentions: [lark_bot_mention()],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 13, :second), :millisecond)
             )

    finalize_due_inbound_batches!()

    refute Repo.get_by(SignalEntry,
             signal_channel_id: "lark:oc_chaos_direct",
             provider_entry_id: "om_direct_1"
           )

    refute Repo.get_by(ActorInput,
             agent_uid: agent_uid,
             provider_entry_id: "om_direct_1"
           )
  end

  def run_old_conversation_recall_after_new(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_old_recall_1",
               message_id: "om_old_recall_1",
               chat_id: "oc_chaos_old_recall",
               chat_type: "p2p",
               text: "@_user_1 Reply exactly CHAOS_OLD_RECALL_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 13_500, :millisecond), :millisecond)
             )

    old_input = actor_input_by_provider_entry_id!(agent_uid, "om_old_recall_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: old_turn}} =
             process_ready_input_for_actor!(
               old_input,
               DateTime.add(old_input.available_at, 1, :second)
             )

    assert {:ok, old_outbox} =
             wait_for_outbox_for_input(container, old_input.id, deadline(60_000), old_turn.id)

    assert old_outbox.payload["text"] =~ "CHAOS_OLD_RECALL_OK"

    assert {:ok, %LlmTurn{status: "succeeded"}} =
             wait_for_turn_status(container, old_turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, old_input.id)
    dispatch_and_assert_lark_outbox(old_turn, "CHAOS_OLD_RECALL_OK", :reply, "om_old_recall_1")

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_old_recall_new_1",
               message_id: "om_old_recall_new_1",
               chat_id: "oc_chaos_old_recall",
               chat_type: "p2p",
               text: "/new Reply exactly CHAOS_AFTER_NEW_RECALL_OK.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 13_700, :millisecond), :millisecond)
             )

    new_input = actor_input_by_provider_entry_id!(agent_uid, "om_old_recall_new_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: new_turn}} =
             process_ready_input_for_actor!(
               new_input,
               DateTime.add(new_input.available_at, 1, :second)
             )

    assert new_turn.conversation_id != old_turn.conversation_id
    assert Repo.get!(Conversation, old_turn.conversation_id).ended_at

    assert {:ok, new_outbox} =
             wait_for_outbox_for_input(container, new_input.id, deadline(60_000), new_turn.id)

    assert new_outbox.payload["text"] =~ "CHAOS_AFTER_NEW_RECALL_OK"

    assert {:ok, %LlmTurn{status: "succeeded"}} =
             wait_for_turn_status(container, new_turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, new_input.id)

    dispatch_and_assert_lark_outbox(
      new_turn,
      "CHAOS_AFTER_NEW_RECALL_OK",
      :reply,
      "om_old_recall_new_1"
    )

    message_count_before_recall = Repo.aggregate(Message, :count)
    turn_count_before_recall = Repo.aggregate(LlmTurn, :count)
    outbox_count_before_recall = Repo.aggregate(OutboxEntry, :count)

    assert {:ok, :ok} =
             FeishuServer.push_message_recalled(dispatcher,
               event_id: "evt_old_recall_removed_1",
               message_id: "om_old_recall_1",
               chat_id: "oc_chaos_old_recall",
               chat_type: "p2p",
               recall_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 13_900, :millisecond), :millisecond)
             )

    lifecycle_input = actor_input_by_provider_entry_id!(agent_uid, "om_old_recall_1")

    assert {:ok,
            %{
              status: :entry_lifecycle_ignored,
              lifecycle_input: processed_input,
              consumption: lifecycle_consumption
            }} =
             process_ready_input_for_actor!(
               lifecycle_input,
               DateTime.add(lifecycle_input.available_at, 1, :second)
             )

    assert processed_input.id == lifecycle_input.id
    assert lifecycle_consumption.conversation_id == old_turn.conversation_id
    refute Repo.get(ActorInput, lifecycle_input.id)

    assert Repo.aggregate(Message, :count) == message_count_before_recall
    assert Repo.aggregate(LlmTurn, :count) == turn_count_before_recall
    assert Repo.aggregate(OutboxEntry, :count) == outbox_count_before_recall

    refute Repo.get_by(Message,
             conversation_id: new_turn.conversation_id,
             event_id: "evt_old_recall_removed_1"
           )
  end

  @doc """
  Runs a `session.reset_due` barrier and verifies later input uses the successor conversation.
  """
  def run_daily_session_reset(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_daily_reset_seed_1",
               message_id: "om_daily_reset_seed_1",
               chat_id: "oc_chaos_daily_reset",
               chat_type: "p2p",
               text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 14_100, :millisecond), :millisecond)
             )

    seed_input = actor_input_by_provider_entry_id!(agent_uid, "om_daily_reset_seed_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: seed_turn}} =
             process_ready_input_for_actor!(
               seed_input,
               DateTime.add(seed_input.available_at, 1, :second)
             )

    assert {:ok, seed_outbox} =
             wait_for_outbox_for_input(container, seed_input.id, deadline(60_000), seed_turn.id)

    assert seed_outbox.payload["text"] =~ "CHAOS_DIRECT_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_seed_turn} =
             wait_for_turn_status(container, seed_turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, seed_input.id)
    dispatch_and_assert_lark_outbox(seed_turn, "CHAOS_DIRECT_OK", :reply, "om_daily_reset_seed_1")

    reset_at = DateTime.add(seed_input.available_at, 2, :second)
    reset_input = append_session_reset_due!(agent_uid, seed_input.session_id, reset_at)

    assert {:ok,
            %{
              status: :session_reset,
              closed_conversation: closed_conversation,
              conversation: next_conversation
            }} =
             process_ready_input_for_actor!(reset_input, DateTime.add(reset_at, 1, :second))

    assert closed_conversation.id == persisted_seed_turn.conversation_id
    assert next_conversation.id != closed_conversation.id
    assert Repo.get!(Conversation, closed_conversation.id).ended_at
    refute Repo.get(ActorInput, reset_input.id)

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_daily_reset_after_1",
               message_id: "om_daily_reset_after_1",
               chat_id: "oc_chaos_daily_reset",
               chat_type: "p2p",
               text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 14_300, :millisecond), :millisecond)
             )

    after_input = actor_input_by_provider_entry_id!(agent_uid, "om_daily_reset_after_1")
    assert after_input.session_id == seed_input.session_id

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: after_turn}} =
             process_ready_input_for_actor!(
               after_input,
               DateTime.add(after_input.available_at, 1, :second)
             )

    assert after_turn.conversation_id == next_conversation.id

    assert {:ok, after_outbox} =
             wait_for_outbox_for_input(container, after_input.id, deadline(60_000), after_turn.id)

    assert after_outbox.payload["text"] =~ "CHAOS_DIRECT_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_after_turn} =
             wait_for_turn_status(container, after_turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, after_input.id)

    dispatch_and_assert_lark_outbox(
      after_turn,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_daily_reset_after_1"
    )

    %{seed_turn: persisted_seed_turn, after_turn: persisted_after_turn}
  end

  defp append_session_reset_due!(agent_uid, session_id, %DateTime{} = now) do
    ingress_event_id = "session.reset_due:chaos:#{Ecto.UUID.generate()}"

    assert {:ok, reset_input} =
             Actors.append_actor_input(%{
               agent_uid: agent_uid,
               binding_name: "control-plane:session-lifecycle",
               session_id: session_id,
               ingress_event_id: ingress_event_id,
               type: "session.reset_due",
               available_at: now,
               payload: %{
                 "specversion" => "1.0",
                 "id" => ingress_event_id,
                 "source" => "control-plane://lark-chaos/session-reset",
                 "time" => DateTime.to_iso8601(now),
                 "type" => "session.reset_due",
                 "data" => %{
                   "session" => %{
                     "agent_uid" => agent_uid,
                     "session_id" => session_id,
                     "binding_name" => "control-plane:session-lifecycle"
                   },
                   "reset" => %{
                     "kind" => "daily",
                     "boundary_at" => DateTime.to_iso8601(now),
                     "timezone" => "Etc/UTC",
                     "local_time" => "04:30"
                   }
                 }
               }
             })

    reset_input
  end
end
