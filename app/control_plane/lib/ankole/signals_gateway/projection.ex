defmodule Ankole.SignalsGateway.Projection do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.SignalChannel
  alias Ankole.SignalsGateway.SignalEntry

  import Ankole.SignalsGateway.Utils, only: [thread_key: 1]

  @tombstone_ttl_seconds 24 * 60 * 60

  def maybe_upsert_channel(_repo, %{signal_channel_id: nil}, _now), do: {:ok, nil}
  def maybe_upsert_channel(repo, fact, now), do: upsert_channel(repo, fact, now)

  def upsert_channel(repo, fact, now) do
    attrs = %{
      id: fact.signal_channel_id,
      kind: fact.channel_kind,
      reply_mode: fact.reply_mode,
      name: fact.channel_name,
      title: fact.channel_title,
      visibility: fact.channel_visibility,
      metadata: fact.channel_metadata,
      raw_payload: fact.channel_raw_payload,
      first_seen_at: now,
      last_seen_at: now
    }

    case repo.get(SignalChannel, fact.signal_channel_id) do
      %SignalChannel{} = channel ->
        channel
        |> SignalChannel.changeset(merge_channel_attrs(channel, attrs))
        |> repo.update()

      nil ->
        %SignalChannel{}
        |> SignalChannel.changeset(attrs)
        |> repo.insert(on_conflict: :nothing, conflict_target: :id, returning: true)
        |> case do
          {:ok, %SignalChannel{id: id} = channel} when is_binary(id) ->
            {:ok, channel}

          {:ok, %SignalChannel{id: nil}} ->
            update_existing_channel(repo, fact.signal_channel_id, attrs)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp update_existing_channel(repo, signal_channel_id, attrs) do
    case repo.get(SignalChannel, signal_channel_id) do
      %SignalChannel{} = channel ->
        channel
        |> SignalChannel.changeset(merge_channel_attrs(channel, attrs))
        |> repo.update()

      nil ->
        {:error, :signal_channel_conflict_not_visible}
    end
  end

  # Different providers send different subsets of channel detail per event, so a
  # later sparse event must not erase richer data from an earlier one. The merge
  # rule is "don't overwrite with nothing": a sparse enum (:unknown/:none), a nil
  # text field, or an empty map all keep the previously stored value.
  # `first_seen_at` is always preserved since it records the first observation.
  defp merge_channel_attrs(%SignalChannel{} = channel, attrs) do
    %{
      attrs
      | kind: preserve_enum(attrs.kind, :unknown, channel.kind),
        reply_mode: preserve_enum(attrs.reply_mode, :none, channel.reply_mode),
        name: attrs.name || channel.name,
        title: attrs.title || channel.title,
        visibility: attrs.visibility || channel.visibility,
        metadata: preserve_empty_map(attrs.metadata, channel.metadata),
        raw_payload: preserve_empty_map(attrs.raw_payload, channel.raw_payload),
        first_seen_at: channel.first_seen_at
    }
  end

  # `sparse_value` is the enum's "no info" member (:unknown / :none); receiving it
  # means the event carried no channel kind / reply mode, so keep what we had.
  defp preserve_enum(incoming, sparse_value, existing) when incoming == sparse_value, do: existing
  defp preserve_enum(incoming, _sparse_value, _existing), do: incoming

  defp preserve_empty_map(map, existing) when map == %{}, do: existing || %{}
  defp preserve_empty_map(map, _existing), do: map

  # Upsert the entry mirror, but never let an out-of-order (older) provider event
  # overwrite a newer stored state: if the incoming provider_time predates what's
  # stored, keep the existing row untouched. On a real update, reactions and
  # raw_reaction_keys are preserved because those are folded in by the reaction
  # path, not carried on a plain receive.
  def mirror_receive_entry(repo, fact, now) do
    with :ok <- lock_entry(repo, fact) do
      attrs = receive_entry_attrs(fact, now)

      case repo.get_by(SignalEntry,
             signal_channel_id: fact.signal_channel_id,
             provider_entry_id: fact.provider_entry_id
           ) do
        %SignalEntry{} = entry ->
          case stale_provider_time?(entry.provider_time, fact.provider_time) do
            true ->
              {:ok, entry}

            false ->
              entry
              |> SignalEntry.changeset(%{
                attrs
                | first_seen_at: entry.first_seen_at,
                  reactions: entry.reactions || %{},
                  raw_reaction_keys: entry.raw_reaction_keys || %{}
              })
              |> repo.update()
          end

        nil ->
          %SignalEntry{}
          |> SignalEntry.changeset(attrs)
          |> repo.insert()
      end
    end
  end

  def receive_entry_attrs(fact, now) do
    search_text = Map.get(fact, :text) || Map.get(fact, :fallback_visible_text)
    metadata_text = metadata_text(fact)

    %{
      signal_channel_id: fact.signal_channel_id,
      provider_entry_id: fact.provider_entry_id,
      text: fact.text,
      formatted_content: fact.formatted_content,
      attachments: fact.attachments,
      links: fact.links,
      author: fact.author,
      mentions: fact.mentions,
      metadata: signal_entry_metadata(fact),
      raw_payload: fact.raw_payload,
      provider_time: fact.provider_time,
      fallback_visible_text: fact.text,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: document_id(fact.signal_channel_id, fact.provider_entry_id),
      search_text: search_text,
      metadata_text: metadata_text,
      content_hash:
        content_hash([
          search_text,
          metadata_text,
          fact.formatted_content,
          fact.attachments,
          fact.links
        ]),
      first_seen_at: now,
      last_seen_at: now
    }
  end

  def signal_entry_metadata(fact) do
    fact.metadata
    |> Map.put_new("provider_thread_id", Map.get(fact, :provider_thread_id))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  def upsert_tombstone(repo, fact, now) do
    attrs = %{
      agent_uid: fact.agent_uid,
      binding_name: fact.binding_name,
      signal_channel_id: fact.signal_channel_id,
      provider_entry_id: fact.provider_entry_id,
      tombstoned_until: DateTime.add(now, @tombstone_ttl_seconds, :second)
    }

    case repo.get_by(InputTombstone,
           agent_uid: fact.agent_uid,
           binding_name: fact.binding_name,
           signal_channel_id: fact.signal_channel_id,
           provider_entry_id: fact.provider_entry_id
         ) do
      %InputTombstone{} = tombstone ->
        tombstone
        |> InputTombstone.changeset(attrs)
        |> repo.update()

      nil ->
        %InputTombstone{}
        |> InputTombstone.changeset(attrs)
        |> repo.insert()
    end
  end

  def active_tombstone?(repo, fact, now) do
    case repo.get_by(InputTombstone,
           agent_uid: fact.agent_uid,
           binding_name: fact.binding_name,
           signal_channel_id: fact.signal_channel_id,
           provider_entry_id: fact.provider_entry_id
         ) do
      %InputTombstone{tombstoned_until: tombstoned_until} ->
        case DateTime.compare(tombstoned_until, now) do
          :gt -> true
          _other -> false
        end

      nil ->
        false
    end
  end

  def delete_mirror_entry(repo, fact) do
    SignalEntry
    |> where([entry], entry.signal_channel_id == ^fact.signal_channel_id)
    |> where([entry], entry.provider_entry_id == ^fact.provider_entry_id)
    |> repo.delete_all()
  end

  # Notify each session that already CONSUMED the now-removed entry. We
  # can't undo what the agent did, but it should know the source message is gone,
  # so we append a "removed" input per affected session, stripped of the
  # original content (no text/mentions/command). It is a tombstone notice, not a
  # re-delivery or user command. Sessions that never consumed the entry had their
  # pending input cancelled instead (see accept_lifecycle), so there's nothing to

  def reaction_entry_attrs(%SignalEntry{} = entry, fact, now) do
    {reactions, raw_reaction_keys} =
      update_reactions(
        entry.reactions || %{},
        entry.raw_reaction_keys || %{},
        fact.action,
        fact.reaction_key,
        fact.actor_key,
        fact.raw_reaction_key
      )

    %{
      reactions: reactions,
      raw_reaction_keys: raw_reaction_keys,
      last_seen_at: now
    }
  end

  defp update_reactions(
         reactions,
         raw_reaction_keys,
         :add,
         reaction_key,
         actor_key,
         raw_reaction_key
       ) do
    actors =
      reactions
      |> Map.get(reaction_key, [])
      |> List.wrap()
      |> MapSet.new()
      |> MapSet.put(actor_key)
      |> MapSet.to_list()
      |> Enum.sort()

    {
      Map.put(reactions, reaction_key, actors),
      Map.put(raw_reaction_keys, reaction_key, raw_reaction_key)
    }
  end

  defp update_reactions(
         reactions,
         raw_reaction_keys,
         :remove,
         reaction_key,
         actor_key,
         raw_reaction_key
       ) do
    actors =
      reactions
      |> Map.get(reaction_key, [])
      |> List.wrap()
      |> MapSet.new()
      |> MapSet.delete(actor_key)
      |> MapSet.to_list()
      |> Enum.sort()

    next_reactions =
      case actors do
        [] -> Map.delete(reactions, reaction_key)
        [_ | _] -> Map.put(reactions, reaction_key, actors)
      end

    {
      next_reactions,
      Map.put(raw_reaction_keys, reaction_key, raw_reaction_key)
    }
  end

  def reaction_result({:ok, entry}), do: {:ok, %{status: :mirrored, signal_entry: entry}}
  def reaction_result({:error, _changeset} = error), do: error

  defp stale_provider_time?(%DateTime{} = stored_time, %DateTime{} = incoming_time) do
    DateTime.compare(incoming_time, stored_time) == :lt
  end

  defp stale_provider_time?(_stored_time, _incoming_time), do: false

  # Serialize all gateway work for a single entry without a row to lock (the entry
  # row may not exist yet on first receive). A transaction-scoped Postgres
  # advisory lock keyed by hash of `channel|entry` makes concurrent
  # receive/reaction/lifecycle handlers for the same message take turns, and it
  # releases automatically at commit/rollback. `hashtext` is acceptable here:
  # rare collisions only cause two unrelated entries to briefly serialize, which
  # is harmless.
  def lock_entry(repo, fact) do
    key =
      Enum.join(
        [fact.signal_channel_id, fact.provider_entry_id],
        "|"
      )

    SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  def lock_inbound_batch(repo, %InboundBatch{} = batch) do
    key =
      Enum.join(
        [
          "inbound_batch",
          batch.agent_uid,
          batch.binding_name,
          batch.signal_channel_id,
          batch.provider_thread_id
        ],
        "|"
      )

    SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  def lock_inbound_batch(repo, fact) do
    key =
      Enum.join(
        [
          "inbound_batch",
          fact.agent_uid,
          fact.binding_name,
          fact.signal_channel_id,
          thread_key(fact.provider_thread_id)
        ],
        "|"
      )

    SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  # Fill the status-machine defaults a freshly committed intent needs: starts
  # :created with zero attempts and a 10-attempt ceiling. `put_new` so a caller

  defp metadata_text(fact) do
    [fact.author, fact.metadata, fact.channel_name, fact.channel_title]
    |> List.flatten()
    |> Enum.map(&metadata_text_part/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp metadata_text_part(value) when is_binary(value), do: value

  defp metadata_text_part(value) when is_map(value),
    do: value |> Map.values() |> Enum.map(&metadata_text_part/1) |> Enum.join(" ")

  defp metadata_text_part(value) when is_list(value),
    do: value |> Enum.map(&metadata_text_part/1) |> Enum.join(" ")

  defp metadata_text_part(value) when is_number(value), do: to_string(value)
  defp metadata_text_part(_value), do: ""

  # Stable, opaque per-entry id derived from its identity (channel + provider
  # entry). `content_hash` instead digests the entry's *content* so a re-receive
  # with unchanged content produces the same hash (cheap change detection).
  defp document_id(signal_channel_id, provider_entry_id) do
    "signal-entry:" <> digest([signal_channel_id, provider_entry_id])
  end

  defp content_hash(parts), do: digest(parts)

  # term_to_binary → SHA-256 → url-safe base64. Hashing the BEAM term (not a
  # string) avoids having to define a canonical serialization for the mixed
  # list of text/maps/lists passed in.
  defp digest(parts) do
    parts
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end
end
