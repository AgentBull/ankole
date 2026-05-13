defmodule BullxTelegram.Delivery do
  @moduledoc """
  Telegram outbound delivery for the Gateway adapter.

  Handles `:send` (with UTF-16 splitting when text exceeds 4096 code units)
  and `:edit` (`editMessageText` only). Replies whose target message is no
  longer reachable fall back to a plain `sendMessage(chat_id)` with a
  `"reply_target_missing_sent_to_scope"` warning.
  """

  alias BullX.Gateway.Delivery, as: GatewayDelivery
  alias BullxTelegram.{ContentMapper, Error, Source}

  @spec deliver(GatewayDelivery.t(), Source.t()) :: {:ok, map()} | {:error, map()}
  def deliver(%GatewayDelivery{} = delivery, %Source{} = source) do
    do_deliver(delivery, source, telemetry_meta(delivery, source))
  end

  defp do_deliver(%GatewayDelivery{} = delivery, %Source{} = source, meta) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:bullx, :telegram, :delivery, :start],
      %{system_time: System.system_time()},
      meta
    )

    try do
      result =
        case delivery.op do
          :send -> send_message(delivery, source)
          :edit -> edit_message(delivery, source)
          other -> {:error, Error.unsupported("unsupported Telegram op", %{"op" => other})}
        end

      :telemetry.execute(
        [:bullx, :telegram, :delivery, :stop],
        %{duration: System.monotonic_time() - start_time},
        Map.put(meta, :result, telemetry_result(result))
      )

      result
    rescue
      exception ->
        :telemetry.execute(
          [:bullx, :telegram, :delivery, :exception],
          %{system_time: System.system_time()},
          Map.put(meta, :reason, inspect(exception))
        )

        {:error, Error.unknown("Telegram delivery failed: #{inspect(exception)}")}
    catch
      kind, reason ->
        :telemetry.execute(
          [:bullx, :telegram, :delivery, :exception],
          %{system_time: System.system_time()},
          Map.merge(meta, %{kind: kind, reason: inspect(reason)})
        )

        {:error, Error.unknown("Telegram delivery failed: #{inspect(reason)}")}
    end
  end

  @spec send_text(GatewayDelivery.t(), String.t(), Source.t(), [String.t()]) ::
          {:ok, map()} | {:error, map()}
  def send_text(%GatewayDelivery{} = delivery, text, %Source{} = source, warnings \\ []) do
    chunks = ContentMapper.split_message(text, source.stream_chunk_soft_limit)

    with {:ok, message_ids, delivery_warnings} <- create_chunks(delivery, source, chunks) do
      {:ok,
       outcome(
         delivery,
         status_for(delivery_warnings),
         message_ids,
         warnings ++ delivery_warnings
       )}
    end
  end

  @spec edit_text(String.t(), String.t(), String.t(), GatewayDelivery.t(), Source.t()) ::
          {:ok, map()} | {:error, map()}
  def edit_text(chat_id, message_id, text, %GatewayDelivery{} = delivery, %Source{} = source) do
    chunks = ContentMapper.split_message(text, source.stream_chunk_soft_limit)
    edit_single_message(chat_id, message_id, chunks, delivery, source, [])
  end

  defp send_message(%GatewayDelivery{} = delivery, %Source{} = source) do
    with {:ok, scope_id} <- require_scope_id(delivery),
         {:ok, text, warnings} <- ContentMapper.render_outbound(delivery.content) do
      delivery = %{delivery | scope_id: scope_id}
      send_text(delivery, text, source, warnings)
    end
  end

  defp edit_message(%GatewayDelivery{target_external_id: nil}, _source) do
    {:error, Error.payload("Telegram edit requires target_external_id")}
  end

  defp edit_message(%GatewayDelivery{} = delivery, %Source{} = source) do
    with {:ok, scope_id} <- require_scope_id(delivery),
         {:ok, text, warnings} <- ContentMapper.render_outbound(delivery.content) do
      chunks = ContentMapper.split_message(text, source.stream_chunk_soft_limit)

      edit_single_message(
        scope_id,
        delivery.target_external_id,
        chunks,
        delivery,
        source,
        warnings
      )
    end
  end

  defp create_chunks(delivery, source, chunks) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {chunk, index}, {:ok, ids, warnings} ->
      case create_chunk(delivery, source, chunk, index) do
        {:ok, message_id, more_warnings} ->
          {:cont, {:ok, [message_id | ids], warnings ++ more_warnings}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, ids, warnings} -> {:ok, Enum.reverse(ids), warnings}
      {:error, _reason} = error -> error
    end
  end

  defp create_chunk(delivery, source, chunk, 0) do
    source
    |> Source.request("sendMessage", send_params(delivery, chunk))
    |> handle_send_result(delivery, source, chunk, true)
  end

  defp create_chunk(delivery, source, chunk, _index) do
    delivery_no_reply = %{delivery | reply_to_external_id: nil}

    source
    |> Source.request("sendMessage", send_params(delivery_no_reply, chunk))
    |> handle_send_result(delivery_no_reply, source, chunk, false)
  end

  defp handle_send_result({:ok, message}, _delivery, _source, _chunk, _allow_reply_fallback?) do
    case message_id(message) do
      id when is_binary(id) and id != "" -> {:ok, id, []}
      _missing -> {:error, Error.payload("Telegram sendMessage returned no message_id")}
    end
  end

  defp handle_send_result({:error, error}, delivery, source, chunk, true) do
    cond do
      Error.reply_target_missing?(error) and is_binary(delivery.reply_to_external_id) ->
        retry_send_without_reply(delivery, source, chunk, error)

      true ->
        {:error, Error.map(error)}
    end
  end

  defp handle_send_result({:error, error}, _delivery, _source, _chunk, false) do
    {:error, Error.map(error)}
  end

  defp retry_send_without_reply(delivery, source, chunk, _original_error) do
    delivery_no_reply = %{delivery | reply_to_external_id: nil}

    case Source.request(source, "sendMessage", send_params(delivery_no_reply, chunk)) do
      {:ok, message} ->
        case message_id(message) do
          id when is_binary(id) and id != "" ->
            {:ok, id, ["reply_target_missing_sent_to_scope"]}

          _missing ->
            {:error, Error.payload("Telegram sendMessage returned no message_id")}
        end

      {:error, error} ->
        {:error, Error.map(error)}
    end
  end

  defp edit_single_message(chat_id, message_id, [single], delivery, source, warnings) do
    source
    |> Source.request("editMessageText", edit_params(chat_id, message_id, single))
    |> handle_edit_result(delivery, message_id, warnings)
  end

  defp edit_single_message(_chat_id, _message_id, [_ | _], _delivery, _source, _warnings) do
    {:error, Error.payload("Telegram edit content exceeds one message")}
  end

  defp handle_edit_result({:ok, message}, delivery, original_message_id, warnings) do
    id = message_id(message) || original_message_id
    ids = if id, do: [id], else: []
    {:ok, outcome(delivery, "sent", ids, warnings)}
  end

  defp handle_edit_result({:error, error}, delivery, original_message_id, warnings) do
    case Error.not_modified?(error) do
      true ->
        {:ok, outcome(delivery, "sent", [original_message_id], warnings ++ ["message_unchanged"])}

      false ->
        {:error, Error.map(error)}
    end
  end

  defp send_params(%GatewayDelivery{} = delivery, chunk) do
    base = [chat_id: chat_id_for_api(delivery.scope_id), text: chunk]
    base = maybe_put(base, :message_thread_id, parse_integer(delivery.thread_id))
    base = maybe_put(base, :reply_parameters, reply_parameters(delivery))
    base
  end

  defp edit_params(chat_id, message_id, text) do
    [
      chat_id: chat_id_for_api(chat_id),
      message_id: parse_integer(message_id),
      text: text
    ]
  end

  defp reply_parameters(%GatewayDelivery{reply_to_external_id: nil}), do: nil

  defp reply_parameters(%GatewayDelivery{reply_to_external_id: id}) do
    case parse_integer(id) do
      nil -> nil
      message_id -> {:json, %{message_id: message_id, allow_sending_without_reply: true}}
    end
  end

  defp chat_id_for_api(value) do
    case parse_integer(value) do
      nil -> to_string(value)
      integer -> integer
    end
  end

  defp parse_integer(nil), do: nil
  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp require_scope_id(%GatewayDelivery{scope_id: nil}),
    do: {:error, Error.payload("Telegram delivery scope_id is required")}

  defp require_scope_id(%GatewayDelivery{scope_id: ""}),
    do: {:error, Error.payload("Telegram delivery scope_id is required")}

  defp require_scope_id(%GatewayDelivery{scope_id: scope_id}), do: {:ok, scope_id}

  defp message_id(%{"message_id" => id}) when is_integer(id), do: Integer.to_string(id)
  defp message_id(%{"message_id" => id}) when is_binary(id) and id != "", do: id
  defp message_id(%{message_id: id}) when is_integer(id), do: Integer.to_string(id)
  defp message_id(%{message_id: id}) when is_binary(id) and id != "", do: id
  defp message_id(_other), do: nil

  defp outcome(%GatewayDelivery{} = delivery, status, ids, warnings) do
    %{
      "delivery_id" => delivery.id,
      "status" => status,
      "external_message_ids" => ids,
      "primary_external_id" => List.first(ids),
      "warnings" => warnings
    }
  end

  defp status_for([]), do: "sent"
  defp status_for([_ | _]), do: "degraded"

  defp telemetry_meta(%GatewayDelivery{} = delivery, %Source{} = source) do
    %{
      channel_id: source.channel_id,
      op: delivery.op,
      delivery_id: delivery.id,
      scope_id: delivery.scope_id
    }
  end

  defp telemetry_result({:ok, _outcome}), do: :ok
  defp telemetry_result({:error, %{"kind" => kind}}) when is_binary(kind), do: kind
  defp telemetry_result(_result), do: :error

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
end
