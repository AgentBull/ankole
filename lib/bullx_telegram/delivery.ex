defmodule BullXTelegram.Delivery do
  @moduledoc """
  Telegram outbound delivery mapping for Gateway `Delivery` structs.
  """

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Outcome
  alias BullXTelegram.{Config, ContentMapper, Error}

  @spec deliver(GatewayDelivery.t(), Config.t()) ::
          {:ok, Outcome.adapter_success_t()} | {:error, map()}
  def deliver(%GatewayDelivery{op: :send} = delivery, %Config{} = config) do
    :telemetry.span([:bullx, :telegram, :delivery], telemetry_meta(delivery), fn ->
      result = send_message(delivery, config)
      {result, telemetry_result(result)}
    end)
  end

  def deliver(%GatewayDelivery{op: :edit} = delivery, %Config{} = config) do
    :telemetry.span([:bullx, :telegram, :delivery], telemetry_meta(delivery), fn ->
      result = edit_message(delivery, config)
      {result, telemetry_result(result)}
    end)
  end

  def deliver(%GatewayDelivery{op: op}, %Config{}),
    do: {:error, Error.unsupported("unsupported Telegram op", %{"op" => op})}

  @spec send_text(GatewayDelivery.t(), String.t(), Config.t(), [String.t()]) ::
          {:ok, Outcome.adapter_success_t()} | {:error, map()}
  def send_text(%GatewayDelivery{} = delivery, text, %Config{} = config, warnings \\ []) do
    chunks = split_message(text, config.stream_chunk_soft_limit)

    with {:ok, messages, delivery_warnings} <- create_chunks(delivery, config, chunks) do
      ids = Enum.map(messages, &message_id/1) |> Enum.reject(&is_nil/1)
      warnings = warnings ++ delivery_warnings
      status = success_status(delivery_warnings)

      {:ok,
       Outcome.new_success(delivery.id, status,
         external_message_ids: ids,
         primary_external_id: List.first(ids),
         warnings: warnings
       )}
    end
  end

  @spec edit_text(String.t(), String.t(), String.t(), GatewayDelivery.t(), Config.t(), [
          String.t()
        ]) ::
          {:ok, Outcome.adapter_success_t()} | {:error, map()}
  def edit_text(chat_id, message_id, text, delivery, config, warnings \\ []) do
    chunks = ContentMapper.split_message(text)

    case stream_message_ids(delivery, message_id) do
      {:ok, ids} ->
        edit_stream_message_set(chat_id, ids, chunks, delivery, config, warnings)

      :error ->
        edit_single_message(chat_id, message_id, chunks, delivery, config, warnings)
    end
  end

  @spec split_message(String.t(), pos_integer()) :: [String.t()]
  def split_message(text, limit \\ 4_096), do: ContentMapper.split_message(text, limit)

  defp send_message(%GatewayDelivery{} = delivery, %Config{} = config) do
    with {:ok, rendered, warnings} <- ContentMapper.render_outbound(delivery.content) do
      send_text(delivery, rendered, config, warnings)
    end
  end

  defp edit_message(%GatewayDelivery{target_external_id: nil}, _config) do
    {:error, Error.payload("Telegram edit requires target_external_id")}
  end

  defp edit_message(%GatewayDelivery{} = delivery, %Config{} = config) do
    with {:ok, rendered, warnings} <- ContentMapper.render_outbound(delivery.content) do
      edit_text(
        delivery.scope_id,
        delivery.target_external_id,
        rendered,
        delivery,
        config,
        warnings
      )
    end
  end

  defp create_chunks(delivery, config, chunks) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn {chunk, index}, {:ok, acc, warnings} ->
      case create_chunk(delivery, config, chunk, index) do
        {:ok, message, next_warnings} ->
          {:cont, {:ok, [message | acc], warnings ++ next_warnings}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, messages, warnings} -> {:ok, Enum.reverse(messages), warnings}
      {:error, _} = error -> error
    end
  end

  defp create_chunk(delivery, config, chunk, 0) do
    config
    |> Config.request("sendMessage", send_params(delivery, chunk))
    |> handle_create_result(delivery, config, chunk)
  end

  defp create_chunk(delivery, config, chunk, _index) do
    fallback_delivery = %{delivery | reply_to_external_id: nil}

    config
    |> Config.request("sendMessage", send_params(fallback_delivery, chunk))
    |> handle_create_result(delivery, config, chunk)
  end

  defp handle_create_result({:ok, message}, _delivery, _config, _chunk), do: {:ok, message, []}

  defp handle_create_result({:error, error}, delivery, config, chunk) do
    case Error.reply_target_missing?(error) and is_binary(delivery.reply_to_external_id) do
      true ->
        fallback_delivery = %{delivery | reply_to_external_id: nil}

        config
        |> Config.request("sendMessage", send_params(fallback_delivery, chunk))
        |> case do
          {:ok, message} -> {:ok, message, ["reply_target_missing_sent_to_scope"]}
          {:error, error} -> {:error, Error.map(error)}
        end

      false ->
        {:error, Error.map(error)}
    end
  end

  defp handle_edit_error(error, delivery, message_id, warnings) do
    case Error.not_modified?(error) do
      true ->
        {:ok,
         Outcome.new_success(delivery.id, :sent,
           external_message_ids: [message_id],
           primary_external_id: message_id,
           warnings: warnings
         )}

      false ->
        {:error, Error.map(error)}
    end
  end

  defp edit_single_message(chat_id, message_id, [single], delivery, config, warnings) do
    config
    |> Config.request("editMessageText", edit_params(chat_id, message_id, single, delivery))
    |> case do
      {:ok, message} ->
        id = message_id(message) || message_id

        {:ok,
         Outcome.new_success(delivery.id, :sent,
           external_message_ids: if(id, do: [id], else: []),
           primary_external_id: id,
           warnings: warnings
         )}

      {:error, error} ->
        handle_edit_error(error, delivery, message_id, warnings)
    end
  end

  defp edit_single_message(_chat_id, _message_id, [_ | _], _delivery, _config, _warnings) do
    {:error, Error.payload("Telegram edit content exceeds one message")}
  end

  defp edit_stream_message_set(chat_id, ids, chunks, delivery, config, warnings) do
    with {:ok, warnings} <-
           edit_existing_stream_messages(chat_id, ids, chunks, delivery, config, warnings),
         {:ok, created_ids} <- create_missing_stream_messages(ids, chunks, delivery, config),
         :ok <- delete_extra_stream_messages(chat_id, ids, chunks, config) do
      final_ids = Enum.take(ids, length(chunks)) ++ created_ids

      {:ok,
       Outcome.new_success(delivery.id, :sent,
         external_message_ids: final_ids,
         primary_external_id: List.first(final_ids),
         warnings: warnings
       )}
    end
  end

  defp edit_existing_stream_messages(chat_id, ids, chunks, delivery, config, warnings) do
    ids
    |> Enum.take(length(chunks))
    |> Enum.zip(chunks)
    |> Enum.reduce_while({:ok, warnings}, fn {id, chunk}, {:ok, warnings} ->
      case edit_single_message(chat_id, id, [chunk], delivery, config, warnings) do
        {:ok, %Outcome{warnings: warnings}} -> {:cont, {:ok, warnings}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp create_missing_stream_messages(ids, chunks, delivery, config) do
    chunks
    |> Enum.drop(length(ids))
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, created_ids} ->
      case create_stream_message(delivery, config, chunk) do
        {:ok, id} -> {:cont, {:ok, created_ids ++ [id]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp create_stream_message(delivery, config, chunk) do
    delivery = %{delivery | op: :send, reply_to_external_id: nil, target_external_id: nil}

    case Config.request(config, "sendMessage", send_params(delivery, chunk)) do
      {:ok, message} -> stream_message_id(message)
      {:error, error} -> {:error, Error.map(error)}
    end
  end

  defp stream_message_id(message) do
    case message_id(message) do
      id when is_binary(id) -> {:ok, id}
      nil -> {:error, Error.payload("Telegram sendMessage response missing message_id")}
    end
  end

  defp delete_extra_stream_messages(chat_id, ids, chunks, config) do
    ids
    |> Enum.drop(length(chunks))
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case Config.request(config, "deleteMessage",
             chat_id: telegram_id(chat_id),
             message_id: telegram_id(id)
           ) do
        {:ok, _result} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, Error.map(error)}}
      end
    end)
  end

  defp send_params(delivery, text) do
    [
      chat_id: telegram_id(delivery.scope_id),
      text: text
    ]
    |> maybe_put(:message_thread_id, telegram_id(delivery.thread_id))
    |> maybe_put(:reply_parameters, reply_parameters(delivery.reply_to_external_id))
  end

  defp edit_params(chat_id, message_id, text, delivery) do
    [
      chat_id: telegram_id(chat_id),
      message_id: telegram_id(message_id),
      text: text
    ]
    |> maybe_put(:message_thread_id, telegram_id(delivery.thread_id))
  end

  defp reply_parameters(nil), do: nil
  defp reply_parameters(message_id), do: {:json, %{message_id: telegram_id(message_id)}}

  defp stream_message_ids(%GatewayDelivery{extensions: extensions}, target_id)
       when is_map(extensions) do
    extensions
    |> stream_message_id_candidates()
    |> Enum.find(&is_list/1)
    |> normalize_stream_message_ids(target_id)
  end

  defp stream_message_ids(%GatewayDelivery{}, _target_id), do: :error

  defp stream_message_id_candidates(extensions) do
    [
      get_in(extensions, ["telegram", "stream_message_ids"]),
      get_in(extensions, [:telegram, :stream_message_ids]),
      Map.get(extensions, "stream_message_ids"),
      Map.get(extensions, :stream_message_ids)
    ]
  end

  defp normalize_stream_message_ids(nil, _target_id), do: :error

  defp normalize_stream_message_ids(ids, target_id) do
    ids =
      ids
      |> Enum.map(&id_string/1)
      |> Enum.reject(&is_nil/1)

    case id_string(target_id) in ids do
      true -> {:ok, ids}
      false -> :error
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Keyword.put(params, key, value)

  defp telegram_id(nil), do: nil
  defp telegram_id(value) when is_integer(value), do: value

  defp telegram_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> value
    end
  end

  defp telegram_id(value), do: value

  defp message_id(%{"message_id" => message_id}), do: id_string(message_id)
  defp message_id(%{message_id: message_id}), do: id_string(message_id)
  defp message_id(_message), do: nil

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)

  defp success_status(warnings) do
    case "reply_target_missing_sent_to_scope" in warnings do
      true -> :degraded
      false -> :sent
    end
  end

  defp telemetry_meta(%GatewayDelivery{} = delivery) do
    %{
      channel: delivery.channel,
      delivery_id: delivery.id,
      op: delivery.op,
      scope_id: delivery.scope_id
    }
  end

  defp telemetry_result({:ok, %Outcome{} = outcome}), do: %{outcome: outcome.status}
  defp telemetry_result({:error, %{"kind" => kind}}), do: %{outcome: :error, error_kind: kind}
  defp telemetry_result(_), do: %{outcome: :error}
end
