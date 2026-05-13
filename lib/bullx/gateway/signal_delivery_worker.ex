defmodule BullX.Gateway.SignalDeliveryWorker do
  @moduledoc """
  Fixed Oban worker for Gateway Mailbox deliveries.

  The worker restores the already resolved `DeliveryIntent` and calls the
  configured consumer delivery boundary. It does not call Router.
  """

  use Oban.Worker, queue: :gateway_signals

  alias BullX.Gateway.DeliveryIntent

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, intent} <- DeliveryIntent.load(args) do
      intent
      |> consumer_delivery().deliver()
      |> map_consumer_result()
    else
      {:error, reason} -> {:cancel, {:invalid_delivery_intent, reason}}
    end
  end

  defp map_consumer_result(:ok), do: :ok
  defp map_consumer_result({:retry, reason}), do: {:error, reason}
  defp map_consumer_result({:discard, reason}), do: {:cancel, reason}
  defp map_consumer_result(other), do: {:error, {:invalid_consumer_result, other}}

  defp consumer_delivery do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(:consumer_delivery, BullX.Gateway.ConsumerDelivery.Unavailable)
  end
end
