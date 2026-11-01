defmodule Ankole.ConversationsMemoryTest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  import Ankole.PrincipalsFixtures, only: [human_fixture: 0]
  import Ankole.SessionsCase, only: [agent_fixture: 1]
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.Brain.{Claims, ConversationsLearning, Sources}
  alias Ankole.Brain.Schemas.{Claim, Source}
  alias Ankole.Conversations
  alias Ankole.Conversations.{Conversation, Message}
  alias Ankole.Sessions.{Admission, Model, Run}
  alias Ankole.Signals.Signal

  setup do
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
    id = Ecto.UUID.generate()

    assert {:ok, detail} =
             Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{
               conversation_id: id,
               agent_uid: agent.uid,
               message_id: Ecto.UUID.generate(),
               text: "Original request"
             })

    input = Repo.get_by!(Signal, conversation_id: id)
    key = %{agent_uid: agent.uid, session_id: detail.session_id}
    assert {:ok, run} = Admission.admit(key, input)
    assert {:ok, {:preparing, run}} = Model.prepare(run)
    %{human: human, agent: agent, id: id, key: key, input: input, run: run}
  end

  test "editing a learned pending message withdraws its claims and rewinds the source", ctx do
    input = post!(ctx, "Old queued preference")
    message = Repo.get_by!(Message, id: input.message_id)
    learned = learned_claims!(ctx, message)

    assert {:ok, _} =
             queue_command(ctx, %{
               action: "edit",
               message_id: input.message_id,
               text: "Corrected queued preference"
             })

    assert_withdrawn(learned)
    assert Repo.get_by!(Message, id: message.id).text == "Corrected queued preference"
    observations = ConversationsLearning.pending_slice(ctx.id)

    assert Enum.find(observations, &(&1.message.id == message.id)).message.text ==
             "Corrected queued preference"
  end

  test "editing a learned completed request removes its old reply and invalidates old memory",
       ctx do
    reply = complete_reply(ctx, "The outdated answer")
    learned = learned_claims!(ctx, reply)

    assert {:ok, _} =
             queue_command(ctx, %{
               action: "edit_last",
               message_id: ctx.input.message_id,
               expected_text: "Original request",
               text: "Corrected completed request",
               command_id: Ecto.UUID.generate()
             })

    assert_withdrawn(learned)
    assert is_nil(Repo.get_by(Message, id: reply.id))
    assert Repo.get_by!(Message, id: ctx.input.message_id).text == "Corrected completed request"

    assert Enum.map(ConversationsLearning.pending_slice(ctx.id), & &1.message.text) ==
             ["Corrected completed request"]
  end

  test "regenerating a learned reply withdraws the deleted answer without changing the Human request",
       ctx do
    reply = complete_reply(ctx, "Withdraw this answer")
    learned = learned_claims!(ctx, reply)

    assert {:ok, _} =
             queue_command(ctx, %{
               action: "regenerate",
               message_id: reply.id,
               command_id: Ecto.UUID.generate()
             })

    assert_withdrawn(learned)
    assert is_nil(Repo.get_by(Message, id: reply.id))
    assert Repo.get_by!(Message, id: ctx.input.message_id).text == "Original request"

    assert Enum.map(ConversationsLearning.pending_slice(ctx.id), & &1.message.text) ==
             ["Original request"]
  end

  test "a wake briefing omits the text of a withdrawn reply target", ctx do
    secret = post!(ctx, "WITHDRAWN_QUOTE_SENTINEL")
    reply = post!(ctx, "A reply that remains visible")
    message = Repo.get_by!(Message, id: reply.message_id)
    Repo.update!(Ecto.Changeset.change(message, reply_to_message_id: secret.message_id))
    Repo.update!(Ecto.Changeset.change(reply, last_attempt_at: DateTime.utc_now(:microsecond)))

    {messages, quotes} =
      Ankole.Conversations.Queries.wake_briefing_messages(
        ctx.id,
        ctx.agent.uid,
        message.seq,
        [],
        20
      )

    assert Enum.any?(messages, &(&1.id == message.id))
    assert quotes[secret.message_id].text == "WITHDRAWN_QUOTE_SENTINEL"
    assert {:ok, _} = queue_command(ctx, %{action: "retract", message_id: secret.message_id})

    {messages, quotes} =
      Ankole.Conversations.Queries.wake_briefing_messages(
        ctx.id,
        ctx.agent.uid,
        message.seq,
        [],
        20
      )

    assert Enum.any?(messages, &(&1.id == message.id))
    refute Map.has_key?(quotes, secret.message_id)
  end

  test "a removed queue identity is retained for retries but is absent from learning and Main context",
       ctx do
    input = post!(ctx, "A removed confidential request")
    message = Repo.get_by!(Message, id: input.message_id)
    learned = learned_claims!(ctx, message)
    assert {:ok, _} = queue_command(ctx, %{action: "retract", message_id: message.id})
    assert_withdrawn(learned)
    assert Repo.get_by!(Message, id: message.id)
    assert Repo.reload!(input).data["removed"] == true

    assert Enum.map(ConversationsLearning.pending_slice(ctx.id), & &1.message.id) ==
             [ctx.input.message_id]

    assert {:ok, snapshot} = Conversations.context_snapshot(ctx.id, ctx.key, 0, [])
    refute Enum.any?(snapshot.messages, &(&1.id == message.id))

    assert {:ok, detail} =
             Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid), ctx.id)

    refute Enum.any?(detail.messages, &(&1.id == message.id))

    # A removed tail must not schedule empty learning work after the remaining
    # visible statements have been processed.
    original = Repo.get_by!(Message, id: ctx.input.message_id)

    assert :ok =
             Sources.record_extraction_watermark(
               learned.source,
               {original.created_at, original.seq}
             )

    old = DateTime.add(DateTime.utc_now(:microsecond), -86_400, :second)
    Repo.update_all(from(c in Conversation, where: c.id == ^ctx.id), set: [last_activity_at: old])
    assert ConversationsLearning.pending_slice(ctx.id) == []
    refute Enum.any?(ConversationsLearning.idle_pending_slices(), &(&1.conversation_id == ctx.id))

    next = post!(ctx, "A valid next request")
    assert {:ok, _} = Run.finalize(ctx.run, :silent)
    assert {:ok, run} = Admission.admit(ctx.key, next)
    assert {:ok, {:preparing, run}} = Model.prepare(run)
    request = Ankole.JSON.encode!(Model.request(run)["input"])
    assert request =~ "A valid next request"
    refute request =~ "A removed confidential request"
  end

  # These are the durable outputs of learning. Use the shared write owners;
  # model inference is not needed to check their invalidation lifecycle.
  defp learned_claims!(ctx, message) do
    assert {:ok, source} =
             Sources.get_or_create(%{kind: "conversation", upstream_id: ctx.id, name: "Chat"})

    attrs = %{
      conversation_id: ctx.id,
      holder: "world",
      audience_scope: "principal:" <> ctx.human.uid,
      provenance_session: "source:" <> source.id,
      provenance: message.text,
      claim: "A learned preference from this conversation",
      kind: "preference",
      notability: "medium",
      confidence: 0.75,
      valid_from: DateTime.utc_now(:microsecond)
    }

    assert {:ok, %{claim: fact}} =
             Ankole.Brain.write_fact(attrs, :system, %{options: [embed: false]})

    assert {:ok, take} =
             Claims.write_take(
               Map.merge(attrs, %{
                 claim: "An interpretation to withdraw",
                 kind: "take",
                 weight: 0.5
               }),
               :system,
               embed: false
             )

    assert :ok =
             Sources.record_extraction_watermark(source, {message.created_at, message.seq})

    %{source: source, fact: fact, take: take}
  end

  defp assert_withdrawn(learned) do
    assert %DateTime{} = Repo.get_by!(Claim, id: learned.fact.id).expired_at
    assert Repo.get_by!(Claim, id: learned.take.id).active == false
    source = Repo.get_by!(Source, id: learned.source.id)
    assert source.extracted_through_seq == 0
    assert is_nil(source.extracted_through_at)
    assert is_binary(source.upstream_revision)
    refute source.upstream_revision == learned.source.upstream_revision
  end

  defp complete_reply(ctx, text) do
    assert {:ok, response} =
             start_response_run(%{
               subject_uid: ctx.agent.uid,
               conversation_id: ctx.run.conversation.id,
               round_state: ctx.run,
               metadata: %{"request_metadata" => Run.metadata(ctx.run)}
             })

    assert {:ok, final} =
             ResponseCommit.commit_complete(response, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => text}]
               }
             ])

    assert {:ok, _} = Run.finalize(%{ctx.run | anchor: final.id})
    Repo.get_by!(Message, conversation_id: ctx.id, signal_id: ctx.input.id)
  end

  defp post!(ctx, text) do
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.post(Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid), ctx.id, %{
               message_id: id,
               text: text,
               delivery_mode: "queue"
             })

    Repo.get_by!(Signal, message_id: id)
  end

  defp queue_command(ctx, attrs) do
    {:ok, detail} =
      Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid), ctx.id)

    Conversations.update_queue(
      Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
      ctx.id,
      attrs
      |> Map.put(:agent_uid, ctx.agent.uid)
      |> Map.put(
        :expected_version,
        Ankole.Conversations.NativeQueue.queue_version(
          detail.conversation,
          detail.pending_inputs,
          ctx.agent.uid
        )
      )
    )
  end
end
