defmodule Ankole.Plugins.DiscordAdapter.ReplyPreview do
  @moduledoc "Discord transport for the shared crash-recoverable message preview ledger."

  @behaviour Ankole.SignalsGateway.ReplyPreviewAdapter
  @behaviour Ankole.Plugins.ChunkedMessagePreview

  alias Ankole.Plugins.ChunkedMessagePreview
  alias Ankole.Plugins.DiscordAdapter.{Client, Config, ErrorPolicy, Outbox, Presentation}
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def open(%Request{} = request), do: deliver(request)

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def update(%Request{} = request), do: deliver(request)

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def finalize(%Request{} = request) do
    case ChunkedMessagePreview.reconcile(%{request | mode: :terminal}, __MODULE__, "discord") do
      {:error, reason} when reason in [:discord_partial_delivery, :discord_send_uncertain] ->
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
    |> ChunkedMessagePreview.reconcile(__MODULE__, "discord")
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
    body = message_body(%{"content" => chunk["content"], "components" => chunk["components"]})

    case Client.patch(client, message_path(channel, message_id), body) do
      {:ok, response} ->
        {:ok, Map.put(current, "index", index), compact_response(response), nil}

      {:error, %Client.Error{status: 404}} ->
        post_message(client, event, chunk, channel, index)

      {:error, %Client.Error{} = error} ->
        {:error, error}
    end
  end

  def upsert_message({client, channel}, event, _missing, chunk, index),
    do: post_message(client, event, chunk, channel, index)

  @impl Ankole.Plugins.ChunkedMessagePreview
  def delete_message({client, channel}, _event, %{"message_id" => message_id}) do
    case Client.delete(client, message_path(channel, message_id)) do
      {:ok, _response} -> :ok
      {:error, %Client.Error{status: 404}} -> :ok
      {:error, %Client.Error{} = error} -> {:error, error}
    end
  end

  @impl Ankole.Plugins.ChunkedMessagePreview
  def classify_error(_reason, stage, _changed?)
      when stage in [:checkpoint, :source_entry],
      do: :discord_partial_delivery

  def classify_error(_reason, :upsert, true), do: :discord_partial_delivery
  def classify_error(reason, _stage, _changed?), do: reason

  defp post_message(client, event, chunk, channel, index) do
    body =
      %{"content" => chunk["content"], "components" => chunk["components"]}
      |> maybe_reply(event)
      |> message_body()

    case Client.post(client, "/channels/#{channel.channel_id}/messages", body) do
      {:ok, %{"id" => message_id} = response} when is_binary(message_id) ->
        {:ok, %{"index" => index, "message_id" => message_id}, compact_response(response), nil}

      {:ok, _invalid} ->
        {:error, :discord_send_uncertain}

      {:error, %Client.Error{} = error} ->
        uncertain_create_or_error(error)
    end
  end

  defp maybe_reply(body, %ActorEvent{} = event) do
    case ActorEvent.reply_anchor_source_entry_id(event) |> Outbox.message_id() do
      {:ok, source_entry_id} ->
        Map.put(body, "message_reference", %{
          "message_id" => source_entry_id,
          "fail_if_not_exists" => false
        })

      {:error, _reason} ->
        body
    end
  end

  defp maybe_reply(body, _event), do: body

  defp message_path(channel, message_id),
    do: "/channels/#{channel.channel_id}/messages/#{message_id}"

  defp uncertain_create_or_error(%Client.Error{kind: :transport}),
    do: {:error, :discord_send_uncertain}

  defp uncertain_create_or_error(%Client.Error{status: status})
       when is_integer(status) and status >= 500,
       do: {:error, :discord_send_uncertain}

  defp uncertain_create_or_error(%Client.Error{} = error), do: {:error, error}

  defp message_body(body) do
    Map.put(body, "allowed_mentions", %{"parse" => [], "replied_user" => false})
  end

  defp compact_response(%{} = response),
    do: Map.take(response, ["id", "timestamp", "edited_timestamp"])

  defp compact_response(_response), do: %{}
end
