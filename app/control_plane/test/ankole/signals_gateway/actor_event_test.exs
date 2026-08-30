defmodule Ankole.SignalsGateway.ActorEventTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.ActorEvent

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
