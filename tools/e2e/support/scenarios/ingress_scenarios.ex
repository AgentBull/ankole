defmodule Ankole.E2E.Scenarios.Observe do
  @moduledoc """
  Lark ingress, queueing, retry, and compression scenarios for the Docker worker.

  Every scenario takes a `ctx` map (`:agent`, `:fake_feishu`, `:container`, ...)
  and drives the chain fake-Feishu-WS → real adapter ingress → real worker →
  fake LLM → real intent HTTP → fake-Feishu-visible message.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      deadline: 1,
      seed_compression_history!: 2,
      wait_for_completed_final_reply: 3,
      wait_for_signal_completed: 3,
      ai_messages_for_signal: 1
    ]

  alias Ankole.E2E.DockerWorker
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Signals.Signal
  alias Ankole.Repo
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Message, as: ConversationMessage

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  def run_lark_adapter_guardrails(%{fake_feishu: fake_feishu, agent: agent}) do
    before_inputs = Repo.aggregate(Signal, :count)
    before_entries = Repo.aggregate(ConversationMessage, :count)

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
    finalize_due_inbound_batch_events!()

    assert Repo.aggregate(Signal, :count) == before_inputs
    assert Repo.aggregate(ConversationMessage, :count) == before_entries
    refute pending_signal(agent.uid, "om_bot_echo_1")
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
    finalize_due_inbound_batch_events!()

    refute message_observation("lark:oc_chaos_ignore", "om_ignored_unaddressed_1")

    refute Repo.get_by(Signal,
             agent_uid: agent.uid,
             provider_message_id: "om_ignored_unaddressed_1"
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

    assert %{
             message: %ConversationMessage{text: "This observe_all line should be mirrored only."}
           } =
             wait_for_message_observation!("lark:oc_chaos_record", "om_record_only_1")

    finalize_due_inbound_batch_events!()

    refute Repo.get_by(Signal,
             agent_uid: agent.uid,
             provider_message_id: "om_record_only_1"
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
      chat_type: "p2p",
      text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
      mentions: [mention],
      create_time_ms: DateTime.to_unix(@base_time, :millisecond)
    ]

    assert :ok = FakeFeishu.State.user_sends_message(fake_feishu.state, attrs)
    assert :ok = FakeFeishu.State.user_sends_message(fake_feishu.state, attrs)

    input = signal_by_provider_message_id!(agent.uid, "om_direct_1")

    assert 1 ==
             Signal
             |> where([input], input.agent_uid == ^agent.uid)
             |> where([input], input.provider_message_id == "om_direct_1")
             |> Repo.aggregate(:count)

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(45_000))

    assert reply.message.text =~ "CHAOS_DIRECT_OK"
    assert_signal_completed!(input.id)

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

    seed_input = signal_by_provider_message_id!(agent.uid, "om_dm_isolation_seed_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               seed_input,
               DateTime.add(seed_input.available_at, 1, :second)
             )

    assert {:ok, seed_reply, seed_message} =
             wait_for_completed_final_reply(container, seed_input.id, deadline(45_000))

    assert seed_reply.message.text =~ "CHAOS_DM_ISOLATION_SEED_OK"
    assert_signal_completed!(seed_input.id)

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

    group_input = signal_by_provider_message_id!(agent.uid, "om_group_isolation_check_1")
    assert group_input.session_id != seed_input.session_id

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               group_input,
               DateTime.add(group_input.available_at, 1, :second)
             )

    # The DM secret must not leak into the group session's model request.
    assert_receive {:fake_llm_request, :group_isolation_check, 1, request}, 15_000
    refute request_contains_text?(request, secret)

    assert {:ok, group_reply, group_message} =
             wait_for_completed_final_reply(container, group_input.id, deadline(45_000))

    assert group_reply.message.text =~ "CHAOS_GROUP_ISOLATION_OK"
    assert group_message.conversation_id != seed_message.conversation_id
    assert_signal_completed!(group_input.id)

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
      mention: lark_bot_mention("ou_lark_bot_a", "@_user_1", "Agent A")
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
      mention: lark_bot_mention("ou_lark_bot_b", "@_user_1", "Agent B")
    }

    secondary_result =
      run_single_agent_mention(
        fake_feishu,
        DockerWorker.container(secondary_agent.uid),
        secondary
      )

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
    # produce an Signal.
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: args.event_id,
               message_id: args.message_id,
               chat_id: "oc_chaos_multi_agent",
               chat_type: "group",
               text:
                 "#{mention_text_prefix(args.mention)} Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
               mentions: [args.mention],
               to_app: [multi_a_app_id(), secondary_app_id()],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 450, :millisecond), :millisecond)
             )

    input = signal_by_provider_message_id!(args.agent_uid, args.message_id)
    assert_actor_entry_text_visible!(input, "Reply exactly CHAOS_DIRECT_OK. Do not call tools.")

    refute Repo.get_by(Signal,
             agent_uid: args.other_agent_uid,
             provider_message_id: args.message_id
           )

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(45_000))

    assert reply.message.text =~ "CHAOS_DIRECT_OK"
    assert_signal_completed!(input.id)
    %{input: input, reply: reply, message: message}
  end

  defp mention_text_prefix(%{"key" => "@" <> _rest = key}), do: key
  defp mention_text_prefix(%{"key" => key}) when is_binary(key), do: "@#{key}"
  defp mention_text_prefix(_mention), do: "@_user_1"

  defp assert_actor_entry_text_visible!(%Signal{} = input, expected_text) do
    entry_text = get_in(input.data, ["entry", "text"])

    assert entry_text == expected_text
    refute entry_text =~ "_user_"
    refute entry_text =~ "_agent_"
  end

  def run_followup_during_generation(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
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

    first_input = signal_by_provider_message_id!(agent.uid, "om_followup_slow_1")

    assert {:ok, %{status: :driving, pid: driver}} =
             ensure_input_driver!(
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

    second_input = signal_by_provider_message_id!(agent.uid, "om_followup_second_1")

    assert {:ok, %{status: :driving, pid: ^driver}} =
             ensure_input_driver!(second_input, second_input.available_at)

    assert {:ok, second_reply, second_message} =
             wait_for_completed_final_reply(container, second_input.id, deadline(60_000))

    assert second_reply.message.text =~ "CHAOS_FOLLOWUP_SECOND_OK"
    assert_signal_completed!(second_input.id)
    assert_signal_completed!(first_input.id)
    refute Repo.get_by(Intent, source_signal_id: first_input.id, operation: :reply)

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

    first_input = signal_by_provider_message_id!(agent.uid, "om_followup_recall_slow_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
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

    recalled_input = signal_by_provider_message_id!(agent.uid, "om_followup_recalled_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
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

    assert first_reply.message.text =~ "CHAOS_FOLLOWUP_RECALL_FIRST_OK"
    assert_signal_completed!(first_input.id)

    assert_signal_finished!(recalled_input.id)
    refute Repo.get_by(Intent, reply_to_provider_message_id: "om_followup_recalled_1")
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

  def run_retry_command(
        %{fake_feishu: fake_feishu, agent: agent, container: container},
        target_signal_id
      ) do
    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_retry_1",
               message_id: "om_retry_1",
               chat_id: "oc_chaos_direct",
               chat_type: "p2p",
               text: "/retry signal::#{target_signal_id}",
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 500, :millisecond), :millisecond)
             )

    command_event = signal_by_provider_message_id!(agent.uid, "om_retry_1")
    assert command_event.type == "command.retry"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               command_event,
               DateTime.add(command_event.available_at, 1, :second)
             )

    assert_signal_finished!(command_event.id)
    retry_event = Repo.get_by!(Signal, source_event_id: "retry:#{command_event.id}")

    delete_intent =
      Repo.get_by!(Intent,
        source_signal_id: command_event.id,
        operation: :delete
      )

    assert delete_intent.status in [:pending, :sent]
    assert is_binary(delete_intent.ai_message_id)
    assert is_binary(delete_intent.target_provider_message_id)

    retry_event = Repo.get!(Signal, retry_event.id)
    assert retry_event.provider_message_id == "om_direct_1"
    assert get_in(retry_event.data, ["entry", "text"]) =~ "CHAOS_DIRECT_OK"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               retry_event,
               DateTime.add(retry_event.available_at, 1, :second)
             )

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, retry_event.id, deadline(60_000))

    assert reply.message.text =~ "CHAOS_DIRECT_OK"
    assert_signal_completed!(retry_event.id)

    assert Repo.get_by!(Intent,
             agent_uid: delete_intent.agent_uid,
             binding_name: delete_intent.binding_name,
             outbound_key: delete_intent.outbound_key
           ).status == :sent

    assert %{deleted: true} =
             FakeFeishu.State.message(
               fake_feishu.state,
               delete_intent.target_provider_message_id
             )

    %{input: retry_event, reply: reply, message: message}
  end

  @doc """
  Runs `/compress` and asserts the compaction artifact plus the operator feedback.
  """
  def run_compress_command(
        %{fake_feishu: fake_feishu, agent: agent, container: container},
        conversation_id
      ) do
    # The driver can process the command as soon as ingress commits it.
    _compressed_seed_message_ids = seed_compression_history!(agent.uid, conversation_id)

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

    input = signal_by_provider_message_id!(agent.uid, "om_compress_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, _completed} = wait_for_signal_completed(container, input.id, deadline(60_000))

    assert %Message{
             id: checkpoint_id,
             type: "checkpoint",
             content: [%{"type" => "compaction_artifact"} = ref]
           } =
             Message
             |> where([message], message.conversation_id == ^conversation_id)
             |> where([message], message.type == "checkpoint")
             |> order_by([message], desc: message.inserted_at, desc: message.id)
             |> limit(1)
             |> Repo.one()

    assert "cmp_" <> artifact_id = ref["id"]
    assert %CompactionArtifact{} = artifact = Repo.get!(CompactionArtifact, artifact_id)
    assert artifact.subject_uid == agent.uid
    assert artifact.conversation_id == conversation_id
    assert get_in(artifact.content, ["summary", "text"]) == "## Active Task\n(none)"
    assert [_ | _] = artifact.content["output"]
    assert_signal_completed!(input.id)

    # The command commits feedback and completion together. Its model artifact
    # is the checkpoint; it does not adopt a normal final Response.
    intent = Repo.one!(from(i in Intent, where: i.source_signal_id == ^input.id))
    assert intent.ai_message_id == checkpoint_id
    assert intent.payload == %{"text" => "Conversation compressed."}

    dispatch_and_assert_lark_intent(
      fake_feishu,
      intent,
      "Conversation compressed.",
      :reply,
      "om_compress_1"
    )

    %{input: input, intent: intent, messages: ai_messages_for_signal(input.id)}
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
