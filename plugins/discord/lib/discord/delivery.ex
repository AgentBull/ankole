defmodule Discord.Delivery do
  @moduledoc """
  Discord outbound delivery for the Gateway adapter.

  Handles `:send` (with UTF-16 splitting when text exceeds 2000 code units)
  and `:edit` (`PATCH /channels/.../messages/...`). Replies whose target
  message is no longer reachable fall back to a plain channel send with a
  `"reply_target_missing_sent_to_scope"` warning.

  Safe `allowed_mentions` defaults (`parse: ["users"], replied_user: true`)
  are applied to every send. Non-text content kinds degrade to
  `body.fallback_text` until native attachment upload is added.
  """

  alias BullX.Gateway.Delivery, as: GatewayDelivery
  alias Discord.{ContentMapper, Error, Source}

  @spec deliver(GatewayDelivery.t(), Source.t()) :: {:ok, map()} | {:error, map()}
  def deliver(%GatewayDelivery{} = delivery, %Source{} = source) do
    do_deliver(delivery, source, telemetry_meta(delivery, source))
  end

  defp do_deliver(%GatewayDelivery{} = delivery, %Source{} = source, meta) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:bullx, :discord, :delivery, :start],
      %{system_time: System.system_time()},
      meta
    )

    try do
      result =
        case delivery.op do
          :send -> send_message(delivery, source)
          :edit -> edit_message(delivery, source)
          other -> {:error, Error.unsupported("unsupported Discord op", %{"op" => other})}
        end

      :telemetry.execute(
        [:bullx, :discord, :delivery, :stop],
        %{duration: System.monotonic_time() - start_time},
        Map.put(meta, :result, telemetry_result(result))
      )

      result
    rescue
      exception ->
        :telemetry.execute(
          [:bullx, :discord, :delivery, :exception],
          %{system_time: System.system_time()},
          Map.put(meta, :reason, inspect(exception))
        )

        {:error, Error.unknown("Discord delivery failed: " <> Exception.message(exception))}
    catch
      kind, reason ->
        :telemetry.execute(
          [:bullx, :discord, :delivery, :exception],
          %{system_time: System.system_time()},
          Map.merge(meta, %{kind: kind, reason: inspect(reason)})
        )

        {:error, Error.unknown("Discord delivery failed: #{inspect(reason)}")}
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
  def edit_text(scope_id, message_id, text, %GatewayDelivery{} = delivery, %Source{} = source) do
    chunks = ContentMapper.split_message(text, source.stream_chunk_soft_limit)
    edit_single_message(scope_id, message_id, chunks, delivery, source, [])
  end

  @spec allowed_mentions() :: map()
  def allowed_mentions, do: %{"parse" => ["users"], "replied_user" => true}

  defp send_message(%GatewayDelivery{} = delivery, %Source{} = source) do
    with {:ok, scope_id} <- require_scope_id(delivery),
         {:ok, text, warnings} <- ContentMapper.render_outbound(delivery.content) do
      delivery = %{delivery | scope_id: scope_id}
      send_text(delivery, text, source, warnings)
    end
  end

  defp edit_message(%GatewayDelivery{target_external_id: nil}, _source) do
    {:error, Error.payload("Discord edit requires target_external_id")}
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
    create_call(delivery, source, chunk, true)
  end

  defp create_chunk(delivery, source, chunk, _index) do
    delivery_no_reply = %{delivery | reply_to_external_id: nil}
    create_call(delivery_no_reply, source, chunk, false)
  end

  defp create_call(delivery, source, chunk, allow_reply_fallback?) do
    scope_id = snowflake(delivery.scope_id)
    options = message_options(delivery, chunk)

    Source.with_bot(source, fn -> source.message_api.create(scope_id, options) end)
    |> handle_create_result(delivery, source, chunk, allow_reply_fallback?)
  end

  defp handle_create_result({:ok, message}, _delivery, _source, _chunk, _allow_fallback?) do
    case message_id(message) do
      id when is_binary(id) and id != "" -> {:ok, id, []}
      _missing -> {:error, Error.payload("Discord sendMessage returned no message_id")}
    end
  end

  defp handle_create_result({:error, error}, delivery, source, chunk, true) do
    cond do
      Error.reply_target_missing?(error) and is_binary(delivery.reply_to_external_id) ->
        retry_send_without_reply(delivery, source, chunk)

      true ->
        {:error, Error.map(error)}
    end
  end

  defp handle_create_result({:error, error}, _delivery, _source, _chunk, false),
    do: {:error, Error.map(error)}

  defp handle_create_result(other, _delivery, _source, _chunk, _allow_fallback?),
    do: {:error, Error.map(other)}

  defp retry_send_without_reply(delivery, source, chunk) do
    delivery_no_reply = %{delivery | reply_to_external_id: nil}

    Source.with_bot(source, fn ->
      source.message_api.create(
        snowflake(delivery_no_reply.scope_id),
        message_options(delivery_no_reply, chunk)
      )
    end)
    |> case do
      {:ok, message} ->
        case message_id(message) do
          id when is_binary(id) and id != "" -> {:ok, id, ["reply_target_missing_sent_to_scope"]}
          _missing -> {:error, Error.payload("Discord sendMessage returned no message_id")}
        end

      {:error, error} ->
        {:error, Error.map(error)}

      other ->
        {:error, Error.map(other)}
    end
  end

  defp edit_single_message(scope_id, message_id, [single], delivery, source, warnings) do
    Source.with_bot(source, fn ->
      source.message_api.edit(snowflake(scope_id), snowflake(message_id), %{
        content: single,
        allowed_mentions: allowed_mentions()
      })
    end)
    |> handle_edit_result(delivery, message_id, warnings)
  end

  defp edit_single_message(_scope_id, _message_id, [_ | _], _delivery, _source, _warnings),
    do: {:error, Error.payload("Discord edit content exceeds one message")}

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

  defp handle_edit_result(other, _delivery, _original_message_id, _warnings),
    do: {:error, Error.map(other)}

  defp message_options(%GatewayDelivery{reply_to_external_id: nil}, content) do
    %{content: content, allowed_mentions: allowed_mentions()}
  end

  defp message_options(%GatewayDelivery{reply_to_external_id: reply_id}, content)
       when is_binary(reply_id) and reply_id != "" do
    %{
      content: content,
      allowed_mentions: allowed_mentions(),
      message_reference: %{
        message_id: snowflake(reply_id),
        fail_if_not_exists: false
      }
    }
  end

  defp message_options(%GatewayDelivery{}, content),
    do: %{content: content, allowed_mentions: allowed_mentions()}

  defp require_scope_id(%GatewayDelivery{scope_id: nil}),
    do: {:error, Error.payload("Discord delivery scope_id is required")}

  defp require_scope_id(%GatewayDelivery{scope_id: ""}),
    do: {:error, Error.payload("Discord delivery scope_id is required")}

  defp require_scope_id(%GatewayDelivery{scope_id: scope_id}), do: {:ok, scope_id}

  defp message_id(%{id: id}), do: id_string(id)
  defp message_id(%{"id" => id}), do: id_string(id)
  defp message_id(_message), do: nil

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

  defp snowflake(value) when is_integer(value), do: value

  defp snowflake(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> value
    end
  end

  defp snowflake(value), do: value

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value) and value != "", do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(_value), do: nil
end
