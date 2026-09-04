defmodule Ankole.Plugins.TelegramAdapter.ReplyPreview do
  @moduledoc "Telegram transport for the shared crash-recoverable message preview ledger."

  @behaviour Ankole.SignalsGateway.ReplyPreviewAdapter
  @behaviour Ankole.Plugins.ChunkedMessagePreview

  alias Ankole.Plugins.ChunkedMessagePreview
  alias Ankole.Plugins.TelegramAdapter.{Client, Config, ErrorPolicy, Outbox, Presentation}
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def open(%Request{} = request), do: deliver(request)

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def update(%Request{} = request), do: deliver(request)

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def finalize(%Request{} = request) do
    case ChunkedMessagePreview.reconcile(%{request | mode: :terminal}, __MODULE__, "telegram") do
      {:error, reason} when reason in [:telegram_partial_delivery, :telegram_send_uncertain] ->
        :unknown

      result ->
        ErrorPolicy.normalize_delivery_result(result)
    end
  end

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def refresh(%Request{} = request), do: deliver(request)

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def surface_ids(checkpoint), do: ChunkedMessagePreview.surface_ids(checkpoint)

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def surface_open?(checkpoint), do: ChunkedMessagePreview.surface_open?(checkpoint)

  defp deliver(request) do
    request
    |> ChunkedMessagePreview.reconcile(__MODULE__, "telegram")
    |> ErrorPolicy.normalize_delivery_result()
  end

  @impl Ankole.Plugins.ChunkedMessagePreview
  def render_chunks(presentation, %Request{actor_event: event} = request) do
    with {:ok, config} <- Config.validate_binding_config(request.config),
         client <- Config.client(config),
         {:ok, chunks} <- Presentation.render(presentation, event.id),
         {:ok, channel} <- Outbox.parse_channel(event.signal_channel_id) do
      {:ok, chunks, {client, channel}, event.signal_channel_id}
    end
  end

  @impl Ankole.Plugins.ChunkedMessagePreview
  def upsert_message(
        {client, channel},
        event,
        %{"message_id" => message_id} = current,
        chunk,
        index
      )
      when is_binary(message_id) do
    with {:ok, message_id} <- Outbox.integer_value(message_id) do
      body =
        %{
          "chat_id" => channel.chat_id,
          "message_id" => message_id,
          "text" => chunk["text"]
        }
        |> maybe_put("reply_markup", chunk["reply_markup"])

      case Client.call(client, "editMessageText", body) do
        {:ok, response} ->
          {:ok, Map.put(current, "index", index), compact_response(response), nil}

        {:error, %Client.Error{error_code: 400, description: description}}
        when is_binary(description) ->
          classify_edit_error(
            description,
            client,
            event,
            chunk,
            channel,
            index,
            current,
            message_id
          )

        {:error, %Client.Error{} = error} ->
          uncertain_or_error(error)
      end
    end
  end

  def upsert_message({client, channel}, event, _missing, chunk, index),
    do: post_message(client, event, chunk, channel, index)

  @impl Ankole.Plugins.ChunkedMessagePreview
  def delete_message({client, channel}, _event, %{"message_id" => message_id}) do
    with {:ok, message_id} <- Outbox.integer_value(message_id) do
      case Client.call(client, "deleteMessage", %{
             "chat_id" => channel.chat_id,
             "message_id" => message_id
           }) do
        {:ok, _response} -> :ok
        {:error, %Client.Error{error_code: 400}} -> :ok
        {:error, %Client.Error{} = error} -> uncertain_or_error(error)
      end
    end
  end

  @impl Ankole.Plugins.ChunkedMessagePreview
  def classify_error(_reason, stage, _changed?)
      when stage in [:checkpoint, :source_entry],
      do: :telegram_partial_delivery

  def classify_error(_reason, :upsert, true), do: :telegram_partial_delivery
  def classify_error(:telegram_send_uncertain, :delete, _changed?), do: :telegram_partial_delivery
  def classify_error(reason, _stage, _changed?), do: reason

  defp classify_edit_error(
         description,
         client,
         event,
         chunk,
         channel,
         index,
         current,
         message_id
       ) do
    normalized_description = String.downcase(description)

    cond do
      String.contains?(normalized_description, "message is not modified") ->
        {:ok, Map.put(current, "index", index),
         %{"message_id" => message_id, "not_modified" => true}, nil}

      String.contains?(normalized_description, "message to edit not found") ->
        post_message(client, event, chunk, channel, index)

      true ->
        {:error, %Client.Error{kind: :api, error_code: 400, description: description}}
    end
  end

  defp post_message(client, event, chunk, channel, index) do
    body =
      %{"chat_id" => channel.chat_id, "text" => chunk["text"]}
      |> maybe_put("message_thread_id", channel.topic_id)
      |> maybe_put("reply_markup", chunk["reply_markup"])
      |> maybe_reply(event)

    case Client.call(client, "sendMessage", body) do
      {:ok, %{"message_id" => message_id} = response} when is_integer(message_id) ->
        {:ok, %{"index" => index, "message_id" => Integer.to_string(message_id)},
         compact_response(response), nil}

      {:ok, _invalid} ->
        {:error, :telegram_message_id_missing}

      {:error, %Client.Error{} = error} ->
        uncertain_or_error(error)
    end
  end

  defp maybe_reply(body, %ActorEvent{} = event) do
    case ActorEvent.reply_anchor_source_entry_id(event) |> Outbox.integer_value() do
      {:ok, source_entry_id} ->
        Map.put(body, "reply_parameters", %{
          "message_id" => source_entry_id,
          "allow_sending_without_reply" => true
        })

      {:error, _reason} ->
        body
    end
  end

  defp maybe_reply(body, _event), do: body

  defp uncertain_or_error(%Client.Error{kind: :transport}),
    do: {:error, :telegram_send_uncertain}

  defp uncertain_or_error(%Client.Error{error_code: code}) when is_integer(code) and code >= 500,
    do: {:error, :telegram_send_uncertain}

  defp uncertain_or_error(%Client.Error{} = error), do: {:error, error}

  defp compact_response(%{} = response),
    do: Map.take(response, ["message_id", "date", "edit_date"])

  defp compact_response(_response), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
