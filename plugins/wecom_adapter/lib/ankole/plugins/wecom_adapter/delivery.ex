defmodule Ankole.Plugins.WeComAdapter.Delivery do
  @moduledoc """
  Conversation Delivery adapter for WeCom provider-visible output.

  Supports `post_entry` (text and single attachment) and `card` (a template
  card rendered by `TemplateCard`). WeCom AI bots have no recall API, no
  message edit, no anchored reply parameter, and no history query, so
  `delete_entry`, `edit_entry`, and reconciliation are not declared.
  Conversations.Delivery finalizes a terminal AI reply (`reply_presentation` payload
  with a source Signal) through `AIStream`, the declared
  `preview_module`; such a row without a source Signal posts its
  plain Markdown text here.

  Delivery resolves a channel per send: the respond anchor (the newest inbound
  frame's `req_id`, valid 24 hours, kept in channel-mirror metadata) rides
  `aibot_respond_msg`; without one the proactive `aibot_send_msg` needs the
  user to have messaged the bot in that conversation before, and media cannot
  be sent at all. Neither path has an idempotency parameter, so a crash after
  send but before recording leaves an uncertain result. The gateway blocks the
  operation or retries a visible durable reply with a recovery notice.
  """

  @behaviour Ankole.Conversations.Delivery.Adapter

  alias Ankole.Signals.Bindings
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.WeComAdapter.Config
  alias Ankole.Plugins.WeComAdapter.ConnectionOwner
  alias Ankole.Plugins.WeComAdapter.Markdown
  alias Ankole.Plugins.WeComAdapter.TemplateCard
  alias Ankole.Repo
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Delivery.Intent
  alias WeComOpenAPI.Bot
  alias WeComOpenAPI.Error

  import MapHelpers, only: [fetch_list: 2, optional_text: 2]

  @respond_window_seconds 24 * 60 * 60
  @image_extensions ~w(.png .jpg .jpeg .gif .webp .bmp)
  @video_extensions ~w(.mp4)
  @voice_extensions ~w(.amr)
  @image_max_bytes 10 * 1024 * 1024
  @video_max_bytes 10 * 1024 * 1024
  @voice_max_bytes 2 * 1024 * 1024
  @file_max_bytes 20 * 1024 * 1024

  @impl true
  def deliver(%Intent{payload: %{"reply_presentation" => presentation}} = intent)
      when is_map(presentation) do
    deliver_text(intent)
  end

  def deliver(%Intent{operation: :post} = intent), do: deliver_post(intent)
  def deliver(%Intent{operation: :card} = intent), do: deliver_card(intent)
  def deliver(%Intent{}), do: {:error, :unsupported_intent_operation}

  defp deliver_post(%Intent{} = intent) do
    case fetch_list(intent.payload, "attachments") do
      [] -> deliver_text(intent)
      [attachment] -> deliver_attachment(intent, attachment)
    end
  end

  defp deliver_text(%Intent{} = intent) do
    with {:ok, config} <- Bindings.delivery_config(intent, Config),
         {:ok, client} <- ConnectionOwner.bot_client(config),
         {:ok, delivery} <- resolve_delivery(intent) do
      chunks =
        intent.fallback_visible_text
        |> to_string()
        |> Markdown.to_wecom()
        |> Markdown.split()
        |> Markdown.display_chunks()

      send_markdown_chunks(client, delivery, chunks, intent)
      |> normalize_delivery_result()
    end
  end

  defp send_markdown_chunks(client, delivery, chunks, _intent) do
    chunks
    |> Enum.reduce_while([], fn chunk, results ->
      case send_markdown(client, delivery, chunk) do
        {:ok, ack} ->
          case confirmed_send_result(ack, chunk, %{"attachments" => []}) do
            {:ok, record} -> {:cont, [record | results]}
            {:unknown, _} = unknown -> {:halt, unknown}
          end

        {:error, _reason} when results != [] ->
          {:halt, :unknown}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      :unknown -> :unknown
      {:unknown, _} = unknown -> unknown
      {:error, _reason} = error -> error
      results -> {:ok, combined_result(Enum.reverse(results))}
    end
  end

  defp deliver_card(%Intent{} = intent) do
    with {:ok, config} <- Bindings.delivery_config(intent, Config),
         {:ok, client} <- ConnectionOwner.bot_client(config),
         {:ok, delivery} <- resolve_delivery(intent) do
      client
      |> TemplateCard.deliver(delivery, intent)
      |> normalize_delivery_result()
    end
  end

  defp deliver_attachment(%Intent{} = intent, attachment) do
    with {:ok, config} <- Bindings.delivery_config(intent, Config),
         {:ok, client} <- ConnectionOwner.bot_client(config),
         {:ok, delivery} <- resolve_delivery(intent),
         # Media rides the respond channel only: `aibot_send_msg` documents
         # markdown and template_card, so a proactive media send has no
         # verified carrier.
         :ok <- ensure_respond_channel(delivery),
         {:ok, content, name} <- read_attachment(attachment),
         {:ok, media_type} <- media_type(name, byte_size(content)),
         {:ok, media_id} <- Bot.upload_media(client, media_type, name, content) do
      client
      |> Bot.reply_media(delivery.respond_req_id, media_type, media_id)
      |> case do
        {:ok, ack} ->
          confirmed_send_result(ack, nil, Map.put(intent.payload, "attachments", [attachment]))

        {:error, _reason} = error ->
          error
      end
      |> normalize_delivery_result()
    end
  end

  defp ensure_respond_channel(%{respond_req_id: req_id}) when is_binary(req_id), do: :ok
  defp ensure_respond_channel(_delivery), do: {:error, :no_reply_anchor}

  defp read_attachment(attachment) do
    with {:ok, content} <- Ankole.Conversations.Delivery.attachment_content(attachment) do
      {:ok, content, attachment_name(attachment)}
    end
  end

  # Type by extension with the platform's caps applied as deterministic form
  # degrades: an oversized image/video and a non-AMR or oversized voice all
  # ship as plain files (content unchanged), while an oversized file fails
  # loudly — there is nothing to degrade into.
  defp media_type(name, size) do
    ext = name |> Path.extname() |> String.downcase()

    cond do
      size > @file_max_bytes -> {:error, :file_too_large}
      ext in @image_extensions and size <= @image_max_bytes -> {:ok, "image"}
      ext in @video_extensions and size <= @video_max_bytes -> {:ok, "video"}
      ext in @voice_extensions and size <= @voice_max_bytes -> {:ok, "voice"}
      true -> {:ok, "file"}
    end
  end

  defp send_markdown(client, %{respond_req_id: req_id}, chunk) when is_binary(req_id) do
    Bot.reply_markdown(client, req_id, chunk)
  end

  defp send_markdown(client, delivery, chunk) do
    Bot.send_markdown(client, delivery.chat_target, delivery.chat_type, chunk)
  end

  @doc false
  def confirmed_send_result(ack, text, payload \\ %{}) do
    case get_in(ack, ["body", "msgid"]) do
      msgid when is_binary(msgid) and msgid != "" ->
        {:ok,
         %{created_provider_message_id: msgid, text: text, payload: payload, raw_payload: ack}}

      _absent ->
        {:unknown, %{"reason" => "missing_provider_message_id", "raw_payload" => ack}}
    end
  end

  defp combined_result([result]), do: Map.put(result, :messages, [result])

  defp combined_result([first | _rest] = results) do
    %{
      created_provider_message_id: first[:created_provider_message_id],
      messages: results,
      raw_payload: %{"split" => true, "chunks" => Enum.map(results, & &1[:raw_payload])}
    }
  end

  defp combined_result([]), do: %{raw_payload: %{}}

  @doc """
  Resolves the delivery channel for one signal channel: the chat target and
  type, plus the respond anchor when the newest inbound `req_id` is still
  inside its 24-hour reply window.
  """
  @spec resolve_delivery(Intent.t() | String.t()) ::
          {:ok, %{chat_target: String.t(), chat_type: 1 | 2, respond_req_id: String.t() | nil}}
          | {:error, term()}
  def resolve_delivery(%Intent{conversation_id: conversation_id}),
    do: resolve_delivery(conversation_id)

  def resolve_delivery(conversation_id) when is_binary(conversation_id) do
    case Repo.get_by(Conversation, id: conversation_id) do
      %Conversation{external_kind: :im_dm, metadata: metadata} ->
        case optional_text(metadata, "dm_user_id") do
          user_id when is_binary(user_id) ->
            {:ok, %{chat_target: user_id, chat_type: 1, respond_req_id: respond_anchor(metadata)}}

          nil ->
            {:error, :dm_recipient_unknown}
        end

      %Conversation{metadata: metadata, provider_conversation_id: provider_id} ->
        {:ok,
         %{
           chat_target: decode_channel(provider_id),
           chat_type: 2,
           respond_req_id: respond_anchor(metadata)
         }}

      nil ->
        {:error, :external_conversation_not_found}
    end
  end

  defp respond_anchor(metadata) when is_map(metadata) do
    with req_id when is_binary(req_id) <- optional_text(metadata, "last_req_id"),
         at when is_binary(at) <- optional_text(metadata, "last_req_at"),
         {:ok, anchored_at, _offset} <- DateTime.from_iso8601(at),
         true <- DateTime.diff(DateTime.utc_now(), anchored_at) < @respond_window_seconds do
      req_id
    else
      _expired_or_missing -> nil
    end
  end

  defp respond_anchor(_metadata), do: nil

  defp decode_channel("wecom:" <> encoded), do: URI.decode(encoded)
  defp decode_channel(value), do: value

  defp attachment_name(attachment) do
    optional_text(attachment, "name") ||
      Path.basename(optional_text(attachment, "path") || "file")
  end

  @doc false
  @spec normalize_delivery_result(term()) :: term()
  def normalize_delivery_result({:error, %Error{} = error}) do
    action =
      cond do
        Error.retryable?(error) -> :retryable
        error.reason in [:auth, :ip_rejected] -> :operator_action_required
        true -> :permanent
      end

    {:error,
     {:reply_delivery, action,
      MapHelpers.compact_map(%{
        reason: error.reason,
        code: error.code,
        message: error.message,
        http_status: error.http_status
      })}}
  end

  def normalize_delivery_result({:error, :wecom_connection_unavailable}) do
    {:error, {:reply_delivery, :retryable, %{reason: :not_connected}}}
  end

  def normalize_delivery_result(result), do: result
end
