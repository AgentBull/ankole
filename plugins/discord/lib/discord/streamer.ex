defmodule Discord.Streamer do
  @moduledoc """
  Discord streaming delivery state machine.

  Discord has no native streaming, so the streamer accumulates chunks, edits
  the active message via `PATCH /channels/.../messages/...` (throttled by
  `stream_update_interval_ms`), and opens new messages whenever the
  accumulated text exceeds `stream_chunk_soft_limit` (default 1850 UTF-16
  code units; ceiling 2000). Finalize reconciles every existing message,
  deletes overshoots beyond the final chunk count, and reports the final
  message id set.
  """

  alias BullX.Gateway.Delivery, as: GatewayDelivery
  alias Discord.{ContentMapper, Delivery, Error, Source}

  defstruct delivery: nil,
            source: nil,
            current_text: "",
            message_ids: [],
            last_update_at: nil,
            warnings: []

  @type t :: %__MODULE__{}

  @spec stream(GatewayDelivery.t(), Enumerable.t() | nil, Source.t()) ::
          {:ok, map()} | {:error, map()}
  def stream(%GatewayDelivery{} = delivery, nil, _source) do
    {:error,
     Error.payload("Discord stream content is not replayable", %{"delivery_id" => delivery.id})}
  end

  def stream(%GatewayDelivery{} = delivery, enumerable, %Source{} = source) do
    case Enumerable.impl_for(enumerable) do
      nil ->
        {:error,
         Error.payload("Discord stream content is not replayable", %{"delivery_id" => delivery.id})}

      _impl ->
        run(delivery, enumerable, source)
    end
  end

  defp run(%GatewayDelivery{} = delivery, enumerable, %Source{} = source) do
    initial = %__MODULE__{delivery: delivery, source: source}

    with {:ok, state} <- consume(enumerable, initial),
         {:ok, state} <- finalize(state) do
      {:ok,
       %{
         "delivery_id" => delivery.id,
         "status" => "sent",
         "external_message_ids" => state.message_ids,
         "primary_external_id" => List.first(state.message_ids),
         "warnings" => state.warnings
       }}
    else
      {:error, error} -> {:error, error}
    end
  catch
    kind, reason ->
      {:error,
       Error.payload("Discord stream delivery failed", %{
         "kind" => Atom.to_string(kind),
         "reason" => inspect(reason)
       })}
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

  defp apply_chunk(%__MODULE__{} = state, {:append, ""}), do: {:ok, state}

  defp apply_chunk(%__MODULE__{} = state, {:append, text}) do
    state
    |> Map.update!(:current_text, &(&1 <> text))
    |> maybe_flush()
  end

  defp apply_chunk(%__MODULE__{} = state, {:replace, text}) do
    %{state | current_text: text} |> maybe_flush(force?: true)
  end

  defp maybe_flush(state, opts \\ []) do
    case String.trim(state.current_text) do
      "" ->
        {:ok, state}

      _text ->
        chunks = stream_chunks(state)
        reconcile(state, chunks, Keyword.get(opts, :force?, false))
    end
  end

  defp reconcile(%__MODULE__{message_ids: []} = state, chunks, _force?) do
    create_missing_messages(state, chunks)
  end

  defp reconcile(state, chunks, force?) do
    cond do
      length(chunks) > length(state.message_ids) ->
        with {:ok, state} <- edit_last_existing(state, chunks),
             {:ok, state} <- create_missing_messages(state, chunks) do
          {:ok, state}
        end

      force? or due_for_edit?(state) ->
        edit_last_existing(state, chunks)

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
      case send_chunk(state, chunk, index) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp send_chunk(%__MODULE__{} = state, chunk, index) do
    delivery = clear_reply_for_followup(state.delivery, index)

    case Delivery.send_text(delivery, chunk, state.source, []) do
      {:ok, %{"external_message_ids" => ids, "warnings" => more_warnings}} ->
        {:ok,
         %{
           state
           | message_ids: state.message_ids ++ ids,
             last_update_at: now_ms(),
             warnings: state.warnings ++ more_warnings
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp edit_last_existing(%__MODULE__{} = state, chunks) do
    index = length(state.message_ids) - 1
    message_id = Enum.at(state.message_ids, index)
    chunk = Enum.at(chunks, index) || List.last(chunks) || state.current_text
    edit_existing(state, message_id, chunk)
  end

  defp edit_existing(%__MODULE__{} = state, message_id, text) do
    case Delivery.edit_text(
           state.delivery.scope_id,
           message_id,
           text,
           state.delivery,
           state.source
         ) do
      {:ok, %{"warnings" => more_warnings}} ->
        :telemetry.execute(
          [:bullx, :discord, :stream, :flush],
          %{count: 1},
          %{channel_id: state.source.channel_id, delivery_id: state.delivery.id}
        )

        {:ok,
         %{
           state
           | last_update_at: now_ms(),
             warnings: state.warnings ++ more_warnings
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp finalize(%__MODULE__{current_text: ""}) do
    {:error, Error.payload("Discord stream content is absent")}
  end

  defp finalize(state) do
    chunks = stream_chunks(state)

    with {:ok, state} <- create_missing_messages(state, chunks),
         {:ok, state} <- edit_final_messages(state, chunks),
         {:ok, state} <- delete_extra_messages(state, chunks) do
      {:ok, state}
    end
  end

  defp edit_final_messages(state, chunks) do
    state.message_ids
    |> Enum.take(length(chunks))
    |> Enum.zip(chunks)
    |> Enum.reduce_while({:ok, state}, fn {message_id, chunk}, {:ok, state} ->
      case edit_existing(state, message_id, chunk) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp delete_extra_messages(state, chunks) do
    keep_count = length(chunks)
    extras = Enum.drop(state.message_ids, keep_count)

    case delete_each(state, extras) do
      :ok -> {:ok, %{state | message_ids: Enum.take(state.message_ids, keep_count)}}
      {:error, _reason} = error -> error
    end
  end

  defp delete_each(_state, []), do: :ok

  defp delete_each(state, [message_id | rest]) do
    Source.with_bot(state.source, fn ->
      state.source.message_api.delete(snowflake(state.delivery.scope_id), snowflake(message_id))
    end)
    |> case do
      :ok -> delete_each(state, rest)
      {:ok, _result} -> delete_each(state, rest)
      {:error, error} -> {:error, Error.map(error)}
      other -> {:error, Error.map(other)}
    end
  end

  defp clear_reply_for_followup(delivery, 0), do: delivery

  defp clear_reply_for_followup(%GatewayDelivery{} = delivery, _index),
    do: %{delivery | reply_to_external_id: nil}

  defp due_for_edit?(%__MODULE__{last_update_at: nil}), do: true

  defp due_for_edit?(%__MODULE__{
         last_update_at: last,
         source: %Source{stream_update_interval_ms: interval}
       }) do
    now_ms() - last >= interval
  end

  defp chunk_text(chunk) when is_binary(chunk), do: {:append, chunk}
  defp chunk_text(%{text: text}) when is_binary(text), do: {:append, text}
  defp chunk_text(%{"text" => text}) when is_binary(text), do: {:append, text}
  defp chunk_text(%{replace_text: text}) when is_binary(text), do: {:replace, text}
  defp chunk_text(%{"replace_text" => text}) when is_binary(text), do: {:replace, text}
  defp chunk_text(_chunk), do: {:append, ""}

  defp stream_chunks(%__MODULE__{} = state) do
    ContentMapper.stream_chunks(state.current_text, state.source.stream_chunk_soft_limit)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp snowflake(value) when is_integer(value), do: value

  defp snowflake(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> value
    end
  end

  defp snowflake(value), do: value
end
