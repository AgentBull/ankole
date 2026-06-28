defmodule Ankole.SignalsGateway.ActorInputEnvelope do
  @moduledoc false

  alias Ankole.Actors
  alias Ankole.SignalsGateway.AmbientRecall
  alias Ankole.SignalsGateway.SignalChannel
  alias Ankole.SignalsGateway.SignalEntry

  import Ankole.SignalsGateway.Utils,
    only: [
      datetime_iso8601: 1,
      signal_session_id: 1
    ]

  def append_actor_input(binding, fact, type, channel, entry, now) do
    session_id = Map.get(fact, :session_id) || signal_session_id(fact.signal_channel_id)

    available_at =
      case Map.get(fact, :available_at) do
        %DateTime{} = available_at -> available_at
        _other -> now
      end

    attrs = %{
      agent_uid: binding.agent_uid,
      binding_name: binding.name,
      session_id: session_id,
      ingress_event_id: fact.ingress_event_id,
      signal_channel_id: fact.signal_channel_id,
      provider_thread_id: fact.provider_thread_id,
      provider_entry_id: fact.provider_entry_id,
      type: type,
      available_at: available_at,
      sender_key: Map.get(fact, :sender_key)
    }

    payload =
      binding
      |> actor_envelope(fact, type, channel, entry, now)
      |> maybe_ambient_batch_payload(type, attrs, fact, now)

    attrs = Map.put(attrs, :payload, payload)

    Actors.append_actor_input(attrs)
  end

  defp maybe_ambient_batch_payload(
         payload,
         "im.message.may_intervene",
         attrs,
         %{finalized_batch_id: _batch_id, batch_entries: entries},
         now
       )
       when is_list(entries) do
    refresh_ambient_batch_payload(payload, attrs, entries, now)
  end

  defp maybe_ambient_batch_payload(
         payload,
         _type,
         _attrs,
         %{finalized_batch_id: _batch_id},
         _now
       ),
       do: payload

  defp maybe_ambient_batch_payload(payload, _type, _attrs, _fact, _now), do: payload

  defp refresh_ambient_batch_payload(payload, attrs, entries, now) do
    payload
    |> put_in(["data", "entry"], batch_entry_summary(entries))
    |> put_in(["data", "entries"], entries)
    |> put_in(["data", "observed_messages"], AmbientRecall.observed_messages(attrs, entries))
    |> put_in(["data", "ambient_batch"], %{
      "size" => length(entries),
      "first_provider_entry_id" => entries |> List.first() |> Map.get("provider_entry_id"),
      "last_provider_entry_id" => entries |> List.last() |> Map.get("provider_entry_id"),
      "updated_at" => DateTime.to_iso8601(now)
    })
  end

  defp batch_entry_summary(entries) do
    text =
      entries
      |> Enum.map(& &1["text"])
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")

    entries
    |> List.last()
    |> Kernel.||(%{})
    |> Map.put("text", text)
  end

  # The payload stored on the ActorInput is a CloudEvents 1.0 envelope so the
  # worker sees a uniform shape regardless of which provider/source produced it.
  # `data` is assembled from whichever fact fields are present (nils dropped);
  # `source`/`subject` encode provenance (see envelope_source/2, envelope_subject/1).
  defp actor_envelope(binding, fact, type, channel, entry, now) do
    data =
      %{
        "session" => %{
          "agent_uid" => binding.agent_uid,
          "session_id" => Map.get(fact, :session_id) || signal_session_id(fact.signal_channel_id),
          "binding_name" => binding.name
        },
        "channel" => channel_payload(channel),
        "entry" => entry_payload(entry || fact, fact),
        "entries" => Map.get(fact, :batch_entries),
        "mentions" => Map.get(fact, :mentions),
        "raw" => Map.get(fact, :raw_payload),
        "command" => Map.get(fact, :command_payload),
        "action" => Map.get(fact, :action),
        "internal" => Map.get(fact, :internal),
        "lifecycle" => lifecycle_payload(fact)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      "specversion" => "1.0",
      "id" => fact.ingress_event_id,
      "source" => envelope_source(binding, fact),
      "subject" => envelope_subject(fact),
      "time" => DateTime.to_iso8601(now),
      "type" => type,
      "data" => data
    }
  end

  defp channel_payload(nil), do: nil

  defp channel_payload(%SignalChannel{} = channel) do
    %{
      "id" => channel.id,
      "kind" => Atom.to_string(channel.kind),
      "reply_mode" => Atom.to_string(channel.reply_mode),
      "name" => channel.name,
      "title" => channel.title,
      "visibility" => channel.visibility
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

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

  defp entry_payload(%SignalEntry{} = entry, fact) do
    %{
      "signal_channel_id" => entry.signal_channel_id,
      "provider_entry_id" => entry.provider_entry_id,
      "provider_thread_id" => Map.get(fact, :provider_thread_id),
      "text" => entry.text,
      "attachments" => entry.attachments,
      "links" => entry.links,
      "author" => entry.author,
      "document_id" => entry.document_id,
      "provider_time" => datetime_iso8601(entry.provider_time)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp entry_payload(fact, _fact_context) when is_map(fact) do
    %{
      "signal_channel_id" => Map.get(fact, :signal_channel_id),
      "provider_entry_id" => Map.get(fact, :provider_entry_id),
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

  defp envelope_source(binding, %{signal_channel_id: nil, session_id: session_id}) do
    "internal://#{binding.name}/#{session_id}"
  end

  defp envelope_source(binding, fact) do
    "signal://#{binding.adapter}/#{URI.encode_www_form(fact.signal_channel_id)}"
  end

  defp envelope_subject(%{action_id: action_id}) when is_binary(action_id),
    do: "signal_actions:#{action_id}"

  defp envelope_subject(%{timer_id: timer_id}) when is_binary(timer_id),
    do: "timers:#{timer_id}"

  defp envelope_subject(%{internal_subject: subject}) when is_binary(subject), do: subject

  defp envelope_subject(%{provider_entry_id: provider_entry_id})
       when is_binary(provider_entry_id), do: "signal_entries:#{provider_entry_id}"

  defp envelope_subject(_fact), do: nil
end
