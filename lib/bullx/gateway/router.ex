defmodule BullX.Gateway.Router do
  @moduledoc """
  Minimal Gateway-to-Router boundary.

  Router implementations own rule matching and consumer selection. Gateway only
  calls `resolve/1`, validates the returned `DeliveryIntent` values, and hands
  them to the Mailbox.
  """

  alias BullX.Gateway.Signal

  @callback resolve(Signal.t()) ::
              {:ok, [BullX.Gateway.DeliveryIntent.t() | map()]} | {:error, term()}
end

defmodule BullX.Gateway.Router.Unavailable do
  @moduledoc false

  @behaviour BullX.Gateway.Router

  @impl true
  def resolve(_signal), do: {:error, :router_unavailable}
end
