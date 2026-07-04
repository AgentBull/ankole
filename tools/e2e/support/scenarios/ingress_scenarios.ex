defmodule Ankole.E2E.Scenarios.Ingress do
  @moduledoc """
  Lark ingress, queueing, retry, and compression scenarios for the Docker worker.

  Every scenario takes a `ctx` map (`:agent`, `:fake_feishu`, `:container`, ...)
  and drives the chain fake-Feishu-WS → real adapter ingress → real worker →
  fake LLM → real outbox HTTP → fake-Feishu-visible message.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      deadline: 1,
      seed_compression_history!: 2,
      wait_for_completed_final_reply: 3,
      wait_for_completed_outbox: 3,
      wait_for_worker_projection: 3,
      ai_messages_for_actor_event: 1
    ]

  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Actors.ActorEvent
  alias Ankole.E2E.FakeFeishu
  alias Ankole.Repo
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Entry

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  def run_lark_adapter_guardrails(%{fake_feishu: fake_feishu, agent: agent}) do
    before_inputs = Repo.aggregate(ActorEvent, :count)
    before_entries = Repo.aggregate(Entry, :count)

    # Bot-authored echoes must not wake the agent. The ack proves the event
    # was fully dispatched before the "nothing happened" assertions run.
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_bot_echo_1",
               message_id: "om_bot_echo_1",
               sender_type: "bot",
               sender_user_id: "ou_bot",
               text: "@_user_1 this should not echo"
             )

    wait_for_event_ack!(fake_feishu, "evt_bot_echo_1")
    finalize_due_inbound_batches!()

    assert Repo.aggregate(ActorEvent, :count) == before_inputs
    assert Repo.aggregate(Entry, :count) == before_entries
    refute pending_actor_event(agent.uid, "om_bot_echo_1")
  end

  def run_unaddressed_ignore_guardrail(%{fake_feishu: fake_feishu, agent: agent}) do
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_ignored_unaddressed_1",
               message_id: "om_ignored_unaddressed_1",
               chat_id: "oc_chaos_ignore",
               chat_type: "group",
               text: "This unaddressed group line must not wake the agent.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 250, :millisecond), :millisecond)
             )

    wait_for_event_ack!(fake_feishu, "evt_ignored_unaddressed_1")
    finalize_due_inbound_batches!()

    refute Repo.get_by(Entry,
             signal_channel_id: "lark:oc_chaos_ignore",
             source_entry_id: "om_ignored_unaddressed_1"
           )

    refute Repo.get_by(ActorEvent,
             agent_uid: agent.uid,
             source_entry_id: "om_ignored_unaddressed_1"
           )
  end

  def run_observe_all_record_only_projection(%{fake_feishu: fake_feishu, agent: agent}) do
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_record_only_1",
               message_id: "om_record_only_1",
               chat_id: "oc_chaos_record",
               chat_type: "group",
               text: "This observe_all line should be mirrored only.",
               mentions: [],
               to_app: record_app_id(),
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 350, :millisecond), :millisecond)
             )

    assert %Entry{text: "This observe_all line should be mirrored only."} =
             wait_for_signal_entry!("lark:oc_chaos_record", "om_record_only_1")

    finalize_due_inbound_batches!()

    refute Repo.get_by(ActorEvent,
             agent_uid: agent.uid,
             source_entry_id: "om_record_only_1"
           )
  end

  def run_direct_duplicate_and_llm_retry(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    attrs = [
      event_id: "evt_direct_duplicate_1",
      message_id: "om_direct_1",
      chat_id: "oc_chaos_direct",
      text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
      mentions: [mention],
      create_time_ms: DateTime.to_unix(@base_time, :millisecond)
    ]

    assert :ok = FakeFeishu.State.user_sends_message(fake_feishu.state, attrs)
    assert :ok = FakeFeishu.State.user_sends_message(fake_feishu.state, attrs)

    input = actor_event_by_source_entry_id!(agent.uid, "om_direct_1")

    assert 1 ==
             ActorEvent
             |> where([input], input.agent_uid == ^agent.uid)
             |> where([input], input.source_entry_id == "om_direct_1")
             |> Repo.aggregate(:count)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(45_000))

    assert reply.text =~ "CHAOS_DIRECT_OK"
    assert_actor_event_completed!(input.id)

    %{input: input, reply: reply, message: message}
  end

  def run_channel_session_isolation(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()
    secret = "DM_ISOLATION_SECRET_ALPHA"

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
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

    seed_input = actor_event_by_source_entry_id!(agent.uid, "om_dm_isolation_seed_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               seed_input,
               DateTime.add(seed_input.available_at, 1, :second)
             )

    assert {:ok, seed_reply, seed_message} =
             wait_for_completed_final_reply(container, seed_input.id, deadline(45_000))

    assert seed_reply.text =~ "CHAOS_DM_ISOLATION_SEED_OK"
    assert_actor_event_completed!(seed_input.id)

    assert_lark_final_reply(
      fake_feishu,
      seed_reply,
      "CHAOS_DM_ISOLATION_SEED_OK",
      :reply,
      "om_dm_isolation_seed_1"
    )

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
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

    group_input = actor_event_by_source_entry_id!(agent.uid, "om_group_isolation_check_1")
    assert group_input.session_id != seed_input.session_id

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               group_input,
               DateTime.add(group_input.available_at, 1, :second)
             )

    # The DM secret must not leak into the group session's model request.
    assert_receive {:fake_llm_request, :group_isolation_check, 1, request}, 15_000
    refute request_contains_text?(request, secret)

    assert {:ok, group_reply, group_message} =
             wait_for_completed_final_reply(container, group_input.id, deadline(45_000))

    assert group_reply.text =~ "CHAOS_GROUP_ISOLATION_OK"
    assert group_message.conversation_id != seed_message.conversation_id
    assert_actor_event_completed!(group_input.id)

    %{input: group_input, reply: group_reply, message: group_message}
  end

  @doc """
  Verifies same-room bot mentions route only to the addressed Lark app binding.
  """
  def run_multi_agent_mention_isolation(%{
        fake_feishu: fake_feishu,
        agent: agent,
        secondary_agent: secondary_agent,
        container: container
      }) do
    primary = %{
      agent_uid: agent.uid,
      other_agent_uid: secondary_agent.uid,
      event_id: "evt_multi_agent_a_1",
      message_id: "om_multi_agent_a_1",
      mention: lark_bot_mention("ou_lark_bot_a", "_agent_a", "Agent A")
    }

    primary_result = run_single_agent_mention(fake_feishu, container, primary)

    assert_lark_final_reply(
      fake_feishu,
      primary_result.reply,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_multi_agent_a_1"
    )

    secondary = %{
      agent_uid: secondary_agent.uid,
      other_agent_uid: agent.uid,
      event_id: "evt_multi_agent_b_1",
      message_id: "om_multi_agent_b_1",
      mention: lark_bot_mention("ou_lark_bot_b", "_agent_b", "Agent B")
    }

    secondary_result = run_single_agent_mention(fake_feishu, container, secondary)

    assert_lark_final_reply(
      fake_feishu,
      secondary_result.reply,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_multi_agent_b_1"
    )

    %{primary: primary_result, secondary: secondary_result}
  end

  defp run_single_agent_mention(fake_feishu, container, args) do
    # One platform push reaches BOTH bots' apps; only the mentioned binding may
    # produce an actor event.
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: args.event_id,
               message_id: args.message_id,
               chat_id: "oc_chaos_multi_agent",
               chat_type: "group",
               text: "#{args.mention["key"]} Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
               mentions: [args.mention],
               to_app: [multi_a_app_id(), secondary_app_id()],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 450, :millisecond), :millisecond)
             )

    input = actor_event_by_source_entry_id!(args.agent_uid, args.message_id)

    refute Repo.get_by(ActorEvent,
             agent_uid: args.other_agent_uid,
             source_entry_id: args.message_id
           )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(45_000))

    assert reply.text =~ "CHAOS_DIRECT_OK"
    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, message: message}
  end

  def run_followup_queue(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        worker_id: worker_id
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
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

    first_input = actor_event_by_source_entry_id!(agent.uid, "om_followup_slow_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               first_input,
               DateTime.add(first_input.available_at, 1, :second)
             )

    assert_receive {:fake_llm_request, :followup_slow, 1, _request}, 15_000

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_followup_second_1",
               message_id: "om_followup_second_1",
               chat_id: "oc_chaos_followup",
               chat_type: "p2p",
               text: "Follow-up while you are busy: reply exactly CHAOS_FOLLOWUP_SECOND_OK.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 700, :millisecond), :millisecond)
             )

    second_input = actor_event_by_source_entry_id!(agent.uid, "om_followup_second_1")

    # While the first turn is live, the queued follow-up must not start.
    assert {:ok, %{status: :idle}} =
             process_ready_event_for_actor!(
               second_input,
               DateTime.add(second_input.available_at, 1, :second)
             )

    assert {:ok, first_reply, _first_message} =
             wait_for_completed_final_reply(container, first_input.id, deadline(60_000))

    assert first_reply.text =~ "CHAOS_FOLLOWUP_FIRST_OK"
    assert_actor_event_completed!(first_input.id)
    assert %ActorEvent{completed_at: nil} = Repo.get(ActorEvent, second_input.id)
    assert {:ok, _worker} = wait_for_worker_projection(worker_id, container, deadline(15_000))

    assert_lark_final_reply(
      fake_feishu,
      first_reply,
      "CHAOS_FOLLOWUP_FIRST_OK",
      :reply,
      "om_followup_slow_1"
    )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               second_input,
               DateTime.add(second_input.available_at, 2, :second)
             )

    assert {:ok, second_reply, second_message} =
             wait_for_completed_final_reply(container, second_input.id, deadline(60_000))

    assert second_reply.text =~ "CHAOS_FOLLOWUP_SECOND_OK"
    assert_actor_event_completed!(second_input.id)

    assert_lark_final_reply(
      fake_feishu,
      second_reply,
      "CHAOS_FOLLOWUP_SECOND_OK",
      :reply,
      "om_followup_second_1"
    )

    %{input: second_input, reply: second_reply, message: second_message}
  end

  def run_recalled_followup_queue(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
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

    first_input = actor_event_by_source_entry_id!(agent.uid, "om_followup_recall_slow_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               first_input,
               DateTime.add(first_input.available_at, 1, :second)
             )

    assert_receive {:fake_llm_request, :followup_recall_slow, 1, _request}, 15_000

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_followup_recalled_1",
               message_id: "om_followup_recalled_1",
               chat_id: "oc_chaos_followup_recall",
               chat_type: "p2p",
               text: "Queued follow-up: CHAOS_RECALLED_FOLLOWUP_SHOULD_NOT_RUN.",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 900, :millisecond), :millisecond)
             )

    recalled_input = actor_event_by_source_entry_id!(agent.uid, "om_followup_recalled_1")

    assert {:ok, %{status: :idle}} =
             process_ready_event_for_actor!(
               recalled_input,
               DateTime.add(recalled_input.available_at, 1, :second)
             )

    assert :ok =
             FakeFeishu.State.user_recalls_message(fake_feishu.state,
               event_id: "evt_followup_recall_removed_1",
               message_id: "om_followup_recalled_1",
               chat_id: "oc_chaos_followup_recall",
               chat_type: "p2p",
               recall_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 1_000, :millisecond), :millisecond)
             )

    wait_for_event_ack!(fake_feishu, "evt_followup_recall_removed_1")

    assert {:ok, first_reply, _message} =
             wait_for_completed_final_reply(container, first_input.id, deadline(60_000))

    assert first_reply.text =~ "CHAOS_FOLLOWUP_RECALL_FIRST_OK"
    assert_actor_event_completed!(first_input.id)

    # The recalled queued follow-up must never start a turn once the busy turn
    # finished: whatever remains of it must not be processable.
    assert {:ok, %{status: :idle}} =
             process_ready_event_for_actor!(
               recalled_input,
               DateTime.add(recalled_input.available_at, 3, :second)
             )

    assert_actor_event_finished!(recalled_input.id)
    refute Repo.get_by(OutboxEntry, reply_to_source_entry_id: "om_followup_recalled_1")
    assert Map.get(Ankole.E2E.FakeOpenAIState.counters(), :recalled_followup, 0) == 0

    assert_lark_final_reply(
      fake_feishu,
      first_reply,
      "CHAOS_FOLLOWUP_RECALL_FIRST_OK",
      :reply,
      "om_followup_recall_slow_1"
    )

    %{input: first_input, reply: first_reply}
  end

  def run_retry_command(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_retry_1",
               message_id: "om_retry_1",
               chat_id: "oc_chaos_direct",
               chat_type: "p2p",
               text: "/retry",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 500, :millisecond), :millisecond)
             )

    command_event = actor_event_by_source_entry_id!(agent.uid, "om_retry_1")
    assert command_event.type == "command.retry"

    assert {:ok, %{status: :command_consumed, retry_actor_event: retry_event}} =
             process_ready_event_for_actor!(
               command_event,
               DateTime.add(command_event.available_at, 1, :second)
             )

    assert_actor_event_finished!(command_event.id)
    refute Repo.get_by(OutboxEntry, source_actor_event_id: command_event.id)

    retry_event = Repo.get!(ActorEvent, retry_event.id)
    assert retry_event.source_entry_id == "om_retry_1"
    assert get_in(retry_event.payload, ["data", "entry", "text"]) =~ "CHAOS_DIRECT_OK"

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               retry_event,
               DateTime.add(retry_event.available_at, 1, :second)
             )

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, retry_event.id, deadline(60_000))

    assert reply.text =~ "CHAOS_DIRECT_OK"
    assert_actor_event_completed!(retry_event.id)

    %{input: retry_event, reply: reply, message: message}
  end

  @doc """
  Runs `/compress` and asserts the compaction fact plus the operator feedback.
  """
  def run_compress_command(
        %{fake_feishu: fake_feishu, agent: agent, container: container},
        _conversation_id
      ) do
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_compress_1",
               message_id: "om_compress_1",
               chat_id: "oc_chaos_direct",
               chat_type: "p2p",
               text: "/compress",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 1, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_compress_1")
    conversation_id = active_conversation_id_for_input!(agent.uid, input.session_id)
    compressed_seed_message_ids = seed_compression_history!(agent.uid, conversation_id)

    assert {:ok, %{status: :command_consumed, feedback: "Conversation compressed."}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox, _message} =
             wait_for_completed_outbox(container, input.id, deadline(60_000))

    assert outbox.payload == %{"text" => "Conversation compressed."}

    assert %Message{type: "compaction", covers_until_message_id: covers_until_message_id} =
             Message
             |> where([message], message.conversation_id == ^conversation_id)
             |> where([message], message.type == "compaction")
             |> order_by([message], desc: message.inserted_at, desc: message.id)
             |> limit(1)
             |> Repo.one()

    assert covers_until_message_id in compressed_seed_message_ids
    assert_actor_event_completed!(input.id)

    dispatch_and_assert_lark_outbox(
      fake_feishu,
      outbox,
      "Conversation compressed.",
      :reply,
      "om_compress_1"
    )

    %{input: input, outbox: outbox, messages: ai_messages_for_actor_event(input.id)}
  end

  defp active_conversation_id_for_input!(agent_uid, session_id) do
    Repo.one!(
      from(conversation in Conversation,
        where: conversation.agent_uid == ^String.downcase(agent_uid),
        where: conversation.conversation_key == ^session_id,
        where: is_nil(conversation.ended_at),
        select: conversation.id
      )
    )
  end

  defp request_contains_text?(value, needle) when is_map(value) do
    value
    |> Map.values()
    |> Enum.any?(&request_contains_text?(&1, needle))
  end

  defp request_contains_text?(value, needle) when is_list(value) do
    Enum.any?(value, &request_contains_text?(&1, needle))
  end

  defp request_contains_text?(value, needle) when is_binary(value) do
    String.contains?(value, needle) or
      case decode_embedded_json(value) do
        {:ok, decoded} -> request_contains_text?(decoded, needle)
        :error -> false
      end
  end

  defp request_contains_text?(_value, _needle), do: false

  defp decode_embedded_json(value) do
    trimmed = String.trim(value)

    if String.starts_with?(trimmed, ["{", "["]) do
      case Ankole.JSON.decode(trimmed) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _reason} -> :error
      end
    else
      :error
    end
  end
end
