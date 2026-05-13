defmodule BullX.Runtime.SignalRouting.RouteConsumer do
  @moduledoc false

  alias BullX.Gateway.{DeliveryIntent, Signal}
  alias BullX.Repo
  alias BullX.Runtime.SignalRouting
  alias BullX.Runtime.SignalRouting.{RouteDecision, RouteIntent, RoutingContext, Rule}

  @spec deliver(DeliveryIntent.t()) :: :ok | {:retry, term()} | {:discard, term()}
  def deliver(%DeliveryIntent{} = intent) do
    do_deliver(intent)
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:retry, error}
  end

  defp do_deliver(%DeliveryIntent{} = intent) do
    with {:ok, signal} <- Signal.load(intent.signal),
         {:ok, context} <- RoutingContext.from_signal(signal),
         {:ok, consumer} <- RouteIntent.load_consumer(intent),
         :ok <- ensure_destination_available(consumer),
         attrs <- decision_attrs(intent, context, consumer),
         :ok <- insert_or_get_decision(attrs) do
      :ok
    else
      {:discard, reason} -> {:discard, reason}
      {:error, reason} -> {:discard, reason}
    end
  end

  defp ensure_destination_available(%{route_action: :deliver_agent, agent_principal_id: id}) do
    case SignalRouting.agent_destination_active?(id) do
      true -> :ok
      false -> {:discard, {:agent_destination_unavailable, id}}
    end
  end

  defp ensure_destination_available(%{route_action: :drop_signal}), do: :ok

  defp decision_attrs(intent, context, consumer) do
    route_action = consumer.route_action
    consumer_snapshot = consumer_snapshot(consumer)

    %{
      delivery_key: intent.delivery_key,
      signal_occurrence_key: intent.signal_occurrence_key,
      signal_id: context.signal_id,
      signal_type: context.signal_type,
      signal_time: context.signal_time,
      adapter: context.adapter,
      channel_id: context.channel_id,
      scope_id: context.scope_id,
      thread_id: context.thread_id,
      event_type: context.event_type,
      event_name: context.event_name,
      actor_bot: context.actor_bot,
      external_actor: RoutingContext.external_actor(context),
      destination_key: consumer.destination_key,
      route_action: route_action,
      agent_principal_id: consumer.agent_principal_id,
      sink_kind: consumer.sink_kind,
      rule_id: persisted_rule_id(consumer.rule_id),
      rule_key: consumer.rule_key,
      reason: consumer.reason,
      routing_snapshot: RoutingContext.routing_snapshot(context, consumer_snapshot),
      content_snapshot: RoutingContext.content_snapshot(context, route_action),
      decision_metadata: %{}
    }
  end

  defp persisted_rule_id(rule_id) do
    case Repo.get(Rule, rule_id) do
      %Rule{id: id} -> id
      nil -> nil
    end
  end

  defp insert_or_get_decision(attrs) do
    %RouteDecision{}
    |> RouteDecision.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, decision} ->
        emit_decision(:persisted, decision)
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        handle_insert_error(attrs, changeset)
    end
  end

  defp handle_insert_error(attrs, changeset) do
    case Repo.get_by(RouteDecision,
           signal_id: attrs.signal_id,
           destination_key: attrs.destination_key
         ) do
      %RouteDecision{} = decision ->
        emit_decision(:duplicate, decision)
        :ok

      nil ->
        {:discard, {:invalid_route_decision, changeset}}
    end
  end

  defp emit_decision(status, %RouteDecision{} = decision) do
    :telemetry.execute(
      [:bullx, :runtime, :signal_routing, :route_decision, status],
      %{count: 1},
      %{
        route_action: decision.route_action,
        destination_key: decision.destination_key,
        agent_principal_id: decision.agent_principal_id,
        sink_kind: decision.sink_kind,
        signal_id: decision.signal_id,
        signal_occurrence_key: decision.signal_occurrence_key,
        rule_id: decision.rule_id,
        rule_key: decision.rule_key
      }
    )
  end

  defp consumer_snapshot(consumer) do
    %{
      "type" => consumer.type,
      "schema_version" => consumer.schema_version,
      "rule_id" => consumer.rule_id,
      "rule_key" => consumer.rule_key,
      "route_action" => Atom.to_string(consumer.route_action),
      "destination_key" => consumer.destination_key,
      "agent_principal_id" => consumer.agent_principal_id,
      "sink_kind" => atom_or_nil(consumer.sink_kind),
      "reason" => consumer.reason
    }
  end

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(value), do: Atom.to_string(value)
end
