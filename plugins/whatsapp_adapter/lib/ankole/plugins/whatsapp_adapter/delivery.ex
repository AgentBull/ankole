defmodule Ankole.Plugins.WhatsAppAdapter.Delivery do
  @moduledoc false

  @behaviour Ankole.Conversations.Delivery.Adapter

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Signals.Bindings
  alias Ankole.Logging
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.WhatsAppAdapter.Client
  alias Ankole.Plugins.WhatsAppAdapter.Config
  alias Ankole.Plugins.WhatsAppAdapter.ErrorPolicy
  alias Ankole.Plugins.WhatsAppAdapter.Presentation
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Delivery.Intent

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
  def deliver(%Intent{} = intent) do
    result =
      with {:ok, conversation} <-
             Ankole.Conversations.External.fetch_conversation(intent.conversation_id),
           {:ok, target} <- Presentation.parse_channel(conversation.provider_conversation_id),
           {:ok, config} <- Bindings.delivery_config(intent, Config),
           config = Config.runtime_config(config),
           :ok <- binding_owns_channel(target, config),
           :ok <- customer_service_window_open(intent, DateTime.utc_now()),
           client <- Config.client(config),
           {:ok, uploads} <- upload_attachments(intent, Config.phone_number_id(config), client),
           {:ok, messages} <- messages(intent, target, uploads),
           {:ok, sent, surface_entry_id} <-
             deliver(messages, client, Config.phone_number_id(config), intent) do
        record_reply_surface(intent, surface_entry_id)
        {:ok, sent}
      end

    ErrorPolicy.normalize_delivery_result(result)
  end

  @doc """
  Builds the message bodies of one intent row.

  `uploads` names the media the adapter already uploaded for this row, in the
  order of the stored attachments.
  """
  @spec messages(Intent.t(), map(), [map()]) :: {:ok, [map()]} | {:error, term()}
  def messages(%Intent{operation: operation} = intent, target, uploads)
      when operation in [:post, :reply, :card] do
    bodies =
      case uploads do
        [] -> Presentation.text_messages(intent.fallback_visible_text) ++ action_messages(intent)
        uploads -> media_bodies(intent, uploads)
      end

    {:ok, envelopes(bodies, target, intent)}
  end

  def messages(%Intent{operation: :divider} = intent, target, _uploads) do
    text =
      case String.trim(to_string(intent.fallback_visible_text || "")) do
        "" -> @divider
        value -> @divider <> "\n" <> value
      end

    {:ok, envelopes(Presentation.text_messages(text), target, intent)}
  end

  def messages(_intent, _target, _uploads), do: {:error, :unsupported_intent_operation}

  # The channel id names the phone number that received the chat. An operator
  # who moves the binding to another number cannot answer those chats from it:
  # Meta would deliver the reply from a number the user never wrote to, and the
  # old channel's window says nothing about the new number.
  defp binding_owns_channel(%{phone_number_id: phone_number_id}, config) do
    if phone_number_id == Config.phone_number_id(config),
      do: :ok,
      else: {:error, :binding_phone_number_mismatch}
  end

  @spec customer_service_window_open(Intent.t(), DateTime.t()) ::
          :ok | {:error, :customer_service_window_closed}
  defp customer_service_window_open(%Intent{} = intent, %DateTime{} = now) do
    case newest_inbound_at(intent.conversation_id) do
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
  defp newest_inbound_at(conversation_id) do
    [
      newest_inbound_message_at(conversation_id),
      newest_interactive_reply_at(conversation_id)
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
  defp newest_inbound_message_at(conversation_id) do
    Ankole.Conversations.list_external_message_refs!(
      query: [
        filter: [
          conversation_id: conversation_id,
          provider_time: [is_nil: false],
          author: [at_path: ["platform_subject"], is_nil: false]
        ],
        sort: [provider_time: :desc],
        limit: 1,
        select: [:provider_time]
      ]
    )
    |> Enum.find_value(& &1.provider_time)
  end

  defp newest_interactive_reply_at(conversation_id) do
    with %Conversation{metadata: %{"last_interactive_reply_at" => value}} when is_binary(value) <-
           Ankole.Conversations.get_conversation!(conversation_id),
         {:ok, at, _offset} <- DateTime.from_iso8601(value) do
      at
    else
      _absent_or_unparsable -> nil
    end
  end

  defp envelopes(bodies, target, intent) do
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
    |> put_context(intent)
  end

  defp put_context(
         [first | rest],
         %Intent{operation: :reply, reply_to_provider_message_id: provider_message_id}
       )
       when is_binary(provider_message_id),
       do: [Map.put(first, "context", %{"message_id" => provider_message_id}) | rest]

  defp put_context(messages, _intent), do: messages

  defp media_bodies(intent, uploads) do
    {caption, remaining} = Presentation.split_caption(intent.fallback_visible_text)

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

  defp action_messages(%Intent{
         payload: %{"reply_presentation" => presentation},
         source_signal_id: signal_id,
         fallback_visible_text: fallback_text
       })
       when is_map(presentation) and is_binary(signal_id) do
    presentation
    |> Presentation.action_message(signal_id, fallback_text)
    |> List.wrap()
  end

  defp action_messages(_intent), do: []

  defp upload_attachments(%Intent{} = intent, phone_number_id, client) do
    intent.payload
    |> MapHelpers.fetch_list("attachments")
    |> Enum.map(&upload_attachment(&1, phone_number_id, client))
    |> MapHelpers.collect_results()
  end

  defp upload_attachment(attachment, phone_number_id, client) do
    with {:ok, kind, mime_type} <- media_kind(attachment),
         {:ok, content, name} <- attachment_content(attachment),
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

  defp attachment_content(attachment) do
    with {:ok, content} <- Ankole.Conversations.Delivery.attachment_content(attachment) do
      {:ok, content,
       MapHelpers.presence(attachment["name"]) ||
         Path.basename(attachment["path"] || "attachment")}
    end
  end

  # The Cloud API has no idempotency key for a message send, and it offers no
  # read-back of a request whose answer was lost. A failure after an earlier
  # message of the same row already landed is therefore uncertain, and so is a
  # transport failure or a server error on the send itself.
  defp deliver(messages, client, phone_number_id, intent) do
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
        {:ok, combine_results(results, intent), interactive_provider_message_id(results)}

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
  defp combine_results(results, intent) do
    messages =
      Enum.flat_map(results, fn {body, result} ->
        text =
          case body["type"] do
            "text" -> get_in(body, ["text", "body"])
            "interactive" -> get_in(body, ["interactive", "body", "text"])
            kind -> get_in(body, [kind, "caption"])
          end

        Enum.map(sent_ids(result), fn id ->
          %{
            created_provider_message_id: id,
            text: text,
            raw_payload: result,
            payload: %{
              "attachments" =>
                if(body["type"] in ["text", "interactive"],
                  do: [],
                  else: MapHelpers.fetch_list(intent.payload, "attachments")
                )
            }
          }
        end)
      end)

    ids = Enum.map(messages, & &1.created_provider_message_id)

    %{
      created_provider_message_id: List.first(ids),
      messages: messages,
      raw_payload: %{"messages" => ids},
      payload: Map.put(intent.payload, "whatsapp_message_ids", ids)
    }
    |> MapHelpers.compact_map()
  end

  # The reply surface is the message that carried the buttons, not the first
  # text chunk of the same reply: an inbound button reply names that exact
  # message in its context, and the gateway accepts a managed callback only for
  # the provider entry the surface holds. A reply with no interactive message
  # has no surface to record.
  defp interactive_provider_message_id(results) do
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
         %Intent{source_signal_id: signal_id},
         provider_message_id
       )
       when is_binary(signal_id) and is_binary(provider_message_id) do
    case PreviewStates.record_provider_message(
           signal_id,
           provider_message_id
         ) do
      :ok ->
        :ok

      {:error, :reply_preview_source_entry_already_recorded} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "whatsapp_adapter.delivery.reply_surface_not_recorded",
          "WhatsApp reply surface could not be recorded",
          %{signal_id: signal_id, reason: inspect(reason)}
        )

        :ok
    end
  end

  defp record_reply_surface(_intent, _provider_message_id), do: :ok

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
