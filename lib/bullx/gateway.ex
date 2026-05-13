defmodule BullX.Gateway do
  @moduledoc """
  Transport boundary for normalized external Signals and internal delivery.

  Gateway receives adapter-normalized inbound inputs, validates the carrier
  contract, runs transport hooks, resolves accepted Signals through Router, and
  persists resolved delivery intents through the Oban-backed Mailbox.
  """

  alias BullX.Gateway.{
    DeliveryIntent,
    Gating,
    InboundError,
    InboundInput,
    Mailbox,
    Moderation,
    Security,
    Signal,
    SourceConfig,
    Sources
  }

  @type publish_result ::
          {:ok, :accepted, Signal.t(), [Mailbox.enqueue_result()]}
          | {:error, InboundError.t()}

  @spec publish(SourceConfig.t() | map(), map()) :: publish_result()
  def publish(source, normalized_input) when is_map(normalized_input) do
    metadata = telemetry_metadata(source, normalized_input)

    :telemetry.span([:bullx, :gateway, :signal, :publish], metadata, fn ->
      result = do_publish(source, normalized_input)
      {result, Map.put(metadata, :accepted?, match?({:ok, :accepted, _signal, _mailbox}, result))}
    end)
  end

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
         :allow <- Security.check_inbound(source, normalized_input),
         {:ok, input, gate_flags} <- Gating.check(source, input),
         {:ok, input, moderation_flags, moderated?} <- Moderation.moderate(source, input),
         input <- put_hook_extensions(input, gate_flags ++ moderation_flags, moderated?),
         {:ok, signal} <- Signal.inbound(source, input),
         {:ok, intents} <- resolve(signal),
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

  defp resolve(%Signal{} = signal) do
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

  defp put_hook_extensions(input, flags, moderated?) do
    input
    |> maybe_put_flags(flags)
    |> maybe_put_moderated(moderated?)
  end

  defp maybe_put_flags(input, []), do: input
  defp maybe_put_flags(input, flags), do: Map.put(input, "bullxflags", flags)

  defp maybe_put_moderated(input, true), do: Map.put(input, "bullxmoderated", true)
  defp maybe_put_moderated(input, _moderated?), do: input

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
end
