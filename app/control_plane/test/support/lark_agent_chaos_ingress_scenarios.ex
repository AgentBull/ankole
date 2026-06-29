defmodule Ankole.LarkAgentChaos.E2E.IngressScenarios do
  @moduledoc """
  Lark ingress, queueing, retry, and compression scenarios for the Docker worker.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.ActorRuntimeWorkerE2E.Scenarios,
    only: [
      deadline: 1,
      seed_compression_history!: 2,
      wait_for_outbox_for_input: 4,
      wait_for_turn_status: 4
    ]

  import Ankole.LarkAgentChaos.E2E.Harness

  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.ReadyInputProcessor
  alias Ankole.LarkAgentChaos.FeishuServer
  alias Ankole.Repo
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalEntry

  @base_time ~U[2026-06-24 08:00:00.000000Z]
  @long_lease_seconds 604_800

  def run_lark_adapter_guardrails(dispatcher) do
    assert {:error, _reason} = FeishuServer.malformed_frame_probe()

    before_inputs = Repo.aggregate(ActorInput, :count)
    before_entries = Repo.aggregate(SignalEntry, :count)

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_bot_echo_1",
               message_id: "om_bot_echo_1",
               sender_type: "bot",
               sender_user_id: "ou_bot",
               text: "@_user_1 this should not echo"
             )

    assert Repo.aggregate(ActorInput, :count) == before_inputs
    assert Repo.aggregate(SignalEntry, :count) == before_entries
  end

  def run_unaddressed_ignore_guardrail(agent_uid, dispatcher) do
    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_ignored_unaddressed_1",
               message_id: "om_ignored_unaddressed_1",
               chat_id: "oc_chaos_ignore",
               chat_type: "group",
               text: "This unaddressed group line must not wake the agent.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 250, :millisecond), :millisecond)
             )

    finalize_due_inbound_batches!()

    refute Repo.get_by(SignalEntry,
             signal_channel_id: "lark:oc_chaos_ignore",
             provider_entry_id: "om_ignored_unaddressed_1"
           )

    refute Repo.get_by(ActorInput,
             agent_uid: agent_uid,
             provider_entry_id: "om_ignored_unaddressed_1"
           )
  end

  def run_observe_all_record_only_projection(agent_uid, dispatcher) do
    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_record_only_1",
               message_id: "om_record_only_1",
               chat_id: "oc_chaos_record",
               chat_type: "group",
               text: "This observe_all line should be mirrored only.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 350, :millisecond), :millisecond)
             )

    finalize_due_inbound_batches!()

    assert %SignalEntry{text: "This observe_all line should be mirrored only."} =
             Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:oc_chaos_record",
               provider_entry_id: "om_record_only_1"
             )

    refute Repo.get_by(ActorInput,
             agent_uid: agent_uid,
             provider_entry_id: "om_record_only_1"
           )
  end

  def run_direct_duplicate_and_llm_retry(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    attrs = [
      event_id: "evt_direct_duplicate_1",
      message_id: "om_direct_1",
      chat_id: "oc_chaos_direct",
      text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
      mentions: [mention],
      create_time_ms: DateTime.to_unix(@base_time, :millisecond)
    ]

    assert {:ok, :ok} = FeishuServer.push_message(dispatcher, attrs)
    assert {:ok, :ok} = FeishuServer.push_message(dispatcher, attrs)

    input = actor_input_by_provider_entry_id!(agent_uid, "om_direct_1")

    assert 1 ==
             ActorInput
             |> where([input], input.agent_uid == ^agent_uid)
             |> where([input], input.provider_entry_id == "om_direct_1")
             |> Repo.aggregate(:count)

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(45_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_DIRECT_OK"

    assert {:ok, %LlmTurn{status: "succeeded"}} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, input.id)
    turn
  end

  def run_channel_session_isolation(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()
    secret = "DM_ISOLATION_SECRET_ALPHA"

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_dm_isolation_seed_1",
               message_id: "om_dm_isolation_seed_1",
               chat_id: "oc_chaos_dm_isolation",
               chat_type: "p2p",
               text:
                 "@_user_1 Remember #{secret}. Trigger CHAOS_DM_ISOLATION_SEED and reply exactly CHAOS_DM_ISOLATION_SEED_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 375, :millisecond), :millisecond)
             )

    seed_input = actor_input_by_provider_entry_id!(agent_uid, "om_dm_isolation_seed_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: seed_turn}} =
             process_ready_input_for_actor!(
               seed_input,
               DateTime.add(seed_input.available_at, 1, :second)
             )

    assert {:ok, seed_outbox} =
             wait_for_outbox_for_input(container, seed_input.id, deadline(45_000), seed_turn.id)

    assert seed_outbox.payload["text"] =~ "CHAOS_DM_ISOLATION_SEED_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_seed_turn} =
             wait_for_turn_status(container, seed_turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, seed_input.id)

    dispatch_and_assert_lark_outbox(
      persisted_seed_turn,
      "CHAOS_DM_ISOLATION_SEED_OK",
      :reply,
      "om_dm_isolation_seed_1"
    )

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_group_isolation_check_1",
               message_id: "om_group_isolation_check_1",
               chat_id: "oc_chaos_group_isolation",
               chat_type: "group",
               text:
                 "@_user_1 Trigger CHAOS_GROUP_ISOLATION_CHECK and reply exactly CHAOS_GROUP_ISOLATION_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 425, :millisecond), :millisecond)
             )

    group_input = actor_input_by_provider_entry_id!(agent_uid, "om_group_isolation_check_1")
    assert group_input.session_id != seed_input.session_id

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: group_turn}} =
             process_ready_input_for_actor!(
               group_input,
               DateTime.add(group_input.available_at, 1, :second)
             )

    assert_receive {:fake_llm_request, :group_isolation_check, 1, request}, 15_000
    refute inspect(request, limit: :infinity, printable_limit: :infinity) =~ secret

    assert {:ok, group_outbox} =
             wait_for_outbox_for_input(container, group_input.id, deadline(45_000), group_turn.id)

    assert group_outbox.payload["text"] =~ "CHAOS_GROUP_ISOLATION_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_group_turn} =
             wait_for_turn_status(container, group_turn.id, "succeeded", deadline(10_000))

    assert persisted_group_turn.conversation_id != persisted_seed_turn.conversation_id
    refute Repo.get(ActorInput, group_input.id)
    persisted_group_turn
  end

  @doc """
  Verifies same-room bot mentions route only to the addressed Lark app binding.
  """
  def run_multi_agent_mention_isolation(
        primary_agent_uid,
        primary_dispatcher,
        secondary_agent_uid,
        secondary_dispatcher,
        container
      ) do
    primary_turn =
      run_single_agent_mention(
        primary_agent_uid,
        primary_dispatcher,
        secondary_agent_uid,
        secondary_dispatcher,
        container,
        %{
          event_id: "evt_multi_agent_a_1",
          message_id: "om_multi_agent_a_1",
          mention: lark_bot_mention("ou_lark_bot_a", "_agent_a", "Agent A")
        }
      )

    dispatch_and_assert_lark_outbox(
      primary_turn,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_multi_agent_a_1"
    )

    secondary_turn =
      run_single_agent_mention(
        secondary_agent_uid,
        secondary_dispatcher,
        primary_agent_uid,
        primary_dispatcher,
        container,
        %{
          event_id: "evt_multi_agent_b_1",
          message_id: "om_multi_agent_b_1",
          mention: lark_bot_mention("ou_lark_bot_b", "_agent_b", "Agent B")
        }
      )

    dispatch_and_assert_lark_outbox(
      secondary_turn,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_multi_agent_b_1"
    )

    %{primary_turn: primary_turn, secondary_turn: secondary_turn}
  end

  def run_retry_command(agent_uid, dispatcher, container) do
    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_retry_1",
               message_id: "om_retry_1",
               chat_id: "oc_chaos_direct",
               chat_type: "p2p",
               text: "/retry",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 500, :millisecond), :millisecond)
             )

    command_input = actor_input_by_provider_entry_id!(agent_uid, "om_retry_1")
    assert command_input.type == "command.retry"

    assert {:ok, %{status: :command_consumed, retry_actor_input: retry_input}} =
             process_ready_input_for_actor!(
               command_input,
               DateTime.add(command_input.available_at, 1, :second)
             )

    refute Repo.get(ActorInput, command_input.id)
    refute Repo.get_by(OutboxEntry, source_actor_input_id: command_input.id)

    retry_input = Repo.get!(ActorInput, retry_input.id)
    assert retry_input.provider_entry_id == "om_retry_1"
    assert get_in(retry_input.payload, ["data", "entry", "text"]) =~ "CHAOS_DIRECT_OK"

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(
               retry_input,
               DateTime.add(retry_input.available_at, 1, :second)
             )

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, retry_input.id, deadline(60_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_DIRECT_OK"

    assert {:ok, %LlmTurn{kind: "retry_generation", status: "succeeded"}} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, retry_input.id)
    turn
  end

  defp run_single_agent_mention(
         target_agent_uid,
         target_dispatcher,
         other_agent_uid,
         other_dispatcher,
         container,
         attrs
       ) do
    %{event_id: event_id, message_id: message_id, mention: mention} = attrs

    push_multi_agent_message(target_dispatcher, event_id, message_id, mention)
    push_multi_agent_message(other_dispatcher, "#{event_id}_other", message_id, mention)

    input = actor_input_by_provider_entry_id!(target_agent_uid, message_id)

    refute Repo.get_by(ActorInput,
             agent_uid: other_agent_uid,
             provider_entry_id: message_id
           )

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(45_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_DIRECT_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  defp push_multi_agent_message(dispatcher, event_id, message_id, mention) do
    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: event_id,
               message_id: message_id,
               chat_id: "oc_chaos_multi_agent",
               chat_type: "group",
               text: "#{mention["key"]} Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 450, :millisecond), :millisecond)
             )
  end

  def run_followup_queue(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_followup_slow_1",
               message_id: "om_followup_slow_1",
               chat_id: "oc_chaos_followup",
               chat_type: "p2p",
               text:
                 "@_user_1 Trigger CHAOS_FOLLOWUP_SLOW and reply exactly CHAOS_FOLLOWUP_FIRST_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 600, :millisecond), :millisecond)
             )

    first_input = actor_input_by_provider_entry_id!(agent_uid, "om_followup_slow_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: first_turn}} =
             process_ready_input_for_actor!(
               first_input,
               DateTime.add(first_input.available_at, 1, :second)
             )

    assert_receive {:fake_llm_request, :followup_slow, 1, _request}, 15_000

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_followup_second_1",
               message_id: "om_followup_second_1",
               chat_id: "oc_chaos_followup",
               chat_type: "p2p",
               text: "Follow-up while you are busy: reply exactly CHAOS_FOLLOWUP_SECOND_OK.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 700, :millisecond), :millisecond)
             )

    second_input = actor_input_by_provider_entry_id!(agent_uid, "om_followup_second_1")

    assert {:ok, %{status: :idle}} =
             process_ready_input_for_actor!(
               second_input,
               DateTime.add(second_input.available_at, 1, :second)
             )

    assert {:ok, first_outbox} =
             wait_for_outbox_for_input(container, first_input.id, deadline(60_000), first_turn.id)

    assert first_outbox.payload["text"] =~ "CHAOS_FOLLOWUP_FIRST_OK"

    assert {:ok, %LlmTurn{status: "succeeded"}} =
             wait_for_turn_status(container, first_turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, first_input.id)
    assert %ActorInput{} = Repo.get(ActorInput, second_input.id)

    dispatch_and_assert_lark_outbox(
      first_turn,
      "CHAOS_FOLLOWUP_FIRST_OK",
      :reply,
      "om_followup_slow_1"
    )

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: second_turn}} =
             process_ready_input_for_actor!(
               second_input,
               DateTime.add(second_input.available_at, 2, :second)
             )

    assert {:ok, second_outbox} =
             wait_for_outbox_for_input(
               container,
               second_input.id,
               deadline(60_000),
               second_turn.id
             )

    assert second_outbox.payload["text"] =~ "CHAOS_FOLLOWUP_SECOND_OK"

    assert {:ok, %LlmTurn{status: "succeeded"}} =
             wait_for_turn_status(container, second_turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, second_input.id)

    dispatch_and_assert_lark_outbox(
      second_turn,
      "CHAOS_FOLLOWUP_SECOND_OK",
      :reply,
      "om_followup_second_1"
    )

    second_turn
  end

  def run_recalled_followup_queue(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_followup_recall_slow_1",
               message_id: "om_followup_recall_slow_1",
               chat_id: "oc_chaos_followup_recall",
               chat_type: "p2p",
               text:
                 "@_user_1 Trigger CHAOS_FOLLOWUP_RECALL_SLOW and reply exactly CHAOS_FOLLOWUP_RECALL_FIRST_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 800, :millisecond), :millisecond)
             )

    first_input = actor_input_by_provider_entry_id!(agent_uid, "om_followup_recall_slow_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: first_turn}} =
             process_ready_input_for_actor!(
               first_input,
               DateTime.add(first_input.available_at, 1, :second)
             )

    assert_receive {:fake_llm_request, :followup_recall_slow, 1, _request}, 15_000

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_followup_recalled_1",
               message_id: "om_followup_recalled_1",
               chat_id: "oc_chaos_followup_recall",
               chat_type: "p2p",
               text: "Queued follow-up: CHAOS_RECALLED_FOLLOWUP_SHOULD_NOT_RUN.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 900, :millisecond), :millisecond)
             )

    recalled_input = actor_input_by_provider_entry_id!(agent_uid, "om_followup_recalled_1")

    assert {:ok, %{status: :idle}} =
             process_ready_input_for_actor!(
               recalled_input,
               DateTime.add(recalled_input.available_at, 1, :second)
             )

    assert {:ok, :ok} =
             FeishuServer.push_message_recalled(dispatcher,
               event_id: "evt_followup_recall_removed_1",
               message_id: "om_followup_recalled_1",
               chat_id: "oc_chaos_followup_recall",
               chat_type: "p2p",
               recall_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 1_000, :millisecond), :millisecond)
             )

    refute Repo.get(ActorInput, recalled_input.id)

    assert {:ok, first_outbox} =
             wait_for_outbox_for_input(container, first_input.id, deadline(60_000), first_turn.id)

    assert first_outbox.payload["text"] =~ "CHAOS_FOLLOWUP_RECALL_FIRST_OK"

    assert {:ok, %LlmTurn{status: "succeeded"}} =
             wait_for_turn_status(container, first_turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, first_input.id)

    assert {:ok, %{status: :idle}} =
             ReadyInputProcessor.process_ready_inputs_for_actor(
               %{agent_uid: agent_uid, session_id: recalled_input.session_id},
               now: DateTime.add(recalled_input.available_at, 3, :second),
               lease_seconds: @long_lease_seconds
             )

    refute Repo.get_by(OutboxEntry, source_provider_entry_id: "om_followup_recalled_1")

    dispatch_and_assert_lark_outbox(
      first_turn,
      "CHAOS_FOLLOWUP_RECALL_FIRST_OK",
      :reply,
      "om_followup_recall_slow_1"
    )

    first_turn
  end

  def run_compress_command(agent_uid, dispatcher, container, conversation_id) do
    compressed_seed_message_ids = seed_compression_history!(agent_uid, conversation_id)

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_compress_1",
               message_id: "om_compress_1",
               chat_id: "oc_chaos_direct",
               chat_type: "p2p",
               text: "/compress",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 1, :second), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_compress_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(60_000), turn.id)

    assert outbox.payload == %{"text" => "Conversation compressed."}

    compression_turn = Repo.get!(LlmTurn, turn.id)
    assert compression_turn.status == "succeeded"
    assert compression_turn.provider_metadata["profile"] == "light"

    assert %Message{kind: "summary", covers_range: %{"message_ids" => covered_message_ids}} =
             Message
             |> where([message], message.conversation_id == ^compression_turn.conversation_id)
             |> where([message], message.kind == "summary")
             |> where([message], message.event_id == ^compression_turn.id)
             |> Repo.one()

    assert Enum.any?(compressed_seed_message_ids, &(&1 in covered_message_ids))

    refute Repo.get(ActorInput, input.id)
    compression_turn
  end
end
