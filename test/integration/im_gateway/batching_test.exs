defmodule BullX.Integration.IMGateway.BatchingTest do
  @moduledoc """
  Family A — coalescing & splitting.

  Exercises the mailbox coalesce window (per-actor, per-session) and the char
  limit that creates cross-batch splits, plus multi-sender
  separation. The suite shrinks the window to #{BullX.Integration.IMGateway.Case.window_ms()}ms and
  the char limit to #{BullX.Integration.IMGateway.Case.max_chars()} chars so these are fast and
  deterministic (see `BullX.Integration.IMGateway.Case`).
  """
  use BullX.Integration.IMGateway.Case

  setup do
    # Distinct, index-stamped reply per agent turn so call ordering is assertable.
    MockLLM.set_responder(fn req -> {:text, "reply-#{req.call_index}"} end)
    :ok
  end

  test "A1: messages from one person within the window coalesce into one agent turn" do
    chat = new_dm(with: :alice)
    say(chat, :alice, "part one")
    say(chat, :alice, "part two")
    say(chat, :alice, "part three")
    settle()

    assert MockLLM.call_count() == 1
    prompt = MockLLM.last_prompt_text()
    assert prompt =~ "part one"
    assert prompt =~ "part two"
    assert prompt =~ "part three"
    assert last_bot_text(chat) == "reply-0"
  end

  test "A2: accumulated text over the char limit splits across batches" do
    chat = new_dm(with: :alice)
    block = String.duplicate("x", 100)
    say(chat, :alice, block <> "-one")
    say(chat, :alice, block <> "-two")
    say(chat, :alice, block <> "-three")
    settle()

    # ~104 chars each, limit 240: {one, two} flush, then {three}.
    assert MockLLM.call_count() == 2
    [first, second] = Enum.map(MockLLM.requests(), &MockLLM.prompt_text/1)
    # First batch coalesced one+two; three spilled into the second batch.
    assert first =~ "-one" and first =~ "-two"
    refute first =~ "-three"
    assert second =~ "-three"
  end

  test "A3: different senders in the same group form separate per-actor batches" do
    chat = new_group(members: [:alice, :bob])
    say(chat, :alice, "alice question", mention: :bot)
    say(chat, :bob, "bob question", mention: :bot)
    settle()

    # Coalescing is per actor key — Alice and Bob never merge into one turn.
    assert MockLLM.call_count() == 2
    prompts = Enum.map(MockLLM.requests(), &MockLLM.prompt_text/1)
    assert Enum.any?(prompts, &(&1 =~ "alice question"))
    assert Enum.any?(prompts, &(&1 =~ "bob question"))
    # The first turn (Alice) must not already contain Bob's later message.
    refute List.first(prompts) =~ "bob question"
  end

  test "A4: messages separated by a processing round form separate batches" do
    chat = new_dm(with: :alice)
    say(chat, :alice, "first question")
    settle()
    say(chat, :alice, "second question")
    settle()

    assert MockLLM.call_count() == 2
  end

  test "A5: a message outside the coalesce window does not merge with an earlier one" do
    chat = new_dm(with: :alice)
    say(chat, :alice, "early message")
    # Push the first message's timestamp out of the window before the next arrives.
    backdate_pending(window_ms() + 50)
    say(chat, :alice, "late message")
    settle()

    assert MockLLM.call_count() == 2
    prompts = Enum.map(MockLLM.requests(), &MockLLM.prompt_text/1)
    refute List.first(prompts) =~ "late message"
  end

  test "A6: a single oversized message is delivered on its own" do
    chat = new_dm(with: :alice)
    say(chat, :alice, String.duplicate("y", max_chars() + 200))
    settle()

    assert MockLLM.call_count() == 1
    assert last_bot_text(chat) == "reply-0"
  end
end
