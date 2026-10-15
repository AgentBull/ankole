defmodule Ankole.Signals.SignalTest do
  use ExUnit.Case, async: true
  alias Ankole.Signals.Signal

  test "a resolved reply reference is a withdrawal source, not a mirrored source" do
    event = %Signal{
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      provider_message_id: "question",
      data: %{
        "entry" => %{
          "provider_message_id" => "question",
          "reply_to" => %{"resolution" => "resolved", "provider_message_id" => "quoted"}
        },
        "entries" => [%{"provider_message_id" => "question"}]
      }
    }

    assert Signal.provider_message_ids(event) == ["question"]
    assert Signal.withdrawal_provider_message_ids(event) == ["question", "quoted"]
    assert Signal.input_provider_message_ids(event) == ["question"]

    for resolution <- ["unresolved", "unavailable"] do
      payload = put_in(event.data, ["entry", "reply_to", "resolution"], resolution)
      assert Signal.provider_message_ids(%{event | data: payload}) == ["question"]
      assert Signal.withdrawal_provider_message_ids(%{event | data: payload}) == ["question"]
    end
  end

  test "only current batched inputs and explicit quotes are withdrawal sources" do
    event = %Signal{
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      provider_message_id: "question",
      data: %{
        "entry" => %{
          "reply_to" => %{"resolution" => "resolved", "provider_message_id" => "context"}
        },
        "entries" => [%{"provider_message_id" => "question"}, %{"provider_message_id" => "batch"}]
      }
    }

    assert Signal.input_provider_message_ids(event) == ["question", "batch"]
    assert Signal.provider_message_ids(event) == ["question", "batch"]
    assert Signal.withdrawal_provider_message_ids(event) == ["question", "batch", "context"]
  end

  test "an input removal does not retain its entry or reply as a live source" do
    event = %Signal{
      type: "input.revised",
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      provider_message_id: "question",
      data: %{
        "revision" => %{"kind" => "remove"},
        "entry" => %{
          "reply_to" => %{"resolution" => "resolved", "provider_message_id" => "quoted"}
        },
        "entries" => [%{"provider_message_id" => "question"}]
      }
    }

    assert Signal.input_provider_message_ids(event) == []
    assert Signal.provider_message_ids(event) == []
    assert Signal.withdrawal_provider_message_ids(event) == []
  end

  test "arbitrary CloudEvent data does not claim provider message provenance" do
    for conversation_id <- [nil, Ecto.UUID.generate()] do
      event = %Signal{
        conversation_id: conversation_id,
        type: "issue.changed",
        data: %{
          "entry" => %{
            "reply_to" => %{"resolution" => "resolved", "provider_message_id" => "quoted"}
          },
          "entries" => [%{"provider_message_id" => "invented"}, 42]
        }
      }

      assert Signal.input_provider_message_ids(event) == []
      assert Signal.provider_message_ids(event) == []
      assert Signal.withdrawal_provider_message_ids(event) == []
    end
  end

  test "workflow completion events preserve their frozen delivery snapshot" do
    delivery = %{
      "channel_id" => "channel-1",
      "provider_thread_id" => "thread-1",
      "reply_to_provider_message_id" => "entry-1"
    }

    for type <- ["workflow.run.completed", "workflow.run.failed"] do
      event = %Signal{
        producer: :kernel,
        type: type,
        data: %{"reply_route" => %{"delivery" => delivery}}
      }

      assert Signal.scheduled_delivery_snapshot(event) == delivery
      assert Signal.scheduled_delivery_snapshot(%{event | producer: :external}) == nil
    end
  end

  test "workflow cancellation does not invent a scheduled delivery route" do
    event = %Signal{
      type: "workflow.run.cancelled",
      data: %{"reply_route" => %{"delivery" => %{"channel_id" => "wrong"}}}
    }

    assert Signal.scheduled_delivery_snapshot(event) == nil
  end
end
