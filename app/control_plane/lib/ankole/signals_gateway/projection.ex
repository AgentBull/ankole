defmodule Ankole.SignalsGateway.Projection do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry

  import Ankole.SignalsGateway.Utils, only: [thread_key: 1]

  @tombstone_ttl_seconds 24 * 60 * 60
  @entry_brain_store_routes_key "_ankole_brain_store_routes"

  def maybe_upsert_channel(_repo, %{signal_channel_id: nil}, _now), do: {:ok, nil}
  def maybe_upsert_channel(repo, fact, now), do: upsert_channel(repo, fact, now)

  def upsert_channel(repo, fact, now) do
    attrs = %{
      id: fact.signal_channel_id,
      kind: fact.channel_kind,
      reply_mode: fact.reply_mode,
      name: fact.channel_name,
      visibility: fact.channel_visibility,
      principal_group_id: Map.get(fact, :principal_group_id),
      metadata: fact.channel_metadata,
      raw_payload: fact.channel_raw_payload,
      first_seen_at: now,
      last_seen_at: now
    }

    case repo.get(Channel, fact.signal_channel_id) do
      %Channel{} = channel ->
        channel
        |> Channel.changeset(merge_channel_attrs(channel, attrs))
        |> repo.update()

      nil ->
        %Channel{}
        |> Channel.changeset(attrs)
        |> repo.insert(on_conflict: :nothing, conflict_target: :id, returning: true)
        |> case do
          {:ok, %Channel{id: id} = channel} when is_binary(id) ->
            {:ok, channel}

          {:ok, %Channel{id: nil}} ->
            update_existing_channel(repo, fact.signal_channel_id, attrs)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp update_existing_channel(repo, signal_channel_id, attrs) do
    case repo.get(Channel, signal_channel_id) do
      %Channel{} = channel ->
        channel
        |> Channel.changeset(merge_channel_attrs(channel, attrs))
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
  defp merge_channel_attrs(%Channel{} = channel, attrs) do
    %{
      attrs
      | kind: preserve_enum(attrs.kind, :unknown, channel.kind),
        reply_mode: preserve_enum(attrs.reply_mode, :none, channel.reply_mode),
        name: attrs.name || channel.name,
        visibility: attrs.visibility || channel.visibility,
        principal_group_id: attrs.principal_group_id || channel.principal_group_id,
        metadata: merge_metadata(channel.metadata, attrs.metadata),
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

  defp merge_metadata(existing, incoming) when is_map(existing) and is_map(incoming) do
    Map.merge(existing, incoming, fn _key, old_value, new_value ->
      if is_map(old_value) and is_map(new_value) do
        merge_metadata(old_value, new_value)
      else
        new_value
      end
    end)
  end

  defp merge_metadata(_existing, incoming) when is_map(incoming), do: incoming

  # Upsert the entry mirror, but never let an out-of-order (older) provider event
  # overwrite a newer stored state: if the incoming provider_time predates what's
  # stored, keep the existing row untouched. On a real update, reactions and
  # raw_reaction_keys are preserved because those are folded in by the reaction
  # path, not carried on a plain receive.
  def mirror_receive_entry(repo, fact, now) do
    with :ok <- lock_entry(repo, fact) do
      attrs = receive_entry_attrs(fact, now)

      case repo.get_by(Entry,
             signal_channel_id: fact.signal_channel_id,
             source_entry_id: fact.source_entry_id
           ) do
        %Entry{} = entry ->
          case stale_provider_time?(entry.provider_time, fact.provider_time) do
            true ->
              {:ok, entry}

            false ->
              entry
              |> Entry.changeset(%{
                attrs
                | first_seen_at: entry.first_seen_at,
                  metadata: merge_entry_metadata(entry.metadata, attrs.metadata),
                  reactions: entry.reactions || %{},
                  raw_reaction_keys: entry.raw_reaction_keys || %{}
              })
              |> repo.update()
          end

        nil ->
          %Entry{}
          |> Entry.changeset(attrs)
          |> repo.insert()
      end
    end
  end

  def receive_entry_attrs(fact, now) do
    rich_content = rich_content(fact.text, fact.formatted_content)
    metadata = signal_entry_metadata(fact)
    content_metadata = Map.delete(metadata, @entry_brain_store_routes_key)

    %{
      signal_channel_id: fact.signal_channel_id,
      source_entry_id: fact.source_entry_id,
      reply_to_source_entry_id: Map.get(fact, :reply_to_source_entry_id),
      provider_thread_id: Map.get(fact, :provider_thread_id),
      text: fact.text,
      rich_content: rich_content,
      attachments: fact.attachments,
      links: fact.links,
      author: fact.author,
      mentions: fact.mentions,
      metadata: metadata,
      raw_payload: fact.raw_payload,
      provider_time: fact.provider_time,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: entry_document_id(fact.signal_channel_id, fact.source_entry_id),
      content_hash:
        entry_content_hash([
          fact.text,
          rich_content,
          fact.attachments,
          fact.links,
          fact.author,
          fact.mentions,
          content_metadata,
          Map.get(fact, :reply_to_source_entry_id),
          Map.get(fact, :provider_thread_id)
        ]),
      first_seen_at: now,
      last_seen_at: now,
      ai_message_id: Map.get(fact, :ai_message_id)
    }
  end

  def signal_entry_metadata(fact) do
    fact.metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc false
  def put_entry_brain_store_route(metadata, principal_uid, store_key)
      when is_map(metadata) and is_binary(principal_uid) and is_binary(store_key) do
    routes = entry_brain_store_routes(metadata)

    Map.put(
      metadata,
      @entry_brain_store_routes_key,
      Map.put(routes, principal_uid, store_key)
    )
  end

  @doc false
  def entry_brain_store_route(%Entry{metadata: metadata}, principal_uid)
      when is_binary(principal_uid) do
    case Map.get(entry_brain_store_routes(metadata), principal_uid) do
      store_key when is_binary(store_key) and store_key != "" -> store_key
      _missing_or_invalid -> nil
    end
  end

  defp merge_entry_metadata(existing, incoming) when is_map(incoming) do
    routes =
      existing
      |> entry_brain_store_routes()
      |> Map.merge(entry_brain_store_routes(incoming))

    incoming = Map.delete(incoming, @entry_brain_store_routes_key)

    if map_size(routes) == 0,
      do: incoming,
      else: Map.put(incoming, @entry_brain_store_routes_key, routes)
  end

  defp entry_brain_store_routes(metadata) when is_map(metadata) do
    case Map.get(metadata, @entry_brain_store_routes_key) do
      %{} = routes -> routes
      _missing_or_invalid -> %{}
    end
  end

  defp entry_brain_store_routes(_metadata), do: %{}

  # `formatted_content` is an ingress representation. Store only structure that
  # adds information beyond the canonical plain text instead of persisting the
  # common `%{"format" => "markdown", "body" => text}` wrapper N times.
  def rich_content(text, formatted_content) when is_map(formatted_content) do
    case formatted_content do
      %{"format" => "markdown", "body" => ^text} when map_size(formatted_content) == 2 -> nil
      %{format: "markdown", body: ^text} when map_size(formatted_content) == 2 -> nil
      map when map == %{} -> nil
      map -> map
    end
  end

  def rich_content(_text, _formatted_content), do: nil

  def upsert_tombstone(repo, fact, now) do
    attrs = %{
      agent_uid: fact.agent_uid,
      binding_name: fact.binding_name,
      signal_channel_id: fact.signal_channel_id,
      source_entry_id: fact.source_entry_id,
      tombstoned_until: DateTime.add(now, @tombstone_ttl_seconds, :second)
    }

    case repo.get_by(InputTombstone,
           agent_uid: fact.agent_uid,
           binding_name: fact.binding_name,
           signal_channel_id: fact.signal_channel_id,
           source_entry_id: fact.source_entry_id
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
           source_entry_id: fact.source_entry_id
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
    Entry
    |> where([entry], entry.signal_channel_id == ^fact.signal_channel_id)
    |> where([entry], entry.source_entry_id == ^fact.source_entry_id)
    |> repo.delete_all()
  end

  def recent_entry_attachments(
        repo,
        signal_channel_id,
        author_id,
        %DateTime{} = provider_time,
        opts \\ []
      )
      when is_binary(signal_channel_id) and is_binary(author_id) do
    window_seconds = Keyword.get(opts, :window_seconds, 120)
    max_attachments = Keyword.get(opts, :limit, 3)
    entry_limit = Keyword.get(opts, :entry_limit, max(20, max_attachments))
    since = DateTime.add(provider_time, -window_seconds, :second)

    Entry
    |> where([entry], entry.signal_channel_id == ^signal_channel_id)
    |> where([entry], entry.provider_time >= ^since and entry.provider_time <= ^provider_time)
    |> order_by([entry], desc: entry.provider_time)
    |> limit(^entry_limit)
    |> repo.all()
    |> Enum.filter(&(get_in(&1.author || %{}, ["id"]) == author_id))
    |> Enum.flat_map(&(&1.attachments || []))
    |> Enum.take(max_attachments)
  end

  def reaction_entry_attrs(%Entry{} = entry, fact, now) do
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
  # row may not exist yet on first receive). A transaction-scoped PostgreSQL
  # advisory lock keyed by hash of `channel|entry` makes concurrent
  # receive/reaction/lifecycle handlers for the same message take turns, and it
  # releases automatically at commit/rollback. `hashtext` is acceptable here:
  # rare collisions only cause two unrelated entries to briefly serialize, which
  # is harmless.
  def lock_entry(repo, fact) do
    key =
      Enum.join(
        [fact.signal_channel_id, fact.source_entry_id],
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

  # Stable, opaque per-entry id derived from its identity (channel + provider
  # entry). `content_hash` instead digests the entry's *content* so a re-receive
  # with unchanged content produces the same hash (cheap change detection).
  def entry_document_id(signal_channel_id, source_entry_id) do
    "signal-gateway-entry:" <> digest([signal_channel_id, source_entry_id])
  end

  def entry_content_hash(parts), do: digest(parts)

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
