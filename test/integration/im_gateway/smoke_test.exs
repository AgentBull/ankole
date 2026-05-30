defmodule BullX.Integration.IMGateway.SmokeTest do
  @moduledoc """
  Minimal happy-path checks that the whole mock pipeline is wired:
  inbound -> mailbox routing/coalescing -> agent -> mock LLM -> outbound capture.
  """
  use BullX.Integration.IMGateway.Case

  test "a DM to the bot produces an agent reply on the transcript" do
    MockLLM.push_text("hello from the bot")

    chat = new_dm(with: :alice)
    say(chat, :alice, "hi there")
    settle()

    assert last_bot_text(chat) == "hello from the bot"
    assert MockLLM.call_count() == 1
  end

  test "a group message that @-mentions the bot gets a reply" do
    MockLLM.push_text("group reply")

    chat = new_group(members: [:alice, :bob])
    say(chat, :alice, "@bot can you help", mention: :bot)
    settle()

    assert last_bot_text(chat) == "group reply"
  end

  test "a group message without an @-mention does not invoke the agent" do
    chat = new_group(members: [:alice, :bob])
    say(chat, :alice, "just chatting, no bot here")
    settle()

    assert transcript(chat) == []
    assert MockLLM.call_count() == 0
  end
end
