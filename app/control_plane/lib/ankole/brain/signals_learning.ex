defmodule Ankole.Brain.SignalsLearning do
  @moduledoc """
  Batch learning from Signal Channel message slices.

  This is the second first-class write path: input is the channel's raw
  message mirror, independent of Agent turn history. One instance-level task
  processes one slice with `brain.extraction_model`; the same slice is never
  processed per Agent, because the knowledge space is shared. Slice identity
  is a stable version token; real claims and the internal terminal claim
  commit in one final short transaction, so a slice without a matching
  terminal can always rerun safely.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.Links
  alias Ankole.Brain.ModelCalls
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Timelines
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Logging
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry

  @max_slice_entries 200

  @doc """
  Processes the pending slice of one channel. Returns a status map; slices
  that cannot learn (missing model, missing member group, no counterpart)
  report their reason instead of failing.
  """
  @spec process_channel(String.t()) :: {:ok, map()} | {:error, term()}
  def process_channel(channel_id) when is_binary(channel_id) do
    with :ok <- ensure_enabled(),
         {:ok, model} <- ensure_extraction_model(),
         {:ok, channel} <- fetch_channel(channel_id),
         {:ok, learning_context} <- learning_context(channel),
         :ok <- ensure_active_source(channel) do
      case pending_slice(channel_id) do
        [] ->
          {:ok, %{status: :no_pending_entries}}

        entries ->
          token = slice_version_token(channel_id, entries)

          if Claims.extraction_terminal(channel_id, token) do
            {:ok, %{status: :already_processed, token: token}}
          else
            process_slice(channel, learning_context, entries, token, model)
          end
      end
    else
      {:skip, reason} -> {:ok, %{status: :skipped, reason: reason}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the channel's unprocessed entries in stable
  `(first_seen_at, source_entry_id)` order.

  The watermark is the newest terminal claim's boundary: `valid_from` holds
  the arrival time of the last covered entry and `context` its entry id.
  Filtering compares that same total order on the same arrival axis, so a
  late provider delivery (whose `first_seen_at` is assigned at mirror time)
  always lands after the watermark, and entries that share the boundary
  arrival instant are not lost to a strict timestamp comparison. Provider
  timestamps never enter this comparison: they lag arrival by delivery
  latency and would silently drop the tail of every full slice.
  """
  @spec pending_slice(String.t(), pos_integer()) :: [Entry.t()]
  def pending_slice(channel_id, limit \\ @max_slice_entries) do
    watermark = latest_terminal_watermark(channel_id)

    Entry
    |> where([entry], entry.signal_channel_id == ^channel_id)
    |> maybe_after_watermark(watermark)
    |> order_by([entry], asc: entry.first_seen_at, asc: entry.source_entry_id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns whether one channel has unprocessed entries, without loading a
  full slice.
  """
  @spec has_pending_slice?(String.t()) :: boolean()
  def has_pending_slice?(channel_id), do: pending_slice(channel_id, 1) != []

  @doc """
  Computes the stable version token of one slice: the channel plus the
  ordered `source_entry_id + content_hash` sequence.
  """
  @spec slice_version_token(String.t(), [Entry.t()]) :: String.t()
  def slice_version_token(channel_id, entries) do
    canonical =
      entries
      |> Enum.map(fn entry -> "#{entry.source_entry_id}:#{entry.content_hash}" end)
      |> then(fn parts -> Enum.join([channel_id | parts], "\n") end)

    NativeKernel.xxh3_128_hex(canonical)
  end

  @doc """
  Returns the channels whose pending slices exceed the idle threshold, for
  the Self-healing sweep.
  """
  @spec idle_channels_with_pending_slices() :: [String.t()]
  def idle_channels_with_pending_slices do
    idle_seconds = Config.signal_channel_batch_idle_time()
    threshold = DateTime.add(DateTime.utc_now(), -idle_seconds, :second)

    Channel
    |> where([channel], channel.kind in [:im_dm, :im_group])
    |> where([channel], channel.last_seen_at < ^threshold)
    |> select([channel], channel.id)
    |> Repo.all()
    |> Enum.filter(&has_pending_slice?/1)
  end

  # Slice processing

  defp process_slice(channel, learning_context, entries, token, model) do
    transcript = build_transcript(entries)
    boundary = slice_boundary(entries)

    if String.trim(transcript.text) == "" do
      finalize(channel.id, token, :not_applicable, [], learning_context, boundary)
    else
      prompt = extraction_prompt(transcript, learning_context)

      case ModelCalls.complete_json(model, prompt) do
        {:ok, output} ->
          items = List.wrap(output["items"])

          # The input version is recomputed over the same entries after the
          # model call: an in-slice edit or delete during the run writes no
          # terminal and reruns. Entries that only arrived later belong to
          # the next slice and do not invalidate this one — otherwise a
          # continuously active channel could never commit any slice.
          if slice_still_current?(channel.id, entries, token) do
            outcome = if items == [], do: :not_applicable, else: :complete
            finalize(channel.id, token, outcome, items, learning_context, boundary)
          else
            {:ok, %{status: :slice_changed, token: token}}
          end

        {:error, reason} ->
          {:error, {:extraction_failed, reason}}
      end
    end
  end

  # The boundary is the last covered entry in slice order; it becomes the
  # next slice's watermark through the terminal claim.
  defp slice_boundary(entries) do
    last = List.last(entries)
    {last.first_seen_at, last.source_entry_id}
  end

  defp slice_still_current?(channel_id, entries, token) do
    ids = Enum.map(entries, & &1.source_entry_id)

    current_by_id =
      Entry
      |> where([entry], entry.signal_channel_id == ^channel_id)
      |> where([entry], entry.source_entry_id in ^ids)
      |> Repo.all()
      |> Map.new(&{&1.source_entry_id, &1})

    refetched = Enum.map(entries, &Map.get(current_by_id, &1.source_entry_id))

    not Enum.any?(refetched, &is_nil/1) and
      slice_version_token(channel_id, refetched) == token
  end

  # Real memory writes and the terminal claim commit in one final short
  # transaction. Embeddings prepare in one batched call before it, so the
  # transaction holds no network I/O while write-time semantic dedup keeps
  # its vectors. The locked Source re-read is the archive fence: a channel
  # archived during the model call must not gain new memory. Item-level
  # validation rejects stay visible in the report and the log; they do not
  # block the terminal, because the prompt-contract filter is expected to
  # drop garbage and an unwritable item must not wedge the channel forever.
  # Infrastructure failures abort the transaction and leave no terminal.
  defp finalize(channel_id, token, outcome, items, learning_context, boundary) do
    prepared = prepare_embeddings(items)

    result =
      Repo.transact(fn repo ->
        with :ok <- lock_active_source(repo, channel_id) do
          written = write_items(repo, channel_id, items, learning_context, prepared)

          with {:ok, _terminal} <-
                 Claims.write_extraction_terminal(channel_id, token, outcome,
                   repo: repo,
                   boundary: boundary
                 ) do
            {:ok, %{status: outcome, token: token, written: written}}
          end
        end
      end)

    case result do
      {:ok, %{written: written} = report} ->
        if written.rejected > 0 do
          Logging.warning(
            "brain.signals_learning.items_rejected",
            "extraction items failed write validation",
            %{
              channel_id: channel_id,
              token: token,
              rejected: written.rejected,
              reasons: written.reject_reasons
            }
          )
        end

        {:ok, Map.put(report, :pending_remaining, has_pending_slice?(channel_id))}

      {:error, :source_archived} ->
        {:ok, %{status: :skipped, reason: :source_archived}}

      {:error, _reason} = error ->
        error
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
         {:ok, vectors} <- Ankole.Brain.Embeddings.embed_texts(texts),
         {:ok, signature} <- Ankole.Brain.Embeddings.signature() do
      texts |> Enum.zip(Enum.map(vectors, &{&1, signature})) |> Map.new()
    else
      _empty_or_failed -> %{}
    end
  end

  @empty_counts %{claims: 0, objects: 0, timelines: 0, links: 0, rejected: 0, reject_reasons: []}

  defp write_items(repo, channel_id, items, learning_context, prepared) do
    # Objects first: facts, takes, timelines, and links in the same batch
    # may reference pages the model declared later in its output order.
    {object_items, other_items} = Enum.split_with(items, &match?(%{"type" => "object"}, &1))

    counts =
      Enum.reduce(object_items ++ other_items, @empty_counts, fn item, counts ->
        case write_item(repo, channel_id, item, learning_context, prepared) do
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

  defp write_item(repo, _channel_id, %{"type" => "object"} = item, _learning_context, _prepared) do
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

  defp write_item(repo, channel_id, %{"type" => "fact"} = item, learning_context, prepared) do
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
      provenance: item["provenance"] || "signal channel conversation"
    }

    attrs = put_parent(attrs, repo, channel_id, item["object_slug"])

    case Claims.write_fact(attrs, :system,
           repo: repo,
           author_uid: learning_context.author_uid,
           embedding: Map.get(prepared, item["claim"], {nil, nil})
         ) do
      {:ok, _result} -> {:ok, :claims}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp write_item(repo, channel_id, %{"type" => "take"} = item, learning_context, prepared) do
    scope = enforce_scope(item["scope"], learning_context)

    attrs = %{
      claim: item["claim"],
      kind: item["kind"] || "take",
      holder: item["holder"] || "world",
      audience_scope: scope,
      weight: Claims.snap_to_grid(item["weight"]),
      since_date: item["since_date"],
      until_date: item["until_date"],
      provenance: item["provenance"] || "signal channel conversation"
    }

    attrs = put_parent(attrs, repo, channel_id, item["object_slug"])

    case Claims.write_take(attrs, :system,
           repo: repo,
           author_uid: learning_context.author_uid,
           embedding: Map.get(prepared, item["claim"], {nil, nil})
         ) do
      {:ok, _claim} -> {:ok, :claims}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp write_item(repo, _channel_id, %{"type" => "timeline"} = item, learning_context, _prepared) do
    scope = enforce_scope(item["scope"], learning_context)

    attrs = %{
      object_slug: item["object_slug"],
      date: parse_date(item["date"]),
      summary: item["summary"],
      detail: item["detail"] || "",
      provenance: item["provenance"] || "signal channel conversation",
      audience_scope: scope
    }

    case Timelines.write_timeline(attrs, :system,
           repo: repo,
           author_uid: learning_context.author_uid
         ) do
      {:ok, _timeline} -> {:ok, :timelines}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp write_item(repo, _channel_id, %{"type" => "link"} = item, _learning_context, _prepared) do
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

  defp write_item(_repo, _channel_id, item, _learning_context, _prepared),
    do: {:rejected, {:unknown_item_type, item["type"]}}

  defp put_parent(attrs, repo, channel_id, object_slug) do
    case object_slug do
      slug when is_binary(slug) and slug != "" ->
        case Objects.resolve_slug(slug, repo: repo) do
          {:ok, object} -> Map.put(attrs, :object_slug, object.slug)
          {:error, :not_found} -> Map.put(attrs, :signal_gateway_channel_id, channel_id)
        end

      _missing ->
        Map.put(attrs, :signal_gateway_channel_id, channel_id)
    end
  end

  # Learning context (defaults per channel kind)

  # Deterministic default scope and author attribution; this path never
  # reads ConfidentialityPolicy.md.
  defp learning_context(%Channel{kind: :im_group} = channel) do
    case channel.principal_group_id do
      nil ->
        {:skip, :im_group_without_member_group}

      group_id ->
        case Ankole.AuthZ.get_principal_group(group_id) do
          {:ok, group} ->
            {:ok,
             %{
               kind: :im_group,
               default_scope: Scope.group(group.name),
               # Group knowledge is reachable through the member-group scope;
               # the mirrored Agent membership covers the Agents.
               author_uid: nil,
               speaker_uids: speaker_uids(channel.id)
             }}

          {:error, :not_found} ->
            {:skip, :im_group_without_member_group}
        end
    end
  end

  defp learning_context(%Channel{kind: :im_dm} = channel) do
    agent_uid = binding_agent_uid(channel.id)

    counterpart =
      channel.id
      |> speaker_uids()
      |> Enum.reject(&(&1 == agent_uid))
      |> Enum.filter(&human_uid?/1)
      |> List.first()

    cond do
      is_nil(agent_uid) ->
        {:skip, :im_dm_without_binding_agent}

      is_nil(counterpart) ->
        {:skip, :im_dm_without_counterpart}

      true ->
        {:ok,
         %{
           kind: :im_dm,
           default_scope: Scope.principal(counterpart),
           # DM learning is the binding Agent's first-hand conversational
           # memory: author accessibility keeps it recallable for the Agent,
           # and the counterpart reaches it through the scope.
           author_uid: agent_uid,
           speaker_uids: speaker_uids(channel.id)
         }}
    end
  end

  defp learning_context(%Channel{kind: kind}), do: {:skip, {:unsupported_channel_kind, kind}}

  # The model can deviate from the default scope in exactly two directions:
  # up to world for public knowledge, or down to one speaker for content
  # with an explicit confidentiality signal. Everything else clamps to the
  # deterministic default.
  defp enforce_scope(scope, learning_context) do
    allowed =
      ["world", learning_context.default_scope] ++
        Enum.map(learning_context.speaker_uids, &Scope.principal/1)

    if is_binary(scope) and scope in allowed,
      do: scope,
      else: learning_context.default_scope
  end

  defp speaker_uids(channel_id) do
    Entry
    |> where([entry], entry.signal_channel_id == ^channel_id)
    |> select([entry], fragment("?->>'principal_uid'", entry.author))
    |> distinct(true)
    |> Repo.all()
    |> Enum.filter(&is_binary/1)
  end

  defp binding_agent_uid(channel_id) do
    ActorEvent
    |> where([event], event.signal_channel_id == ^channel_id)
    |> order_by([event], desc: event.id)
    |> limit(1)
    |> select([event], event.agent_uid)
    |> Repo.one()
  end

  defp human_uid?(uid) do
    Principal
    |> where([principal], principal.uid == ^uid and principal.type == :human)
    |> Repo.exists?()
  end

  # Transcript and prompt

  defp build_transcript(entries) do
    lines =
      entries
      |> Enum.map(fn entry ->
        speaker = speaker_label(entry)
        text = String.trim(entry.text || "")

        if text == "", do: nil, else: "#{speaker}: #{text}"
      end)
      |> Enum.reject(&is_nil/1)

    %{text: Enum.join(lines, "\n"), entries: entries}
  end

  # The speaker's canonical slug is the holder identity: attribution itself
  # does the perspective separation.
  defp speaker_label(%Entry{author: author}) when is_map(author) do
    case author["principal_uid"] do
      uid when is_binary(uid) ->
        case Scope.canonical_slug(uid) do
          {:ok, slug} -> slug
          {:error, _reason} -> author["display_name"] || uid
        end

      _missing ->
        author["display_name"] || "unknown"
    end
  end

  defp speaker_label(_entry), do: "unknown"

  defp extraction_prompt(transcript, learning_context) do
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
      Ankole.Brain.Schemas.SchemaType
      |> select([type], {type.name, type.slug_prefix})
      |> order_by([type], asc: type.name)
      |> Repo.all()
      |> Enum.map_join(", ", fn {name, prefix} -> "#{name} (slug prefix #{prefix})" end)

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

    Scope: the default scope is #{learning_context.default_scope}. Use
    "world" only for public common knowledge. Use a narrower
    "principal:<uid>" of one speaker only when the content carries an
    explicit confidentiality signal (for example "don't tell anyone").
    Any other scope value falls back to the default.

    Holders are canonical page slugs of the speakers, "world" for common
    knowledge, or an entity page slug. Speakers:
    #{speakers}

    Installed object types (for new object items): #{installed_types}

    Transcript:
    #{transcript.text}
    """
  end

  # Bookkeeping

  defp ensure_enabled do
    if Config.enabled?(), do: :ok, else: {:skip, :brain_disabled}
  end

  defp ensure_extraction_model do
    case Config.extraction_model() do
      nil -> {:skip, :extraction_model_not_configured}
      model -> {:ok, model}
    end
  end

  defp fetch_channel(channel_id) do
    case Repo.get(Channel, channel_id) do
      %Channel{} = channel -> {:ok, channel}
      nil -> {:error, :channel_not_found}
    end
  end

  # Every learning channel registers one Source row idempotently on first
  # trigger. An archived Source stops later learning, so the registered row
  # reads back and gates the run.
  defp ensure_active_source(%Channel{} = channel) do
    Repo.insert!(
      %Source{
        id: UUIDv7.autogenerate(),
        upstream_id: channel.id,
        kind: "signal_channel",
        name: channel.name || channel.id
      },
      on_conflict: :nothing,
      conflict_target: [:kind, :upstream_id]
    )

    case Repo.get_by!(Source, kind: "signal_channel", upstream_id: channel.id) do
      %Source{archived_at: nil} -> :ok
      %Source{} -> {:skip, :source_archived}
    end
  end

  # The final-commit half of the archive fence: the run start already
  # checked, this locked re-read catches an archive that landed during the
  # model call, following the SourceLearning.commit_run pattern.
  defp lock_active_source(repo, channel_id) do
    Source
    |> where([source], source.kind == "signal_channel" and source.upstream_id == ^channel_id)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %Source{archived_at: nil} -> :ok
      %Source{} -> {:error, :source_archived}
      nil -> {:error, :source_archived}
    end
  end

  defp latest_terminal_watermark(channel_id) do
    prefix = Claims.internal_provenance_prefix() <> "%"

    Ankole.Brain.Schemas.Claim
    |> where([claim], claim.signal_gateway_channel_id == ^channel_id)
    |> where([claim], like(claim.provenance, ^prefix))
    |> order_by([claim], desc: claim.valid_from, desc: claim.created_at)
    |> limit(1)
    |> select([claim], {claim.valid_from, claim.context})
    |> Repo.one()
  end

  defp maybe_after_watermark(query, nil), do: query

  # A terminal written before boundaries carried the entry id filters on the
  # arrival time alone; every new terminal stores both halves.
  defp maybe_after_watermark(query, {boundary_at, nil}),
    do: where(query, [entry], entry.first_seen_at > ^boundary_at)

  defp maybe_after_watermark(query, {boundary_at, boundary_entry_id}) do
    where(
      query,
      [entry],
      entry.first_seen_at > ^boundary_at or
        (entry.first_seen_at == ^boundary_at and entry.source_entry_id > ^boundary_entry_id)
    )
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_value), do: nil
end
