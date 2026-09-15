defmodule Ankole.Plugins.WhatsAppAdapter.Outbox do
  @moduledoc false

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  import Ecto.Query, warn: false

  alias Ankole.{Logging, Repo, SignalsGateway, WorkerFiles}
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.WhatsAppAdapter.{Client, Config, ErrorPolicy, Presentation}
  alias Ankole.SignalsGateway.{Actors, Channel, Entry, OutboxEntry}

  @divider "────────"

  # Meta closes the customer service window 24 hours after the user's newest
  # message. The margin keeps a reply that starts just inside the window from
  # arriving just outside it.
  @customer_service_window_seconds 24 * 60 * 60
  @customer_service_window_margin_seconds 5 * 60

  @image_mime_types ["image/jpeg", "image/png"]
  @video_mime_types ["video/mp4", "video/3gpp"]
  @audio_mime_types ["audio/aac", "audio/mp4", "audio/mpeg", "audio/amr", "audio/ogg"]
  @document_mime_types [
    "text/plain",
    "application/pdf",
    "application/vnd.ms-powerpoint",
    "application/msword",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  ]

  @media_limits %{
    "image" => 5 * 1024 * 1024,
    "video" => 16 * 1024 * 1024,
    "audio" => 16 * 1024 * 1024,
    "document" => 100 * 1024 * 1024
  }

  @impl true
  def send(%OutboxEntry{} = outbox) do
    result =
      with {:ok, target} <- Presentation.parse_channel(outbox.signal_channel_id),
           {:ok, config} <- config_for_outbox(outbox),
           :ok <- binding_owns_channel(target, config),
           :ok <- customer_service_window_open(outbox, DateTime.utc_now()),
           client <- Config.client(config),
           {:ok, uploads} <- upload_attachments(outbox, Config.phone_number_id(config), client),
           {:ok, messages} <- messages(outbox, target, uploads),
           {:ok, sent, surface_entry_id} <-
             deliver(messages, client, Config.phone_number_id(config), outbox) do
        record_reply_surface(outbox, surface_entry_id)
        {:ok, sent}
      end

    ErrorPolicy.normalize_delivery_result(result)
  end

  @doc """
  Builds the message bodies of one outbox row.

  `uploads` names the media the adapter already uploaded for this row, in the
  order of the stored attachments.
  """
  @spec messages(OutboxEntry.t(), map(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def messages(%OutboxEntry{operation: operation} = outbox, target, uploads)
      when operation in [:post, :reply, :card] do
    bodies =
      case uploads do
        [] -> Presentation.text_messages(outbox.fallback_visible_text) ++ action_messages(outbox)
        uploads -> media_bodies(outbox, uploads)
      end

    {:ok, envelopes(bodies, target, outbox)}
  end

  def messages(%OutboxEntry{operation: :divider} = outbox, target, _uploads) do
    text =
      case String.trim(to_string(outbox.fallback_visible_text || "")) do
        "" -> @divider
        value -> @divider <> "\n" <> value
      end

    {:ok, envelopes(Presentation.text_messages(text), target, outbox)}
  end

  def messages(_outbox, _target, _uploads), do: {:error, :unsupported_outbox_operation}

  # The channel id names the phone number that received the chat. An operator
  # who moves the binding to another number cannot answer those chats from it:
  # Meta would deliver the reply from a number the user never wrote to, and the
  # old channel's window says nothing about the new number.
  defp binding_owns_channel(%{phone_number_id: phone_number_id}, config) do
    if phone_number_id == Config.phone_number_id(config),
      do: :ok,
      else: {:error, :binding_phone_number_mismatch}
  end

  @doc false
  @spec customer_service_window_open(OutboxEntry.t(), DateTime.t()) ::
          :ok | {:error, :customer_service_window_closed}
  def customer_service_window_open(%OutboxEntry{} = outbox, %DateTime{} = now) do
    case newest_inbound_at(outbox.signal_channel_id) do
      nil ->
        :ok

      %DateTime{} = inbound_at ->
        if DateTime.diff(now, inbound_at, :second) >=
             @customer_service_window_seconds - @customer_service_window_margin_seconds,
           do: {:error, :customer_service_window_closed},
           else: :ok
    end
  end

  # Meta re-opens the window on any user action, and a button tap is one. Both
  # facts the check reads are provider times: a message is a human Entry with
  # its `provider_time`, and a tap is the channel fact the adapter writes from
  # the interactive message's own `timestamp`. Reading a database time instead
  # would open a window Meta had already closed, because Meta redelivers an
  # undelivered webhook for up to seven days.
  #
  # The tap fact is monotonic: the adapter writes it under the channel row lock
  # and keeps the newer time, so an older redelivered tap cannot move it
  # backwards. A callback whose token does not resolve writes no fact at all, so
  # a stale token does not re-open the window either.
  defp newest_inbound_at(signal_channel_id) do
    [
      newest_human_entry_at(signal_channel_id),
      newest_interactive_reply_at(signal_channel_id)
    ]
    |> Enum.filter(&match?(%DateTime{}, &1))
    |> case do
      [] -> nil
      times -> Enum.max(times, DateTime)
    end
  end

  # The gateway mirrors its own replies into the same channel, and those entries
  # carry only an Agent author. A human entry is the one with a platform
  # subject, so only a real inbound message opens the window. A channel with no
  # human entry at all, such as the one that carries the held-sender notice,
  # never had a window to close.
  defp newest_human_entry_at(signal_channel_id) do
    Entry
    |> where([entry], entry.signal_channel_id == ^signal_channel_id)
    |> where([entry], not is_nil(entry.provider_time))
    |> where([entry], fragment("? ->> 'platform_subject' IS NOT NULL", entry.author))
    |> order_by([entry], desc: entry.provider_time)
    |> limit(1)
    |> select([entry], entry.provider_time)
    |> Repo.one()
  end

  defp newest_interactive_reply_at(signal_channel_id) do
    with %Channel{metadata: %{"last_interactive_reply_at" => value}} when is_binary(value) <-
           Repo.get(Channel, signal_channel_id),
         {:ok, at, _offset} <- DateTime.from_iso8601(value) do
      at
    else
      _absent_or_unparsable -> nil
    end
  end

  defp envelopes(bodies, target, outbox) do
    bodies
    |> Enum.map(
      &Map.merge(
        %{
          "messaging_product" => "whatsapp",
          "recipient_type" => "individual",
          "to" => target.wa_id
        },
        &1
      )
    )
    |> put_context(outbox)
  end

  defp put_context(
         [first | rest],
         %OutboxEntry{operation: :reply, reply_to_source_entry_id: source_entry_id}
       )
       when is_binary(source_entry_id),
       do: [Map.put(first, "context", %{"message_id" => source_entry_id}) | rest]

  defp put_context(messages, _outbox), do: messages

  defp media_bodies(outbox, uploads) do
    {caption, remaining} = Presentation.split_caption(outbox.fallback_visible_text)

    media =
      uploads
      |> Enum.with_index()
      |> Enum.map(fn {upload, index} ->
        media_body(upload, if(index == 0, do: caption, else: ""))
      end)

    case String.trim(remaining) do
      "" -> media
      _text -> media ++ Presentation.text_messages(remaining)
    end
  end

  defp media_body(%{kind: kind, id: media_id, name: name}, caption) do
    media =
      %{"id" => media_id}
      |> maybe_put("caption", media_caption(kind, caption))
      |> maybe_put("filename", if(kind == "document", do: name))

    %{"type" => kind, kind => media}
  end

  # The Cloud API accepts a caption on an image, a video, and a document only.
  defp media_caption(kind, caption) when kind in ["image", "video", "document"] do
    case caption do
      "" -> nil
      text -> text
    end
  end

  defp media_caption(_kind, _caption), do: nil

  defp action_messages(%OutboxEntry{
         payload: %{"reply_presentation" => presentation},
         source_actor_event_id: actor_event_id,
         fallback_visible_text: fallback_text
       })
       when is_map(presentation) and is_binary(actor_event_id) do
    presentation
    |> Presentation.action_message(actor_event_id, fallback_text)
    |> List.wrap()
  end

  defp action_messages(_outbox), do: []

  defp upload_attachments(%OutboxEntry{} = outbox, phone_number_id, client) do
    outbox.payload
    |> MapHelpers.fetch_list("attachments")
    |> Enum.map(&upload_attachment(&1, outbox.agent_uid, phone_number_id, client))
    |> MapHelpers.collect_results()
  end

  defp upload_attachment(attachment, agent_uid, phone_number_id, client) do
    with {:ok, kind, mime_type} <- media_kind(attachment),
         {:ok, content, name} <- attachment_content(attachment, agent_uid),
         :ok <- within_media_limit(kind, byte_size(content)),
         {:ok, media_id} <-
           Client.upload_media(client, phone_number_id, name, mime_type, content) do
      {:ok, %{id: media_id, kind: kind, name: name}}
    end
  end

  # The Cloud API accepts one message type for each media class and rejects a
  # file that is too large for it. Ankole refuses such a file here instead of
  # sending a request that cannot succeed, and it checks the recorded size
  # before it moves the bytes out of the worker.
  defp media_kind(attachment) do
    name = MapHelpers.presence(attachment["name"]) || ""
    mime_type = MapHelpers.presence(attachment["mime_type"]) || MIME.from_path(name)

    kind =
      cond do
        mime_type in @image_mime_types -> "image"
        mime_type in @video_mime_types -> "video"
        mime_type in @audio_mime_types -> "audio"
        mime_type in @document_mime_types -> "document"
        true -> nil
      end

    with true <- is_binary(kind),
         :ok <- within_media_limit(kind, attachment["size"]) do
      {:ok, kind, mime_type}
    else
      _unsupported -> {:error, :outbound_attachment_unsupported}
    end
  end

  defp within_media_limit(kind, size) when is_integer(size) do
    if size <= Map.fetch!(@media_limits, kind),
      do: :ok,
      else: {:error, :outbound_attachment_unsupported}
  end

  defp within_media_limit(_kind, _size), do: :ok

  defp attachment_content(attachment, agent_uid) do
    relative = MapHelpers.presence(attachment["user_files_relative_path"])
    lane_path = if relative, do: Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative)

    with path when is_binary(path) <- lane_path,
         {:ok, %{"content" => content}} <- WorkerFiles.get("user_files", path) do
      {:ok, content, MapHelpers.presence(attachment["name"]) || Path.basename(relative)}
    else
      nil -> {:error, :outbound_attachment_path_missing}
      {:error, _reason} = error -> error
    end
  end

  # The Cloud API has no idempotency key for a message send, and it offers no
  # read-back of a request whose answer was lost. A failure after an earlier
  # message of the same row already landed is therefore uncertain, and so is a
  # transport failure or a server error on the send itself.
  defp deliver(messages, client, phone_number_id, outbox) do
    messages
    |> Enum.reduce_while({:ok, []}, fn body, {:ok, sent} ->
      case Client.send_message(client, phone_number_id, body) do
        {:ok, result} ->
          {:cont, {:ok, [{body, result} | sent]}}

        {:error, error} ->
          cond do
            sent != [] -> {:halt, :unknown}
            uncertain?(error) -> {:halt, :unknown}
            true -> {:halt, {:error, error}}
          end
      end
    end)
    |> case do
      {:ok, results} ->
        results = Enum.reverse(results)
        {:ok, combine_results(results, outbox), interactive_source_entry_id(results)}

      other ->
        other
    end
  end

  defp uncertain?(%Client.Error{kind: :transport}), do: true

  defp uncertain?(%Client.Error{status: status}) when is_integer(status) and status >= 500,
    do: true

  defp uncertain?(%Client.Error{}), do: false

  # The gateway keeps one created entry id per row. A long reply is several
  # WhatsApp messages, so the row's payload keeps every sent id.
  defp combine_results(results, outbox) do
    ids = Enum.flat_map(results, fn {_body, result} -> sent_ids(result) end)

    %{
      created_source_entry_id: List.first(ids),
      raw_payload: %{"messages" => ids},
      payload: Map.put(outbox.payload, "whatsapp_message_ids", ids)
    }
    |> MapHelpers.compact_map()
  end

  # The reply surface is the message that carried the buttons, not the first
  # text chunk of the same reply: an inbound button reply names that exact
  # message in its context, and the gateway accepts a managed callback only for
  # the provider entry the surface holds. A reply with no interactive message
  # has no surface to record.
  defp interactive_source_entry_id(results) do
    Enum.find_value(results, fn
      {%{"type" => "interactive"}, result} -> List.first(sent_ids(result))
      _text_or_media -> nil
    end)
  end

  defp sent_ids(result) do
    result
    |> MapHelpers.fetch_list("messages")
    |> Enum.map(fn message -> is_map(message) && message["id"] end)
    |> Enum.filter(&is_binary/1)
  end

  defp record_reply_surface(
         %OutboxEntry{source_actor_event_id: actor_event_id},
         source_entry_id
       )
       when is_binary(actor_event_id) and is_binary(source_entry_id) do
    case Actors.record_reply_preview_source_entry(actor_event_id, source_entry_id) do
      :ok ->
        :ok

      {:error, :reply_preview_source_entry_already_recorded} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "whatsapp_adapter.outbox.reply_surface_not_recorded",
          "WhatsApp reply surface could not be recorded",
          %{actor_event_id: actor_event_id, reason: inspect(reason)}
        )

        :ok
    end
  end

  defp record_reply_surface(_outbox, _source_entry_id), do: :ok

  defp config_for_outbox(outbox) do
    with {:ok, config_ref} <- SignalsGateway.outbox_binding_config_ref(outbox),
         {:ok, config} <- Config.load_config_ref(config_ref) do
      {:ok, config}
    else
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
