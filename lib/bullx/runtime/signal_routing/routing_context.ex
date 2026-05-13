defmodule BullX.Runtime.SignalRouting.RoutingContext do
  @moduledoc """
  Runtime routing projection for a Gateway Signal.

  Route rules match this struct, not raw provider payloads. The projection uses
  strict CloudEvents top-level fields and BullX top-level extension attributes;
  routing facts are loaded only from `data["routing_facts"]`.
  """

  alias BullX.Gateway.Signal

  @inbound_type "com.agentbull.x.inbound.received"
  @delivery_succeeded_type "com.agentbull.x.delivery.succeeded"
  @delivery_failed_type "com.agentbull.x.delivery.failed"
  @routing_fact_key ~r/\A[a-z][a-z0-9_.:-]{0,127}\z/

  @enforce_keys [
    :signal_id,
    :signal_type,
    :signal_time,
    :signal_occurrence_key,
    :adapter,
    :channel_id,
    :scope_id,
    :thread_id,
    :event_type,
    :event_name,
    :actor_external_id,
    :actor_bot,
    :outcome_status,
    :routing_facts,
    :data
  ]
  defstruct [
    :signal_id,
    :signal_type,
    :signal_time,
    :signal_occurrence_key,
    :adapter,
    :channel_id,
    :scope_id,
    :thread_id,
    :event_type,
    :event_name,
    :actor_external_id,
    :actor_bot,
    :outcome_status,
    :routing_facts,
    :data
  ]

  @type routing_fact_value :: String.t() | [String.t()]
  @type t :: %__MODULE__{
          signal_id: Ecto.UUID.t(),
          signal_type: String.t(),
          signal_time: DateTime.t(),
          signal_occurrence_key: String.t(),
          adapter: String.t() | nil,
          channel_id: String.t() | nil,
          scope_id: String.t() | nil,
          thread_id: String.t() | nil,
          event_type: String.t() | nil,
          event_name: String.t() | nil,
          actor_external_id: String.t() | nil,
          actor_bot: boolean() | nil,
          outcome_status: String.t() | nil,
          routing_facts: %{optional(String.t()) => routing_fact_value()},
          data: map()
        }

  @spec from_signal(Signal.t() | map()) :: {:ok, t()} | {:error, term()}
  def from_signal(%Signal{} = signal), do: project(signal)

  def from_signal(%{} = signal) do
    with {:ok, signal} <- Signal.load(signal) do
      project(signal)
    end
  end

  def from_signal(_signal), do: {:error, :invalid_signal}

  @spec external_actor(t()) :: map()
  def external_actor(%__MODULE__{actor_external_id: nil, actor_bot: nil}), do: %{}

  def external_actor(%__MODULE__{} = context) do
    %{}
    |> maybe_put("id", context.actor_external_id)
    |> maybe_put("bot", context.actor_bot)
  end

  @spec routing_snapshot(t(), map()) :: map()
  def routing_snapshot(%__MODULE__{} = context, %{} = route_snapshot) do
    %{
      "signal" => %{
        "id" => context.signal_id,
        "occurrence_key" => context.signal_occurrence_key,
        "type" => context.signal_type,
        "time" => DateTime.to_iso8601(context.signal_time)
      },
      "source" => %{
        "adapter" => context.adapter,
        "channel_id" => context.channel_id,
        "scope_id" => context.scope_id,
        "thread_id" => context.thread_id
      },
      "event" => %{
        "type" => context.event_type,
        "name" => context.event_name
      },
      "outcome" => %{
        "status" => context.outcome_status
      },
      "actor" => external_actor(context),
      "routing_facts" => context.routing_facts,
      "route" =>
        Map.take(route_snapshot, [
          "rule_id",
          "rule_key",
          "route_action",
          "destination_key",
          "agent_principal_id",
          "sink_kind",
          "reason"
        ])
    }
  end

  @spec content_snapshot(t(), :deliver_agent | :drop_signal) :: map() | nil
  def content_snapshot(_context, :drop_signal), do: nil

  def content_snapshot(%__MODULE__{signal_type: @inbound_type, data: data}, :deliver_agent) do
    data
    |> Map.take(["content", "duplex", "event", "refs", "reply_channel", "provenance"])
    |> empty_to_nil()
  end

  def content_snapshot(_context, :deliver_agent), do: nil

  defp project(%Signal{} = signal) do
    with {:ok, routing_facts} <- routing_facts(signal.data) do
      {:ok,
       signal
       |> base_context(routing_facts)
       |> project_carrier(signal)}
    end
  end

  defp base_context(%Signal{} = signal, routing_facts) do
    %__MODULE__{
      signal_id: signal.id,
      signal_type: signal.type,
      signal_time: signal.time,
      signal_occurrence_key: Signal.occurrence_key(signal),
      adapter: Map.get(signal.extensions, "bullxadapter"),
      channel_id: Map.get(signal.extensions, "bullxchannel"),
      scope_id: nil,
      thread_id: nil,
      event_type: nil,
      event_name: nil,
      actor_external_id: nil,
      actor_bot: nil,
      outcome_status: nil,
      routing_facts: routing_facts,
      data: signal.data
    }
  end

  defp project_carrier(%__MODULE__{} = context, %Signal{type: @inbound_type, data: data}) do
    event = object_or_empty(Map.get(data, "event"))
    actor = object_or_empty(Map.get(data, "actor"))

    %{
      context
      | scope_id: string_or_nil(Map.get(data, "scope_id")),
        thread_id: string_or_nil(Map.get(data, "thread_id")),
        event_type: string_or_nil(Map.get(event, "type")),
        event_name: string_or_nil(Map.get(event, "name")),
        actor_external_id: string_or_nil(Map.get(actor, "id")),
        actor_bot: bool_or_nil(Map.get(actor, "bot"))
    }
  end

  defp project_carrier(%__MODULE__{} = context, %Signal{
         type: type,
         data: data
       })
       when type in [@delivery_succeeded_type, @delivery_failed_type] do
    delivery = object_or_empty(Map.get(data, "delivery"))
    outcome = object_or_empty(Map.get(data, "outcome"))

    %{
      context
      | scope_id: string_or_nil(Map.get(delivery, "scope_id")),
        thread_id: string_or_nil(Map.get(delivery, "thread_id")),
        outcome_status: outcome_status(type, outcome)
    }
  end

  defp project_carrier(%__MODULE__{} = context, _signal), do: context

  defp outcome_status(@delivery_failed_type, _outcome), do: "failed"
  defp outcome_status(_type, outcome), do: string_or_nil(Map.get(outcome, "status"))

  defp routing_facts(data) do
    case Map.get(data, "routing_facts", %{}) do
      %{} = facts ->
        facts
        |> Enum.map(&routing_fact/1)
        |> collect_values(:routing_facts)
        |> case do
          {:ok, pairs} -> {:ok, Map.new(pairs)}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :invalid_routing_facts}
    end
  end

  defp routing_fact({key, value}) when is_binary(key) do
    with true <- Regex.match?(@routing_fact_key, key),
         {:ok, value} <- routing_fact_value(value) do
      {:ok, {key, value}}
    else
      _other -> :error
    end
  end

  defp routing_fact(_pair), do: :error

  defp routing_fact_value(value) when is_binary(value) and value != "", do: {:ok, value}

  defp routing_fact_value([_ | _] = values) do
    case Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      true -> {:ok, values}
      false -> :error
    end
  end

  defp routing_fact_value(_value), do: :error

  defp object_or_empty(%{} = value), do: value
  defp object_or_empty(_value), do: %{}

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp bool_or_nil(value) when is_boolean(value), do: value
  defp bool_or_nil(_value), do: nil

  defp collect_values(values, reason) do
    case Enum.all?(values, &match?({:ok, _value}, &1)) do
      true -> {:ok, Enum.map(values, fn {:ok, value} -> value end)}
      false -> {:error, {:invalid_list, reason}}
    end
  end

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(map), do: map

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
