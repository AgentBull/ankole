defmodule Ankole.Plugins.EmailAdapter.Inbound do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.{Logging, Repo}
  alias Ankole.Plugins.EmailAdapter.Address
  alias Ankole.Plugins.EmailAdapter.Authentication
  alias Ankole.Plugins.EmailAdapter.Config
  alias Ankole.Plugins.EmailAdapter.Message
  alias Ankole.Plugins.EmailAdapter.ReplyText
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Conversations.AdapterContext
  alias Ankole.Conversations.{Conversation, ExternalMessageRef}
  alias Ankole.Conversations.{Attachments, Observe}

  @references_limit 40

  @spec chat_consumer(AdapterContext.t(), map()) :: map()
  def chat_consumer(%AdapterContext{} = context, config) do
    %{kind: :chat, context: context, config: Config.runtime(config)}
  end

  @spec handle_message_receive(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_receive(_event_type, event, consumers) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(&emit_message(&1, event))
    |> MapHelpers.collect_results()
  end

  @doc """
  Builds the channel ID of one thread on one mailbox.

  The root ID is the message ID of the first message Ankole saw in the thread.
  """
  @spec provider_conversation_id(String.t(), String.t()) :: String.t()
  def provider_conversation_id(address, root_message_id),
    do: channel_prefix(address) <> root_message_id

  @spec channel_prefix(String.t()) :: String.t()
  def channel_prefix(address), do: "email:#{address}:thread:"

  @doc false
  @spec normalize_message_receive(map(), map()) ::
          {:ok, map(), map()} | {:ignore, term()} | {:error, :invalid_email_event}
  def normalize_message_receive(
        %{"uid" => uid, "uidvalidity" => uidvalidity, "raw" => raw} = event,
        %{context: %AdapterContext{}, config: %Config.Runtime{} = config}
      )
      when is_integer(uid) and is_binary(raw) do
    headers_only? = event["headers_only"] == true

    with {:ok, message} <- decode(raw, headers_only?),
         :ok <- supported_sender(message, config) do
      provider_message_id = message.message_id || "uid:#{uidvalidity}:#{uid}"
      {channel_id, new_thread?} = resolve_channel(config.address, message, provider_message_id)
      participants = participants(message, config.address)
      explicit? = explicit?(message, config.address)
      {text, quoted_removed?} = visible_text(message, headers_only?, new_thread?, event["size"])
      attachments = pending_attachments(message, provider_message_id)

      if is_nil(text) and attachments == [] do
        {:ignore, :empty_message}
      else
        input = %{
          source_event_id: provider_message_id,
          provider_conversation_id: channel_id,
          provider_message_id: provider_message_id,
          reply_to_provider_message_id: List.first(message.in_reply_to),
          provider_thread_id: channel_id,
          channel: %{
            kind: if(participants == [message.from.address], do: :im_dm, else: :im_group),
            reply_mode: :entry,
            name: if(new_thread?, do: Message.base_subject(message.subject)),
            metadata:
              MapHelpers.compact_map(%{
                "provider" => "email",
                "mailbox" => config.address,
                "participants" => participants,
                "subject" => message.subject
              }),
            raw_payload: %{}
          },
          text: text,
          formatted_content: %{},
          attachments: attachments,
          mentions: [],
          structured_mention_prefixes: [],
          explicit: explicit?,
          author: author(message.from),
          metadata:
            MapHelpers.compact_map(%{
              "provider" => "email",
              "message_id" => message.message_id,
              "subject" => message.subject,
              "uid" => uid,
              "uidvalidity" => uidvalidity,
              "quoted_text_removed" => if(quoted_removed?, do: true),
              "size_limit_exceeded" => if(headers_only?, do: true),
              "unsupported_charsets" => nonempty(message.unsupported_charsets)
            }),
          raw_payload: header_payload(message),
          provider_time: message.date
        }

        {:ok, input, attachment_bytes(message, provider_message_id)}
      end
    end
  end

  def normalize_message_receive(_event, _consumer), do: {:error, :invalid_email_event}

  @doc "Header facts the adapter keeps on every mirrored entry so a reply can address the thread."
  @spec header_payload(Message.t()) :: map()
  def header_payload(%Message{} = message) do
    MapHelpers.compact_map(%{
      "message_id" => message.message_id,
      "in_reply_to" => nonempty(message.in_reply_to),
      "references" => nonempty(Enum.take(message.references, -@references_limit)),
      "from" => message.from && mailbox_payload(message.from),
      "reply_to" => nonempty(Enum.map(message.reply_to, &mailbox_payload/1)),
      "to" => nonempty(Enum.map(message.to, &mailbox_payload/1)),
      "cc" => nonempty(Enum.map(message.cc, &mailbox_payload/1)),
      "subject" => message.subject,
      "date" => message.date && DateTime.to_iso8601(message.date)
    })
  end

  defp emit_message(consumer, event) do
    case normalize_message_receive(event, consumer) do
      {:ok, input, bytes} -> emit_with_materialization(input, bytes, consumer)
      {:ignore, reason} -> {:ok, %{status: :ignored, reason: reason}}
      {:error, :invalid_email_event} -> {:ok, %{status: :ignored, reason: :invalid_message}}
    end
  end

  defp emit_with_materialization(input, bytes, consumer) do
    Observe.emit_entry_with_attachments(
      consumer.context.agent_uid,
      consumer.context.binding_name,
      input,
      &Attachments.materialize_attachments(&1, "email", fn attachment ->
        download_attachment(attachment, bytes)
      end)
    )
  end

  defp decode(raw, headers_only?) do
    {:ok, if(headers_only?, do: Message.decode_headers(raw), else: Message.decode(raw))}
  rescue
    exception ->
      Logging.warning(
        "email_adapter.inbound.decode_failed",
        "email message could not be decoded",
        %{reason: Exception.message(exception)}
      )

      {:ignore, :decode_failed}
  end

  defp supported_sender(%Message{from: nil}, _config), do: {:ignore, :missing_sender}

  defp supported_sender(%Message{} = message, config) do
    cond do
      message.from.address == config.address ->
        {:ignore, :own_message}

      message.auto_submitted ->
        {:ignore, :auto_submitted}

      true ->
        case Authentication.verify(
               config.sender_authentication,
               message.authentication_results,
               Address.domain(message.from.address)
             ) do
          :ok -> :ok
          {:error, reason} -> {:ignore, {:unauthenticated_sender, reason}}
        end
    end
  end

  # An existing thread wins over the message's own ID, so a reply to any
  # mirrored message, including one Ankole sent, joins that thread.
  defp resolve_channel(address, message, provider_message_id) do
    references = Enum.uniq(message.in_reply_to ++ message.references)

    case existing_channel(address, references) do
      nil -> {provider_conversation_id(address, provider_message_id), true}
      channel_id -> {channel_id, false}
    end
  end

  defp existing_channel(_address, []), do: nil

  defp existing_channel(address, references) do
    prefix = channel_prefix(address)

    Repo.one(
      from ref in ExternalMessageRef,
        join: conversation in Conversation,
        on: conversation.id == ref.conversation_id,
        where:
          ref.provider_message_id in ^references and
            fragment("starts_with(?, ?)", conversation.provider_conversation_id, ^prefix),
        order_by: [asc: ref.first_seen_at],
        limit: 1,
        select: conversation.provider_conversation_id
    )
  end

  defp participants(%Message{} = message, address) do
    ([message.from] ++ message.to ++ message.cc)
    |> Enum.map(& &1.address)
    |> Enum.reject(&(&1 == address))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp explicit?(%Message{} = message, address) do
    in_to? = Enum.any?(message.to, &(&1.address == address))
    in_cc? = Enum.any?(message.cc, &(&1.address == address))
    in_to? or not in_cc?
  end

  # The body stays at the start of the text so a leading control command is
  # still recognized; the subject lives in the channel name and metadata.
  # Quoted history is cut only when the message joined a mirrored thread, so
  # the first message Ankole sees keeps the earlier text it carries.
  defp visible_text(%Message{} = message, headers_only?, new_thread?, size) do
    cond do
      headers_only? ->
        {"[The message body of #{size} bytes exceeds the 25 MB limit and was not downloaded.]",
         false}

      is_binary(message.text) and not new_thread? and
          not ReplyText.forwarded_subject?(message.subject) ->
        ReplyText.strip_quoted(message.text)

      is_binary(message.text) ->
        {message.text, false}

      is_binary(message.subject) ->
        {"Subject: #{message.subject}", false}

      true ->
        {nil, false}
    end
  end

  defp pending_attachments(%Message{attachments: attachments}, provider_message_id) do
    Enum.map(attachments, fn attachment ->
      %{
        "provider" => "email",
        "provider_ref" => attachment_ref(provider_message_id, attachment.index),
        "source_message_id" => provider_message_id,
        "kind" => "file",
        "name" => attachment.name,
        "mimetype" => attachment.mime_type,
        "size" => attachment.size
      }
    end)
  end

  defp attachment_bytes(%Message{attachments: attachments}, provider_message_id) do
    Map.new(attachments, &{attachment_ref(provider_message_id, &1.index), &1.body})
  end

  defp attachment_ref(provider_message_id, index),
    do: "email:#{provider_message_id}:part:#{index}"

  defp download_attachment(%{"provider_ref" => ref}, bytes) do
    with body when is_binary(body) <- Map.get(bytes, ref, {:error, :attachment_bytes_missing}) do
      {:ok, %{body: body, filename: nil, content_type: nil, put: %{}}}
    end
  end

  defp download_attachment(_attachment, _bytes), do: {:error, :attachment_reference_missing}

  # The address is the subject id, not a contact field: an email sender is
  # admitted only through an `email` binding, never through the contact match
  # that an operator-entered profile email could satisfy.
  defp author(%{address: address, name: name}) do
    %{
      "id" => address,
      "platform_subject" => address,
      "provider" => "email",
      "display_name" => name || address,
      "metadata" => %{"provider" => "email"}
    }
  end

  defp mailbox_payload(%{address: address, name: name}),
    do: MapHelpers.compact_map(%{"address" => address, "name" => name})

  defp nonempty([]), do: nil
  defp nonempty(list), do: list
end
