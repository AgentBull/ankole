defmodule BullX.Gateway.Outbound do
  @moduledoc false

  alias BullX.Gateway.{
    Delivery,
    Outbound.Dispatcher,
    Outbound.Store,
    Outbound.StreamRunner,
    OutboundError,
    Security,
    SourceConfig,
    Sources
  }

  @spec deliver(Delivery.t() | map()) ::
          {:ok, :accepted, String.t()} | {:error, OutboundError.t()}
  def deliver(delivery) do
    with {:ok, delivery} <- Delivery.normalize(delivery),
         {:ok, source} <- fetch_source(delivery),
         {:ok, delivery} <- sanitize_delivery(delivery, source),
         :ok <- validate_capabilities(delivery, source),
         {:ok, accepted?} <- accept(delivery, source) do
      maybe_notify_dispatcher(delivery, accepted?)
      {:ok, :accepted, delivery.id}
    end
  end

  @spec replay_dead_letter(String.t()) ::
          {:ok, :accepted, String.t()} | {:error, OutboundError.t()}
  def replay_dead_letter(id) when is_binary(id) do
    with {:ok, generation, snapshot} <- increment_replay_count(id),
         {:ok, delivery} <- Delivery.normalize(snapshot),
         delivery <- Delivery.put_generation(delivery, generation),
         delivery <- put_replay_extension(delivery, uuid_string(id)) do
      deliver(delivery)
    end
  end

  def replay_dead_letter(_id),
    do: {:error, OutboundError.new(:not_replayable, "invalid dead-letter id")}

  @spec stream_batches(String.t(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, OutboundError.t()}
  def stream_batches(stream_id, after_seq \\ 0)

  def stream_batches(stream_id, after_seq) when is_binary(stream_id) and is_integer(after_seq) do
    {:ok, Store.stream_chunks(stream_id, after_seq)}
  end

  def stream_batches(_stream_id, _after_seq) do
    {:error, OutboundError.new(:malformed, "invalid stream resume request")}
  end

  @doc false
  @spec resolve_signal(BullX.Gateway.Signal.t()) ::
          {:ok, [BullX.Gateway.DeliveryIntent.t()]} | {:error, term()}
  def resolve_signal(signal), do: BullX.Gateway.resolve_signal(signal)

  defp fetch_source(%Delivery{} = delivery) do
    case Sources.fetch_enabled(delivery.adapter, delivery.channel_id) do
      {:ok, source} ->
        {:ok, source}

      {:error, :unknown_source} ->
        {:error, OutboundError.new(:unknown_source, "unknown Gateway source")}
    end
  end

  defp sanitize_delivery(%Delivery{} = delivery, %SourceConfig{} = source) do
    with {:ok, sanitized} <- Security.sanitize_outbound(delivery, source),
         {:ok, delivery} <- Delivery.normalize(sanitized) do
      {:ok, delivery}
    else
      {:error, %OutboundError{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         OutboundError.new(:security_denied, "Gateway outbound delivery denied", %{
           reason: inspect(reason)
         })}
    end
  end

  defp validate_capabilities(%Delivery{} = delivery, %SourceConfig{adapter_module: module})
       when is_atom(module) do
    capabilities = module.capabilities()

    with :ok <- validate_op(delivery, capabilities),
         :ok <- validate_content_kinds(delivery, capabilities),
         :ok <- validate_stream_strategy(delivery, capabilities) do
      :ok
    end
  catch
    kind, reason ->
      {:error,
       OutboundError.new(:unsupported_op, "Gateway adapter capabilities unavailable", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end

  defp validate_capabilities(_delivery, _source) do
    {:error, OutboundError.new(:unknown_source, "unknown Gateway adapter")}
  end

  defp validate_op(%Delivery{op: op}, capabilities) do
    supported =
      Map.get(capabilities, :outbound_ops, []) ++ Map.get(capabilities, "outbound_ops", [])

    case op in Enum.map(supported, &normalize_atom/1) do
      true ->
        :ok

      false ->
        {:error,
         OutboundError.new(:unsupported_op, "Gateway adapter does not support delivery op")}
    end
  end

  defp validate_content_kinds(%Delivery{op: :stream}, _capabilities), do: :ok

  defp validate_content_kinds(%Delivery{} = delivery, capabilities) do
    supported =
      capabilities
      |> supported_content_kinds()
      |> MapSet.new()

    unsupported =
      delivery
      |> Delivery.content_kinds()
      |> Enum.reject(&MapSet.member?(supported, &1))

    case unsupported do
      [] ->
        :ok

      _unsupported ->
        {:error,
         OutboundError.new(
           :unsupported_op,
           "Gateway adapter does not support delivery content kind",
           %{
             unsupported: unsupported
           }
         )}
    end
  end

  defp validate_stream_strategy(%Delivery{op: :stream}, capabilities) do
    case stream_strategy(capabilities) do
      :unsupported ->
        {:error,
         OutboundError.new(:unsupported_op, "Gateway adapter does not support stream delivery")}

      strategy when strategy in [:native, :post_edit, :buffered] ->
        :ok

      _other ->
        {:error, OutboundError.new(:unsupported_op, "Gateway adapter stream strategy is invalid")}
    end
  end

  defp validate_stream_strategy(_delivery, _capabilities), do: :ok

  defp accept(%Delivery{op: op} = delivery, _source) when op in [:send, :edit] do
    case Store.accept_dispatch(delivery) do
      {:ok, :inserted} -> {:ok, true}
      {:ok, :duplicate} -> {:ok, true}
      {:ok, :receipt_succeeded} -> {:ok, false}
      {:error, error} -> {:error, error}
    end
  end

  defp accept(%Delivery{op: :stream} = delivery, source) do
    strategy = stream_strategy(source.adapter_module.capabilities())

    with {:ok, status, stream_id} <- Store.accept_stream(delivery, strategy) do
      case status do
        :inserted -> start_stream_runner(delivery, source, stream_id)
        :duplicate -> {:ok, true}
        :receipt_succeeded -> {:ok, false}
      end
    end
  end

  defp start_stream_runner(delivery, source, stream_id) do
    case StreamRunner.start(delivery, source, stream_id) do
      {:ok, _pid} ->
        {:ok, false}

      {:error, reason} ->
        {:error,
         OutboundError.new(:store_unavailable, "Gateway stream execution boundary unavailable", %{
           reason: inspect(reason)
         })}
    end
  end

  defp maybe_notify_dispatcher(%Delivery{op: op}, true) when op in [:send, :edit] do
    Dispatcher.notify()
  end

  defp maybe_notify_dispatcher(_delivery, _accepted?), do: :ok

  defp increment_replay_count(id) do
    case Store.increment_replay_count(id) do
      {:ok, generation, snapshot} ->
        {:ok, generation, snapshot}

      {:error, :not_replayable} ->
        {:error, OutboundError.new(:not_replayable, "dead letter is not replayable")}

      {:error, :not_found} ->
        {:error, OutboundError.new(:not_replayable, "dead letter was not found")}

      {:error, reason} ->
        {:error,
         OutboundError.new(:store_unavailable, "Gateway dead-letter store unavailable", %{
           reason: inspect(reason)
         })}
    end
  end

  defp put_replay_extension(%Delivery{} = delivery, dead_letter_id) do
    %{
      delivery
      | extensions: Map.put(delivery.extensions, "replayed_dead_letter_id", dead_letter_id)
    }
  end

  defp uuid_string(value) when is_binary(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp uuid_string(value), do: value

  defp supported_content_kinds(capabilities) do
    kinds =
      Map.get(capabilities, :content_kinds, []) ++ Map.get(capabilities, "content_kinds", [])

    Enum.map(kinds, &(&1 |> normalize_atom() |> Atom.to_string()))
  end

  defp stream_strategy(capabilities) do
    capabilities
    |> Map.get(:stream_strategy, Map.get(capabilities, "stream_strategy", :unsupported))
    |> normalize_atom()
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    case value do
      "send" -> :send
      "edit" -> :edit
      "stream" -> :stream
      "text" -> :text
      "image" -> :image
      "audio" -> :audio
      "video" -> :video
      "file" -> :file
      "card" -> :card
      "native" -> :native
      "post_edit" -> :post_edit
      "buffered" -> :buffered
      "unsupported" -> :unsupported
      _other -> :unknown
    end
  end

  defp normalize_atom(_value), do: :unknown
end
