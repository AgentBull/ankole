defmodule Ankole.Plugins.WhatsAppAdapter.Inbound do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.{Logging, Principals, Repo, SignalsGateway, WorkerFiles}
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.WhatsAppAdapter.{Client, Config, Presentation}
  alias Ankole.SignalsGateway.{ActorEvent, AdapterContext, Entry, Ingress, Projection}
  alias Ankole.SignalsGateway.ReplyActionToken

  @download_limit_bytes 25 * 1024 * 1024
  @media_types ["image", "video", "audio", "document", "sticker"]
  @message_types ["text", "location", "contacts", "button" | @media_types]
  @terminal_attachment_states ["complete", "provider_download_limit"]

  @spec chat_consumer(AdapterContext.t(), map()) :: map()
  def chat_consumer(%AdapterContext{} = context, config) when is_map(config) do
    %{kind: :chat, context: context, config: config}
  end

  @spec handle_message_receive(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_message_receive(_message_type, envelope, consumers) do
    dispatch_chat(consumers, &emit_message(&1, envelope))
  end

  @spec handle_card_action(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_card_action(_message_type, envelope, consumers) do
    dispatch_chat(consumers, &emit_action(&1, envelope))
  end

  @doc """
  Records the delivery states of messages Ankole sent.

  A status is not a gateway fact: Ankole already stores what it sent, and a
  status carries no new content. Only `failed` is worth an operator's attention,
  because the message never reached the user.
  """
  @spec handle_statuses(map(), map()) :: {:ok, map()}
  def handle_statuses(value, consumer) when is_map(value) do
    value
    |> MapHelpers.fetch_list("statuses")
    |> Enum.filter(&(is_map(&1) and &1["status"] == "failed"))
    |> Enum.each(fn status ->
      Logging.warning(
        "whatsapp_adapter.status.failed",
        "WhatsApp reported a failed delivery",
        %{
          binding: consumer.context.binding_name,
          message_id: MapHelpers.presence(status["id"]),
          error_codes: error_codes(status)
        }
      )
    end)

    {:ok, %{status: :recorded_statuses}}
  end

  @doc false
  @spec normalize_message_receive(map(), map()) ::
          {:ok, map()} | {:ignore, atom()} | {:error, term()}
  def normalize_message_receive(
        %{"value" => value, "message" => message},
        %{context: %AdapterContext{}} = consumer
      )
      when is_map(value) and is_map(message) do
    cond do
      MapHelpers.presence(message["group_id"]) != nil -> {:ignore, :group_message}
      message["type"] not in @message_types -> {:ignore, :unsupported_message_type}
      true -> normalize_supported_message(value, message, consumer)
    end
  end

  def normalize_message_receive(_envelope, _consumer), do: {:error, :invalid_whatsapp_event}

  defp normalize_supported_message(value, message, _consumer) do
    metadata = map(value, "metadata")

    with message_id when is_binary(message_id) <- MapHelpers.presence(message["id"]),
         wa_id when is_binary(wa_id) <- MapHelpers.presence(message["from"]),
         phone_number_id when is_binary(phone_number_id) <-
           MapHelpers.presence(metadata["phone_number_id"]),
         text <- message_text(message),
         attachments <- attachments(message),
         true <- material_message?(text, attachments) || {:ignore, :empty_message} do
      {:ok,
       %{
         source_event_id: message_id,
         signal_channel_id: Presentation.signal_channel_id(phone_number_id, wa_id),
         source_entry_id: message_id,
         reply_to_source_entry_id: MapHelpers.presence(get_in(message, ["context", "id"])),
         provider_thread_id: nil,
         channel: %{
           kind: :im_dm,
           reply_mode: :entry,
           name: nil,
           metadata:
             MapHelpers.compact_map(%{
               "provider" => "whatsapp",
               "phone_number_id" => phone_number_id,
               "wa_id" => wa_id,
               "display_phone_number" => MapHelpers.presence(metadata["display_phone_number"])
             }),
           raw_payload: metadata
         },
         text: text,
         formatted_content: %{},
         attachments: attachments,
         mentions: [],
         structured_mention_prefixes: [],
         explicit: true,
         author: author(value, wa_id),
         metadata:
           MapHelpers.compact_map(%{
             "provider" => "whatsapp",
             "phone_number_id" => phone_number_id,
             "wa_id" => wa_id,
             "message_type" => message["type"]
           }),
         raw_payload: message,
         provider_time: unix_seconds(message["timestamp"])
       }}
    else
      {:ignore, _reason} = ignored -> ignored
      _invalid -> {:error, :invalid_whatsapp_event}
    end
  end

  defp emit_message(consumer, envelope) do
    case normalize_message_receive(envelope, consumer) do
      {:ok, input} -> emit_with_materialization(input, consumer)
      {:ignore, reason} -> {:ok, %{status: :ignored, reason: reason}}
      {:error, :invalid_whatsapp_event} -> {:ok, %{status: :ignored, reason: :invalid_event}}
    end
  end

  # The pending observation is durable before the webhook returns 200; the
  # download runs after, so Meta does not time out and redeliver the change
  # while Ankole fetches a large file.
  defp emit_with_materialization(input, consumer) do
    {input, observed_at} = reuse_materialized_attachments(input, consumer)

    if materialization_required?(input.attachments) do
      pending = put_materialization_state(input, "pending", observed_at)

      case emit_entry(pending, consumer) do
        {:ok, %{signal_entry: %Entry{attachments: attachments}}} = result
        when is_list(attachments) ->
          start_materialization(input, attachments, consumer, observed_at)
          result

        {:ok, _held_or_ignored} = result ->
          result

        {:error, _reason} = error ->
          error
      end
    else
      emit_entry(input, consumer)
    end
  end

  # Meta redelivers a change that did not get a 200, and the redelivered message
  # names the same media. A result this Agent already holds stays, together with
  # the observation anchor of the first sighting. Everything else is fetched
  # again, including a download whose earlier task never finished: the adapter
  # has no proof that such a task is alive, and the gateway keeps a stored
  # readable path under its entry lock, so a second download that overlaps the
  # first cannot lose the file. A copy that another Agent downloaded does not
  # count; each Agent holds its own copy.
  defp reuse_materialized_attachments(%{attachments: []} = input, _consumer),
    do: {input, DateTime.utc_now(:microsecond)}

  defp reuse_materialized_attachments(input, consumer) do
    case Repo.get_by(Entry,
           signal_channel_id: input.signal_channel_id,
           source_entry_id: input.source_entry_id
         ) do
      %Entry{attachments: stored, metadata: stored_metadata}
      when is_list(stored) and stored != [] ->
        by_ref = Map.new(stored, &{&1["provider_ref"], &1})
        agent_uid = consumer.context.agent_uid

        attachments =
          Enum.map(input.attachments, fn attachment ->
            case Map.get(by_ref, attachment["provider_ref"]) do
              %{"materialization_state" => "complete"} = kept ->
                if Projection.materialized_attachment?(agent_uid, kept),
                  do: kept,
                  else: attachment

              %{"materialization_state" => "provider_download_limit"} = kept ->
                kept

              _missing_failed_or_unfinished ->
                attachment
            end
          end)

        observation = stored_metadata["attachment_materialization"]

        metadata =
          if is_map(observation),
            do: Map.put(input.metadata, "attachment_materialization", observation),
            else: input.metadata

        {%{input | attachments: attachments, metadata: metadata}, observed_at(observation)}

      _no_mirror ->
        {input, DateTime.utc_now(:microsecond)}
    end
  rescue
    exception ->
      Logging.warning(
        "whatsapp_adapter.attachment.reuse_lookup_failed",
        "WhatsApp attachment reuse lookup failed",
        %{source_entry_id: input.source_entry_id, reason: Exception.message(exception)}
      )

      {input, DateTime.utc_now(:microsecond)}
  end

  # The anchor stays the first sighting, so a fetched-again attachment does not
  # move the batch window of an event the gateway already accepted.
  defp observed_at(%{"observed_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, observed_at, _offset} -> observed_at
      _invalid -> DateTime.utc_now(:microsecond)
    end
  end

  defp observed_at(_observation), do: DateTime.utc_now(:microsecond)

  # The download never runs in the webhook process: Meta waits for the answer
  # and redelivers a slow one. If the task cannot start, the webhook fails
  # instead, Meta delivers the change again, and the pending observation that is
  # already durable makes that redelivery fetch the file.
  defp start_materialization(input, attachments, consumer, observed_at) do
    {:ok, _pid} =
      Task.Supervisor.start_child(
        Ankole.Plugins.WhatsAppAdapter.MaterializationTaskSupervisor,
        fn -> materialize_and_emit(input, attachments, consumer, observed_at) end
      )

    :ok
  end

  defp materialize_and_emit(input, attachments, consumer, observed_at) do
    attachments = materialize_attachments(attachments, consumer)

    input
    |> Map.put(:attachments, attachments)
    |> put_materialization_state(materialization_state(attachments), observed_at)
    |> emit_entry(consumer)
    |> case do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "whatsapp_adapter.attachment.materialization_emit_failed",
          "WhatsApp attachment observation could not be stored",
          %{binding: consumer.context.binding_name, reason: inspect(reason)}
        )

        :ok
    end
  end

  defp emit_entry(input, consumer) do
    Ingress.emit_entry(consumer.context.agent_uid, consumer.context.binding_name, input)
  end

  # An interactive reply names the message that carried the buttons, so the
  # token binds to that provider entry as well as to the ActorEvent, the
  # binding, and the action fingerprint. A stale token produces no visible
  # change, which is the right outcome for an action the reply already replaced.
  defp emit_action(consumer, %{"value" => value, "message" => message})
       when is_map(value) and is_map(message) do
    metadata = map(value, "metadata")

    with message_id when is_binary(message_id) <- MapHelpers.presence(message["id"]),
         wa_id when is_binary(wa_id) <- MapHelpers.presence(message["from"]),
         phone_number_id when is_binary(phone_number_id) <-
           MapHelpers.presence(metadata["phone_number_id"]),
         surface_entry_id when is_binary(surface_entry_id) <-
           MapHelpers.presence(get_in(message, ["context", "id"])),
         token when is_binary(token) <- interactive_token(message),
         {:ok, principal} <- Principals.resolve_platform_subject("whatsapp", wa_id),
         {:ok, action_value} <-
           ReplyActionToken.resolve(
             token,
             consumer.context.agent_uid,
             consumer.context.binding_name,
             nil,
             prefix: "wa1"
           ),
         true <- reply_surface?(action_value, surface_entry_id),
         signal_channel_id <- Presentation.signal_channel_id(phone_number_id, wa_id),
         :ok <- record_interactive_reply_time(signal_channel_id, message),
         {:ok, _action_result} = result <-
           Ingress.emit_action(consumer.context.agent_uid, consumer.context.binding_name, %{
             source_event_id: message_id,
             action_id: message_id,
             signal_channel_id: signal_channel_id,
             source_entry_id: surface_entry_id,
             provider_thread_id: nil,
             actor_event_type: "signal.action.invoked",
             action: %{
               "name" => "whatsapp_interactive_reply",
               "value" => action_value,
               "operator_id" => wa_id,
               "operator_principal_uid" => principal.uid,
               "source_entry_id" => surface_entry_id
             },
             raw_payload: %{
               "message_id" => message_id,
               "interactive" => message["interactive"]
             }
           }) do
      result
    else
      false ->
        {:ok, %{status: :ignored_stale_action}}

      {:error, :not_found} ->
        {:ok, %{status: :ignored_unmapped_operator}}

      {:error, reason}
      when reason in [
             :invalid_callback_token,
             :callback_source_not_found,
             :callback_binding_mismatch,
             :callback_message_mismatch,
             :invalid_callback_action
           ] ->
        {:ok, %{status: :ignored_stale_action}}

      {:error, _reason} = error ->
        error

      _invalid ->
        {:ok, %{status: :ignored_invalid_interactive}}
    end
  end

  defp emit_action(_consumer, _envelope), do: {:ok, %{status: :ignored_invalid_interactive}}

  # Meta re-opens the customer service window on a button tap, and the outbox
  # pre-check needs the time WhatsApp reports for it, not the time Ankole
  # accepted the callback: Meta redelivers an undelivered webhook for up to
  # seven days. The channel fact carries that provider time, and the gateway
  # applies the update under the channel row lock, so the newest time wins over
  # a concurrent or redelivered older tap.
  #
  # The write runs for every authenticated tap whose token resolves, before the
  # gateway decides accepted, duplicate, or stale, which makes the fact
  # idempotent under redelivery. A message with no parsable timestamp writes
  # nothing and therefore cannot re-open the window.
  defp record_interactive_reply_time(signal_channel_id, message) do
    case unix_seconds(message["timestamp"]) do
      %DateTime{} = tapped_at -> put_interactive_reply_time(signal_channel_id, tapped_at)
      nil -> :ok
    end
  end

  defp put_interactive_reply_time(signal_channel_id, tapped_at) do
    signal_channel_id
    |> SignalsGateway.update_channel_metadata(&newest_interactive_reply(&1, tapped_at))
    |> case do
      {:ok, _channel} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "whatsapp_adapter.action.reply_time_not_recorded",
          "WhatsApp interactive reply time could not be recorded",
          %{signal_channel_id: signal_channel_id, reason: inspect(reason)}
        )

        :ok
    end
  end

  defp newest_interactive_reply(metadata, tapped_at) do
    case stored_reply_time(metadata) do
      %DateTime{} = stored ->
        if DateTime.compare(tapped_at, stored) == :gt,
          do: Map.put(metadata, "last_interactive_reply_at", DateTime.to_iso8601(tapped_at)),
          else: metadata

      nil ->
        Map.put(metadata, "last_interactive_reply_at", DateTime.to_iso8601(tapped_at))
    end
  end

  defp stored_reply_time(%{"last_interactive_reply_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _invalid -> nil
    end
  end

  defp stored_reply_time(_metadata), do: nil

  # The message that carried the buttons is the ActorEvent's reply surface, and
  # an interactive reply names it in `context.id`. A callback that names another
  # message is refused even when its token is otherwise valid, so a token copied
  # out of one card cannot answer from anywhere else.
  defp reply_surface?(%{"sourceActorEventId" => actor_event_id}, surface_entry_id)
       when is_binary(actor_event_id) do
    match?(
      %ActorEvent{reply_preview_source_entry_id: ^surface_entry_id},
      Repo.get(ActorEvent, actor_event_id)
    )
  end

  defp reply_surface?(_action_value, _surface_entry_id), do: false

  defp interactive_token(message) do
    interactive = map(message, "interactive")

    case interactive["type"] do
      "button_reply" -> MapHelpers.presence(get_in(interactive, ["button_reply", "id"]))
      "list_reply" -> MapHelpers.presence(get_in(interactive, ["list_reply", "id"]))
      _other -> nil
    end
  end

  defp message_text(%{"type" => "text"} = message),
    do: MapHelpers.presence(get_in(message, ["text", "body"]))

  defp message_text(%{"type" => "button"} = message),
    do: MapHelpers.presence(get_in(message, ["button", "text"]))

  defp message_text(%{"type" => "location"} = message) do
    location = map(message, "location")

    [location["name"], location["address"]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.concat(["#{location["latitude"]}, #{location["longitude"]}"])
    |> Enum.join(" ")
    |> then(&"Location: #{&1}")
  end

  defp message_text(%{"type" => "contacts"} = message) do
    names =
      message
      |> MapHelpers.fetch_list("contacts")
      |> Enum.map(&contact_name/1)
      |> Enum.filter(&is_binary/1)

    case names do
      [] -> "Contacts: shared"
      names -> "Contacts: " <> Enum.join(names, ", ")
    end
  end

  defp message_text(%{"type" => type} = message) when type in @media_types,
    do: MapHelpers.presence(get_in(message, [type, "caption"]))

  defp message_text(_message), do: nil

  defp contact_name(contact) when is_map(contact) do
    MapHelpers.presence(get_in(contact, ["name", "formatted_name"]))
  end

  defp contact_name(_contact), do: nil

  defp attachments(%{"type" => type} = message) when type in @media_types do
    media = map(message, type)

    case MapHelpers.presence(media["id"]) do
      nil ->
        []

      media_id ->
        %{
          "provider" => "whatsapp",
          "provider_ref" => "whatsapp:media:#{media_id}",
          "provider_file_id" => media_id,
          "kind" => type,
          "name" => MapHelpers.presence(media["filename"]) || "#{type}-#{media_id}",
          "mimetype" => mime_type(media)
        }
        |> MapHelpers.compact_map()
        |> List.wrap()
    end
  end

  defp attachments(_message), do: []

  defp mime_type(media) do
    case MapHelpers.presence(media["mime_type"]) do
      nil -> nil
      value -> value |> String.split(";") |> List.first() |> String.trim()
    end
  end

  defp restricted_attachment(attachment) do
    attachment
    |> Map.put("materialization_state", "provider_download_limit")
    |> Map.put("restriction", "Ankole downloads WhatsApp content up to 25 MB.")
  end

  defp materialization_required?(attachments) do
    Enum.any?(attachments, fn attachment ->
      is_binary(attachment["provider_file_id"]) and is_nil(attachment["materialization_state"])
    end)
  end

  defp materialize_attachments(attachments, consumer) do
    client = Config.client(consumer.config)
    Enum.map(attachments, &materialize_attachment(&1, client, consumer.context.agent_uid))
  end

  defp materialize_attachment(
         %{"materialization_state" => _state} = attachment,
         _client,
         _agent_uid
       ),
       do: attachment

  defp materialize_attachment(%{"provider_file_id" => media_id} = attachment, client, agent_uid) do
    with {:ok, media} <- Client.media(client, media_id),
         :ok <- within_download_limit(media["file_size"]),
         {:ok, download} <- Client.download(client, media["url"], @download_limit_bytes),
         content_type <- download.content_type || attachment["mimetype"],
         name <- materialized_name(attachment, content_type),
         relative <- materialized_relative_path(attachment, name),
         lane_path <- Ankole.AgentHomePaths.user_files_lane_path(agent_uid, relative),
         {:ok, result} <- WorkerFiles.put("user_files", lane_path, download.body) do
      attachment
      |> Map.put("materialization_state", "complete")
      |> Map.put("name", name)
      |> Map.put(
        "agent_computer_path",
        Path.join(Ankole.AgentHomePaths.user_files(agent_uid), relative)
      )
      |> Map.put("user_files_relative_path", relative)
      |> MapHelpers.put_present("mimetype", content_type)
      |> MapHelpers.put_present("xxh3_128", result["xxh3_128"])
      |> MapHelpers.put_present("size", result["size"])
    else
      {:error, :provider_download_limit} -> restricted_attachment(attachment)
      reason -> materialization_failed(attachment, reason)
    end
  rescue
    exception -> materialization_failed(attachment, exception)
  end

  defp materialize_attachment(attachment, _client, _agent_uid), do: attachment

  defp within_download_limit(size) when is_integer(size) and size > @download_limit_bytes,
    do: {:error, :provider_download_limit}

  defp within_download_limit(size) when is_binary(size) do
    case Integer.parse(size) do
      {value, ""} -> within_download_limit(value)
      _invalid -> :ok
    end
  end

  defp within_download_limit(_size), do: :ok

  defp materialization_failed(attachment, reason) do
    Logging.warning(
      "whatsapp_adapter.attachment.materialization_skipped",
      "WhatsApp attachment materialization skipped",
      %{provider_ref: attachment["provider_ref"], reason: safe_reason(reason)}
    )

    Map.put(attachment, "materialization_state", "failed")
  end

  # A document arrives with the sender's own file name; every other media kind
  # has only a generated name, so the content type supplies the extension.
  defp materialized_name(%{"kind" => "document"} = attachment, _content_type),
    do: attachment["name"]

  defp materialized_name(attachment, content_type) do
    case extension(content_type) do
      nil -> attachment["name"]
      extension -> attachment["name"] <> "." <> extension
    end
  end

  defp extension("image/jpeg"), do: "jpg"
  defp extension("image/png"), do: "png"
  defp extension("image/webp"), do: "webp"
  defp extension("video/mp4"), do: "mp4"
  defp extension("video/3gpp"), do: "3gp"
  defp extension("audio/aac"), do: "aac"
  defp extension("audio/mp4"), do: "m4a"
  defp extension("audio/mpeg"), do: "mp3"
  defp extension("audio/amr"), do: "amr"
  defp extension("audio/ogg"), do: "ogg"
  defp extension(_content_type), do: nil

  defp materialized_relative_path(attachment, name) do
    Path.join([
      "inbox",
      Integer.to_string(attachment["attachment_id"]),
      WorkerFiles.sanitize_path_segment(name || "attachment")
    ])
  end

  defp put_materialization_state(input, state, observed_at) do
    %{
      input
      | metadata: Ingress.put_attachment_materialization(input.metadata, state, observed_at)
    }
  end

  defp materialization_state(attachments) do
    if Enum.all?(attachments, &(&1["materialization_state"] in @terminal_attachment_states)),
      do: "complete",
      else: "failed"
  end

  # The `wa_id` is the sender's phone number, which Meta verified before it
  # issued the account. It therefore feeds the Principal contact match like the
  # directory mobile number of an enterprise IM adapter.
  defp author(value, wa_id) do
    %{
      "id" => wa_id,
      "platform_subject" => wa_id,
      "provider" => "whatsapp",
      "metadata" => %{"provider" => "whatsapp"}
    }
    |> MapHelpers.put_present("display_name", contact_display_name(value, wa_id))
    |> MapHelpers.put_present("mobile", normalized_mobile(wa_id))
  end

  defp contact_display_name(value, wa_id) do
    value
    |> MapHelpers.fetch_list("contacts")
    |> Enum.find_value(fn contact ->
      if is_map(contact) and contact["wa_id"] == wa_id,
        do: MapHelpers.presence(get_in(contact, ["profile", "name"]))
    end)
  end

  defp normalized_mobile(wa_id) do
    case NativeKernel.phone_normalize_e164("+" <> wa_id) do
      normalized when is_binary(normalized) -> normalized
      _invalid -> nil
    end
  end

  defp error_codes(status) do
    status
    |> MapHelpers.fetch_list("errors")
    |> Enum.map(fn error -> is_map(error) && error["code"] end)
    |> Enum.filter(&is_integer/1)
  end

  defp dispatch_chat(consumers, fun) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(fun)
    |> MapHelpers.collect_results()
  end

  defp material_message?(text, attachments), do: is_binary(text) or attachments != []

  defp unix_seconds(value) when is_integer(value) do
    case DateTime.from_unix(value, :second) do
      {:ok, datetime} -> datetime
      _invalid -> nil
    end
  end

  defp unix_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> unix_seconds(seconds)
      _invalid -> nil
    end
  end

  defp unix_seconds(_value), do: nil

  defp map(container, key) do
    case Map.get(container, key) do
      %{} = value -> value
      _missing -> %{}
    end
  end

  defp safe_reason(%Client.Error{} = error),
    do: inspect(%{kind: error.kind, status: error.status, code: error.code})

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason({:error, reason}), do: safe_reason(reason)
  defp safe_reason(_reason), do: "whatsapp_content_unavailable"
end
