defmodule Ankole.SignalsGateway.Projection do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.Files
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry

  import Ankole.SignalsGateway.Utils, only: [thread_key: 1]

  @tombstone_ttl_seconds 24 * 60 * 60
  @attachment_id_sequence "signal_gateway_attachment_id_seq"
  @attachment_id_min 10_000
  @attachment_id_max 9_007_199_254_740_991
  @attachment_identity_fields ~w(provider_ref provider_file_id provider_file_key provider_uri blob_ref storage_ref)
  @attachment_materialization_fields ~w(attachment_id blob_ref path content_type size size_bytes bytes)

  @doc "Resolves one observed direct conversation reachable through this binding."
  def existing_direct_conversation(binding, principal_uid) do
    Ankole.Repo.all(
      from channel in Channel,
        join: event in Ankole.SignalsGateway.ActorEvent,
        on: event.tenant_id == channel.tenant_id and event.signal_channel_id == channel.id,
        where:
          event.agent_uid == ^binding.agent_uid and event.binding_name == ^binding.name and
            channel.kind == :im_dm and
            fragment("?->>'dm_peer_principal_uid'", channel.metadata) == ^principal_uid,
        distinct: true,
        limit: 2,
        select: channel
    )
    |> case do
      [channel] -> {:ok, channel}
      [] -> {:error, :principal_conversation_not_observed}
      _ambiguous -> {:error, :principal_conversation_ambiguous}
    end
  end

  @doc """
  Updates the metadata of one channel mirror under the channel row lock.

  An adapter keeps its own provider fact on the channel mirror with this call.
  The lock is the one ingress takes, so a monotonic value, such as the newest
  provider time an adapter has seen, cannot move backwards through a concurrent
  or redelivered event: the function reads the stored metadata and writes the
  result of `fun` inside the same transaction.
  """
  @spec update_channel_metadata(String.t(), (map() -> map())) ::
          {:ok, Channel.t()} | {:error, :signal_channel_not_found | Ecto.Changeset.t()}
  def update_channel_metadata(signal_channel_id, fun)
      when is_binary(signal_channel_id) and is_function(fun, 1) do
    Ankole.Repo.transact(fn repo ->
      case lock_channel(repo, signal_channel_id) do
        %Channel{} = channel ->
          channel
          |> Channel.changeset(%{metadata: fun.(channel.metadata || %{})})
          |> repo.update()

        nil ->
          {:error, :signal_channel_not_found}
      end
    end)
  end

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

    case lock_channel(repo, fact.signal_channel_id) do
      %Channel{} = channel ->
        channel
        |> Channel.changeset(merge_channel_attrs(channel, attrs))
        |> repo.update()

      nil ->
        %Channel{}
        |> Channel.changeset(attrs)
        |> repo.insert(on_conflict: :nothing, conflict_target: [:tenant_id, :id])
        |> case do
          {:ok, _attempted_channel} ->
            update_existing_channel(repo, fact.signal_channel_id, attrs)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp update_existing_channel(repo, signal_channel_id, attrs) do
    case lock_channel(repo, signal_channel_id) do
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
    kind = preserve_enum(attrs.kind, :unknown, channel.kind)

    %{
      attrs
      | kind: kind,
        reply_mode: preserve_enum(attrs.reply_mode, :none, channel.reply_mode),
        name: attrs.name || channel.name,
        visibility: attrs.visibility || channel.visibility,
        principal_group_id: merged_principal_group_id(kind, attrs, channel),
        metadata: merge_metadata(channel.metadata, attrs.metadata),
        raw_payload: preserve_empty_map(attrs.raw_payload, channel.raw_payload),
        first_seen_at: channel.first_seen_at,
        last_seen_at: latest_seen_at(channel.last_seen_at, attrs.last_seen_at)
    }
  end

  # `sparse_value` is the enum's "no info" member (:unknown / :none); receiving it
  # means the event carried no channel kind / reply mode, so keep what we had.
  defp preserve_enum(incoming, sparse_value, existing) when incoming == sparse_value, do: existing
  defp preserve_enum(incoming, _sparse_value, _existing), do: incoming

  # A principal group belongs to a group channel. "Don't overwrite with nothing"
  # cannot apply to this field on its own: when an observation reclassifies the
  # channel away from `im_group`, keeping the stored group produces a row the
  # storage rejects, and every later message on that channel then fails.
  defp merged_principal_group_id(:im_group, attrs, %Channel{} = channel),
    do: attrs.principal_group_id || channel.principal_group_id

  defp merged_principal_group_id(_kind, _attrs, %Channel{}), do: nil

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

  defp latest_seen_at(%DateTime{} = existing, %DateTime{} = incoming) do
    case DateTime.compare(existing, incoming) do
      :gt -> existing
      _not_later -> incoming
    end
  end

  defp latest_seen_at(_existing, incoming), do: incoming

  defp lock_channel(repo, signal_channel_id) do
    repo.one(
      from channel in Channel,
        where: channel.id == ^signal_channel_id,
        lock: "FOR UPDATE"
    )
  end

  # Upsert the entry mirror, but never let an out-of-order (older) provider event
  # overwrite a newer stored state: if the incoming provider_time predates what's
  # stored, keep the existing row untouched. On a real update, reactions and
  # raw_reaction_keys are preserved because those are folded in by the reaction
  # path, not carried on a plain receive.
  def mirror_receive_entry(repo, fact, now) do
    with :ok <- lock_entry(repo, fact) do
      entry =
        repo.get_by(Entry,
          signal_channel_id: fact.signal_channel_id,
          source_entry_id: fact.source_entry_id
        )

      case entry do
        %Entry{} = entry ->
          case stale_provider_time?(entry.provider_time, fact.provider_time) do
            true ->
              {:ok, entry}

            false ->
              fact = put_attachment_ids(repo, fact, entry.attachments)
              attrs = receive_entry_attrs(fact, now)

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
          fact = put_attachment_ids(repo, fact, [])
          attrs = receive_entry_attrs(fact, now)

          %Entry{}
          |> Entry.changeset(attrs)
          |> repo.insert()
      end
    end
  end

  # Names every stored attachment in the drive of the Agent that receives the
  # fact, in the same transaction as the mirror. The drive reference keeps the
  # bytes from collection until the ActorEvent reaches the Agent, however long
  # that takes. A content that collection already removed loses its
  # `blob_ref`, so the attachment counts as one without bytes.
  defp put_attachment_ids(repo, fact, existing_attachments) do
    attachments =
      fact.attachments
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn {attachment, index} ->
        put_attachment_id(repo, attachment, index, List.wrap(existing_attachments))
      end)
      |> channel_attachments(fact.signal_channel_id)
      |> Enum.map(&link_attachment(repo, Map.get(fact, :agent_uid), provenance(fact), &1))

    Map.put(fact, :attachments, attachments)
  end

  # A later observation cannot take stored bytes away from an attachment. A
  # provider that redelivers an event can fetch the same file twice; when the
  # second fetch fails after the first one stored the bytes, or reports before
  # it, the stored result with its `blob_ref` stays. This runs under the entry
  # lock, so the order in which two downloads finish cannot lose the bytes.
  defp put_attachment_id(repo, attachment, index, existing_attachments)
       when is_map(attachment) do
    existing = matching_existing_attachment(attachment, index, existing_attachments)

    if stored_attachment?(existing) and not stored_attachment?(attachment) do
      existing
    else
      Map.put(
        attachment,
        "attachment_id",
        valid_attachment_id(existing) || next_attachment_id(repo)
      )
    end
  end

  defp put_attachment_id(_repo, attachment, _index, _existing_attachments), do: attachment

  @doc """
  Names in the Agent's drive every stored attachment that an ActorEvent
  payload shows to the Agent and that the drive does not name yet.

  The control plane calls it before it hands a payload to a Worker. Paths that
  bypass the mirror, or reach the Agent before the mirror, then still give the
  Agent attachments it can read: an entry whose stored copy is newer than the
  observation, a group entry that is mirrored only when its batch closes, and
  a supplement that updates an open ActorEvent before the mirror. A path that
  the drive already names stays as its writer left it, with the provenance of
  the mirror and the source of a sent or generated file.
  """
  @spec link_payload_attachments(String.t(), map(), String.t() | nil) :: :ok
  def link_payload_attachments(agent_uid, payload, channel_id)
      when is_binary(agent_uid) and is_map(payload) do
    payload
    |> channel_payload(channel_id)
    |> payload_attachments()
    |> Enum.filter(&stored_attachment?/1)
    |> Enum.uniq_by(&{&1["path"], &1["blob_ref"]})
    |> Enum.reject(&match?({:ok, _file}, Files.fetch(agent_uid, &1["path"])))
    |> Enum.each(fn attachment ->
      {:ok, _attachment} =
        Ankole.Repo.transact(fn repo ->
          {:ok, link_attachment(repo, agent_uid, %{signal_channel_id: channel_id}, attachment)}
        end)
    end)
  end

  def link_payload_attachments(_agent_uid, _payload, _channel_id), do: :ok

  @doc "Gives received files their channel paths, including old inbox references."
  def channel_attachments(attachments, channel_id) do
    Enum.map(attachments, fn
      %{"path" => "inbox/" <> _rest = path} = attachment when is_binary(channel_id) ->
        Map.put(attachment, "path", Files.chat_path(channel_id, path))

      attachment ->
        attachment
    end)
  end

  @doc "Updates received attachment paths in an input payload without changing its other facts."
  def channel_payload(payload, channel_id) do
    case payload do
      %{"data" => data} when is_map(data) ->
        data =
          Enum.reduce(["entry", "entries", "unreplied_messages"], data, fn key, acc ->
            case Map.fetch(acc, key) do
              {:ok, entries} when is_list(entries) ->
                Map.put(acc, key, Enum.map(entries, &channel_entry(&1, channel_id)))

              {:ok, entry} when is_map(entry) ->
                Map.put(acc, key, channel_entry(entry, channel_id))

              _missing ->
                acc
            end
          end)

        Map.put(payload, "data", data)

      _other ->
        payload
    end
  end

  defp channel_entry(entry, channel_id) when is_map(entry) do
    entry =
      case Map.fetch(entry, "attachments") do
        {:ok, attachments} when is_list(attachments) ->
          Map.put(entry, "attachments", channel_attachments(attachments, channel_id))

        _missing ->
          entry
      end

    case Map.get(entry, "reply_to") do
      reply when is_map(reply) -> Map.put(entry, "reply_to", channel_entry(reply, channel_id))
      _missing -> entry
    end
  end

  defp channel_entry(other, _channel_id), do: other

  # Attachments of the entry, of the message it quotes, and of every entry of
  # a batch. The payload is the stored JSON of an ActorEvent, so its keys are
  # strings.
  defp payload_attachments(payload) do
    data = field(payload, "data") || %{}

    entries =
      [field(data, "entry")] ++
        List.wrap(field(data, "entries")) ++
        List.wrap(field(data, "unreplied_messages"))

    Enum.flat_map(entries, fn
      entry when is_map(entry) ->
        List.wrap(field(entry, "attachments")) ++
          List.wrap(field(field(entry, "reply_to"), "attachments"))

      _other ->
        []
    end)
    |> Enum.filter(&is_map/1)
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_value, _key), do: nil

  defp provenance(fact),
    do: %{signal_channel_id: fact.signal_channel_id, source_entry_id: fact.source_entry_id}

  defp link_attachment(
         repo,
         agent_uid,
         provenance,
         %{"blob_ref" => sha256, "path" => path} = attachment
       )
       when is_binary(agent_uid) and is_binary(sha256) and is_binary(path) do
    upsert = %{
      path: path,
      sha256: sha256,
      source: "inbound",
      content_type: attachment_content_type(attachment),
      signal_channel_id: Map.get(provenance, :signal_channel_id),
      source_entry_id: Map.get(provenance, :source_entry_id)
    }

    case Files.commit(repo, agent_uid, [upsert], []) do
      {:ok, _result} -> attachment
      {:error, {:blob_missing, _sha256}} -> Map.drop(attachment, ["blob_ref", "path"])
      {:error, reason} -> raise ArgumentError, "invalid stored attachment: #{inspect(reason)}"
    end
  end

  defp link_attachment(_repo, _agent_uid, _fact, attachment), do: attachment

  @doc "The declared content type of one attachment, if the provider gave one."
  @spec attachment_content_type(map()) :: String.t() | nil
  def attachment_content_type(attachment) when is_map(attachment) do
    Enum.find_value(["content_type", "mimetype", "mime_type"], fn key ->
      case Map.get(attachment, key) do
        value when is_binary(value) and value != "" -> value
        _missing -> nil
      end
    end)
  end

  defp matching_existing_attachment(attachment, index, existing_attachments) do
    case attachment_identity(attachment) do
      nil ->
        existing_attachment = Enum.at(existing_attachments, index)

        if attachment_descriptor(existing_attachment) == attachment_descriptor(attachment),
          do: existing_attachment

      identity ->
        Enum.find(existing_attachments, &(attachment_identity(&1) == identity))
    end
  end

  defp attachment_identity(attachment) when is_map(attachment) do
    Enum.find_value(@attachment_identity_fields, fn field ->
      case Map.get(attachment, field) do
        value when is_binary(value) and value != "" -> {field, value}
        _missing_or_invalid -> nil
      end
    end)
  end

  defp attachment_identity(_attachment), do: nil

  defp attachment_descriptor(attachment) when is_map(attachment),
    do: Map.drop(attachment, @attachment_materialization_fields)

  defp attachment_descriptor(_attachment), do: nil

  @doc """
  Returns whether the file service already holds the bytes of an attachment.

  The bytes are content addressed and shared, so one stored copy serves every
  Agent that receives the attachment.
  """
  @spec stored_attachment?(term()) :: boolean()
  def stored_attachment?(%{"blob_ref" => sha256, "path" => path})
      when is_binary(sha256) and sha256 != "" and is_binary(path) and path != "",
      do: true

  def stored_attachment?(_attachment), do: false

  defp valid_attachment_id(%{"attachment_id" => attachment_id})
       when is_integer(attachment_id) and attachment_id >= @attachment_id_min and
              attachment_id <= @attachment_id_max,
       do: attachment_id

  defp valid_attachment_id(_attachment), do: nil

  defp next_attachment_id(repo) do
    %{rows: [[attachment_id]]} =
      SQL.query!(repo, "SELECT nextval('#{@attachment_id_sequence}')", [])

    attachment_id
  end

  def receive_entry_attrs(fact, now) do
    rich_content = rich_content(fact.text, fact.formatted_content)
    metadata = signal_entry_metadata(fact)

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
          metadata,
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

  defp merge_entry_metadata(_existing, incoming) when is_map(incoming), do: incoming

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

    # The author predicate runs in SQL before the window limit; filtering
    # after the limit let a busy channel push the author's entries out of the
    # window.
    Entry
    |> where([entry], entry.signal_channel_id == ^signal_channel_id)
    |> where([entry], fragment("?->>'id' = ?", entry.author, ^author_id))
    |> where([entry], entry.provider_time >= ^since and entry.provider_time <= ^provider_time)
    |> order_by([entry], desc: entry.provider_time)
    |> limit(^entry_limit)
    |> repo.all()
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
