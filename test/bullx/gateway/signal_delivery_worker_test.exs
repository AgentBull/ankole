defmodule BullX.Gateway.SignalDeliveryWorkerTest.Consumer do
  @behaviour BullX.Gateway.ConsumerDelivery

  @impl true
  def deliver(%{consumer_key: "ok"}), do: :ok
  def deliver(%{consumer_key: "retry"}), do: {:retry, :temporary}
  def deliver(%{consumer_key: "discard"}), do: {:discard, :ignored}
end

defmodule BullX.Gateway.SignalDeliveryWorkerTest do
  use BullX.DataCase, async: false

  alias BullX.Gateway.{DeliveryIntent, Signal, SignalDeliveryWorker}

  setup do
    previous = Application.get_env(:bullx, :gateway)

    Application.put_env(
      :bullx,
      :gateway,
      Keyword.put(previous, :consumer_delivery, BullX.Gateway.SignalDeliveryWorkerTest.Consumer)
    )

    on_exit(fn -> Application.put_env(:bullx, :gateway, previous) end)

    :ok
  end

  test "worker maps consumer results to Oban lifecycle values" do
    assert :ok = perform("ok")
    assert {:error, :temporary} = perform("retry")
    assert {:cancel, :ignored} = perform("discard")
  end

  test "worker retries while consumer delivery boundary is unavailable" do
    previous = Application.get_env(:bullx, :gateway)

    Application.put_env(
      :bullx,
      :gateway,
      Keyword.put(previous, :consumer_delivery, BullX.Gateway.ConsumerDelivery.Unavailable)
    )

    assert {:error, :consumer_delivery_unavailable} = perform("ok")
  end

  defp perform(consumer_key) do
    intent = intent(consumer_key)
    SignalDeliveryWorker.perform(%Oban.Job{args: DeliveryIntent.dump(intent)})
  end

  defp intent(consumer_key) do
    {:ok, signal} =
      Signal.new(%{
        "id" => BullX.Ext.gen_uuid_v7(),
        "source" => "bullx://gateway/feishu/main",
        "type" => "com.agentbull.x.inbound.received",
        "time" => "2026-05-13T00:00:00Z",
        "data" => %{"content" => []},
        "bullxoccurkey" => "feishu:event_worker_#{consumer_key}",
        "bullxadapter" => "feishu",
        "bullxchannel" => "main"
      })

    {:ok, intent} =
      DeliveryIntent.from_signal(signal, %{
        "route_id" => "route.default",
        "consumer_key" => consumer_key,
        "queue" => "gateway_signals",
        "consumer" => %{"type" => "test", "id" => consumer_key}
      })

    intent
  end
end
