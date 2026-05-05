defmodule BullXDiscord.Streamer do
  @moduledoc """
  Discord streaming delivery state machine.
  """

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Outcome
  alias BullXDiscord.{Config, Delivery, Error}

  @spec stream(GatewayDelivery.t(), Enumerable.t() | nil, Config.t()) ::
          {:ok, Outcome.adapter_success_t()} | {:error, map()}
  def stream(%GatewayDelivery{} = delivery, nil, _config) do
    {:error,
     Error.payload("Discord stream content is not replayable", %{"delivery_id" => delivery.id})}
  end

  def stream(%GatewayDelivery{} = delivery, enumerable, %Config{} = config) do
    initial = %{
      delivery: delivery,
      config: config,
      current_text: "",
      active_message_id: nil,
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
    cond do
      String.trim(state.current_text) == "" ->
        {:ok, state}

      true ->
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
      {:ok,
       %Outcome{primary_external_id: message_id, external_message_ids: ids, warnings: warnings}} ->
        message_ids = state.message_ids ++ ids

        {:ok,
         %{
           state
           | active_message_id: List.last(message_ids) || message_id,
             message_ids: message_ids,
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
    {:error, Error.payload("Discord stream content is absent")}
  end

  defp finalize(state) do
    state
    |> stream_chunks()
    |> then(&reconcile_final_messages(state, &1))
  end

  defp reconcile_final_messages(state, chunks) do
    with {:ok, state} <- edit_final_existing_messages(state, chunks),
         {:ok, state} <- create_missing_messages(state, chunks),
         {:ok, state} <- delete_extra_messages(state, length(chunks)) do
      {:ok, %{state | active_message_id: List.last(state.message_ids)}}
    end
  end

  defp edit_final_existing_messages(state, chunks) do
    state.message_ids
    |> Enum.zip(chunks)
    |> Enum.reduce_while({:ok, state}, fn {message_id, chunk}, {:ok, state} ->
      case edit_existing_message(state, message_id, chunk) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp delete_extra_messages(state, keep_count) do
    {kept, extra} = Enum.split(state.message_ids, keep_count)

    extra
    |> Enum.reduce_while({:ok, %{state | message_ids: kept}}, fn message_id, {:ok, state} ->
      case delete_message(state, message_id) do
        :ok -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp delete_message(state, message_id) do
    Config.with_bot(state.config, fn ->
      state.config.message_api.delete(snowflake(state.delivery.scope_id), message_id)
    end)
    |> case do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, error} -> {:error, Error.map(error)}
      error -> {:error, Error.map(error)}
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
    Delivery.split_message(state.current_text, stream_chunk_limit(state.config))
  end

  defp stream_chunk_limit(%Config{stream_chunk_soft_limit: limit}) do
    min(max(limit, 1), 2_000)
  end

  defp snowflake(value) when is_integer(value), do: value

  defp snowflake(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> value
    end
  end

  defp snowflake(value), do: value

  defp now_ms, do: System.monotonic_time(:millisecond)
end
