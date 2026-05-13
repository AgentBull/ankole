defmodule BullX.Gateway.Outbound.Finalizer do
  @moduledoc false

  alias BullX.Gateway.{Delivery, Outcome, Outbound, OutboundError, Signal, SourceConfig}
  alias BullX.Gateway.Outbound.Store

  @spec terminal_payload(Delivery.t(), Outcome.t(), non_neg_integer(), boolean()) :: map()
  def terminal_payload(%Delivery{} = delivery, %Outcome{} = outcome, attempts, replayable?) do
    %{
      "delivery" => Delivery.dump(delivery),
      "outcome" => Outcome.dump(outcome),
      "attempts" => attempts,
      "replayable" => replayable?
    }
  end

  @spec finalize_dispatch(map()) :: :ok | {:error, OutboundError.t()}
  def finalize_dispatch(%{"terminal_outcome" => %{} = terminal_outcome} = row) do
    with {:ok, delivery} <- Delivery.normalize(terminal_outcome["delivery"]),
         {:ok, outcome} <- Outcome.load(terminal_outcome["outcome"]),
         {:ok, payload, intents} <- prepare_terminal(row, delivery, outcome, terminal_outcome),
         :ok <- Store.finalize_dispatch(row, delivery, payload, intents) do
      :ok
    else
      {:error, %OutboundError{} = error} -> {:error, error}
      {:error, reason} -> {:error, store_error(reason)}
    end
  end

  @spec finalize_stream(String.t()) :: :ok | {:error, OutboundError.t()}
  def finalize_stream(stream_id) when is_binary(stream_id) do
    with %{"terminal_outcome" => %{} = terminal_outcome} = row <- Store.stream_session(stream_id),
         {:ok, delivery} <- Delivery.normalize(terminal_outcome["delivery"]),
         {:ok, outcome} <- Outcome.load(terminal_outcome["outcome"]),
         {:ok, payload, intents} <- prepare_terminal(row, delivery, outcome, terminal_outcome),
         :ok <- Store.finalize_stream(row, delivery, payload, intents) do
      :ok
    else
      nil -> {:error, store_error(:unknown_stream)}
      {:error, %OutboundError{} = error} -> {:error, error}
      {:error, reason} -> {:error, store_error(reason)}
    end
  end

  defp prepare_terminal(row, delivery, outcome, terminal_outcome) do
    source = %SourceConfig{
      adapter: delivery.adapter,
      channel_id: delivery.channel_id,
      enabled?: true
    }

    with {:ok, signal} <- Signal.outcome(source, delivery, outcome),
         {:ok, intents} <- Outbound.resolve_signal(signal) do
      payload =
        terminal_outcome
        |> Map.put("outcome", Outcome.dump(outcome))
        |> Map.put("outcome_signal_id", signal.id)

      {:ok, payload, intents}
    else
      {:error, reason} ->
        {:error,
         OutboundError.new(:store_unavailable, "Gateway outcome finalization unavailable", %{
           reason: inspect(reason),
           delivery_id: row["delivery_id"] || delivery.id,
           generation: row["generation"] || delivery.generation
         })}
    end
  end

  defp store_error(%OutboundError{} = error), do: error

  defp store_error(reason) do
    OutboundError.new(:store_unavailable, "Gateway terminal outcome store unavailable", %{
      reason: inspect(reason)
    })
  end
end
