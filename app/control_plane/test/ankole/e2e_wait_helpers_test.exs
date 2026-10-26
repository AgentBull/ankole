defmodule Ankole.E2E.WaitHelpersTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.SessionsCase

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Run
  alias Ankole.E2E.WaitHelpers

  alias Ankole.Conversations.{External, ExternalMessageRef}
  alias Ankole.Conversations.Message, as: ConversationMessage
  alias Ankole.Conversations.Delivery.Intent

  setup {Ankole.SessionsCase, :use_mock_signal_provider_plugin}

  test "completed final reply waits for the latest final message mirror" do
    %{agent: agent, signal: signal, turn_ref: turn_ref} =
      start_accepted_turn("latest-final", "Need a final reply.")

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, signal.session_id)

    old_message = complete_response!(agent.uid, conversation.id, signal.id, "old final")

    latest_message =
      complete_response!(
        agent.uid,
        conversation.id,
        signal.id,
        "latest final",
        "resp_#{old_message.id}"
      )

    assert {:ok, %{status: :completed}} = complete_turn(turn_ref, latest_message)

    latest_mirror = insert_mirror!(signal, latest_message, "latest-final-mirror")
    old_mirror = insert_mirror!(signal, old_message, "old-final-mirror")

    _attachment_mirror =
      insert_mirror!(signal, latest_message, "latest-attachment-mirror", %{})

    force_created_at!(old_mirror, DateTime.add(latest_mirror.message.created_at, 1, :second))

    assert {:ok, %{message: %ConversationMessage{}, external_ref: %ExternalMessageRef{}} = reply,
            %Message{} = message} =
             WaitHelpers.wait_for_completed_final_reply(
               %{},
               signal.id,
               WaitHelpers.deadline(1_000)
             )

    assert reply.external_ref.ai_message_id == latest_message.id
    assert message.id == latest_message.id
  end

  test "completed final reply drains its durable Oban delivery job" do
    %{agent: agent, signal: signal, turn_ref: turn_ref} =
      start_accepted_turn("runtime-event-final", "Need a dispatched final reply.")

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, signal.session_id)

    committed =
      complete_response!(agent.uid, conversation.id, signal.id, "runtime event final")

    assert {:ok, %{status: :completed}} = complete_turn(turn_ref, committed)

    assert %Intent{status: :pending} =
             Repo.get_by!(Intent, outbound_key: "ai-reply:#{committed.id}")

    port = open_idle_port!()

    assert {:ok, %{message: %ConversationMessage{}, external_ref: %ExternalMessageRef{}} = reply,
            %Message{} = message} =
             WaitHelpers.wait_for_completed_final_reply(
               port,
               signal.id,
               WaitHelpers.deadline(1_000)
             )

    assert reply.external_ref.ai_message_id == committed.id
    assert message.id == committed.id
  end

  test "completed intent helper fails loudly when one input produced multiple side-effect rows" do
    %{agent: agent, signal: signal, turn_ref: turn_ref} =
      start_accepted_turn("multiple-side-effects", "Need multiple side effects.")

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, signal.session_id)
    message = complete_response!(agent.uid, conversation.id, signal.id, "done")

    assert {:ok, %{status: :completed}} = complete_turn(turn_ref, message)

    insert_side_effect_intent!(signal, message, "side-effect:one")
    insert_side_effect_intent!(signal, message, "side-effect:two")

    assert_raise ExUnit.AssertionError, ~r/expected one side-effect intent/, fn ->
      WaitHelpers.wait_for_intent_for_input(
        %{},
        signal.id,
        WaitHelpers.deadline(1_000),
        message.id
      )
    end
  end

  defp start_accepted_turn(suffix, text) do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsFixtures.binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    {:ok, %{signal: signal}} =
      emit_entry(
        agent.uid,
        "mock",
        Ankole.SignalsFixtures.group_entry(%{
          source_event_id: "wait-helper-#{suffix}",
          provider_conversation_id: "mock:chat:wait-helper-#{suffix}",
          provider_message_id: "human-wait-helper-#{suffix}",
          explicit: true,
          text: text
        }),
        now: @base_time
      )

    assert {:ok, run} =
             Admission.admit(
               %{agent_uid: agent.uid, session_id: signal.session_id},
               signal
             )

    %{agent: agent, signal: signal, turn_ref: run}
  end

  defp assistant_content(text) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    ]
  end

  defp complete_response!(subject_uid, conversation_id, signal_id, text) do
    complete_response!(subject_uid, conversation_id, signal_id, text, nil)
  end

  defp complete_response!(subject_uid, conversation_id, signal_id, text, previous) do
    attrs = %{
      subject_uid: subject_uid,
      metadata: %{"request_metadata" => %{"signal_id" => signal_id}}
    }

    attrs =
      case previous do
        nil -> Map.put(attrs, :conversation_id, conversation_id)
        previous_response_id -> Map.put(attrs, :previous_response_id, previous_response_id)
      end

    assert {:ok, run} = start_response_run(attrs)
    assert {:ok, response} = ResponseCommit.commit_complete(run, assistant_content(text))
    response
  end

  defp complete_turn(turn_ref, response) do
    Run.finalize(%{turn_ref | anchor: response.id}, :loop_finished)
  end

  defp insert_mirror!(signal, message, provider_message_id, metadata \\ nil) do
    now = DateTime.utc_now(:microsecond)

    metadata =
      metadata ||
        %{
          "signal_id" => signal.id,
          "ai_message_id" => message.id
        }

    assert {:ok, observed} =
             Repo.transact(fn ->
               External.record_delivery_in_tx(
                 signal.conversation_id,
                 %{
                   agent_uid: signal.agent_uid,
                   provider_message_id: provider_message_id,
                   text: provider_message_id,
                   author: %{"agent_uid" => signal.agent_uid},
                   metadata: metadata,
                   ai_message_id: message.id,
                   provider_time: now
                 },
                 now
               )
             end)

    observed
  end

  defp insert_side_effect_intent!(signal, message, outbound_key) do
    assert {:ok, %Intent{} = intent} =
             Ankole.SignalsFixtures.commit_delivery(%{
               agent_uid: signal.agent_uid,
               binding_name: signal.reply_binding_name,
               outbound_key: outbound_key,
               operation: :reply,
               conversation_id: signal.conversation_id,
               reply_to_provider_message_id: signal.provider_message_id,
               source_signal_id: signal.id,
               ai_message_id: message.id,
               payload: %{"text" => outbound_key},
               fallback_visible_text: outbound_key,
               idempotency_key: outbound_key
             })

    intent
  end

  defp open_idle_port! do
    port = Port.open({:spawn, "cat"}, [:binary, :exit_status])

    on_exit(fn ->
      if Port.info(port) do
        Port.close(port)
      end
    end)

    port
  end

  defp force_created_at!(%{message: %ConversationMessage{} = message}, created_at) do
    ConversationMessage
    |> where([m], m.id == ^message.id)
    |> Repo.update_all(set: [created_at: created_at])
  end
end
