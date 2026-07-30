defmodule Ankole.Plugins.WeComAdapter.Outbox do
  @moduledoc """
  SignalsGateway outbox adapter for WeCom provider-visible output.

  Supports `post_entry` (text and single attachment) and `card` (a template
  card rendered by `TemplateCard`). WeCom AI bots have no recall API, no
  message edit, no anchored reply parameter, and no history query, so
  `delete_entry`, `edit_entry`, and reconciliation are not declared. A
  terminal AI reply (`reply_presentation` payload) routes through
  `AIStream.finalize/1` — the module declared as the `reply_preview_module` —
  which seals the streaming chain or degrades once to plain Markdown.

  Delivery resolves a channel per send: the respond anchor (the newest inbound
  frame's `req_id`, valid 24 hours, kept in channel-mirror metadata) rides
  `aibot_respond_msg`; without one the proactive `aibot_send_msg` needs the
  user to have messaged the bot in that conversation before, and media cannot
  be sent at all. Neither path has an idempotency parameter, so a crash after
  send but before recording leaves a documented duplicate window.
  """

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.WeComAdapter.AIStream
  alias Ankole.Plugins.WeComAdapter.Config
  alias Ankole.Plugins.WeComAdapter.ConnectionOwner
  alias Ankole.Plugins.WeComAdapter.Markdown
  alias Ankole.Plugins.WeComAdapter.TemplateCard
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.ReplyPreviewAdapter.Request
  alias Ankole.WorkerFiles
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
  def send(
        %OutboxEntry{
          payload: %{"reply_presentation" => presentation},
          source_actor_event_id: actor_event_id
        } = outbox
      )
      when is_map(presentation) and is_binary(actor_event_id) do
    # The durable terminal AI reply finalizes the streaming chain (or degrades
    # to plain Markdown messages when no stream ever opened).
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{} = event ->
        checkpoint = event.reply_preview_checkpoint || %{}

        AIStream.finalize(%Request{
          actor_event: event,
          presentation: presentation,
          checkpoint: checkpoint,
          subject_uid: checkpoint["subject_uid"],
          conversation_id: checkpoint["conversation_id"],
          outbox: outbox,
          mode: :terminal
        })

      nil ->
        {:error, :actor_event_not_found}
    end
  end

  def send(%OutboxEntry{payload: %{"reply_presentation" => presentation}} = outbox)
      when is_map(presentation) do
    deliver_text(outbox)
  end

  def send(%OutboxEntry{operation: :post} = outbox), do: deliver_post(outbox)
  def send(%OutboxEntry{operation: :card} = outbox), do: deliver_card(outbox)
  def send(%OutboxEntry{}), do: {:error, :unsupported_outbox_operation}

  # --- post -----------------------------------------------------------------

  defp deliver_post(%OutboxEntry{} = outbox) do
    case fetch_list(outbox.payload, "attachments") do
      [] -> deliver_text(outbox)
      [attachment] -> deliver_attachment(outbox, attachment)
      _attachments -> {:error, :multiple_outbound_attachments_not_supported}
    end
  end

  defp deliver_text(%OutboxEntry{} = outbox) do
    with {:ok, config} <- config_for_outbox(outbox),
         {:ok, client} <- ConnectionOwner.bot_client(config),
         {:ok, delivery} <- resolve_delivery(outbox) do
      chunks =
        outbox.fallback_visible_text
        |> to_string()
        |> Markdown.to_wecom()
        |> Markdown.split()
        |> Markdown.display_chunks()

      send_markdown_chunks(client, delivery, chunks, outbox)
      |> normalize_delivery_error()
    end
  end

  defp send_markdown_chunks(client, delivery, chunks, outbox) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {chunk, index}, results ->
      case send_markdown(client, delivery, chunk) do
        {:ok, ack} -> {:cont, [send_record(ack, outbox, index) | results]}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      results -> {:ok, combined_result(Enum.reverse(results))}
    end
  end

  # --- card -----------------------------------------------------------------

  defp deliver_card(%OutboxEntry{} = outbox) do
    with {:ok, config} <- config_for_outbox(outbox),
         {:ok, client} <- ConnectionOwner.bot_client(config),
         {:ok, delivery} <- resolve_delivery(outbox) do
      client
      |> TemplateCard.deliver(delivery, outbox)
      |> normalize_delivery_error()
    end
  end

  # --- attachment -----------------------------------------------------------

  defp deliver_attachment(%OutboxEntry{} = outbox, attachment) do
    with {:ok, config} <- config_for_outbox(outbox),
         {:ok, client} <- ConnectionOwner.bot_client(config),
         {:ok, delivery} <- resolve_delivery(outbox),
         # Media rides the respond channel only: `aibot_send_msg` documents
         # markdown and template_card, so a proactive media send has no
         # verified carrier.
         :ok <- ensure_respond_channel(delivery),
         {:ok, content, name} <- read_attachment(attachment, outbox.agent_uid),
         {:ok, media_type} <- media_type(name, byte_size(content)),
         {:ok, media_id} <- Bot.upload_media(client, media_type, name, content) do
      client
      |> Bot.reply_media(delivery.respond_req_id, media_type, media_id)
      |> case do
        {:ok, ack} -> {:ok, send_record(ack, outbox, 0)}
        {:error, _reason} = error -> error
      end
      |> normalize_delivery_error()
    end
  end

  defp ensure_respond_channel(%{respond_req_id: req_id}) when is_binary(req_id), do: :ok
  defp ensure_respond_channel(_delivery), do: {:error, :no_reply_anchor}

  defp read_attachment(attachment, agent_uid) do
    with relative_path when is_binary(relative_path) <-
           attachment_relative_path(attachment, agent_uid),
         {:ok, %{"content" => content}} <- WorkerFiles.get("user_files", relative_path) do
      {:ok, content, attachment_name(attachment, relative_path)}
    else
      nil -> {:error, :outbound_attachment_path_missing}
      {:error, _reason} = error -> error
      _other -> {:error, :outbound_attachment_read_failed}
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

  # --- send primitives ------------------------------------------------------

  defp send_markdown(client, %{respond_req_id: req_id}, chunk) when is_binary(req_id) do
    Bot.reply_markdown(client, req_id, chunk)
  end

  defp send_markdown(client, delivery, chunk) do
    Bot.send_markdown(client, delivery.chat_target, delivery.chat_type, chunk)
  end

  # The ack frame is not documented to carry a provider message id; use it when
  # present and otherwise record a synthetic id derived from the outbox key so
  # the mirror entry stays stable across retries.
  defp send_record(ack, outbox, index) do
    case get_in(ack, ["body", "msgid"]) do
      msgid when is_binary(msgid) and msgid != "" ->
        %{created_source_entry_id: msgid, raw_payload: ack}

      _absent ->
        %{
          created_source_entry_id: "wecom:outbox:#{outbox_key(outbox)}:#{index}",
          synthetic_entry_id: true,
          raw_payload: ack
        }
    end
  end

  defp outbox_key(%OutboxEntry{} = outbox),
    do: outbox.idempotency_key || outbox.outbound_key

  defp combined_result([result]), do: result

  defp combined_result([first | _rest] = results) do
    %{
      created_source_entry_id: first[:created_source_entry_id],
      raw_payload: %{"split" => true, "chunks" => Enum.map(results, & &1[:raw_payload])}
    }
  end

  defp combined_result([]), do: %{raw_payload: %{}}

  # --- delivery resolution --------------------------------------------------

  @doc """
  Resolves the delivery channel for one signal channel: the chat target and
  type, plus the respond anchor when the newest inbound `req_id` is still
  inside its 24-hour reply window.
  """
  @spec resolve_delivery(OutboxEntry.t() | String.t()) ::
          {:ok, %{chat_target: String.t(), chat_type: 1 | 2, respond_req_id: String.t() | nil}}
          | {:error, term()}
  def resolve_delivery(%OutboxEntry{signal_channel_id: signal_channel_id}),
    do: resolve_delivery(signal_channel_id)

  def resolve_delivery(signal_channel_id) when is_binary(signal_channel_id) do
    decoded_target = decode_channel(signal_channel_id)

    case Repo.get(Channel, signal_channel_id) do
      %Channel{kind: :im_dm, metadata: metadata} ->
        case optional_text(metadata, "dm_user_id") do
          user_id when is_binary(user_id) ->
            {:ok, %{chat_target: user_id, chat_type: 1, respond_req_id: respond_anchor(metadata)}}

          nil ->
            {:error, :dm_recipient_unknown}
        end

      %Channel{metadata: metadata} ->
        {:ok,
         %{chat_target: decoded_target, chat_type: 2, respond_req_id: respond_anchor(metadata)}}

      nil ->
        {:ok, %{chat_target: decoded_target, chat_type: 2, respond_req_id: nil}}
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

  # --- helpers --------------------------------------------------------------

  defp config_for_outbox(%OutboxEntry{} = outbox) do
    with {:ok, config_ref} <- SignalsGateway.outbox_binding_config_ref(outbox),
         {:ok, config} <- Config.load_chat_config_ref(config_ref) do
      {:ok, config}
    else
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp attachment_relative_path(attachment, agent_uid) do
    case optional_text(attachment, "user_files_relative_path") do
      relative when is_binary(relative) ->
        Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative)

      _missing ->
        user_files = Ankole.AgentHomePaths.user_files(agent_uid) <> "/"

        case optional_text(attachment, "agent_computer_path") || optional_text(attachment, "path") do
          ^user_files <> relative ->
            Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative)

          _outside ->
            nil
        end
    end
  end

  defp attachment_name(attachment, relative_path) do
    optional_text(attachment, "name") || Path.basename(relative_path)
  end

  defp normalize_delivery_error({:error, %Error{} = error}) do
    {:error,
     {:provider_error,
      MapHelpers.compact_map(%{
        reason: error.reason,
        code: error.code,
        message: error.message,
        http_status: error.http_status
      })}}
  end

  defp normalize_delivery_error({:error, :wecom_connection_unavailable}) do
    {:error, {:provider_error, %{reason: :not_connected}}}
  end

  defp normalize_delivery_error(result), do: result
end
