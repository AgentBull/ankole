defmodule BullX.Gateway.Outbound.StreamRunner do
  @moduledoc false

  alias BullX.Gateway.{
    Delivery,
    Outcome,
    Outbound.Finalizer,
    Outbound.Store,
    Outbound.StreamBuffer
  }

  @spec start(Delivery.t(), BullX.Gateway.SourceConfig.t(), String.t()) ::
          DynamicSupervisor.on_start_child()
  def start(%Delivery{} = delivery, source, stream_id) when is_binary(stream_id) do
    Task.Supervisor.start_child(BullX.Gateway.StreamSupervisor, fn ->
      run(delivery, source, stream_id)
    end)
  end

  defp run(%Delivery{} = delivery, source, stream_id) do
    enumerable = StreamBuffer.wrap(stream_id, delivery.content)
    stream_delivery = %{delivery | content: nil}

    result =
      case stream_strategy(source.adapter_module.capabilities()) do
        :buffered ->
          safe_buffered_deliver(source.adapter_module, stream_delivery, enumerable, source)

        _strategy ->
          safe_stream(source.adapter_module, stream_delivery, enumerable, source)
      end

    outcome =
      case result do
        {:ok, outcome} ->
          case Outcome.from_adapter(stream_delivery, outcome) do
            {:ok, outcome} -> outcome
            {:error, error} -> Outcome.failed(stream_delivery, error)
          end

        {:error, error} when is_map(error) ->
          Outcome.failed(stream_delivery, error)

        _other ->
          Outcome.failed(stream_delivery, %{
            "kind" => "contract",
            "message" => "adapter returned invalid stream result"
          })
      end

    payload = Finalizer.terminal_payload(stream_delivery, outcome, 1, false)

    with :ok <- Store.capture_stream_terminal(stream_id, payload) do
      Finalizer.finalize_stream(stream_id)
    end
  end

  defp safe_buffered_deliver(adapter_module, delivery, enumerable, source)
       when is_atom(adapter_module) do
    with {:ok, content} <- buffered_content(enumerable) do
      adapter_module.deliver(%{delivery | op: :send, content: content}, source)
    end
  catch
    :exit, reason -> {:error, exception_error(:exit, reason)}
    kind, reason -> {:error, exception_error(kind, reason)}
  end

  defp safe_stream(adapter_module, delivery, enumerable, source) when is_atom(adapter_module) do
    adapter_module.stream(delivery, enumerable, source)
  catch
    :exit, reason -> {:error, exception_error(:exit, reason)}
    kind, reason -> {:error, exception_error(kind, reason)}
  end

  defp exception_error(kind, reason) do
    %{
      "kind" => "exception",
      "message" => "Gateway adapter stream failed",
      "details" => %{"kind" => inspect(kind), "reason" => inspect(reason)}
    }
  end

  defp buffered_content(enumerable) do
    text =
      enumerable
      |> Enum.reduce("", fn chunk, acc -> apply_chunk_text(acc, chunk) end)

    {:ok, [%{"kind" => "text", "body" => %{"text" => text}}]}
  end

  defp apply_chunk_text(_acc, %{"replace_text" => text}) when is_binary(text), do: text
  defp apply_chunk_text(acc, %{"text" => text}) when is_binary(text), do: acc <> text
  defp apply_chunk_text(_acc, %{replace_text: text}) when is_binary(text), do: text
  defp apply_chunk_text(acc, %{text: text}) when is_binary(text), do: acc <> text
  defp apply_chunk_text(acc, text) when is_binary(text), do: acc <> text
  defp apply_chunk_text(acc, _chunk), do: acc

  defp stream_strategy(capabilities) do
    capabilities
    |> Map.get(:stream_strategy, Map.get(capabilities, "stream_strategy", :unsupported))
    |> normalize_atom()
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    case value do
      "native" -> :native
      "post_edit" -> :post_edit
      "buffered" -> :buffered
      _other -> :unsupported
    end
  end

  defp normalize_atom(_value), do: :unsupported
end
