defmodule BullXGateway.DeliveryTelemetryTest do
  use ExUnit.Case, async: false

  alias BullXGateway.Delivery
  alias BullXGateway.Delivery.{Content, Outcome}

  test "emits common adapter delivery span metadata" do
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        {handler_id, :start},
        [:bullx, :test_adapter, :delivery, :start],
        fn event, measurements, metadata, pid ->
          send(pid, {:delivery_start, event, measurements, metadata})
        end,
        self()
      )

    :ok =
      :telemetry.attach(
        {handler_id, :stop},
        [:bullx, :test_adapter, :delivery, :stop],
        fn event, measurements, metadata, pid ->
          send(pid, {:delivery_stop, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn ->
      :telemetry.detach({handler_id, :start})
      :telemetry.detach({handler_id, :stop})
    end)

    delivery = %Delivery{
      id: "delivery-1",
      op: :send,
      channel: {:test_adapter, "default"},
      scope_id: "scope-1",
      content: %Content{kind: :text, body: %{"text" => "hello"}}
    }

    outcome = Outcome.new_success(delivery.id, :sent)

    assert {:ok, ^outcome} =
             Delivery.telemetry_span(:test_adapter, delivery, fn -> {:ok, outcome} end)

    assert_receive {:delivery_start, [:bullx, :test_adapter, :delivery, :start],
                    start_measurements, start_metadata}

    assert is_integer(start_measurements.system_time)
    assert start_metadata.channel == {:test_adapter, "default"}
    assert start_metadata.delivery_id == "delivery-1"
    assert start_metadata.op == :send
    assert start_metadata.scope_id == "scope-1"

    assert_receive {:delivery_stop, [:bullx, :test_adapter, :delivery, :stop], measurements,
                    metadata}

    assert is_integer(measurements.duration)
    assert metadata.outcome == :sent
  end
end
