defmodule BullX.Gateway.Signal do
  @moduledoc """
  BullX's normalized transport Signal envelope.

  The serialized form is strict CloudEvents 1.0 JSON Event Format: extension
  attributes are flat top-level properties, never a nested `extensions` map.
  Gateway does not persist Signals as rows; `dump/1` is the payload format used
  inside Mailbox jobs and outcome publication data.
  """

  alias BullX.Gateway.{Delivery, InboundError, JSON, Outcome, SourceConfig}

  @base_fields ~w(id specversion source type subject time datacontenttype dataschema data)
  @gateway_types ~w(
    com.agentbull.x.inbound.received
    com.agentbull.x.delivery.succeeded
    com.agentbull.x.delivery.failed
  )

  @enforce_keys [:id, :source, :type, :time, :data, :extensions]
  defstruct [
    :id,
    :source,
    :type,
    :subject,
    :time,
    :dataschema,
    :data,
    specversion: "1.0",
    datacontenttype: "application/json",
    extensions: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          specversion: String.t(),
          source: String.t(),
          type: String.t(),
          subject: String.t() | nil,
          time: DateTime.t(),
          datacontenttype: String.t(),
          dataschema: String.t() | nil,
          data: map(),
          extensions: map()
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, attrs} <- JSON.stringify_keys(attrs),
         :ok <- reject_nested_extensions(attrs),
         {:ok, id} <- required_string(attrs, "id"),
         :ok <- validate_uuid(id),
         {:ok, source} <- required_string(attrs, "source"),
         :ok <- validate_source(source),
         {:ok, type} <- required_string(attrs, "type"),
         :ok <- validate_type(type),
         :ok <- validate_constant(attrs, "specversion", "1.0"),
         :ok <- validate_constant(attrs, "datacontenttype", "application/json"),
         {:ok, time} <- normalize_time(Map.get(attrs, "time")),
         {:ok, data} <- required_object(attrs, "data"),
         {:ok, extensions} <- extensions(attrs),
         :ok <- validate_gateway_extensions(type, extensions) do
      {:ok,
       %__MODULE__{
         id: id,
         source: source,
         type: type,
         subject: optional_string(attrs, "subject"),
         time: time,
         dataschema: optional_string(attrs, "dataschema"),
         data: data,
         extensions: extensions
       }}
    end
  end

  @spec inbound(SourceConfig.t(), map(), keyword()) :: {:ok, t()} | {:error, InboundError.t()}
  def inbound(%SourceConfig{} = source, input, opts \\ []) when is_map(input) do
    attrs = %{
      "id" => Keyword.get_lazy(opts, :id, &BullX.Ext.gen_uuid_v7/0),
      "source" => SourceConfig.source_uri(source),
      "type" => "com.agentbull.x.inbound.received",
      "time" => Map.get(input, "time") || DateTime.to_iso8601(DateTime.utc_now()),
      "data" => Map.fetch!(input, "data"),
      "bullxoccurkey" => Map.fetch!(input, "occurrence_key"),
      "bullxadapter" => source.adapter,
      "bullxchannel" => source.channel_id
    }

    attrs
    |> new()
    |> case do
      {:ok, signal} ->
        {:ok, signal}

      {:error, reason} ->
        {:error,
         InboundError.new(:malformed, "invalid Signal envelope", %{reason: inspect(reason)})}
    end
  end

  @spec outcome(SourceConfig.t(), Delivery.t(), Outcome.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def outcome(%SourceConfig{} = source, %Delivery{} = delivery, %Outcome{} = outcome, opts \\ []) do
    attrs = %{
      "id" => Keyword.get_lazy(opts, :id, &BullX.Ext.gen_uuid_v7/0),
      "source" => SourceConfig.source_uri(source),
      "type" => outcome_type(outcome),
      "time" => Keyword.get_lazy(opts, :time, fn -> DateTime.to_iso8601(DateTime.utc_now()) end),
      "data" => outcome_data(delivery, outcome),
      "bullxoccurkey" => "gateway:delivery:#{delivery.id}:#{delivery.generation}:outcome",
      "bullxadapter" => source.adapter,
      "bullxchannel" => source.channel_id
    }

    new(attrs)
  end

  @spec load(map()) :: {:ok, t()} | {:error, term()}
  def load(%{} = map), do: new(map)
  def load(_value), do: {:error, :invalid_signal}

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = signal) do
    %{
      "id" => signal.id,
      "specversion" => "1.0",
      "source" => signal.source,
      "type" => signal.type,
      "time" => DateTime.to_iso8601(signal.time),
      "datacontenttype" => "application/json",
      "data" => signal.data
    }
    |> maybe_put("subject", signal.subject)
    |> maybe_put("dataschema", signal.dataschema)
    |> Map.merge(signal.extensions)
  end

  @spec occurrence_key(t()) :: String.t()
  def occurrence_key(%__MODULE__{extensions: %{"bullxoccurkey" => occurrence_key}}),
    do: occurrence_key

  defp reject_nested_extensions(%{"extensions" => _value}), do: {:error, :nested_extensions}
  defp reject_nested_extensions(_attrs), do: :ok

  defp validate_constant(attrs, key, value) do
    case Map.get(attrs, key, value) do
      ^value -> :ok
      _other -> {:error, {:invalid_constant, key}}
    end
  end

  defp extensions(attrs) do
    attrs
    |> Map.drop(@base_fields)
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, value}, {:ok, acc} ->
        with :ok <- validate_extension_name(key),
             true <- JSON.json_neutral?(value) do
          {:cont, {:ok, Map.put(acc, key, value)}}
        else
          _other -> {:halt, {:error, {:invalid_extension, key}}}
        end
    end)
  end

  defp validate_extension_name(name) do
    case Regex.match?(~r/\A[a-z0-9]+\z/, name) do
      true -> :ok
      false -> {:error, {:invalid_extension_name, name}}
    end
  end

  defp validate_gateway_extensions(type, extensions) when type in @gateway_types do
    with {:ok, occurkey} <- Map.fetch(extensions, "bullxoccurkey"),
         true <- is_binary(occurkey) and occurkey != "",
         {:ok, adapter} <- Map.fetch(extensions, "bullxadapter"),
         true <- is_binary(adapter) and adapter != "",
         {:ok, channel} <- Map.fetch(extensions, "bullxchannel"),
         true <- is_binary(channel) and channel != "" do
      :ok
    else
      _other -> {:error, :missing_gateway_extensions}
    end
  end

  defp validate_gateway_extensions(_type, extensions) do
    case Map.fetch(extensions, "bullxoccurkey") do
      {:ok, value} when is_binary(value) and value != "" -> :ok
      _other -> {:error, :missing_occurrence_key}
    end
  end

  defp validate_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, ^value} -> :ok
      {:ok, _canonical} -> {:error, :noncanonical_uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp validate_source(source) do
    case URI.parse(source) do
      %URI{} -> :ok
      _other -> {:error, :invalid_source}
    end
  end

  defp validate_type(type) do
    case Regex.match?(~r/\A[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+\z/, type) do
      true -> :ok
      false -> {:error, :invalid_type}
    end
  end

  defp normalize_time(%DateTime{} = time) do
    time
    |> DateTime.to_unix(:microsecond)
    |> DateTime.from_unix!(:microsecond)
    |> then(&{:ok, &1})
  end

  defp normalize_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> normalize_time(time)
      {:error, reason} -> {:error, {:invalid_time, reason}}
    end
  end

  defp normalize_time(_value), do: {:error, :invalid_time}

  defp required_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:required_string, key}}
    end
  end

  defp required_object(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_map(value) ->
        case JSON.json_object?(value) do
          true -> {:ok, value}
          false -> {:error, {:invalid_object, key}}
        end

      _other ->
        {:error, {:required_object, key}}
    end
  end

  defp optional_string(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp outcome_type(%Outcome{status: status}) when status in [:sent, :degraded],
    do: "com.agentbull.x.delivery.succeeded"

  defp outcome_type(%Outcome{status: :failed}), do: "com.agentbull.x.delivery.failed"

  defp outcome_data(%Delivery{} = delivery, %Outcome{} = outcome) do
    %{
      "delivery" => %{
        "id" => delivery.id,
        "generation" => delivery.generation,
        "adapter" => delivery.adapter,
        "channel_id" => delivery.channel_id,
        "scope_id" => delivery.scope_id,
        "thread_id" => delivery.thread_id
      },
      "outcome" => %{
        "status" => Atom.to_string(outcome.status),
        "external_message_ids" => outcome.external_message_ids,
        "primary_external_id" => outcome.primary_external_id,
        "warnings" => outcome.warnings,
        "error" => outcome.error
      }
    }
  end
end
