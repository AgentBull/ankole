defmodule BullX.Integration.IMGateway.MentionAttentionTest do
  @moduledoc """
  Family C — @-mention drives attention, and editing the mention retargets it.

  In a group the bot answers only when addressed (@-mentioned); a DM is always
  addressed. Editing a message to add/remove the @-mention upgrades/downgrades
  the attention and changes whether the bot engages.
  """
  use BullX.Integration.IMGateway.Case

  setup do
    MockLLM.set_responder(fn req -> {:text, "reply-#{req.call_index}"} end)
    :ok
  end

  test "C1/C2: group answers only when the bot is @-mentioned" do
    chat = new_group(members: [:alice])

    say(chat, :alice, "just thinking out loud")
    settle()
    assert MockLLM.call_count() == 0
    assert transcript(chat) == []

    say(chat, :alice, "@bot what do you think", mention: :bot)
    settle()
    assert MockLLM.call_count() == 1
    assert last_bot_text(chat) == "reply-0"
  end

  test "C7: a DM is always addressed without an @-mention" do
    chat = new_dm(with: :alice)
    say(chat, :alice, "no at-sign needed here")
    settle()

    assert MockLLM.call_count() == 1
    assert last_bot_text(chat) == "reply-0"
  end

  test "C8: observe_all group messages are stored as ambient context without a reply" do
    chat = new_group(members: [:alice], mode: "observe_all")

    say(chat, :alice, "ambient customer risk signal")
    settle()

    assert MockLLM.call_count() == 0
    assert transcript(chat) == []

    assert %Message{role: :im_ambient, kind: :normal, content: content} =
             Repo.one!(from(m in Message, where: m.role == :im_ambient and m.kind == :normal))

    assert Enum.any?(content, &(Map.get(&1, "text") == "ambient customer risk signal"))
  end

  test "C4: editing a non-addressed message to add the @-mention makes the bot engage" do
    chat = new_group(members: [:alice], mode: "engage_all")

    m = say(chat, :alice, "someone should look at the logs")
    settle()
    assert MockLLM.call_count() == 0
    assert transcript(chat) == []

    calls_before = MockLLM.call_count()

    edit(m, "@bot can you look at the logs", mention: :bot)
    settle()

    assert MockLLM.call_count() == calls_before + 1
    assert MockLLM.last_prompt_text() =~ "@bot can you look at the logs"
    assert last_bot_text(chat) == "reply-#{calls_before}"
  end

  test "C3: editing an addressed message to drop the @-mention does not re-answer" do
    chat = new_group(members: [:alice], mode: "engage_all")

    m = say(chat, :alice, "@bot summarize this", mention: :bot)
    settle()
    assert MockLLM.call_count() == 1

    # Remove the @-mention: the edit downgrades to ambient, no fresh answer.
    edit(m, "summarize this", mention: :none)
    settle()

    assert MockLLM.call_count() == 1
  end
end
