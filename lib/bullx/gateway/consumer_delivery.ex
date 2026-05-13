defmodule BullX.Gateway.ConsumerDelivery do
  @moduledoc """
  Worker-facing internal consumption boundary for resolved Gateway deliveries.

  Implementations deliver to concrete consumers such as agent runtimes,
  workflows, inboxes, or services. They must not re-route the Signal.
  """

  alias BullX.Gateway.DeliveryIntent

  @callback deliver(DeliveryIntent.t()) :: :ok | {:retry, term()} | {:discard, term()}
end

defmodule BullX.Gateway.ConsumerDelivery.Unavailable do
  @moduledoc false

  @behaviour BullX.Gateway.ConsumerDelivery

  @impl true
  def deliver(_intent), do: {:retry, :consumer_delivery_unavailable}
end
