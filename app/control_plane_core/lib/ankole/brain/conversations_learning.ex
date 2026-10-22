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

  Messages, their external references, and Participants are read through
  the Conversations domain. `known_pages/1` is a read model over Objects and
  their aliases (M4) that selects only values.
  """

  import Ecto.Query, warn: false
  require Ash.Expr

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
  alias Ankole.Repo
  alias Ankole.Conversations.Conversation

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

  # The public Messages of one conversation in sequence order, each with its
  # external reference. A withdrawn Message is not a public conversation fact.
  defp observations(conversation_id, query) do
    messages =
      Ankole.Conversations.Domain.list_messages!(
        query:
          [
            filter: [conversation_id: conversation_id],
            filter: not_withdrawn(),
            sort: [seq: :asc]
          ] ++ query
      )

    refs =
      case messages do
        [] ->
          %{}

        messages ->
          [query: [filter: [message_id: [in: Enum.map(messages, & &1.id)]]]]
          |> Ankole.Conversations.Domain.list_external_message_refs!()
          |> Map.new(&{&1.message_id, &1})
      end

    Enum.map(messages, &%{message: &1, external_ref: Map.get(refs, &1.id)})
  end

  # Transitional: the Message calculation `withdrawn` of the Conversations
  # domain replaces this expression.
  defp not_withdrawn do
    Ash.Expr.expr(
      not exists(
        Ankole.Signals.Signal,
        message_id == parent(id) and fragment("? @> '{\"removed\": true}'::jsonb", data)
      )
    )
  end

  defp slice_after(conversation_id, watermark, limit) do
    observations(conversation_id,
      filter: [seq: [greater_than: watermark || 0]],
      limit: limit
    )
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

  @doc """
  Finds idle conversations with Messages beyond their Source watermark and
  gives the creation time of the first pending Message of each.
  """
  def idle_pending_slices do
    threshold =
      DateTime.add(DateTime.utc_now(), -Config.signal_channel_batch_idle_time(), :second)

    # A Message is pending when no conversation Source of its conversation has
    # a watermark at or after its sequence.
    [
      query: [
        filter:
          Ash.Expr.expr(
            (kind == :native or external_kind in [:im_dm, :im_group]) and
              last_activity_at < ^threshold and
              exists(
                Ankole.Conversations.Message,
                conversation_id == parent(id) and ^not_withdrawn() and
                  not exists(
                    Source,
                    kind == "conversation" and
                      upstream_id == fragment("?::text", parent(conversation_id)) and
                      extracted_through_seq >= parent(seq)
                  )
              )
          ),
        select: [:id]
      ]
    ]
    |> Ankole.Conversations.Domain.list_conversations!()
    |> Enum.flat_map(fn conversation ->
      case pending_slice(conversation.id, 1) do
        [%{message: first}] ->
          [%{conversation_id: conversation.id, first_seen_at: first.created_at}]

        [] ->
          []
      end
    end)
  end

  defp process_slice(channel, source, start, learning_context, entries, token, model) do
    transcript = build_transcript(entries)
    boundary = slice_boundary(entries)

    slice = %{
      source: source,
      start: start,
      conversation_id: channel.id,
      token: token,
      learning_context: learning_context,
      boundary: boundary
    }

    if String.trim(transcript.text) == "" do
      finalize(slice, :not_applicable, [])
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
            finalize(slice, outcome, items)
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
      conversation_id
      |> observations(filter: [id: [in: ids]])
      |> Map.new(&{&1.message.id, &1})

    refetched = Enum.map(observations, &Map.get(current, &1.message.id))

    not Enum.any?(refetched, &is_nil/1) and
      slice_version_token(conversation_id, refetched) == token
  end

  # Real memory writes and the Source watermark commit in the final short
  # transaction of the `:finalize_conversation_slice` action. Embeddings
  # prepare in one batched call before it, so the transaction holds no network
  # I/O while write-time semantic dedup keeps its vectors. Mixed item-level
  # validation rejects stay visible in the report and the log. If every
  # non-empty model item is rejected, the transaction rolls back without
  # advancing the watermark, so Oban can retry the slice. Infrastructure
  # failures follow the same rollback contract.
  defp finalize(%{conversation_id: conversation_id, token: token} = slice, outcome, items) do
    result =
      Ankole.Ash.run_action(Source, :finalize_conversation_slice, %{
        slice:
          Map.merge(slice, %{outcome: outcome, items: items, prepared: prepare_embeddings(items)})
      })

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

  @doc false
  # Writes the memory items of one slice and advances the Source watermark in
  # the transaction of the `:finalize_conversation_slice` action. The locked
  # Source re-read is the archive fence: a channel archived during the model
  # call must not gain new memory.
  #
  # An item write gives an error only before its first write (a Fact write
  # that fails after its insert rolls back this transaction), so a rejected
  # item leaves no partial memory and the other items still commit.
  def finalize_in_tx(%{source: source, conversation_id: conversation_id} = slice) do
    with {:ok, %Conversation{}} <- lock_conversation(conversation_id),
         {:ok, current} <- lock_active_source(source),
         :ok <- ensure_source_revision(current, source),
         :ok <- ensure_same_watermark(Sources.extraction_watermark(current), slice.start),
         :ok <- ensure_slice_version_in_tx(slice),
         written =
           write_items(conversation_id, slice.items, slice.learning_context, slice.prepared),
         :ok <- ensure_extraction_written(slice.items, written),
         :ok <- Sources.record_extraction_watermark(Repo, current, slice.boundary) do
      {:ok, %{status: slice.outcome, token: slice.token, written: written}}
    else
      {:ok, nil} -> {:error, :source_archived}
      {:error, _reason} = error -> error
    end
  end

  defp lock_conversation(conversation_id),
    do: Ankole.Conversations.Domain.get_conversation(conversation_id, query: [lock: "FOR SHARE"])

  defp ensure_source_revision(%Source{upstream_revision: revision}, %Source{
         upstream_revision: revision
       }),
       do: :ok

  defp ensure_source_revision(_, _), do: {:error, :slice_changed}

  defp ensure_slice_version_in_tx(
         %{conversation_id: conversation_id, boundary: {_at, seq}} = slice
       ) do
    current =
      observations(conversation_id,
        filter: [seq: [greater_than: slice.start || 0, less_than_or_equal: seq]]
      )

    if slice_version_token(conversation_id, current) == slice.token,
      do: :ok,
      else: {:error, :slice_changed}
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

  defp write_items(conversation_id, items, learning_context, prepared) do
    # Objects first: facts, takes, timelines, and links in the same batch
    # may reference pages the model declared later in its output order.
    {object_items, other_items} = Enum.split_with(items, &match?(%{"type" => "object"}, &1))

    counts =
      Enum.reduce(object_items ++ other_items, @empty_counts, fn item, counts ->
        case write_item(conversation_id, item, learning_context, prepared) do
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

    case Objects.create_object_in_tx(attrs, :system) do
      {:ok, object} ->
        item
        |> Map.get("aliases", [])
        |> List.wrap()
        |> Enum.each(fn alias_text ->
          Links.add_alias(object.slug, alias_text)
        end)

        {:ok, :objects}

      {:error, {:slug_taken, _slug}} ->
        {:ok, :objects}

      {:error, reason} ->
        {:rejected, reason}
    end
  end

  defp write_item(conversation_id, %{"type" => "fact"} = item, learning_context, prepared) do
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

    attrs = put_parent(attrs, conversation_id, item["object_slug"])

    case Claims.write_fact_in_tx(attrs, :system,
           author: learning_context.author,
           embedding: Map.get(prepared, item["claim"], {nil, nil})
         ) do
      {:ok, _result} -> {:ok, :claims}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp write_item(conversation_id, %{"type" => "take"} = item, learning_context, prepared) do
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

    attrs = put_parent(attrs, conversation_id, item["object_slug"])

    case Claims.write_take(attrs, :system,
           author: learning_context.author,
           embedding: Map.get(prepared, item["claim"], {nil, nil})
         ) do
      {:ok, _claim} -> {:ok, :claims}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp write_item(
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

    case Timelines.write_timeline_in_tx(attrs, :system, author: learning_context.author) do
      {:ok, _timeline} -> {:ok, :timelines}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp write_item(
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

    case Links.upsert_link(attrs) do
      {:ok, _link} -> {:ok, :links}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp write_item(_conversation_id, item, _learning_context, _prepared),
    do: {:rejected, {:unknown_item_type, item["type"]}}

  defp put_parent(attrs, conversation_id, object_slug) do
    case object_slug do
      slug when is_binary(slug) and slug != "" ->
        case Objects.resolve_slug(slug) do
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
      [
        query: [
          filter: [conversation_id: conversation.id, role: :agent],
          select: [:principal_uid]
        ]
      ]
      |> Ankole.Conversations.Domain.list_participants!()
      |> Enum.map(& &1.principal_uid)
      |> Enum.find(&match?({:ok, _principal}, Ankole.Principals.get_principal(&1)))

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
    [
      query: [
        filter: [conversation_id: conversation_id, author_uid: [is_nil: false]],
        distinct: [:author_uid],
        select: [:author_uid]
      ]
    ]
    |> Ankole.Conversations.Domain.list_messages!()
    |> Enum.map(& &1.author_uid)
  end

  defp human_uid?(uid), do: match?({:ok, %{type: :human}}, Ankole.Principals.get_principal(uid))

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

    titles =
      Repo.all(
        from o in Object,
          where: o.slug in ^slugs and is_nil(o.deleted_at),
          select: {o.slug, o.title}
      )
      |> Map.new()

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

    for slug <- slugs, title = titles[slug], not is_nil(title) do
      %{slug: slug, title: title, aliases: Map.get(aliases, slug, [])}
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
    case Ankole.Conversations.Domain.get_conversation(conversation_id) do
      {:ok, %Conversation{} = channel} -> {:ok, channel}
      _missing -> {:error, :channel_not_found}
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
  defp lock_active_source(source) do
    case Sources.lock_active(Repo, source) do
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
