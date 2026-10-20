defmodule Ankole.Brain.ConversationsLearning do
  @moduledoc """
  Batch learning from committed conversation Message slices.

  This is the second first-class write path: input is the public
  conversation history, independent of Agent turn history. One instance-level task
  processes one slice with the maintainer Agent's `light` profile; the same
  slice is never processed per Agent, because the knowledge space is shared.
  Slice identity is a stable version token. Memory writes and the Source's
  extraction watermark commit together under the Source row lock. A failed
  slice leaves the watermark unchanged and can run again.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.Links
  alias Ankole.Brain.ModelCalls
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Scope
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Sources
  alias Ankole.Brain.Timelines
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Logging
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.{Message, ExternalMessageRef}

  @max_slice_entries 200
  @known_page_limit 20
  @known_page_alias_limit 5

  @doc """
  Processes the pending slice of one channel. Returns a status map; slices
  that cannot learn (missing model, missing member group, no counterpart)
  report their reason instead of failing.
  """
  @spec process_conversation(String.t()) :: {:ok, map()} | {:error, term()}
  def process_conversation(conversation_id) when is_binary(conversation_id) do
    with :ok <- ensure_enabled(),
         {:ok, model} <- ensure_extraction_model(),
         {:ok, channel} <- fetch_conversation(conversation_id),
         {:ok, learning_context} <- learning_context(channel),
         {:ok, source} <- ensure_active_source(channel) do
      learning_context = Map.put(learning_context, :source_id, source.id)
      start = Sources.extraction_watermark(source)

      case slice_after(conversation_id, start, @max_slice_entries) do
        [] ->
          {:ok, %{status: :no_pending_entries}}

        entries ->
          token = slice_version_token(conversation_id, entries)

          process_slice(channel, source, start, learning_context, entries, token, model)
      end
    else
      {:skip, reason} -> {:ok, %{status: :skipped, reason: reason}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Reads the next bounded slice in public Message sequence order."
  def pending_slice(conversation_id, limit \\ @max_slice_entries) do
    slice_after(
      conversation_id,
      Sources.conversation_extraction_watermark(conversation_id),
      limit
    )
  end

  defp observations_query(conversation_id) do
    from message in Message,
      left_join: ref in ExternalMessageRef,
      on: ref.message_id == message.id and ref.tenant_id == message.tenant_id,
      where: message.conversation_id == ^conversation_id,
      where:
        message.id not in subquery(
          Ankole.Conversations.removed_message_ids_query(conversation_id)
        ),
      select: %{message: message, external_ref: ref}
  end

  defp slice_after(conversation_id, watermark, limit) do
    observations_query(conversation_id)
    |> where([message], message.seq > ^(watermark || 0))
    |> order_by([message], asc: message.seq)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns whether one channel has unprocessed entries, without loading a
  full slice.
  """
  @spec has_pending_slice?(String.t()) :: boolean()
  def has_pending_slice?(conversation_id), do: pending_slice(conversation_id, 1) != []

  @doc """
  Computes the stable version token of one slice: the channel plus the
  ordered `provider_message_id + content_hash` sequence.
  """
  @spec slice_version_token(String.t(), [map()]) :: String.t()
  def slice_version_token(conversation_id, observations) do
    canonical =
      Enum.map(observations, fn %{message: message, external_ref: ref} ->
        [
          message.id,
          message.seq,
          message.text,
          message.author_uid,
          message.attachments,
          message.links,
          message.rich_content,
          if(ref, do: ref.content_hash)
        ]
      end)

    NativeKernel.xxh3_128_hex(Ankole.JSON.encode!([conversation_id, canonical]))
  end

  @doc "Finds idle conversations with Messages beyond their Source watermark."
  def idle_pending_slices do
    threshold =
      DateTime.add(DateTime.utc_now(), -Config.signal_channel_batch_idle_time(), :second)

    watermark =
      from source in Source,
        where:
          source.kind == "conversation" and
            source.upstream_id == fragment("?::text", parent_as(:conversation).id),
        select: %{seq: source.extracted_through_seq}

    first_message =
      from message in Message,
        where:
          message.conversation_id == parent_as(:conversation).id and
            message.seq > fragment("COALESCE(?, 0)", parent_as(:watermark).seq),
        where: message.id not in subquery(Ankole.Conversations.removed_message_ids_query()),
        order_by: message.seq,
        limit: 1,
        select: %{created_at: message.created_at}

    Conversation
    |> from(as: :conversation)
    |> where(
      [conversation],
      conversation.kind == :native or conversation.external_kind in [:im_dm, :im_group]
    )
    |> where([conversation], conversation.last_activity_at < ^threshold)
    |> join(:left_lateral, [], watermark in subquery(watermark), as: :watermark, on: true)
    |> join(:inner_lateral, [], message in subquery(first_message), on: true)
    |> select([conversation, _watermark, message], %{
      conversation_id: conversation.id,
      first_seen_at: message.created_at
    })
    |> Repo.all()
  end

  defp process_slice(channel, source, start, learning_context, entries, token, model) do
    transcript = build_transcript(entries)
    boundary = slice_boundary(entries)

    if String.trim(transcript.text) == "" do
      finalize(source, start, channel.id, token, :not_applicable, [], learning_context, boundary)
    else
      prompt = extraction_prompt(transcript, learning_context, known_pages(transcript.text))

      case ModelCalls.complete_json(model, prompt, caller: "brain.conversations_learning") do
        {:ok, %{"items" => items}} when is_list(items) ->
          # The input version is recomputed over the same entries after the
          # model call: an in-slice edit or delete during the run writes no
          # memory or watermark and runs again. Entries that only arrived later belong to
          # the next slice and do not invalidate this one — otherwise a
          # continuously active channel could never commit any slice.
          if slice_still_current?(channel.id, entries, token) do
            outcome = if items == [], do: :not_applicable, else: :complete
            finalize(source, start, channel.id, token, outcome, items, learning_context, boundary)
          else
            {:ok, %{status: :slice_changed, token: token}}
          end

        {:ok, _invalid_output} ->
          {:error, {:extraction_failed, :invalid_extraction_response}}

        {:error, reason} ->
          {:error, {:extraction_failed, reason}}
      end
    end
  end

  # The boundary is the last covered entry in slice order; it becomes the
  # next slice's Source watermark.
  defp slice_boundary(observations) do
    last = List.last(observations).message
    {last.created_at, last.seq}
  end

  defp slice_still_current?(conversation_id, observations, token) do
    ids = Enum.map(observations, & &1.message.id)

    current =
      observations_query(conversation_id)
      |> where([message], message.id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.message.id, &1})

    refetched = Enum.map(observations, &Map.get(current, &1.message.id))

    not Enum.any?(refetched, &is_nil/1) and
      slice_version_token(conversation_id, refetched) == token
  end

  # Real memory writes and the Source watermark commit in one final short
  # transaction. Embeddings prepare in one batched call before it, so the
  # transaction holds no network I/O while write-time semantic dedup keeps
  # its vectors. The locked Source re-read is the archive fence: a channel
  # archived during the model call must not gain new memory. Mixed
  # item-level validation rejects stay visible in the report and the log.
  # If every non-empty model item is rejected, the transaction rolls back
  # without advancing the watermark, so Oban can retry the slice.
  # Infrastructure failures follow the same rollback contract.
  defp finalize(source, start, conversation_id, token, outcome, items, learning_context, boundary) do
    prepared = prepare_embeddings(items)

    result =
      Repo.transact(fn repo ->
        with %Conversation{} <-
               repo.one(
                 from c in Conversation, where: c.id == ^conversation_id, lock: "FOR SHARE"
               ),
             {:ok, current} <- lock_active_source(repo, source),
             :ok <- ensure_source_revision(current, source),
             :ok <- ensure_same_watermark(Sources.extraction_watermark(current), start),
             :ok <- ensure_slice_version_in_tx(repo, conversation_id, start, boundary, token),
             written = write_items(repo, conversation_id, items, learning_context, prepared),
             :ok <- ensure_extraction_written(items, written),
             :ok <- Sources.record_extraction_watermark(repo, current, boundary) do
          {:ok, %{status: outcome, token: token, written: written}}
        else
          nil -> {:error, :source_archived}
          {:error, _reason} = error -> error
        end
      end)

    case result do
      {:ok, %{written: written} = report} ->
        if written.rejected > 0 do
          Logging.warning(
            "brain.conversations_learning.items_rejected",
            "extraction items failed write validation",
            %{
              conversation_id: conversation_id,
              token: token,
              rejected: written.rejected,
              reasons: written.reject_reasons
            }
          )
        end

        {:ok, Map.put(report, :pending_remaining, has_pending_slice?(conversation_id))}

      {:error, :slice_changed} ->
        {:ok, %{status: :slice_changed, token: token}}

      {:error, :source_archived} ->
        {:ok, %{status: :skipped, reason: :source_archived}}

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_source_revision(%Source{upstream_revision: revision}, %Source{
         upstream_revision: revision
       }),
       do: :ok

  defp ensure_source_revision(_, _), do: {:error, :slice_changed}

  defp ensure_slice_version_in_tx(repo, conversation_id, start, {_at, seq}, token) do
    case repo.one(from c in Conversation, where: c.id == ^conversation_id, lock: "FOR SHARE") do
      nil ->
        {:error, :slice_changed}

      _ ->
        current =
          observations_query(conversation_id)
          |> where([message], message.seq > ^(start || 0) and message.seq <= ^seq)
          |> order_by([message], asc: message.seq)
          |> repo.all()

        if slice_version_token(conversation_id, current) == token,
          do: :ok,
          else: {:error, :slice_changed}
    end
  end

  # One batched call embeds every fact and take text of the slice; a failure
  # degrades every item to the untried vector state, the same contract as a
  # failed per-claim embedding.
  defp prepare_embeddings(items) do
    texts =
      items
      |> Enum.filter(&(&1["type"] in ["fact", "take"]))
      |> Enum.map(& &1["claim"])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    with [_ | _] <- texts,
         {:ok, {vectors, signature}} <- Ankole.Brain.Embeddings.embed_texts(texts) do
      texts |> Enum.zip(Enum.map(vectors, &{&1, signature})) |> Map.new()
    else
      _empty_or_failed -> %{}
    end
  end

  @empty_counts %{claims: 0, objects: 0, timelines: 0, links: 0, rejected: 0, reject_reasons: []}

  defp ensure_extraction_written(items, %{rejected: rejected, reject_reasons: reasons})
       when items != [] and rejected == length(items),
       do: {:error, {:all_items_rejected, reasons}}

  defp ensure_extraction_written(_items, _written), do: :ok

  defp write_items(repo, conversation_id, items, learning_context, prepared) do
    # Objects first: facts, takes, timelines, and links in the same batch
    # may reference pages the model declared later in its output order.
    {object_items, other_items} = Enum.split_with(items, &match?(%{"type" => "object"}, &1))

    counts =
      Enum.reduce(object_items ++ other_items, @empty_counts, fn item, counts ->
        case write_item(repo, conversation_id, item, learning_context, prepared) do
          {:ok, kind} ->
            Map.update!(counts, kind, &(&1 + 1))

          {:rejected, reason} ->
            counts
            |> Map.update!(:rejected, &(&1 + 1))
            |> Map.update!(:reject_reasons, &[inspect(reason) | &1])
        end
      end)

    Map.update!(counts, :reject_reasons, fn reasons ->
      reasons |> Enum.reverse() |> Enum.uniq() |> Enum.take(5)
    end)
  end

  defp write_item(
         repo,
         _conversation_id,
         %{"type" => "object"} = item,
         _learning_context,
         _prepared
       ) do
    attrs = %{
      slug: item["slug"],
      type: item["object_type"],
      subtype: item["subtype"],
      title: item["title"],
      body: item["body"] || ""
    }

    case Objects.create_object(attrs, :system, repo: repo) do
      {:ok, object} ->
        item
        |> Map.get("aliases", [])
        |> List.wrap()
        |> Enum.each(fn alias_text ->
          Links.add_alias(object.slug, alias_text, repo: repo)
        end)

        {:ok, :objects}

      {:error, {:slug_taken, _slug}} ->
        {:ok, :objects}

      {:error, reason} ->
        {:rejected, reason}
    end
  end

  defp write_item(repo, conversation_id, %{"type" => "fact"} = item, learning_context, prepared) do
    scope = enforce_scope(item["scope"], learning_context)

    attrs = %{
      claim: item["claim"],
      kind: item["kind"],
      holder: item["holder"] || "world",
      audience_scope: scope,
      notability: item["notability"] || "medium",
      # The 0.75 self-report and 0.55 relay caps are conditional rules the
      # prompt owns; the server enforces only the mechanical grid, because
      # clamping every value would misstate first-person conviction.
      confidence: Claims.snap_to_grid(item["confidence"]),
      context: item["context"],
      valid_from: parse_datetime(item["valid_from"]) || DateTime.utc_now(:microsecond),
      provenance: item["provenance"] || "conversation",
      provenance_session: "source:" <> learning_context.source_id
    }

    attrs = put_parent(attrs, repo, conversation_id, item["object_slug"])

    case Claims.write_fact(attrs, :system,
           repo: repo,
           author: learning_context.author,
           embedding: Map.get(prepared, item["claim"], {nil, nil})
         ) do
      {:ok, _result} -> {:ok, :claims}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp write_item(repo, conversation_id, %{"type" => "take"} = item, learning_context, prepared) do
    scope = enforce_scope(item["scope"], learning_context)

    attrs = %{
      claim: item["claim"],
      kind: item["kind"] || "take",
      holder: item["holder"] || "world",
      audience_scope: scope,
      weight: Claims.snap_to_grid(item["weight"]),
      since_date: item["since_date"],
      until_date: item["until_date"],
      provenance: item["provenance"] || "conversation",
      provenance_session: "source:" <> learning_context.source_id
    }

    attrs = put_parent(attrs, repo, conversation_id, item["object_slug"])

    case Claims.write_take(attrs, :system,
           repo: repo,
           author: learning_context.author,
           embedding: Map.get(prepared, item["claim"], {nil, nil})
         ) do
      {:ok, _claim} -> {:ok, :claims}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp write_item(
         repo,
         _conversation_id,
         %{"type" => "timeline"} = item,
         learning_context,
         _prepared
       ) do
    scope = enforce_scope(item["scope"], learning_context)

    attrs = %{
      object_slug: item["object_slug"],
      date: parse_date(item["date"]),
      summary: item["summary"],
      detail: item["detail"] || "",
      provenance: item["provenance"] || "conversation",
      audience_scope: scope
    }

    case Timelines.write_timeline(attrs, :system,
           repo: repo,
           author: learning_context.author
         ) do
      {:ok, _timeline} -> {:ok, :timelines}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp write_item(
         repo,
         _conversation_id,
         %{"type" => "link"} = item,
         _learning_context,
         _prepared
       ) do
    attrs = %{
      from_object_slug: item["from"],
      to_object_slug: item["to"],
      link_type: item["link_type"] || "",
      context: item["context"] || "",
      link_source: "extraction"
    }

    case Links.upsert_link(attrs, repo: repo) do
      {:ok, _link} -> {:ok, :links}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp write_item(_repo, _conversation_id, item, _learning_context, _prepared),
    do: {:rejected, {:unknown_item_type, item["type"]}}

  defp put_parent(attrs, repo, conversation_id, object_slug) do
    case object_slug do
      slug when is_binary(slug) and slug != "" ->
        case Objects.resolve_slug(slug, repo: repo) do
          {:ok, object} -> Map.put(attrs, :object_slug, object.slug)
          {:error, :not_found} -> Map.put(attrs, :conversation_id, conversation_id)
        end

      _missing ->
        Map.put(attrs, :conversation_id, conversation_id)
    end
  end

  # Deterministic default scope and author attribution; this path never
  # reads ConfidentialityPolicy.md.
  defp learning_context(%Conversation{kind: :external, external_kind: :im_group} = channel) do
    case Scope.member_group_scope(channel.principal_group_id) do
      {:ok, scope} ->
        {:ok,
         %{
           kind: :im_group,
           default_scope: scope,
           author: nil,
           speaker_uids: speaker_uids(channel.id)
         }}

      {:error, :im_group_without_member_group} ->
        {:skip, :im_group_without_member_group}
    end
  end

  defp learning_context(%Conversation{kind: :external, external_kind: :im_dm} = conversation) do
    speakers = speaker_uids(conversation.id)

    case Enum.filter(speakers, &human_uid?/1) do
      [counterpart] ->
        {:ok,
         %{
           kind: :im_dm,
           default_scope: Scope.principal(counterpart),
           author: nil,
           speaker_uids: speakers
         }}

      [] ->
        {:skip, :im_dm_without_counterpart}

      _ ->
        {:skip, :im_dm_without_single_counterpart}
    end
  end

  defp learning_context(%Conversation{kind: :native} = conversation) do
    author =
      Repo.one(
        from p in Ankole.Conversations.Participant,
          join: principal in Principal,
          on: principal.uid == p.principal_uid,
          where: p.conversation_id == ^conversation.id and p.role == :agent,
          select: principal.uid
      )

    if is_binary(conversation.created_by) and is_binary(author) do
      {:ok,
       %{
         kind: :native,
         default_scope: Scope.principal(conversation.created_by),
         author: Ankole.ActorRef.from_principal(%{tenant_id: Repo.tenant_id!(), uid: author}),
         speaker_uids: speaker_uids(conversation.id)
       }}
    else
      {:skip, :native_conversation_without_participants}
    end
  end

  defp learning_context(%Conversation{external_kind: kind}),
    do: {:skip, {:unsupported_conversation_kind, kind}}

  # The source audience is an upper bound. The model can keep the deterministic
  # default or narrow content with an explicit confidentiality signal to one
  # speaker; every other value clamps to the default.
  defp enforce_scope(scope, learning_context) do
    allowed =
      [learning_context.default_scope] ++
        Enum.map(learning_context.speaker_uids, &Scope.principal/1)

    if is_binary(scope) and scope in allowed,
      do: scope,
      else: learning_context.default_scope
  end

  defp speaker_uids(conversation_id) do
    Repo.all(
      from message in Message,
        where: message.conversation_id == ^conversation_id and not is_nil(message.author_uid),
        select: message.author_uid,
        distinct: true
    )
  end

  defp human_uid?(uid) do
    Principal
    |> where([principal], principal.uid == ^uid and principal.type == :human)
    |> Repo.exists?()
  end

  defp build_transcript(entries) do
    lines =
      entries
      |> Enum.map(fn entry ->
        speaker = speaker_label(entry)
        text = String.trim(entry.message.text || "")

        if text == "", do: nil, else: "#{speaker}: #{text}"
      end)
      |> Enum.reject(&is_nil/1)

    %{text: Enum.join(lines, "\n"), entries: entries}
  end

  # The speaker's canonical slug is the holder identity: attribution itself
  # does the perspective separation.
  defp speaker_label(%{message: message, external_ref: ref}) do
    case message.author_uid do
      uid when is_binary(uid) ->
        case Scope.canonical_slug(uid) do
          {:ok, slug} -> slug
          {:error, _} -> uid
        end

      _ ->
        if(ref, do: ref.author["display_name"] || "unknown", else: "unknown")
    end
  end

  # Write-time dedup of named entities: the model declares new pages, and
  # the exact-slug idempotency on the write side cannot recognize the same
  # entity under a second wording, so the prompt must carry the pages this
  # slice already names. Vector similarity does not catch these duplicates
  # either — a page stored under its chosen name does not embed near a
  # descriptive paraphrase — so the match is the exact-alias containment
  # that volunteer pointers already use.
  defp known_pages(text) do
    slugs = text |> Links.match_aliases_in_text() |> Enum.take(@known_page_limit)

    objects =
      Repo.all(from o in Object, where: o.slug in ^slugs and is_nil(o.deleted_at))
      |> Map.new(&{&1.slug, &1})

    ranked_aliases =
      from a in ObjectAlias,
        where: a.object_slug in ^slugs,
        select: %{
          slug: a.object_slug,
          name: a.alias_norm,
          rank: over(row_number(), partition_by: a.object_slug, order_by: a.alias_norm)
        }

    aliases =
      Repo.all(
        from a in subquery(ranked_aliases),
          where: a.rank <= ^@known_page_alias_limit,
          order_by: a.name,
          select: {a.slug, a.name}
      )
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    for slug <- slugs, object = objects[slug], not is_nil(object) do
      %{slug: slug, title: object.title, aliases: Map.get(aliases, slug, [])}
    end
  end

  defp known_pages_section([]), do: ""

  defp known_pages_section(pages) do
    lines =
      Enum.map_join(pages, "\n", fn page ->
        case page.aliases do
          [] -> "- #{page.slug} — #{page.title}"
          aliases -> "- #{page.slug} — #{page.title} (aka: #{Enum.join(aliases, ", ")})"
        end
      end)

    """
    Known pages already in memory that this transcript mentions:
    #{lines}

    An entity in this list must reuse the listed slug in every object_slug,
    link, and timeline reference; do not create a new object item for it.
    Create a new object only for an entity absent from this list and from
    the speaker list.

    """
  end

  defp extraction_prompt(transcript, learning_context, known_pages) do
    speakers =
      learning_context.speaker_uids
      |> Enum.map(fn uid ->
        case Scope.canonical_slug(uid) do
          {:ok, slug} -> "- #{slug} (scope value: principal:#{uid})"
          {:error, _reason} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    installed_types =
      Objects.writable_types()
      |> Enum.map_join(", ", fn type -> "#{type.name} (slug prefix #{type.slug_prefix})" end)

    relation_vocabulary =
      SchemaPacks.relation_vocabulary()
      |> Enum.map_join(", ", fn relation ->
        if relation.inverse,
          do: "#{relation.name} (inverse #{relation.inverse})",
          else: relation.name
      end)

    """
    You extract long-term memory from a chat transcript. Return one JSON
    object: {"items": [...]}. Each item is one of:

    - {"type":"fact","claim":"...","kind":"event|preference|commitment|belief|fact","holder":"<who holds it>","scope":"...","notability":"high|medium|low","confidence":0.75,"context":"...","object_slug":"<optional entity page>","valid_from":"<ISO8601, optional>","provenance":"<quote or paraphrase of the source line>"}
    - {"type":"take","claim":"...","kind":"take|bet|hunch","holder":"<who holds it>","scope":"...","weight":0.55,"provenance":"..."}
    - {"type":"object","slug":"<prefix/name>","object_type":"<installed type>","title":"...","aliases":["..."]}
    - {"type":"timeline","object_slug":"...","date":"YYYY-MM-DD","summary":"...","scope":"..."}
    - {"type":"link","from":"<slug>","to":"<slug>","link_type":"..."}

    Filing rules:
    1. holder is who HOLDS the judgment, not who it is about. "A says B is
       unreliable" is a take held by A, not a fact about B.
    2. One item carries exactly one independently changeable assertion;
       split compound statements.
    3. Relaying another person's judgment keeps their holder; the relayer's
       own endorsement is a separate take with weight at most 0.55.
    4. A fact self-reported by its subject caps confidence at 0.75; only
       independent corroboration justifies more.
    5. weight and confidence are multiples of 0.05.
    6. Skip greetings, transient operational detail, and anything without
       long-term value. Prefer writing nothing over writing noise.
    7. The agent type and agents/ prefix identify this instance's system
       Agent Principals. Their pages are created by the Principal lifecycle.
       Reuse the supplied canonical Agent slugs for references and holders;
       never create an agent object or invent an agents/ slug. Skills, model
       names, tools, automations, and assistant personas are not Principals.
       Use an appropriate writable type, or note when none fits. Attach
       information to the page it describes, not to an Agent acting on it.

    Scope: the source audience is an upper bound. The default scope is
    #{learning_context.default_scope}. Keep that scope unless the content has
    an explicit confidentiality signal (for example "don't tell anyone"); in
    that case, use the narrower "principal:<uid>" of one speaker. Do not use
    "world" for content learned from this conversation. Any other scope value
    falls back to the default.

    Holders are canonical page slugs of the speakers, "world" for common
    knowledge, or an entity page slug. Speakers:
    #{speakers}

    #{known_pages_section(known_pages)}Installed object types (for new object items): #{installed_types}

    Installed relation vocabulary: #{relation_vocabulary}
    Prefer these relation labels when they express the source. Other labels
    remain allowed when none fits; do not invent a relation just to use a label.

    Transcript:
    #{transcript.text}
    """
  end

  defp ensure_enabled do
    if Config.enabled?(), do: :ok, else: {:skip, :brain_disabled}
  end

  defp ensure_extraction_model do
    case Config.extraction_model() do
      nil -> {:skip, :extraction_model_not_configured}
      model -> {:ok, model}
    end
  end

  defp fetch_conversation(conversation_id) do
    case Repo.get_by(Conversation, id: conversation_id) do
      %Conversation{} = channel -> {:ok, channel}
      nil -> {:error, :channel_not_found}
    end
  end

  # Every learning channel registers one Source row idempotently on first
  # trigger. An archived Source stops later learning, so the registered row
  # reads back and gates the run.
  defp ensure_active_source(%Conversation{} = channel) do
    with {:ok, source} <-
           Sources.get_or_create(%{
             upstream_id: channel.id,
             kind: "conversation",
             name: channel.title || channel.id
           }),
         :ok <- Sources.ensure_active(source) do
      {:ok, source}
    else
      {:error, :source_archived} ->
        {:skip, :source_archived}

      {:error, _reason} = error ->
        error
    end
  end

  # The final-commit half of the archive fence: the run start already
  # checked, this locked re-read catches an archive that landed during the
  # model call, following the SourceLearning.commit_run pattern.
  defp lock_active_source(repo, source) do
    case Sources.lock_active(repo, source) do
      {:ok, current} -> {:ok, current}
      {:error, reason} when reason in [:not_found, :source_archived] -> {:error, :source_archived}
    end
  end

  defp ensure_same_watermark(current, current), do: :ok
  defp ensure_same_watermark(_current, _start), do: {:error, :extraction_watermark_moved}

  defp parse_datetime(value) when is_binary(value), do: Ankole.Attrs.parse_datetime(value)

  defp parse_datetime(_value), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_value), do: nil
end
