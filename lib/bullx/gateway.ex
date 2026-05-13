defmodule BullX.Gateway do
  @moduledoc """
  Transport boundary for normalized external Signals and internal delivery.

  Gateway receives adapter-normalized inbound inputs, validates the carrier
  contract, resolves accepted Signals through Router, and persists resolved
  delivery intents through the Oban-backed Mailbox.
  """

  alias BullX.Gateway.{
    Delivery,
    DeliveryIntent,
    InboundError,
    InboundInput,
    Mailbox,
    Outbound,
    OutboundError,
    Signal,
    SourceConfig,
    Sources
  }

  @type publish_result ::
          {:ok, :accepted, Signal.t(), [Mailbox.enqueue_result()]}
          | {:error, InboundError.t()}

  @type deliver_result :: {:ok, :accepted, String.t()} | {:error, OutboundError.t()}

  @spec publish(SourceConfig.t() | map(), map()) :: publish_result()
  def publish(source, normalized_input) when is_map(normalized_input) do
    metadata = telemetry_metadata(source, normalized_input)

    :telemetry.span([:bullx, :gateway, :signal, :publish], metadata, fn ->
      result = do_publish(source, normalized_input)
      {result, Map.put(metadata, :accepted?, match?({:ok, :accepted, _signal, _mailbox}, result))}
    end)
  end

  @spec deliver(Delivery.t() | map()) :: deliver_result()
  def deliver(delivery) do
    metadata = outbound_telemetry_metadata(delivery)

    :telemetry.span([:bullx, :gateway, :delivery], metadata, fn ->
      result = Outbound.deliver(delivery)
      {result, Map.put(metadata, :accepted?, match?({:ok, :accepted, _id}, result))}
    end)
  end

  @spec replay_dead_letter(String.t()) :: deliver_result()
  def replay_dead_letter(id) when is_binary(id) do
    :telemetry.span([:bullx, :gateway, :dead_letter, :replay], %{dead_letter_id: id}, fn ->
      result = Outbound.replay_dead_letter(id)
      {result, %{dead_letter_id: id, accepted?: match?({:ok, :accepted, _id}, result)}}
    end)
  end

  @spec stream_batches(String.t(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, OutboundError.t()}
  def stream_batches(stream_id, after_seq \\ 0), do: Outbound.stream_batches(stream_id, after_seq)

  @spec publish(String.t(), String.t(), map()) :: publish_result()
  def publish(adapter, channel_id, normalized_input)
      when is_binary(adapter) and is_binary(channel_id) and is_map(normalized_input) do
    case Sources.fetch_enabled(adapter, channel_id) do
      {:ok, source} ->
        publish(source, normalized_input)

      {:error, :unknown_source} ->
        {:error, InboundError.new(:unknown_source, "unknown Gateway source")}
    end
  end

  @spec normalize_inbound(String.t(), String.t(), term(), map()) ::
          {:ok, map()} | {:error, InboundError.t()}
  def normalize_inbound(adapter, channel_id, provider_payload, request_metadata \\ %{})
      when is_binary(adapter) and is_binary(channel_id) and is_map(request_metadata) do
    with {:ok, source} <- fetch_source(adapter, channel_id),
         {:ok, input} <- call_normalize_inbound(source, provider_payload, request_metadata) do
      {:ok, input}
    end
  end

  defp do_publish(source, normalized_input) do
    with {:ok, source} <- normalize_source(source),
         {:ok, input} <- InboundInput.normalize(source, normalized_input),
         {:ok, signal} <- Signal.inbound(source, input),
         {:ok, intents} <- resolve_signal(signal),
         {:ok, mailbox_result} <- enqueue(intents) do
      {:ok, :accepted, signal, mailbox_result}
    else
      {:error, %InboundError{} = error} ->
        {:error, error}

      {:error, {:router_contract, reason}} ->
        {:error,
         InboundError.new(:router_contract, "Router returned invalid delivery intents", %{
           reason: inspect(reason)
         })}

      {:error, {:store_unavailable, reason}} ->
        {:error,
         InboundError.new(:store_unavailable, "Gateway Mailbox unavailable", %{
           reason: inspect(reason)
         })}

      {:error, :unknown_source} ->
        {:error, InboundError.new(:unknown_source, "unknown Gateway source")}

      {:error, reason} ->
        {:error,
         InboundError.new(:router_unavailable, "Router unavailable", %{reason: inspect(reason)})}
    end
  end

  defp fetch_source(adapter, channel_id) do
    case Sources.fetch_enabled(adapter, channel_id) do
      {:ok, source} ->
        {:ok, source}

      {:error, :unknown_source} ->
        {:error, InboundError.new(:unknown_source, "unknown Gateway source")}
    end
  end

  defp normalize_source(%SourceConfig{} = source), do: {:ok, source}
  defp normalize_source(%{} = source), do: Sources.normalize_runtime_source(source)

  defp call_normalize_inbound(
         %SourceConfig{adapter_module: adapter_module} = source,
         payload,
         metadata
       )
       when is_atom(adapter_module) do
    case adapter_module.normalize_inbound(payload, source, metadata) do
      {:ok, %{} = input} ->
        {:ok, input}

      {:error, reason} ->
        {:error,
         InboundError.new(:adapter_contract, "adapter failed to normalize inbound input", %{
           reason: inspect(reason)
         })}

      _other ->
        {:error, InboundError.new(:adapter_contract, "adapter returned invalid inbound input")}
    end
  catch
    :exit, reason ->
      {:error,
       InboundError.new(:adapter_contract, "adapter normalization exited", %{
         reason: inspect(reason)
       })}

    kind, reason ->
      {:error,
       InboundError.new(:adapter_contract, "adapter normalization failed", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end

  defp call_normalize_inbound(_source, _payload, _metadata) do
    {:error, InboundError.new(:unknown_source, "unknown Gateway adapter")}
  end

  @doc false
  @spec resolve_signal(Signal.t()) :: {:ok, [DeliveryIntent.t()]} | {:error, term()}
  def resolve_signal(%Signal{} = signal) do
    signal
    |> router().resolve()
    |> normalize_router_result(signal)
  catch
    :exit, reason -> {:error, {:router_unavailable, reason}}
    kind, reason -> {:error, {:router_unavailable, {kind, reason}}}
  end

  defp normalize_router_result({:ok, intents}, signal) when is_list(intents) do
    intents
    |> Enum.map(&DeliveryIntent.from_signal(signal, &1))
    |> collect_intents()
    |> validate_unique_delivery_keys()
  end

  defp normalize_router_result({:error, reason}, _signal),
    do: {:error, {:router_unavailable, reason}}

  defp normalize_router_result(_other, _signal),
    do: {:error, {:router_contract, :non_list_result}}

  defp collect_intents(intents) do
    case Enum.all?(intents, &match?({:ok, _intent}, &1)) do
      true -> {:ok, Enum.map(intents, fn {:ok, intent} -> intent end)}
      false -> {:error, {:router_contract, Enum.find(intents, &match?({:error, _reason}, &1))}}
    end
  end

  defp validate_unique_delivery_keys({:ok, intents}) do
    duplicated =
      intents
      |> Enum.frequencies_by(& &1.delivery_key)
      |> Enum.filter(fn {_key, count} -> count > 1 end)

    case duplicated do
      [] -> {:ok, intents}
      _duplicates -> {:error, {:router_contract, :duplicate_delivery_key}}
    end
  end

  defp validate_unique_delivery_keys({:error, reason}), do: {:error, reason}

  defp enqueue(intents) do
    case Mailbox.enqueue_all(intents) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:store_unavailable, reason}}
    end
  end

  defp router do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(:router, BullX.Gateway.Router.Unavailable)
  end

  defp telemetry_metadata(%SourceConfig{} = source, input) do
    %{
      adapter: source.adapter,
      channel_id: source.channel_id,
      event_type: get_in(input, ["event", "type"]),
      event_name: get_in(input, ["event", "name"]),
      signal_occurrence_key: Map.get(input, "occurrence_key") || Map.get(input, "bullxoccurkey")
    }
  end

  defp telemetry_metadata(_source, input) do
    %{
      event_type: get_in(input, ["event", "type"]),
      event_name: get_in(input, ["event", "name"]),
      signal_occurrence_key: Map.get(input, "occurrence_key") || Map.get(input, "bullxoccurkey")
    }
  end

  defp outbound_telemetry_metadata(%Delivery{} = delivery) do
    %{
      adapter: delivery.adapter,
      channel_id: delivery.channel_id,
      scope_id: delivery.scope_id,
      delivery_id: delivery.id,
      generation: delivery.generation
    }
  end

  defp outbound_telemetry_metadata(%{} = delivery) do
    %{
      adapter: Map.get(delivery, :adapter) || Map.get(delivery, "adapter"),
      channel_id: Map.get(delivery, :channel_id) || Map.get(delivery, "channel_id"),
      scope_id: Map.get(delivery, :scope_id) || Map.get(delivery, "scope_id"),
      delivery_id: Map.get(delivery, :id) || Map.get(delivery, "id"),
      generation: Map.get(delivery, :generation) || Map.get(delivery, "generation")
    }
  end

  defp outbound_telemetry_metadata(_delivery), do: %{}
end
