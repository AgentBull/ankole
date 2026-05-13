defmodule BullX.Gateway.DeliveryIntent do
  @moduledoc """
  Router output accepted by the Gateway Mailbox.

  A DeliveryIntent is a concrete internal delivery request. Mailbox and worker
  code must not route it again. `delivery_key` is the per-delivery idempotency
  boundary and is derived from occurrence key, route, consumer, and kind.
  """

  alias BullX.Gateway.{JSON, Signal}

  @delivery_kind "signal_delivery"
  @default_schema_version 1

  @enforce_keys [
    :schema_version,
    :delivery_key,
    :signal_occurrence_key,
    :route_id,
    :consumer_key,
    :delivery_kind,
    :queue,
    :priority,
    :max_attempts,
    :consumer,
    :signal,
    :metadata
  ]

  defstruct [
    :schema_version,
    :delivery_key,
    :signal_occurrence_key,
    :route_id,
    :consumer_key,
    :delivery_kind,
    :queue,
    :priority,
    :max_attempts,
    :consumer,
    :signal,
    :metadata
  ]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          delivery_key: String.t(),
          signal_occurrence_key: String.t(),
          route_id: String.t(),
          consumer_key: String.t(),
          delivery_kind: :signal_delivery,
          queue: String.t(),
          priority: 0..9,
          max_attempts: pos_integer(),
          consumer: map(),
          signal: map(),
          metadata: map()
        }

  @spec from_router(map() | t()) :: {:ok, t()} | {:error, term()}
  def from_router(%__MODULE__{} = intent), do: validate(intent)

  def from_router(%{} = attrs) do
    with {:ok, attrs} <- JSON.stringify_keys(attrs),
         {:ok, schema_version} <-
           positive_integer(attrs, "schema_version", @default_schema_version),
         {:ok, signal_occurrence_key} <- required_string(attrs, "signal_occurrence_key"),
         {:ok, route_id} <- required_string(attrs, "route_id"),
         {:ok, consumer_key} <- required_string(attrs, "consumer_key"),
         {:ok, delivery_kind} <- delivery_kind(attrs),
         {:ok, queue} <- queue(attrs),
         {:ok, priority} <- bounded_integer(attrs, "priority", 0, 0, 9),
         {:ok, max_attempts} <- positive_integer(attrs, "max_attempts", 20),
         {:ok, consumer} <- required_object(attrs, "consumer"),
         {:ok, signal} <- signal(attrs),
         {:ok, metadata} <- optional_object(attrs, "metadata", %{}),
         {:ok, delivery_key} <-
           delivery_key(attrs, signal_occurrence_key, route_id, consumer_key, delivery_kind) do
      validate(%__MODULE__{
        schema_version: schema_version,
        delivery_key: delivery_key,
        signal_occurrence_key: signal_occurrence_key,
        route_id: route_id,
        consumer_key: consumer_key,
        delivery_kind: String.to_existing_atom(delivery_kind),
        queue: queue,
        priority: priority,
        max_attempts: max_attempts,
        consumer: consumer,
        signal: signal,
        metadata: metadata
      })
    end
  end

  @spec from_signal(Signal.t(), map()) :: {:ok, t()} | {:error, term()}
  def from_signal(%Signal{} = signal, attrs) when is_map(attrs) do
    attrs
    |> Map.put("signal_occurrence_key", Signal.occurrence_key(signal))
    |> Map.put("signal", Signal.dump(signal))
    |> from_router()
  end

  @spec load(map()) :: {:ok, t()} | {:error, term()}
  def load(%{} = attrs), do: from_router(attrs)
  def load(_attrs), do: {:error, :invalid_delivery_intent}

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = intent) do
    %{
      "schema_version" => intent.schema_version,
      "delivery_key" => intent.delivery_key,
      "signal_occurrence_key" => intent.signal_occurrence_key,
      "route_id" => intent.route_id,
      "consumer_key" => intent.consumer_key,
      "delivery_kind" => Atom.to_string(intent.delivery_kind),
      "consumer" => intent.consumer,
      "signal" => intent.signal,
      "metadata" => intent.metadata
    }
  end

  @spec delivery_key(String.t(), String.t(), String.t(), atom() | String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def delivery_key(signal_occurrence_key, route_id, consumer_key, delivery_kind) do
    canonical = [signal_occurrence_key, route_id, consumer_key, to_string(delivery_kind)]

    case Jason.encode(canonical) do
      {:ok, encoded} ->
        case BullX.Ext.generic_hash(encoded) do
          hash when is_binary(hash) -> {:ok, hash}
          {:error, reason} -> {:error, {:hash_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = intent) do
    with :ok <- validate_queue(intent.queue),
         true <- JSON.json_object?(intent.consumer),
         true <- JSON.json_object?(intent.signal),
         true <- JSON.json_object?(intent.metadata) do
      {:ok, intent}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_json_payload}
    end
  end

  defp delivery_key(attrs, signal_occurrence_key, route_id, consumer_key, delivery_kind) do
    case Map.get(attrs, "delivery_key") do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        delivery_key(signal_occurrence_key, route_id, consumer_key, delivery_kind)
    end
  end

  defp delivery_kind(attrs) do
    case Map.get(attrs, "delivery_kind", @delivery_kind) do
      @delivery_kind -> {:ok, @delivery_kind}
      :signal_delivery -> {:ok, @delivery_kind}
      _other -> {:error, :invalid_delivery_kind}
    end
  end

  defp queue(attrs) do
    case Map.get(attrs, "queue") || gateway_config(:mailbox_default_queue, "gateway_signals") do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_atom(value) -> {:ok, Atom.to_string(value)}
      _other -> {:error, :invalid_queue}
    end
  end

  defp validate_queue(queue) do
    allowed = gateway_config(:mailbox_queues, ["gateway_signals"])

    case queue in Enum.map(allowed, &to_string/1) do
      true -> :ok
      false -> {:error, {:queue_not_allowed, queue}}
    end
  end

  defp signal(attrs) do
    case Map.fetch(attrs, "signal") do
      {:ok, %Signal{} = signal} -> {:ok, Signal.dump(signal)}
      {:ok, %{} = signal} -> validate_signal_map(signal)
      _other -> {:error, :invalid_signal}
    end
  end

  defp validate_signal_map(signal) do
    case Signal.load(signal) do
      {:ok, loaded} -> {:ok, Signal.dump(loaded)}
      {:error, reason} -> {:error, {:invalid_signal, reason}}
    end
  end

  defp required_object(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, %{} = value} ->
        case JSON.json_object?(value) do
          true -> {:ok, value}
          false -> {:error, {:invalid_object, key}}
        end

      _other ->
        {:error, {:required_object, key}}
    end
  end

  defp optional_object(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, %{} = value} ->
        case JSON.json_object?(value) do
          true -> {:ok, value}
          false -> {:error, {:invalid_object, key}}
        end

      :error ->
        {:ok, default}

      _other ->
        {:error, {:optional_object, key}}
    end
  end

  defp required_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:required_string, key}}
    end
  end

  defp positive_integer(attrs, key, default) do
    case Map.get(attrs, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, {:positive_integer, key}}
    end
  end

  defp bounded_integer(attrs, key, default, min, max) do
    case Map.get(attrs, key, default) do
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      _other -> {:error, {:bounded_integer, key}}
    end
  end

  defp gateway_config(key, default) do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(key, default)
  end
end
