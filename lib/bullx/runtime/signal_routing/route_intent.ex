defmodule BullX.Runtime.SignalRouting.RouteIntent do
  @moduledoc false

  alias BullX.Gateway.{DeliveryIntent, Signal}
  alias BullX.Runtime.SignalRouting.Rule

  @consumer_type "signal_route_intent"
  @schema_version 1

  @type consumer_snapshot :: %{
          required(:type) => String.t(),
          required(:schema_version) => pos_integer(),
          required(:rule_id) => Ecto.UUID.t(),
          required(:rule_key) => String.t(),
          required(:route_action) => :deliver_agent | :drop_signal,
          required(:destination_key) => String.t(),
          required(:agent_principal_id) => Ecto.UUID.t() | nil,
          required(:sink_kind) => :blackhole | nil,
          required(:reason) => String.t()
        }

  @spec build(Signal.t(), Rule.t()) :: {:ok, DeliveryIntent.t()} | {:error, term()}
  def build(%Signal{} = signal, %Rule{} = rule) do
    DeliveryIntent.from_signal(signal, %{
      "route_id" => route_id(rule),
      "consumer_key" => consumer_key(rule),
      "consumer" => consumer(rule),
      "metadata" => %{}
    })
  end

  @spec load_consumer(DeliveryIntent.t()) :: {:ok, consumer_snapshot()} | {:error, term()}
  def load_consumer(%DeliveryIntent{consumer: %{} = consumer}) do
    with {:ok, @consumer_type} <- required_string(consumer, "type"),
         {:ok, @schema_version} <- schema_version(consumer),
         {:ok, rule_id} <- required_uuid(consumer, "rule_id"),
         {:ok, rule_key} <- required_string(consumer, "rule_key"),
         {:ok, route_action} <- route_action(consumer),
         {:ok, destination_key} <- required_string(consumer, "destination_key"),
         {:ok, agent_principal_id} <- optional_uuid(consumer, "agent_principal_id"),
         {:ok, sink_kind} <- sink_kind(consumer),
         {:ok, reason} <- required_string(consumer, "reason") do
      {:ok,
       %{
         type: @consumer_type,
         schema_version: @schema_version,
         rule_id: rule_id,
         rule_key: rule_key,
         route_action: route_action,
         destination_key: destination_key,
         agent_principal_id: agent_principal_id,
         sink_kind: sink_kind,
         reason: reason
       }}
    else
      {:ok, other} -> {:error, {:invalid_consumer, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  def load_consumer(_intent), do: {:error, :invalid_consumer}

  @spec route_id(Rule.t()) :: String.t()
  def route_id(%Rule{id: id}), do: "signal_route_rule:#{id}"

  @spec consumer_key(Rule.t()) :: String.t()
  def consumer_key(%Rule{} = rule), do: "signal_route_destination:#{Rule.destination_key(rule)}"

  defp consumer(%Rule{} = rule) do
    %{
      "type" => @consumer_type,
      "schema_version" => @schema_version,
      "rule_id" => rule.id,
      "rule_key" => rule.key,
      "route_action" => Rule.route_action_string(rule),
      "destination_key" => Rule.destination_key(rule),
      "agent_principal_id" => rule.agent_principal_id,
      "sink_kind" => Rule.sink_kind_string(rule),
      "reason" => rule.reason
    }
  end

  defp schema_version(consumer) do
    case Map.get(consumer, "schema_version") do
      @schema_version -> {:ok, @schema_version}
      _other -> {:error, :invalid_schema_version}
    end
  end

  defp route_action(consumer) do
    case Map.get(consumer, "route_action") do
      "deliver_agent" -> {:ok, :deliver_agent}
      "drop_signal" -> {:ok, :drop_signal}
      _other -> {:error, :invalid_route_action}
    end
  end

  defp sink_kind(consumer) do
    case Map.get(consumer, "sink_kind") do
      nil -> {:ok, nil}
      "blackhole" -> {:ok, :blackhole}
      _other -> {:error, :invalid_sink_kind}
    end
  end

  defp required_uuid(map, key) do
    with {:ok, value} when is_binary(value) <- Map.fetch(map, key),
         {:ok, uuid} <- Ecto.UUID.cast(value) do
      {:ok, uuid}
    else
      _other -> {:error, {:required_uuid, key}}
    end
  end

  defp optional_uuid(map, key) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, {:optional_uuid, key}}
        end

      _other ->
        {:error, {:optional_uuid, key}}
    end
  end

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:required_string, key}}
    end
  end
end
