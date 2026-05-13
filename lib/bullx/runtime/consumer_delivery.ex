defmodule BullX.Runtime.ConsumerDelivery do
  @moduledoc """
  Runtime dispatcher for Gateway Mailbox consumer deliveries.

  Gateway delivers already resolved `DeliveryIntent` jobs to this boundary. The
  dispatcher selects a Runtime consumer by `intent.consumer["type"]`; Gateway
  does not learn SignalRouting, Agent runtime, workflow, or sink internals.
  """

  @behaviour BullX.Gateway.ConsumerDelivery

  alias BullX.Gateway.DeliveryIntent
  alias BullX.Runtime.SignalRouting.RouteConsumer

  @impl true
  def deliver(%DeliveryIntent{consumer: %{"type" => "signal_route_intent"}} = intent) do
    RouteConsumer.deliver(intent)
  end

  def deliver(%DeliveryIntent{consumer: %{"type" => type}}) do
    {:discard, {:unknown_consumer, type}}
  end

  def deliver(%DeliveryIntent{}), do: {:discard, {:unknown_consumer, nil}}
end
