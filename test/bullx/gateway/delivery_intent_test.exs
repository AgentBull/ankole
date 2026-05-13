defmodule BullX.Gateway.DeliveryIntentTest do
  use ExUnit.Case, async: true

  alias BullX.Gateway.{DeliveryIntent, Signal}

  test "delivery_key is deterministic from occurrence route consumer and kind" do
    assert {:ok, first} =
             DeliveryIntent.delivery_key("occur", "route", "consumer", :signal_delivery)

    assert {:ok, ^first} =
             DeliveryIntent.delivery_key("occur", "route", "consumer", "signal_delivery")

    assert {:ok, second} =
             DeliveryIntent.delivery_key("occur", "route", "other", :signal_delivery)

    assert first != second
  end

  test "from_signal validates queue allowlist and dumps JSON payload" do
    signal = signal()

    assert {:ok, intent} =
             DeliveryIntent.from_signal(signal, %{
               "route_id" => "route.default",
               "consumer_key" => "test:default",
               "queue" => "gateway_signals",
               "consumer" => %{"type" => "test", "id" => "default"}
             })

    dumped = DeliveryIntent.dump(intent)

    assert dumped["delivery_key"] == intent.delivery_key
    assert dumped["delivery_kind"] == "signal_delivery"
    assert dumped["signal"]["bullxoccurkey"] == "feishu:event_1"
    refute Map.has_key?(dumped, "queue")
  end

  test "from_signal rejects queues outside Gateway allowlist" do
    assert {:error, {:queue_not_allowed, "other"}} =
             DeliveryIntent.from_signal(signal(), %{
               "route_id" => "route.default",
               "consumer_key" => "test:default",
               "queue" => "other",
               "consumer" => %{"type" => "test", "id" => "default"}
             })
  end

  defp signal do
    {:ok, signal} =
      Signal.new(%{
        "id" => BullX.Ext.gen_uuid_v7(),
        "source" => "bullx://gateway/feishu/main",
        "type" => "com.agentbull.x.inbound.received",
        "time" => "2026-05-13T00:00:00Z",
        "data" => %{"content" => []},
        "bullxoccurkey" => "feishu:event_1",
        "bullxadapter" => "feishu",
        "bullxchannel" => "main"
      })

    signal
  end
end
