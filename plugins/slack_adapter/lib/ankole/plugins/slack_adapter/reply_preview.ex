defmodule Ankole.Plugins.SlackAdapter.ReplyPreview do
  @moduledoc """
  Slack transport for the shared crash-recoverable message preview ledger.

  Slack renders one reply as one or more Block Kit messages. The shared
  `ChunkedMessagePreview` module owns the durable message list and the order of
  provider mutations and checkpoint writes.
  """

  @behaviour Ankole.SignalsGateway.ReplyPreviewAdapter
  @behaviour Ankole.Plugins.ChunkedMessagePreview

  alias Ankole.I18n
  alias Ankole.Plugins.ChunkedMessagePreview
  alias Ankole.Plugins.SlackAdapter.{BlockKit, Config, ErrorPolicy, Mrkdwn}
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias SlackOpenAPI.Error

  @fallback_chars 3_000

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def open(%Request{} = request), do: deliver(request)

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def update(%Request{} = request), do: deliver(request)

  @impl Ankole.SignalsGateway.ReplyPreviewAdapter
  def finalize(%Request{} = request) do
    case ChunkedMessagePreview.reconcile(%{request | mode: :terminal}, __MODULE__, "slack") do
      {:error, :slack_partial_delivery} -> :unknown
      result -> ErrorPolicy.normalize_delivery_result(result)
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
    |> ChunkedMessagePreview.reconcile(__MODULE__, "slack")
    |> ErrorPolicy.normalize_delivery_result()
  end

  @impl Ankole.Plugins.ChunkedMessagePreview
  def render_chunks(presentation, %Request{} = request) do
    with {:ok, config} <- Config.validate_chat_config(request.config),
         client <- Config.client(config),
         {:ok, blocks} <- BlockKit.render(%{"reply_presentation" => presentation}) do
      {:ok, normalized_chunks(blocks), {client, presentation}, nil}
    end
  end

  @impl Ankole.Plugins.ChunkedMessagePreview
  def upsert_message(
        {client, presentation},
        event,
        %{"message_id" => message_id},
        blocks,
        index
      )
      when is_binary(message_id) do
    body = %{
      "channel" => channel_id(event.signal_channel_id),
      "ts" => message_id,
      "text" => fallback_text(presentation, index),
      "blocks" => blocks
    }

    case SlackOpenAPI.post(client, "chat.update", body: body) do
      {:ok, response} ->
        {:ok, message_record(index, message_id), response, response_thread_id(event, response)}

      {:error, %Error{reason: "message_not_found"}} ->
        post_message(client, event, blocks, presentation, index)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def upsert_message({client, presentation}, event, _missing, blocks, index),
    do: post_message(client, event, blocks, presentation, index)

  @impl Ankole.Plugins.ChunkedMessagePreview
  def delete_message({client, _presentation}, event, %{"message_id" => message_id}) do
    body = %{"channel" => channel_id(event.signal_channel_id), "ts" => message_id}

    case SlackOpenAPI.post(client, "chat.delete", body: body) do
      {:ok, _response} -> :ok
      {:error, %Error{reason: "message_not_found"}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Ankole.Plugins.ChunkedMessagePreview
  def classify_error(_reason, stage, _changed?)
      when stage in [:checkpoint, :source_entry],
      do: :slack_partial_delivery

  def classify_error(_reason, :upsert, true), do: :slack_partial_delivery
  def classify_error(reason, _stage, _changed?), do: reason

  defp post_message(client, event, blocks, presentation, index) do
    body = %{
      "channel" => channel_id(event.signal_channel_id),
      "text" => fallback_text(presentation, index),
      "blocks" => blocks
    }

    body =
      case ActorEvent.reply_anchor_source_entry_id(event) do
        source_entry_id when is_binary(source_entry_id) ->
          Map.put(body, "thread_ts", source_entry_id)

        _no_anchor ->
          body
      end

    case post_with_thread_fallback(client, body) do
      {:ok, %{"ts" => message_id} = response} when is_binary(message_id) ->
        {:ok, message_record(index, message_id), response, response_thread_id(event, response)}

      {:ok, response} ->
        {:error, {:slack_message_id_missing, response}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post_with_thread_fallback(client, body) do
    case SlackOpenAPI.post(client, "chat.postMessage", body: body) do
      {:error, %Error{reason: reason}}
      when reason in ["thread_not_found", "message_not_found"] and is_map_key(body, "thread_ts") ->
        SlackOpenAPI.post(client, "chat.postMessage", body: Map.delete(body, "thread_ts"))

      result ->
        result
    end
  end

  defp response_thread_id(event, response) do
    case get_in(response, ["message", "thread_ts"]) do
      thread_ts when is_binary(thread_ts) ->
        "#{event.signal_channel_id}:#{URI.encode(thread_ts)}"

      _missing ->
        nil
    end
  end

  defp message_record(index, message_id), do: %{"index" => index, "message_id" => message_id}

  defp normalized_chunks(blocks) do
    case BlockKit.split_blocks(blocks) do
      [] ->
        text = I18n.t("signals_gateway.reply.no_content")
        [[%{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => text}}]]

      chunks ->
        chunks
    end
  end

  defp fallback_text(presentation, index) do
    text = presentation |> ReplyPresentation.fallback_text() |> Mrkdwn.from_markdown()
    text = if index == 0, do: text, else: "#{text} (continued #{index + 1})"
    String.slice(text, 0, @fallback_chars)
  end

  defp channel_id("slack:" <> encoded), do: URI.decode(encoded)
  defp channel_id(channel), do: channel
end
