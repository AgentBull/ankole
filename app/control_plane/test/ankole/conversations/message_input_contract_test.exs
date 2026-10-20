defmodule Ankole.Conversations.MessageInputContractTest do
  use ExUnit.Case, async: true

  alias Ankole.Conversations.MessageInput
  alias Ankole.Signals.Signal

  test "no pending attachment leaves initial batching to its caller and releases revisions now" do
    now = ~U[2026-10-20 12:00:00Z]
    entry = %{"provider_message_id" => "m1", "text" => "first"}
    assert MessageInput.pending_attachment_deadline([entry], now) == nil

    event = %Signal{
      id: Ecto.UUID.generate(),
      occurred_at: now,
      data: %{"entry" => entry, "entries" => [entry]}
    }

    assert {:update, %{available_at: ^now}} =
             MessageInput.revised_input_attrs(event, "supplement", entry, now)
  end

  test "pending attachment uses its observed instant and ignores malformed historical entries" do
    now = ~U[2026-10-20 12:00:00Z]

    entry = %{
      "received_at" => "2026-10-20T11:59:59Z",
      "metadata" => %{
        "attachment_materialization" => %{"state" => "pending", "observed_at" => "invalid"}
      }
    }

    assert MessageInput.pending_attachment_deadline([nil, entry], now) ==
             ~U[2026-10-20 12:00:03.000Z]
  end
end
