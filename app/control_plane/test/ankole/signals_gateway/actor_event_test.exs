defmodule Ankole.SignalsGateway.ActorEventTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.ActorEvent

  test "a resolved reply reference is a withdrawal source, not a mirrored source" do
    event = %ActorEvent{
      source_entry_id: "question",
      payload: %{
        "data" => %{
          "entry" => %{
            "source_entry_id" => "question",
            "reply_to" => %{"resolution" => "resolved", "source_entry_id" => "quoted"}
          },
          "entries" => [%{"source_entry_id" => "question"}]
        }
      }
    }

    assert ActorEvent.source_entry_ids(event) == ["question"]
    assert ActorEvent.withdrawal_source_entry_ids(event) == ["question", "quoted"]
    assert ActorEvent.input_source_entry_ids(event) == ["question"]

    for resolution <- ["unresolved", "unavailable"] do
      payload = put_in(event.payload, ["data", "entry", "reply_to", "resolution"], resolution)
      assert ActorEvent.source_entry_ids(%{event | payload: payload}) == ["question"]
      assert ActorEvent.withdrawal_source_entry_ids(%{event | payload: payload}) == ["question"]
    end
  end

  test "batched inputs and mirrored context remain withdrawal sources" do
    event = %ActorEvent{
      source_entry_id: "question",
      payload: %{
        "data" => %{
          "entry" => %{
            "reply_to" => %{"resolution" => "resolved", "source_entry_id" => "context"}
          },
          "entries" => [
            %{"source_entry_id" => "question"},
            %{"source_entry_id" => "batch"}
          ],
          "channel_context" => %{"messages" => [%{"source_entry_id" => "context"}]}
        }
      }
    }

    assert ActorEvent.input_source_entry_ids(event) == ["question", "batch"]
    assert ActorEvent.source_entry_ids(event) == ["question", "batch", "context"]
    assert ActorEvent.withdrawal_source_entry_ids(event) == ["question", "batch", "context"]
  end

  test "an input removal does not retain its entry or reply as a live source" do
    event = %ActorEvent{
      type: "input.revised",
      source_entry_id: "question",
      payload: %{
        "data" => %{
          "revision" => %{"kind" => "remove"},
          "entry" => %{
            "reply_to" => %{"resolution" => "resolved", "source_entry_id" => "quoted"}
          },
          "entries" => [%{"source_entry_id" => "question"}],
          "channel_context" => %{"messages" => [%{"source_entry_id" => "context"}]}
        }
      }
    }

    assert ActorEvent.input_source_entry_ids(event) == []
    assert ActorEvent.source_entry_ids(event) == []
    assert ActorEvent.withdrawal_source_entry_ids(event) == []
  end

  test "workflow completion events preserve their frozen delivery snapshot" do
    delivery = %{
      "channel_id" => "channel-1",
      "provider_thread_id" => "thread-1",
      "reply_to_source_entry_id" => "entry-1"
    }

    for type <- ["workflow.run.completed", "workflow.run.failed"] do
      event = %ActorEvent{
        type: type,
        payload: %{"data" => %{"reply_route" => %{"delivery" => delivery}}}
      }

      assert ActorEvent.scheduled_delivery_snapshot(event) == delivery
    end
  end

  test "workflow cancellation does not invent a scheduled delivery route" do
    event = %ActorEvent{
      type: "workflow.run.cancelled",
      payload: %{"data" => %{"reply_route" => %{"delivery" => %{"channel_id" => "wrong"}}}}
    }

    assert ActorEvent.scheduled_delivery_snapshot(event) == nil
  end
end
