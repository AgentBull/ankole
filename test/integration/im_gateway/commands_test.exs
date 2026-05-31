defmodule BullX.Integration.IMGateway.CommandsTest do
  @moduledoc """
  Family D — the slash-command channel.

  Commands arrive as `bullx.command.invoked` and are dispatched as control
  entries: they bypass the coalesce window and any queued message work (this is
  what "/steer skips the queue" means). `/undo` rolls back the last exchange and
  recalls the delivered reply.
  """
  use BullX.Integration.IMGateway.Case

  setup do
    MockLLM.set_responder(fn req -> {:text, "reply-#{req.call_index}"} end)
    :ok
  end

  test "D3: /undo recalls the delivered reply of the last exchange" do
    chat = new_dm(with: :alice)
    say(chat, :alice, "question one")
    settle()
    assert last_bot_text(chat) == "reply-0"
    assert [%{op: "send", external_id: delivered_id}] = transcript(chat)

    undo(chat, :alice)
    settle()

    assert MockLLM.call_count() == 1
    assert [%{op: "send"}, %{op: "recall", target_external_id: ^delivered_id}] = transcript(chat)
  end

  test "D3: a new message after /undo starts a fresh exchange" do
    chat = new_dm(with: :alice)
    say(chat, :alice, "first")
    settle()
    undo(chat, :alice)
    settle()

    say(chat, :alice, "second")
    settle()

    assert MockLLM.call_count() == 2
    assert last_bot_text(chat) == "reply-1"
  end

  test "D7: a command is dispatched immediately, ahead of a still-windowed message" do
    chat = new_dm(with: :alice)
    say(chat, :alice, "first")
    settle()
    assert last_bot_text(chat) == "reply-0"
    assert [%{op: "send", external_id: delivered_id}] = transcript(chat)

    # Queue a message (still inside its coalesce window) then issue /undo. The
    # command runs immediately via the control path while the message waits.
    say(chat, :alice, "second, still pending")
    undo(chat, :alice)
    assert {:ok, 1} = BullX.MailBox.process_ready(1, async?: true)

    wait_for(fn ->
      Enum.any?(recalls(chat), &(&1.target_external_id == delivered_id))
    end)

    # "second" has not been answered yet — it is still inside its window.
    assert MockLLM.call_count() == 1

    # Drain for a clean exit.
    settle()
  end

  test "D2: /steer with no active generation is handled without crashing or re-answering" do
    chat = new_dm(with: :alice)
    say(chat, :alice, "hello")
    settle()
    assert MockLLM.call_count() == 1

    steer(chat, :alice, "be more concise")
    settle()

    # No active generation to steer: no extra agent turn, no failure.
    assert MockLLM.call_count() == 1
  end
end
