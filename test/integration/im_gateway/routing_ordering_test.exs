defmodule BullX.Integration.IMGateway.RoutingOrderingTest do
  @moduledoc """
  Family F — idempotency, rule fan-out, and deterministic processing order.
  """
  use BullX.Integration.IMGateway.Case

  setup do
    MockLLM.set_responder(fn req -> {:text, "reply-#{req.call_index}"} end)
    :ok
  end

  test "F3: re-delivering the same event id is deduped to a single agent turn" do
    chat = new_dm(with: :alice)
    oid = "dup-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"

    say(chat, :alice, "hello once", occurrence_id: oid, message_id: "m-#{oid}")
    # Same occurrence id (network re-delivery): the gateway dedupes it.
    say(chat, :alice, "hello twice",
      occurrence_id: oid,
      message_id: "m-#{oid}",
      allow_ignore: true
    )

    settle()

    assert MockLLM.call_count() == 1
  end

  test "F5: one event fans out to every matching delivery rule / agent" do
    other = create_agent!("im-gateway-integration-agent-fanout")
    delivery_rule!(other.uid, name: "fanout-extra")
    provision_users!([:alice], other.uid)

    chat = new_dm(with: :alice)
    say(chat, :alice, "hello everyone")
    settle()

    # Default agent + the extra agent both handle the message.
    assert MockLLM.call_count() == 2
    assert Repo.aggregate(from(c in Conversation), :count) == 2
  end

  test "F1: two messages in the same session are handled in arrival order" do
    chat = new_group(members: [:alice, :bob])
    say(chat, :alice, "alice first", mention: :bot)
    say(chat, :bob, "bob second", mention: :bot)
    settle()

    assert MockLLM.call_count() == 2
    [first, second] = Enum.map(MockLLM.requests(), &MockLLM.prompt_text/1)
    assert first =~ "alice first"
    # The second turn sees the first turn's exchange already in history.
    assert second =~ "bob second"
    assert second =~ "alice first"
  end

  test "F6: concurrent inbound emits still coalesce under async mailbox workers" do
    chat = new_dm(with: :alice)

    ["async part one", "async part two", "async part three"]
    |> Task.async_stream(&say(chat, :alice, &1), ordered: false, timeout: 5_000)
    |> Enum.each(fn result -> assert {:ok, _message_id} = result end)

    flush_ready()
    assert {:ok, claimed} = BullX.MailBox.process_ready(200, async?: true)
    assert claimed >= 1

    wait_for(fn -> MockLLM.call_count() == 1 end)
    settle()

    prompt = MockLLM.last_prompt_text()
    assert prompt =~ "async part one"
    assert prompt =~ "async part two"
    assert prompt =~ "async part three"
    assert last_bot_text(chat) == "reply-0"
  end
end
