defmodule BullXDiscord.Delivery do
  @moduledoc """
  Discord outbound delivery mapping for Gateway `Delivery` structs.
  """

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Content
  alias BullXGateway.Delivery.Outcome
  alias BullXDiscord.{Config, Error}

  @discord_message_limit 2_000

  @spec deliver(GatewayDelivery.t(), Config.t()) ::
          {:ok, Outcome.adapter_success_t()} | {:error, map()}
  def deliver(%GatewayDelivery{op: :send} = delivery, %Config{} = config) do
    :telemetry.span([:bullx, :discord, :delivery], telemetry_meta(delivery), fn ->
      result = send_message(delivery, config)
      {result, telemetry_result(result)}
    end)
  end

  def deliver(%GatewayDelivery{op: :edit} = delivery, %Config{} = config) do
    :telemetry.span([:bullx, :discord, :delivery], telemetry_meta(delivery), fn ->
      result = edit_message(delivery, config)
      {result, telemetry_result(result)}
    end)
  end

  def deliver(%GatewayDelivery{op: op}, %Config{}),
    do: {:error, Error.unsupported("unsupported Discord op", %{"op" => op})}

  @spec render_content(Content.t() | nil) :: {:ok, String.t(), [String.t()]} | {:error, map()}
  def render_content(nil), do: {:error, Error.payload("Discord delivery content is required")}

  def render_content(%Content{kind: :text, body: %{"text" => text}}) when is_binary(text) do
    {:ok, text, []}
  end

  def render_content(%Content{kind: kind, body: %{"fallback_text" => text}})
      when kind in [:image, :audio, :video, :file, :card] and is_binary(text) and text != "" do
    {:ok, text, ["#{kind}_degraded_to_fallback_text"]}
  end

  def render_content(%Content{} = content) do
    {:error,
     Error.unsupported("unsupported Discord content kind", %{
       "kind" => Atom.to_string(content.kind)
     })}
  end

  @spec send_text(GatewayDelivery.t(), String.t(), Config.t(), [String.t()]) ::
          {:ok, Outcome.adapter_success_t()} | {:error, map()}
  def send_text(%GatewayDelivery{} = delivery, text, %Config{} = config, warnings \\ []) do
    chunks = split_message(text)

    with {:ok, messages, delivery_warnings} <- create_chunks(delivery, config, chunks) do
      ids = Enum.map(messages, &message_id/1) |> Enum.reject(&is_nil/1)
      warnings = warnings ++ delivery_warnings

      status =
        if "reply_target_missing_sent_to_scope" in delivery_warnings, do: :degraded, else: :sent

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
  def edit_text(channel_id, message_id, text, delivery, config, warnings \\ []) do
    case split_message(text) do
      [single] ->
        Config.with_bot(config, fn ->
          config.message_api.edit(
            snowflake(channel_id),
            snowflake(message_id),
            message_options(single)
          )
        end)
        |> case do
          {:ok, message} ->
            id = message_id(message)

            {:ok,
             Outcome.new_success(delivery.id, :sent,
               external_message_ids: if(id, do: [id], else: []),
               primary_external_id: id,
               warnings: warnings
             )}

          {:error, error} ->
            {:error, Error.map(error)}
        end

      [_ | _] ->
        {:error, Error.payload("Discord edit content exceeds one message")}
    end
  end

  @spec allowed_mentions() :: map()
  def allowed_mentions do
    %{"parse" => ["users"], "replied_user" => true}
  end

  @spec split_message(String.t()) :: [String.t()]
  def split_message(text) do
    split_message(text, @discord_message_limit)
  end

  @spec split_message(String.t(), pos_integer()) :: [String.t()]
  def split_message(text, limit) when is_integer(limit) and limit > 0 do
    text
    |> to_string()
    |> String.trim()
    |> case do
      "" -> [BullX.I18n.t("gateway.discord.delivery.fallback_text")]
      text -> chunk_text(text, limit)
    end
  end

  defp send_message(%GatewayDelivery{} = delivery, %Config{} = config) do
    with {:ok, rendered, warnings} <- render_content(delivery.content) do
      send_text(delivery, rendered, config, warnings)
    end
  end

  defp edit_message(%GatewayDelivery{target_external_id: nil}, _config) do
    {:error, Error.payload("Discord edit requires target_external_id")}
  end

  defp edit_message(%GatewayDelivery{} = delivery, %Config{} = config) do
    with {:ok, rendered, warnings} <- render_content(delivery.content) do
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
    Config.with_bot(config, fn ->
      config.message_api.create(snowflake(delivery.scope_id), message_options(chunk, delivery))
    end)
    |> handle_create_result(delivery, config, chunk)
  end

  defp create_chunk(delivery, config, chunk, _index) do
    Config.with_bot(config, fn ->
      config.message_api.create(snowflake(delivery.scope_id), message_options(chunk))
    end)
    |> handle_create_result(delivery, config, chunk)
  end

  defp handle_create_result({:ok, message}, _delivery, _config, _chunk), do: {:ok, message, []}

  defp handle_create_result({:error, error}, delivery, config, chunk) do
    case Error.reply_target_missing?(error) and is_binary(delivery.reply_to_external_id) do
      true ->
        fallback_delivery = %{delivery | reply_to_external_id: nil}

        Config.with_bot(config, fn ->
          config.message_api.create(snowflake(fallback_delivery.scope_id), message_options(chunk))
        end)
        |> case do
          {:ok, message} -> {:ok, message, ["reply_target_missing_sent_to_scope"]}
          {:error, error} -> {:error, Error.map(error)}
        end

      false ->
        {:error, Error.map(error)}
    end
  end

  defp message_options(content) do
    %{content: content, allowed_mentions: allowed_mentions()}
  end

  defp message_options(content, %GatewayDelivery{reply_to_external_id: reply_id})
       when is_binary(reply_id) and reply_id != "" do
    Map.put(message_options(content), :message_reference, %{
      message_id: snowflake(reply_id),
      fail_if_not_exists: false
    })
  end

  defp message_options(content, %GatewayDelivery{}), do: message_options(content)

  defp chunk_text(text, limit) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(limit)
    |> Enum.map(&Enum.join/1)
  end

  defp message_id(%{id: id}), do: id_string(id)
  defp message_id(%{"id" => id}), do: id_string(id)
  defp message_id(_message), do: nil

  defp snowflake(value) when is_integer(value), do: value

  defp snowflake(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> value
    end
  end

  defp snowflake(value), do: value

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)

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
