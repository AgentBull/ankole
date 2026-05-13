defmodule Feishu.Delivery do
  @moduledoc false

  alias Feishu.{ContentMapper, Source}

  @spec deliver(term(), Source.t()) :: {:ok, map()} | {:error, map()}
  def deliver(delivery, %Source{} = source) do
    start_time = System.monotonic_time()
    meta = telemetry_meta(delivery, source)

    try do
      :telemetry.execute(
        [:bullx, :feishu, :delivery, :start],
        %{system_time: System.system_time()},
        meta
      )

      result = do_deliver(delivery, source)

      :telemetry.execute(
        [:bullx, :feishu, :delivery, :stop],
        %{duration: System.monotonic_time() - start_time},
        Map.put(meta, :result, telemetry_result(result))
      )

      result
    catch
      kind, reason ->
        :telemetry.execute(
          [:bullx, :feishu, :delivery, :exception],
          %{duration: System.monotonic_time() - start_time},
          Map.merge(meta, %{kind: kind, reason: inspect(reason)})
        )

        {:error, Feishu.Error.unknown("Feishu delivery failed")}
    end
  end

  defp do_deliver(delivery, %Source{} = source) do
    case op(delivery) do
      :send -> send_message(delivery, source)
      :edit -> edit_message(delivery, source)
      other -> {:error, Feishu.Error.unsupported("unsupported Feishu delivery op", %{op: other})}
    end
  end

  @spec reply_text(map(), Source.t(), String.t()) :: {:ok, map()} | {:error, map()}
  def reply_text(command, %Source{} = source, text) when is_map(command) and is_binary(text) do
    delivery = %{
      "id" => BullX.Ext.gen_uuid_v7(),
      "op" => "send",
      "scope_id" => command.chat_id,
      "thread_id" => command.thread_id,
      "reply_to_external_id" => command.message_id,
      "content" => [%{"kind" => "text", "body" => %{"text" => text}}]
    }

    deliver(delivery, source)
  end

  defp send_message(delivery, %Source{} = source) do
    with {:ok, rendered, warnings} <- render_content(content(delivery), source),
         {:ok, response} <- do_send(delivery, source, rendered) do
      {:ok, outcome(delivery, "sent", response, warnings)}
    else
      {:reply_failed, %FeishuOpenAPI.Error{} = error} ->
        handle_reply_failure(error, delivery, source)

      {:error, %FeishuOpenAPI.Error{} = error} ->
        {:error, Feishu.Error.map(error)}

      {:error, error} when is_map(error) ->
        {:error, error}
    end
  end

  defp edit_message(delivery, %Source{} = source) do
    with {:ok, target_id} <- target_external_id(delivery),
         {:ok, rendered, warnings} <- render_content(content(delivery), source),
         {:ok, response} <-
           FeishuOpenAPI.patch(Source.client!(source), "/open-apis/im/v1/messages/:message_id",
             path_params: %{message_id: target_id},
             body: %{msg_type: rendered.msg_type, content: rendered.content}
           ) do
      {:ok, outcome(delivery, "sent", response, warnings)}
    else
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Feishu.Error.map(error)}
      {:error, error} when is_map(error) -> {:error, error}
    end
  end

  defp do_send(delivery, %Source{} = source, rendered) do
    case reply_to_external_id(delivery) do
      reply_id when is_binary(reply_id) and reply_id != "" ->
        case FeishuOpenAPI.post(
               Source.client!(source),
               "/open-apis/im/v1/messages/:message_id/reply",
               path_params: %{message_id: reply_id},
               query: [uuid: delivery_id(delivery)],
               body: %{
                 msg_type: rendered.msg_type,
                 content: rendered.content,
                 uuid: delivery_id(delivery)
               }
             ) do
          {:ok, response} -> {:ok, response}
          {:error, %FeishuOpenAPI.Error{} = error} -> {:reply_failed, error}
        end

      _value ->
        send_to_scope(delivery, source, rendered)
    end
  end

  defp send_to_scope(delivery, %Source{} = source, rendered) do
    with {:ok, scope_id} <- scope_id(delivery) do
      FeishuOpenAPI.post(Source.client!(source), "/open-apis/im/v1/messages",
        query: [receive_id_type: "chat_id", uuid: delivery_id(delivery)],
        body: %{
          receive_id: scope_id,
          msg_type: rendered.msg_type,
          content: rendered.content,
          uuid: delivery_id(delivery)
        }
      )
    end
  end

  defp handle_reply_failure(%FeishuOpenAPI.Error{} = error, delivery, %Source{} = source) do
    case Feishu.Error.reply_target_missing?(error) and present?(map_value(delivery, "scope_id")) do
      true -> send_reply_fallback(delivery, source)
      false -> {:error, Feishu.Error.map(error)}
    end
  end

  defp send_reply_fallback(delivery, %Source{} = source) do
    with {:ok, rendered, warnings} <- render_content(content(delivery), source),
         fallback_delivery <- put_value(delivery, "reply_to_external_id", nil),
         {:ok, response} <- send_to_scope(fallback_delivery, source, rendered) do
      {:ok,
       outcome(delivery, "degraded", response, warnings ++ ["reply_target_missing_sent_to_scope"])}
    else
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Feishu.Error.map(error)}
      {:error, error} when is_map(error) -> {:error, error}
    end
  end

  defp render_content(nil, _source),
    do: {:error, Feishu.Error.payload("Feishu delivery content is required")}

  defp render_content(content, source), do: ContentMapper.render_outbound(content, source)

  defp outcome(delivery, status, response, warnings) do
    message_id = message_id(response)

    %{
      "delivery_id" => delivery_id(delivery),
      "status" => status,
      "external_message_ids" => if(message_id, do: [message_id], else: []),
      "primary_external_id" => message_id,
      "warnings" => warnings
    }
  end

  defp message_id(%{"data" => data}) when is_map(data) do
    Map.get(data, "message_id") ||
      get_in(data, ["message", "message_id"]) ||
      Map.get(data, "open_message_id")
  end

  defp message_id(%{"message_id" => message_id}), do: message_id
  defp message_id(_response), do: nil

  defp op(delivery) do
    case map_value(delivery, "op") do
      "send" -> :send
      :send -> :send
      "edit" -> :edit
      :edit -> :edit
      other -> other
    end
  end

  defp content(delivery), do: map_value(delivery, "content")
  defp delivery_id(delivery), do: map_value(delivery, "id") || BullX.Ext.gen_uuid_v7()
  defp reply_to_external_id(delivery), do: map_value(delivery, "reply_to_external_id")

  defp scope_id(delivery) do
    case map_value(delivery, "scope_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, Feishu.Error.payload("Feishu delivery scope_id is required")}
    end
  end

  defp target_external_id(delivery) do
    case map_value(delivery, "target_external_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, Feishu.Error.payload("Feishu edit requires target_external_id")}
    end
  end

  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))
  defp map_value(%_{} = struct, key), do: Map.get(struct, String.to_atom(key))
  defp map_value(_value, _key), do: nil

  defp put_value(%{} = map, key, value), do: Map.put(map, key, value)
  defp put_value(%_{} = struct, key, value), do: Map.put(struct, String.to_atom(key), value)

  defp telemetry_meta(delivery, %Source{} = source) do
    %{
      channel_id: source.channel_id,
      op: op(delivery),
      delivery_id: map_value(delivery, "id"),
      scope_id: map_value(delivery, "scope_id")
    }
  end

  defp telemetry_result({:ok, _outcome}), do: :ok
  defp telemetry_result({:error, %{"kind" => kind}}) when is_binary(kind), do: kind
  defp telemetry_result(_result), do: :error

  defp present?(value), do: is_binary(value) and value != ""
end
