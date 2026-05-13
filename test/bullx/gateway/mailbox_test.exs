defmodule BullX.Gateway.MailboxTest do
  use BullX.DataCase, async: false

  import Ecto.Query

  alias BullX.Gateway.{DeliveryIntent, Mailbox, Signal, SignalDeliveryWorker}
  alias BullX.Repo

  test "enqueue_all inserts Oban jobs with delivery_key dedupe" do
    intent = intent("feishu:event_1", "route.default", "test:default")

    assert {:ok, [{:enqueued, %Oban.Job{} = job}]} = Mailbox.enqueue_all([intent])
    assert job.worker == inspect(SignalDeliveryWorker)
    assert job.queue == "gateway_signals"
    assert job.args["delivery_key"] == intent.delivery_key
    assert job.meta["delivery_key"] == intent.delivery_key

    assert {:ok, [{:duplicate, %Oban.Job{}}]} = Mailbox.enqueue_all([intent])

    count =
      Oban.Job
      |> where([job], job.worker == ^inspect(SignalDeliveryWorker))
      |> Repo.aggregate(:count)

    assert count == 1
  end

  test "enqueue_all rolls back all jobs when one intent is invalid" do
    valid = intent("feishu:event_2", "route.default", "test:default")
    invalid = %{valid | queue: "outside"}

    assert {:error, {:queue_not_allowed, "outside"}} = Mailbox.enqueue_all([valid, invalid])

    count =
      Oban.Job
      |> where([job], job.worker == ^inspect(SignalDeliveryWorker))
      |> Repo.aggregate(:count)

    assert count == 0
  end

  defp intent(occurrence_key, route_id, consumer_key) do
    {:ok, signal} =
      Signal.new(%{
        "id" => BullX.Ext.gen_uuid_v7(),
        "source" => "bullx://gateway/feishu/main",
        "type" => "com.agentbull.x.inbound.received",
        "time" => "2026-05-13T00:00:00Z",
        "data" => %{"content" => []},
        "bullxoccurkey" => occurrence_key,
        "bullxadapter" => "feishu",
        "bullxchannel" => "main"
      })

    {:ok, intent} =
      DeliveryIntent.from_signal(signal, %{
        "route_id" => route_id,
        "consumer_key" => consumer_key,
        "queue" => "gateway_signals",
        "consumer" => %{"type" => "test", "id" => consumer_key}
      })

    intent
  end
end
