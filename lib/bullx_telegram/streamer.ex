defmodule BullXTelegram.Streamer do
  @moduledoc """
  Telegram streaming delivery state machine.
  """

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Outcome
  alias BullXTelegram.{Config, ContentMapper, Delivery, Error}

  @spec stream(GatewayDelivery.t(), Enumerable.t() | nil, Config.t()) ::
          {:ok, Outcome.adapter_success_t()} | {:error, map()}
  def stream(%GatewayDelivery{} = delivery, nil, _config) do
    {:error,
     Error.payload("Telegram stream content is not replayable", %{"delivery_id" => delivery.id})}
  end

  def stream(%GatewayDelivery{} = delivery, enumerable, %Config{} = config) do
    initial = %{
      delivery: delivery,
      config: config,
      current_text: "",
      message_ids: [],
      last_update_at: nil,
      warnings: []
    }

    with {:ok, state} <- consume(enumerable, initial),
         {:ok, state} <- finalize(state) do
      {:ok,
       Outcome.new_success(delivery.id, :sent,
         external_message_ids: state.message_ids,
         primary_external_id: List.first(state.message_ids),
         warnings: state.warnings
       )}
    end
  end

  defp consume(enumerable, initial) do
    try do
      Enum.reduce_while(enumerable, {:ok, initial}, fn chunk, {:ok, state} ->
        case apply_chunk(state, chunk_text(chunk)) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    rescue
      exception -> {:error, Error.map(exception)}
    catch
      kind, reason -> {:error, Error.map({kind, reason})}
    end
  end

  defp apply_chunk(state, {:append, ""}), do: {:ok, state}

  defp apply_chunk(state, {:append, text}) do
    state
    |> Map.update!(:current_text, &(&1 <> text))
    |> maybe_flush()
  end

  defp apply_chunk(state, {:replace, text}) do
    %{state | current_text: text}
    |> maybe_flush(force?: true)
  end

  defp maybe_flush(state, opts \\ []) do
    case String.trim(state.current_text) do
      "" ->
        {:ok, state}

      _text ->
        chunks = stream_chunks(state)
        reconcile_stream_messages(state, chunks, Keyword.get(opts, :force?, false))
    end
  end

  defp reconcile_stream_messages(%{message_ids: []} = state, chunks, _force?) do
    create_missing_messages(state, chunks)
  end

  defp reconcile_stream_messages(state, chunks, force?) do
    cond do
      length(chunks) > length(state.message_ids) ->
        with {:ok, state} <- edit_last_existing_message(state, chunks),
             {:ok, state} <- create_missing_messages(state, chunks) do
          {:ok, state}
        end

      force? or due_for_edit?(state) ->
        edit_last_existing_message(state, chunks)

      true ->
        {:ok, state}
    end
  end

  defp create_missing_messages(state, chunks) do
    existing_count = length(state.message_ids)

    chunks
    |> Enum.drop(existing_count)
    |> Enum.with_index(existing_count)
    |> Enum.reduce_while({:ok, state}, fn {chunk, index}, {:ok, state} ->
      case create_message(state, chunk, index) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp create_message(state, chunk, index) do
    delivery =
      state.delivery
      |> maybe_clear_reply(index)
      |> Map.merge(%{op: :send, content: text_content(chunk)})

    case Delivery.send_text(delivery, chunk, state.config) do
      {:ok, %Outcome{external_message_ids: ids, warnings: warnings}} ->
        message_ids = state.message_ids ++ ids

        {:ok,
         %{
           state
           | message_ids: message_ids,
             last_update_at: now_ms(),
             warnings: state.warnings ++ warnings
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp maybe_clear_reply(delivery, 0), do: delivery
  defp maybe_clear_reply(delivery, _index), do: %{delivery | reply_to_external_id: nil}

  defp edit_last_existing_message(state, chunks) do
    index = length(state.message_ids) - 1
    message_id = Enum.at(state.message_ids, index)
    chunk = Enum.at(chunks, index) || List.last(chunks) || state.current_text
    edit_existing_message(state, message_id, chunk)
  end

  defp edit_existing_message(state, message_id, text) do
    delivery = %{
      state.delivery
      | op: :edit,
        target_external_id: message_id,
        content: text_content(text)
    }

    case Delivery.edit_text(
           state.delivery.scope_id,
           message_id,
           text,
           delivery,
           state.config
         ) do
      {:ok, %Outcome{warnings: warnings}} ->
        {:ok, %{state | last_update_at: now_ms(), warnings: state.warnings ++ warnings}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp finalize(%{current_text: ""}) do
    {:error, Error.payload("Telegram stream content is absent")}
  end

  defp finalize(state) do
    chunks = stream_chunks(state)

    with {:ok, state} <- create_missing_messages(state, chunks),
         {:ok, state} <- edit_final_existing_messages(chunks, state),
         {:ok, state} <- delete_extra_messages(chunks, state) do
      {:ok, state}
    end
  end

  defp edit_final_existing_messages(chunks, state) do
    state.message_ids
    |> Enum.take(length(chunks))
    |> Enum.zip(chunks)
    |> Enum.reduce_while({:ok, state}, fn {message_id, chunk}, {:ok, state} ->
      case edit_existing_message(state, message_id, chunk) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp delete_extra_messages(chunks, state) do
    keep_count = length(chunks)

    state.message_ids
    |> Enum.drop(keep_count)
    |> Enum.reduce_while({:ok, state}, fn message_id, {:ok, state} ->
      case delete_message(state, message_id) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, state} -> {:ok, %{state | message_ids: Enum.take(state.message_ids, keep_count)}}
      {:error, _error} = error -> error
    end
  end

  defp delete_message(state, message_id) do
    case Config.request(state.config, "deleteMessage",
           chat_id: telegram_id(state.delivery.scope_id),
           message_id: telegram_id(message_id)
         ) do
      {:ok, _result} ->
        {:ok, state}

      {:error, error} ->
        {:error, Error.map(error)}
    end
  end

  defp due_for_edit?(%{last_update_at: nil}), do: true

  defp due_for_edit?(%{
         last_update_at: last,
         config: %Config{stream_update_interval_ms: interval}
       }) do
    now_ms() - last >= interval
  end

  defp chunk_text(chunk) when is_binary(chunk), do: {:append, chunk}
  defp chunk_text(%{text: text}) when is_binary(text), do: {:append, text}
  defp chunk_text(%{"text" => text}) when is_binary(text), do: {:append, text}
  defp chunk_text(%{replace_text: text}) when is_binary(text), do: {:replace, text}
  defp chunk_text(%{"replace_text" => text}) when is_binary(text), do: {:replace, text}
  defp chunk_text(_chunk), do: {:append, ""}

  defp text_content(text),
    do: %BullXGateway.Delivery.Content{kind: :text, body: %{"text" => text}}

  defp stream_chunks(state) do
    ContentMapper.stream_chunks(state.current_text, state.config.stream_chunk_soft_limit)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp telegram_id(nil), do: nil
  defp telegram_id(value) when is_integer(value), do: value

  defp telegram_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> value
    end
  end

  defp telegram_id(value), do: value
end
