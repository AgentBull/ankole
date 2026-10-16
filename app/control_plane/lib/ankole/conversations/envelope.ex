defmodule Ankole.Conversations.Envelope do
  import Ankole.Attrs, only: [datetime_iso8601: 1]
  @moduledoc false

  alias Ankole.Signals
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Context
  alias Ankole.Conversations.{External, ExternalMessageRef, Message}
  alias Ankole.Conversations.Delivery.Reference

  @ambient_execution_ttl_seconds 5 * 60

  def accept(repo, binding, fact, type, channel, entry, now) do
    fact = Reference.enrich(repo, fact)

    session_id =
      Map.get(fact, :session_id) || Ankole.Sessions.Key.conversation(fact.conversation_id)

    available_at =
      case Map.get(fact, :available_at) do
        %DateTime{} = available_at -> available_at
        _other -> now
      end

    attrs = %{
      source_work: event_authorization(repo, fact, type),
      agent_uid: binding.agent_uid,
      binding_name: binding.name,
      session_id: session_id,
      source_event_id: fact.source_event_id,
      conversation_id: fact.conversation_id,
      provider_thread_id: fact.provider_thread_id,
      provider_message_id: fact.provider_message_id,
      type: type,
      available_at: available_at,
      sender_key: Map.get(fact, :sender_key)
    }

    payload =
      binding
      |> im_envelope(fact, type, channel, entry, now)
      |> maybe_ambient_batch_payload(repo, type, attrs, fact, channel, now)
      |> Ankole.Conversations.Attachments.scope_payload(fact.conversation_id)

    message_ids = current_message_ids(repo, fact, entry)
    message_id = current_message_id(entry) || List.last(message_ids)

    Signals.accept_in_tx(repo, %{
      producer: :kernel,
      source: payload["source"],
      id: fact.source_event_id,
      type: type,
      subject: payload["subject"] || session_id,
      time: now,
      data:
        payload["data"]
        |> Map.put("conversation_id", fact.conversation_id)
        |> Map.put("message_ids", message_ids)
        |> Map.put("message_id", message_id)
        |> Map.put("text", Map.get(fact, :text)),
      message_id: message_id,
      target: %{agent_uid: binding.agent_uid, session_id: session_id},
      sender: Map.get(fact, :sender_key),
      authorization: attrs.source_work,
      available_at: available_at,
      reply_route: %{
        binding_name: binding.name,
        conversation_id: fact.conversation_id,
        provider_thread_id: fact.provider_thread_id,
        provider_message_id: fact.provider_message_id
      }
    })
  end

  defp maybe_ambient_batch_payload(
         payload,
         repo,
         "im.message.may_intervene",
         attrs,
         %{finalized_batch_id: _batch_id, batch_entries: entries},
         channel,
         now
       )
       when is_list(entries) do
    refresh_ambient_batch_payload(payload, repo, attrs, entries, channel, now)
  end

  defp maybe_ambient_batch_payload(
         payload,
         _repo,
         _type,
         _attrs,
         %{finalized_batch_id: _batch_id},
         _channel,
         _now
       ),
       do: payload

  defp maybe_ambient_batch_payload(payload, _repo, _type, _attrs, _fact, _channel, _now),
    do: payload

  defp refresh_ambient_batch_payload(payload, repo, attrs, entries, _channel, now) do
    judged_until =
      Ankole.Sessions.AmbientCuration.judged_until(attrs.agent_uid, attrs.conversation_id, repo)

    observed_messages = Context.ambient_delta_messages(attrs, entries, judged_until)
    backdrop_messages = Context.ambient_backdrop_messages(attrs, judged_until)
    unreplied_messages = Context.unreplied_messages(attrs, entries)
    scene_fingerprint = Context.ambient_scene_fingerprint(repo, attrs.conversation_id)

    payload
    |> put_in(["data", "entry"], batch_entry_summary(entries))
    |> put_in(["data", "entries"], entries)
    |> put_in(["data", "observed_messages"], observed_messages)
    |> put_in(["data", "backdrop_messages"], backdrop_messages)
    |> put_in(["data", "unreplied_messages"], unreplied_messages)
    |> put_in(["data", "ambient_batch"], %{
      "size" => length(entries),
      "first_provider_message_id" => entries |> List.first() |> Map.get("provider_message_id"),
      "last_provider_message_id" => entries |> List.last() |> Map.get("provider_message_id"),
      "scene_fingerprint" => scene_fingerprint,
      "as_of" => DateTime.to_iso8601(now),
      "expires_at" =>
        now |> DateTime.add(@ambient_execution_ttl_seconds, :second) |> DateTime.to_iso8601()
    })
  end

  defp batch_entry_summary(entries) do
    text =
      entries
      |> Context.batch_observed_messages()
      |> Enum.map(&observed_message_line/1)
      |> Enum.join("\n")

    entries
    |> List.last()
    |> Kernel.||(%{})
    |> Map.put("text", text)
  end

  defp observed_message_line(%{"text" => text} = message) when is_binary(text) do
    label =
      [message["sent_at"], message["speaker"]]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join(" ")

    case label do
      "" -> text
      label -> "[#{label}] #{text}"
    end
  end

  defp observed_message_line(_message), do: nil

  # Assemble the IM facts before Signals stores the canonical event fields.
  defp im_envelope(binding, fact, type, channel, entry, now) do
    data =
      %{
        "session" => %{
          "agent_uid" => binding.agent_uid,
          "session_id" =>
            Map.get(fact, :session_id) || Ankole.Sessions.Key.conversation(fact.conversation_id),
          "binding_name" => binding.name
        },
        "channel" => channel_payload(channel, binding),
        "entry" => entry_payload(entry || fact, fact),
        "entries" => Map.get(fact, :batch_entries),
        "mentions" => Map.get(fact, :mentions),
        "raw" => Map.get(fact, :raw_payload),
        "command" => Map.get(fact, :command_payload),
        "action" => Map.get(fact, :action),
        "lifecycle" => lifecycle_payload(fact)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      "specversion" => "1.0",
      "id" => fact.source_event_id,
      "source" => envelope_source(binding, fact),
      "subject" => envelope_subject(fact),
      "time" => DateTime.to_iso8601(now),
      "type" => type,
      "data" => data
    }
  end

  defp channel_payload(nil, _binding), do: nil

  defp channel_payload(%Conversation{} = channel, binding) do
    %{
      "id" => channel.id,
      "kind" => Atom.to_string(channel.external_kind),
      "reply_mode" => Atom.to_string(channel.reply_mode),
      "name" => channel.title,
      "visibility" => channel.visibility,
      "standing_orders" => active_standing_orders(channel, binding)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Standing orders drive behavior only where ambient intervention is allowed;
  # on other bindings the stored text stays inert and invisible to the model.
  defp active_standing_orders(%Conversation{} = channel, %{
         unaddressed_group_message_policy: :may_intervene
       }),
       do: channel.ambient_standing_orders

  defp active_standing_orders(_channel, _binding), do: nil

  defp lifecycle_payload(%{lifecycle_kind: lifecycle_kind} = fact)
       when not is_nil(lifecycle_kind) do
    %{
      "kind" => Atom.to_string(lifecycle_kind),
      "provider_kind" => Map.get(fact, :provider_lifecycle_kind)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp lifecycle_payload(_fact), do: nil

  defp entry_payload(
         %{message: %Message{} = message, external_ref: %ExternalMessageRef{} = ref},
         fact
       ) do
    %{
      "message_id" => message.id,
      "conversation_id" => message.conversation_id,
      "provider_message_id" => ref.provider_message_id,
      "reply_to_message_id" => message.reply_to_message_id,
      "reply_to_provider_message_id" => ref.reply_to_provider_message_id,
      "reply_to" => Map.get(fact, :reply_to),
      "provider_thread_id" => ref.provider_thread_id,
      "text" => Map.get(fact, :text) || message.text,
      "attachments" => Map.get(fact, :attachments) || message.attachments,
      "links" => Map.get(fact, :links) || message.links,
      "author" => ref.author,
      "provider_time" => datetime_iso8601(ref.provider_time)
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp entry_payload(fact, _fact_context) when is_map(fact) do
    %{
      "conversation_id" => Map.get(fact, :conversation_id),
      "provider_message_id" => Map.get(fact, :provider_message_id),
      "reply_to_provider_message_id" => Map.get(fact, :reply_to_provider_message_id),
      "reply_to" => Map.get(fact, :reply_to),
      "provider_thread_id" => Map.get(fact, :provider_thread_id),
      "text" => Map.get(fact, :text),
      "attachments" => Map.get(fact, :attachments),
      "links" => Map.get(fact, :links),
      "author" => Map.get(fact, :author),
      "provider_time" => datetime_iso8601(Map.get(fact, :provider_time))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp current_message_id(%{message: %Message{id: id}}), do: id
  defp current_message_id(_), do: nil

  defp current_message_ids(repo, fact, entry) do
    case Map.get(fact, :batch_entries) do
      entries when is_list(entries) ->
        Enum.flat_map(entries, fn entry ->
          case Map.get(entry, "message_id") do
            id when is_binary(id) ->
              [id]

            _ ->
              case External.get_message(repo, fact.conversation_id, entry["provider_message_id"]) do
                %{message: %{id: id}} -> [id]
                _ -> []
              end
          end
        end)
        |> Enum.uniq()

      _ ->
        List.wrap(current_message_id(entry))
    end
  end

  defp envelope_source(binding, fact) do
    "signal://#{binding.adapter}/#{URI.encode_www_form(fact.provider_conversation_id)}"
  end

  defp envelope_subject(%{action_id: action_id}) when is_binary(action_id),
    do: "signal_actions:#{action_id}"

  defp envelope_subject(%{provider_message_id: provider_message_id})
       when is_binary(provider_message_id), do: "provider-message:#{provider_message_id}"

  defp envelope_subject(_fact), do: nil

  defp event_authorization(_repo, _fact, "im.message.may_intervene"),
    do: Ankole.Principals.WorkAccess.service()

  defp event_authorization(_repo, _fact, "conversation.message.removed"),
    do: Ankole.Principals.WorkAccess.service()

  defp event_authorization(repo, fact, _type) do
    if Map.has_key?(fact, :finalized_batch_id),
      do: Ankole.Principals.WorkAccess.from_observation(repo, fact.author),
      else: Ankole.Principals.WorkAccess.from_sender(repo, Map.get(fact, :sender_key))
  end
end
