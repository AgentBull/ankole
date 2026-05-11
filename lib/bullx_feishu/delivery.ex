defmodule BullXFeishu.Delivery do
  @moduledoc """
  Feishu outbound delivery mapping for Gateway `Delivery` structs.
  """

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Outcome
  alias BullXFeishu.{Config, ContentMapper, Error}

  @spec deliver(GatewayDelivery.t(), Config.t()) ::
          {:ok, Outcome.adapter_success_t()} | {:error, map()}
  def deliver(%GatewayDelivery{op: :send} = delivery, %Config{} = config) do
    GatewayDelivery.telemetry_span(:feishu, delivery, fn -> send_message(delivery, config) end)
  end

  def deliver(%GatewayDelivery{op: :edit} = delivery, %Config{} = config) do
    GatewayDelivery.telemetry_span(:feishu, delivery, fn -> edit_message(delivery, config) end)
  end

  def deliver(%GatewayDelivery{op: op}, %Config{}),
    do: {:error, Error.unsupported("unsupported Feishu op", %{"op" => op})}

  defp send_message(%GatewayDelivery{} = delivery, %Config{} = config) do
    with {:ok, rendered, warnings} <- render_content(delivery.content),
         {:ok, response} <- do_send(delivery, config, rendered) do
      {:ok, outcome(delivery, :sent, response, warnings)}
    else
      {:reply_failed, %FeishuOpenAPI.Error{} = error} ->
        handle_reply_failure(error, delivery, config)

      {:error, %FeishuOpenAPI.Error{} = error} ->
        {:error, Error.map(error)}

      {:error, error} when is_map(error) ->
        {:error, error}
    end
  end

  defp handle_reply_failure(%FeishuOpenAPI.Error{} = error, delivery, config) do
    case Error.reply_target_missing?(error) and is_binary(delivery.scope_id) do
      true -> send_reply_fallback(delivery, config)
      false -> {:error, Error.map(error)}
    end
  end

  defp edit_message(%GatewayDelivery{target_external_id: nil}, _config) do
    {:error, Error.payload("Feishu edit requires target_external_id")}
  end

  defp edit_message(%GatewayDelivery{} = delivery, %Config{} = config) do
    with {:ok, rendered, warnings} <- render_content(delivery.content),
         {:ok, response} <-
           FeishuOpenAPI.patch(Config.client!(config), "/open-apis/im/v1/messages/:message_id",
             path_params: %{message_id: delivery.target_external_id},
             body: %{
               msg_type: rendered.msg_type,
               content: rendered.content
             }
           ) do
      {:ok, outcome(delivery, :sent, response, warnings)}
    else
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Error.map(error)}
      {:error, error} when is_map(error) -> {:error, error}
    end
  end

  defp do_send(%GatewayDelivery{reply_to_external_id: reply_id} = delivery, config, rendered)
       when is_binary(reply_id) and reply_id != "" do
    case FeishuOpenAPI.post(Config.client!(config), "/open-apis/im/v1/messages/:message_id/reply",
           path_params: %{message_id: reply_id},
           query: [uuid: delivery.id],
           body: %{
             msg_type: rendered.msg_type,
             content: rendered.content,
             uuid: delivery.id
           }
         ) do
      {:ok, response} -> {:ok, response}
      {:error, %FeishuOpenAPI.Error{} = error} -> {:reply_failed, error}
    end
  end

  defp do_send(%GatewayDelivery{} = delivery, config, rendered) do
    FeishuOpenAPI.post(Config.client!(config), "/open-apis/im/v1/messages",
      query: [receive_id_type: "chat_id", uuid: delivery.id],
      body: %{
        receive_id: delivery.scope_id,
        msg_type: rendered.msg_type,
        content: rendered.content,
        uuid: delivery.id
      }
    )
  end

  defp send_reply_fallback(%GatewayDelivery{} = delivery, %Config{} = config) do
    with {:ok, rendered, warnings} <- render_content(delivery.content),
         fallback_delivery <- %{delivery | reply_to_external_id: nil},
         {:ok, response} <- do_send(fallback_delivery, config, rendered) do
      warnings = warnings ++ ["reply_target_missing_sent_to_scope"]
      {:ok, outcome(delivery, :degraded, response, warnings)}
    else
      {:error, %FeishuOpenAPI.Error{} = error} -> {:error, Error.map(error)}
      {:error, error} when is_map(error) -> {:error, error}
    end
  end

  defp render_content(nil), do: {:error, Error.payload("Feishu delivery content is required")}
  defp render_content(content), do: ContentMapper.render_outbound(content)

  defp outcome(delivery, status, response, warnings) do
    message_id = message_id(response)

    Outcome.new_success(delivery.id, status,
      external_message_ids: if(message_id, do: [message_id], else: []),
      primary_external_id: message_id,
      warnings: warnings
    )
  end

  defp message_id(%{"data" => data}) when is_map(data) do
    Map.get(data, "message_id") ||
      get_in(data, ["message", "message_id"]) ||
      Map.get(data, "open_message_id")
  end

  defp message_id(%{"message_id" => message_id}), do: message_id
  defp message_id(_), do: nil
end
