defmodule BullX.Runtime.SignalRouting.Router do
  @moduledoc """
  Gateway Router implementation backed by Runtime Signal routing rules.

  The router projects a Gateway Signal into a `RoutingContext`, reads the
  reconstructible route-rule cache, evaluates deterministic fixed-column
  matches, and returns Gateway `DeliveryIntent` values. It does not persist
  route decisions; Mailbox consumption owns that durable write.
  """

  @behaviour BullX.Gateway.Router

  alias BullX.Gateway.Signal
  alias BullX.Runtime.SignalRouting
  alias BullX.Runtime.SignalRouting.{Cache, Matcher, RouteIntent, RoutingContext, Rule}

  @impl true
  def resolve(%Signal{} = signal) do
    :telemetry.span([:bullx, :runtime, :signal_routing, :router], %{}, fn ->
      result = do_resolve(signal)
      {result, telemetry_metadata(signal, result)}
    end)
  end

  defp do_resolve(%Signal{} = signal) do
    with {:ok, context} <- RoutingContext.from_signal(signal),
         {:ok, rules} <- Cache.snapshot(),
         {:ok, rules} <- active_winners(context, rules),
         {:ok, intents} <- build_intents(signal, rules) do
      {:ok, intents}
    else
      {:error, :not_running} -> {:error, :signal_routing_unavailable}
      {:error, :down} -> {:error, :signal_routing_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_winners(_context, []), do: {:ok, []}

  defp active_winners(context, rules) do
    rules =
      rules
      |> Enum.filter(&active_destination?/1)
      |> then(&Matcher.match(context, &1))

    {:ok, rules}
  end

  defp active_destination?(%Rule{route_action: :drop_signal}), do: true

  defp active_destination?(%Rule{route_action: :deliver_agent, agent_principal_id: id}) do
    SignalRouting.agent_destination_active?(id)
  end

  defp active_destination?(_rule), do: false

  defp build_intents(signal, rules) do
    rules
    |> Enum.map(&RouteIntent.build(signal, &1))
    |> collect_intents()
  end

  defp collect_intents(results) do
    case Enum.all?(results, &match?({:ok, _intent}, &1)) do
      true -> {:ok, Enum.map(results, fn {:ok, intent} -> intent end)}
      false -> {:error, {:route_intent_failed, Enum.find(results, &match?({:error, _}, &1))}}
    end
  end

  defp telemetry_metadata(%Signal{} = signal, result) do
    %{
      signal_id: signal.id,
      signal_occurrence_key: Signal.occurrence_key(signal),
      signal_type: signal.type,
      adapter: Map.get(signal.extensions, "bullxadapter"),
      channel_id: Map.get(signal.extensions, "bullxchannel"),
      routed?: match?({:ok, [_ | _]}, result)
    }
  end
end
