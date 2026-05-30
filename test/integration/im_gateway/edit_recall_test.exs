defmodule BullX.Integration.IMGateway.EditRecallTest do
  @moduledoc """
  Family B — message edit / recall across lifecycle timing.

  Distinguishes the cases that matter:

    * edit/recall while the message is still PENDING (pre-flush) — the batch
      reflects the change (edit mutates, recall drops);
    * edit/recall of an already-answered (historical) message — recorded as an
      introspection note, old content is not rewritten, no re-answer.
  """
  use BullX.Integration.IMGateway.Case

  setup do
    MockLLM.set_responder(fn req -> {:text, "reply-#{req.call_index}"} end)
    :ok
  end

  test "B2: editing a still-pending message delivers the edited text" do
    chat = new_dm(with: :alice)
    m = say(chat, :alice, "original question")
    # Edit before settling — the receive entry is still pending.
    edit(m, "edited question")
    settle()

    assert MockLLM.call_count() == 1
    prompt = MockLLM.last_prompt_text()
    assert prompt =~ "edited question"
    refute prompt =~ "original question"
  end

  test "B2: recalling a still-pending message drops it before the agent runs" do
    chat = new_dm(with: :alice)
    m = say(chat, :alice, "never mind this")
    recall(m)
    settle()

    assert MockLLM.call_count() == 0
    assert transcript(chat) == []
  end

  test "B1: editing the just-answered (latest) message re-answers with the new text" do
    chat = new_dm(with: :alice)
    m = say(chat, :alice, "what is the weather")
    settle()
    assert MockLLM.call_count() == 1

    edit(m, "what is the weather in NYC")
    settle()

    # The most recent exchange is re-run against the edited question.
    assert MockLLM.call_count() == 2
    assert MockLLM.last_prompt_text() =~ "NYC"
    assert last_bot_text(chat) == "reply-1"
  end

  test "B1: recalling the just-answered (latest) message recalls the bot's reply" do
    chat = new_dm(with: :alice)
    m = say(chat, :alice, "delete this please")
    settle()
    assert last_bot_text(chat) == "reply-0"
    assert [%{op: "send", external_id: delivered_id}] = transcript(chat)

    recall(m)
    settle()

    # No re-answer, and the now-orphaned reply is recalled.
    assert MockLLM.call_count() == 1
    assert [%{op: "send"}, %{op: "recall", target_external_id: ^delivered_id}] = transcript(chat)
  end

  test "B6: repeating a recall for an already-recalled message is idempotent" do
    chat = new_dm(with: :alice)
    m = say(chat, :alice, "recall this once")
    settle()
    assert [%{op: "send", external_id: delivered_id}] = transcript(chat)

    recall(m)
    settle()
    assert [%{op: "send"}, %{op: "recall", target_external_id: ^delivered_id}] = transcript(chat)

    recall(m)
    settle()

    assert MockLLM.call_count() == 1
    assert [%{op: "send"}, %{op: "recall", target_external_id: ^delivered_id}] = transcript(chat)
  end

  test "B7: a recall webhook that arrives before the receive webhook prevents a stale reply" do
    chat = new_dm(with: :alice)
    message_id = "out-of-order-#{System.unique_integer([:positive])}"

    emit_provider_input(%{
      kind: :recall,
      occurrence_id: "recall-before-receive-#{message_id}",
      message_id: message_id,
      chat_id: chat.id,
      chat_kind: chat.kind,
      source_id: chat.source_id,
      sender: %{id: "ou_alice", display_name: "alice"},
      mention_bot: false,
      group_message_mode: chat.group_message_mode
    })

    settle()

    say(chat, :alice, "this recalled message should not be answered", message_id: message_id)
    settle()

    assert MockLLM.call_count() == 0
    assert transcript(chat) == []
  end

  test "B4: editing the third-to-last message in a multi-turn chat does not re-answer" do
    chat = new_dm(with: :alice)
    first = say(chat, :alice, "first topic")
    settle()
    say(chat, :alice, "second topic")
    settle()
    say(chat, :alice, "third topic")
    settle()
    assert MockLLM.call_count() == 3

    # Edit the oldest (third-to-last) user message.
    edit(first, "first topic revised")
    settle()

    # Deep-history edit is introspected, never re-answered.
    assert MockLLM.call_count() == 3
    assert bot_texts(chat) == ["reply-0", "reply-1", "reply-2"]
    assert Repo.exists?(from(msg in Message, where: msg.kind == :introspection))
  end
end
