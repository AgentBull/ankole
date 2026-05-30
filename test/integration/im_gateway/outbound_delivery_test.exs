defmodule BullX.Integration.IMGateway.OutboundDeliveryTest do
  @moduledoc """
  Family G — outbound: streaming replies and delivery-failure handling.
  """
  use BullX.Integration.IMGateway.Case

  alias BullX.Integration.IMGateway.MockIM.Server

  test "G2: a streaming reply is delivered over the stream surface, not a plain send" do
    MockLLM.push_text("streamed reply")

    chat = new_dm(with: :alice)
    say(chat, :alice, "stream this please", delivery_mode: "stream")
    settle()

    # Streaming uses consume_stream; the final assistant message is persisted.
    scope_id = chat.id
    assert [%{scope_id: ^scope_id}] = streams()
    assert transcript(chat) == []
    assert Repo.exists?(from(m in Message, where: m.role == :assistant and m.kind == :normal))
  end

  test "G3: a delivery failure is handled without crashing the agent" do
    MockLLM.push_text("undeliverable reply")
    Server.fail_delivery()

    chat = new_dm(with: :alice)
    say(chat, :alice, "hello there")
    settle()

    assert [%{op: "send", text: "undeliverable reply", safe_error: %{"kind" => "network"}}] =
             delivery_failures(chat)

    # No outbound side effect was recorded for the chat...
    assert transcript(chat) == []

    refute Repo.exists?(
             from(m in BullX.IMGateway.Message, where: m.text == "undeliverable reply")
           )

    # ...but the generation itself completed and was persisted.
    assert %Message{
             metadata: %{"delivery" => %{"status" => "failed", "safe_error_code" => "network"}}
           } =
             Repo.one!(from(m in Message, where: m.role == :assistant and m.kind == :normal))
  end

  test "G4: retrying a processed entry recovers failed delivery without another LLM call" do
    MockLLM.push_text("recoverable reply")
    Server.fail_delivery()

    chat = new_dm(with: :alice)
    say(chat, :alice, "please recover delivery")
    settle()

    assert MockLLM.call_count() == 1
    assert [%{op: "send", text: "recoverable reply"}] = delivery_failures(chat)
    assert transcript(chat) == []

    Server.fail_delivery(false)
    entry = Repo.one!(from(e in Entry, where: e.status == :processed))

    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [
        status: :pending,
        available_at: DateTime.utc_now(:microsecond),
        safe_error: nil,
        lease_holder: nil,
        lease_expires_at: nil
      ]
    )

    settle()

    assert MockLLM.call_count() == 1
    assert [%{op: "send", text: "recoverable reply"}] = transcript(chat)

    assert %Message{metadata: %{"delivery" => %{"status" => "sent"}}} =
             Repo.one!(from(m in Message, where: m.role == :assistant and m.kind == :normal))
  end

  test "G1: a normal reply is captured as a send on the transcript" do
    MockLLM.push_text("plain reply")

    chat = new_dm(with: :alice)
    say(chat, :alice, "hi")
    settle()

    assert [%{op: "send", text: "plain reply"}] = transcript(chat)

    assert Repo.exists?(
             from(m in BullX.IMGateway.Message,
               where: m.text == "plain reply" and m.lifecycle_state == :active
             )
           )
  end
end
