defmodule Ankole.Brain.Dreaming do
  @moduledoc """
  Instance-level maintenance of the knowledge space.

  Phases run in order; one failing phase is recorded and the round
  continues. Every product goes through the shared write contracts, so a
  rerun is idempotent: consolidation marks its inputs, analysis pages use
  deterministic slugs, contradiction pairs and pending suggestions have
  unique keys, and grading updates in place. Model phases use
  `brain.dreaming_model` and skip with a report when it is absent.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Calibration
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.Links
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.ModelCalls
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Contradiction
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Schemas.Tag
  alias Ankole.Brain.Timelines
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Repo

  @consolidate_similarity 0.85
  @consolidate_min_bucket 3
  @consolidate_min_oldest_hours 24
  @consolidate_bucket_limit 200
  @patterns_window_days 30
  @patterns_min_items 5
  @contradiction_batch_limit 50
  @contradiction_min_confidence 0.7
  @contradiction_verdicts ~w(
    no_contradiction contradiction temporal_regression temporal_supersession
    evolution negation_artifact
  )
  @suggest_subtype_threshold 20
  @suggest_type_threshold 100

  @high_emotion_tags MapSet.new(~w(
    family marriage wedding loss death grief relationship love mental-health
    health illness birth children kids parents
  ))

  @phases [
    :consolidate,
    :patterns,
    :extract_links,
    :emotional_weight,
    :grade_takes,
    :calibration_profile,
    :contradictions,
    :schema_suggest,
    :merge_suggest,
    :purge,
    :skill_lessons
  ]

  @doc """
  Runs one Dreaming round and returns per-phase reports.

  One round at a time is a property of the Oban job that calls this: the job
  stays unique across every non-terminal state, which is a database-backed
  mutex across nodes. A session advisory lock cannot own this — its acquire
  and release land on different pooled connections, so the lock leaks and
  every later round reports a phantom concurrent run.
  """
  @spec run() :: {:ok, map()} | {:error, term()}
  def run do
    if Config.enabled?() do
      report =
        Map.new(@phases, fn phase ->
          {phase, run_phase(phase)}
        end)

      {:ok, report}
    else
      {:ok, %{status: :brain_disabled}}
    end
  end

  # A phase boundary is a real failure boundary: one broken phase must not
  # block the rest of the round.
  defp run_phase(phase) do
    case phase do
      :consolidate -> phase_consolidate()
      :patterns -> phase_patterns()
      :extract_links -> phase_extract_links()
      :emotional_weight -> phase_emotional_weight()
      :grade_takes -> Calibration.grade_takes()
      :calibration_profile -> Calibration.calibration_profile()
      :contradictions -> phase_contradictions()
      :schema_suggest -> phase_schema_suggest()
      :merge_suggest -> Ankole.Brain.Merge.run_phase()
      :purge -> phase_purge()
      :skill_lessons -> Ankole.Brain.SkillLessons.run_phase()
    end
  rescue
    error -> %{status: :failed, error: Exception.message(error)}
  catch
    :exit, reason -> %{status: :failed, error: inspect(reason)}
  end

  # Phase 1: consolidate

  # Bucket qualification runs as one aggregate query, so fact embeddings
  # only load for buckets that can actually promote; facts stuck in small
  # buckets cost the aggregate scan and nothing more per round.
  @doc false
  def phase_consolidate do
    threshold =
      DateTime.add(DateTime.utc_now(:microsecond), -@consolidate_min_oldest_hours * 3600, :second)

    bucket_keys =
      Claim
      |> consolidation_candidates()
      |> group_by(
        [claim],
        [claim.object_slug, claim.holder, claim.audience_scope, claim.embedding_signature]
      )
      |> having(
        [claim],
        count(claim.id) >= @consolidate_min_bucket and min(claim.created_at) <= ^threshold
      )
      |> select(
        [claim],
        {claim.object_slug, claim.holder, claim.audience_scope, claim.embedding_signature}
      )
      |> limit(@consolidate_bucket_limit)
      |> Repo.all()

    promoted =
      Enum.reduce(bucket_keys, 0, fn {object_slug, holder, scope, signature}, count ->
        facts =
          Claim
          |> consolidation_candidates()
          |> where([claim], claim.object_slug == ^object_slug)
          |> where([claim], claim.holder == ^holder)
          |> where([claim], claim.audience_scope == ^scope)
          |> where([claim], claim.embedding_signature == ^signature)
          |> Repo.all()

        facts
        |> cluster_by_similarity(@consolidate_similarity)
        |> Enum.filter(&(length(&1) >= 2))
        |> Enum.reduce(count, fn cluster, count ->
          case promote_cluster(object_slug, scope, cluster) do
            :ok -> count + 1
            :skip -> count
          end
        end)
      end)

    %{status: :ok, promoted: promoted, buckets: length(bucket_keys)}
  end

  @doc "Lists contradiction findings and loads their Claims for the Console read model."
  @spec list_contradictions_for_console(String.t(), keyword()) :: [map()]
  def list_contradictions_for_console(status, opts)
      when is_binary(status) and is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)

    contradictions =
      Contradiction
      |> where([contradiction], contradiction.status == ^status)
      |> order_by([contradiction], desc: contradiction.created_at)
      |> limit(^limit)
      |> Repo.all()

    claims_by_id =
      contradictions
      |> Enum.flat_map(&[&1.a_claim_id, &1.b_claim_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> claims_by_id()

    Enum.map(contradictions, fn contradiction ->
      %{
        contradiction: contradiction,
        a_claim: Map.get(claims_by_id, contradiction.a_claim_id),
        b_claim: Map.get(claims_by_id, contradiction.b_claim_id)
      }
    end)
  end

  defp consolidation_candidates(query) do
    query
    |> Claims.current_external_facts()
    |> where([claim], is_nil(claim.consolidated_at))
    |> where([claim], not is_nil(claim.embedding))
    |> where([claim], not is_nil(claim.embedding_signature))
    |> where([claim], not is_nil(claim.object_slug))
  end

  defp claims_by_id([]), do: %{}

  defp claims_by_id(ids) do
    Claim
    |> where([claim], claim.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # Greedy clustering: newest first, each fact joins the first cluster whose
  # head is at least the threshold similar.
  defp cluster_by_similarity(facts, threshold) do
    facts
    |> Enum.sort_by(&DateTime.to_unix(&1.valid_from || &1.created_at), :desc)
    |> Enum.reduce([], fn fact, clusters ->
      index =
        Enum.find_index(clusters, fn [head | _rest] ->
          cosine(head.embedding, fact.embedding) >= threshold
        end)

      case index do
        nil -> clusters ++ [[fact]]
        index -> List.update_at(clusters, index, &(&1 ++ [fact]))
      end
    end)
  end

  defp cosine(a, b) do
    a = Pgvector.to_list(a)
    b = Pgvector.to_list(b)

    {dot, norm_a, norm_b} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, na, nb} ->
        {dot + x * y, na + x * x, nb + y * y}
      end)

    if norm_a == 0.0 or norm_b == 0.0,
      do: 0.0,
      else: dot / (:math.sqrt(norm_a) * :math.sqrt(norm_b))
  end

  # The take insert and the consolidation marks commit together: a crash
  # between them would leave unmarked facts that re-promote a duplicate take
  # on the next round. The embedding prepares before the transaction.
  defp promote_cluster(object_slug, scope, cluster) do
    top = Enum.max_by(cluster, & &1.confidence)
    average = Enum.sum(Enum.map(cluster, & &1.confidence)) / length(cluster)
    weight = Float.round(average * 20) / 20
    prepared = Claims.prepare_embedding(top.claim)

    result =
      Repo.transact(fn repo ->
        with {:ok, take} <-
               Claims.write_take(
                 %{
                   object_slug: object_slug,
                   claim: top.claim,
                   kind: "take",
                   holder: "brain",
                   audience_scope: scope,
                   weight: min(max(weight, 0.0), 1.0),
                   provenance: "dreaming consolidation of #{length(cluster)} facts"
                 },
                 :system,
                 repo: repo,
                 embedding: prepared
               ) do
          now = DateTime.utc_now(:microsecond)
          ids = Enum.map(cluster, & &1.id)

          Claim
          |> where([claim], claim.id in ^ids)
          |> repo.update_all(set: [consolidated_at: now, consolidated_into: take.id])

          {:ok, take}
        end
      end)

    case result do
      {:ok, _take} -> :ok
      {:error, _reason} -> :skip
    end
  end

  # Phase 2: patterns

  @doc false
  def phase_patterns do
    case Config.dreaming_model() do
      nil ->
        %{status: :skipped, reason: :dreaming_model_not_configured}

      model ->
        window_start = DateTime.add(DateTime.utc_now(), -@patterns_window_days * 86_400, :second)

        buckets =
          Claim
          |> Claims.current_external_facts()
          |> where([claim], claim.created_at >= ^window_start)
          |> where([claim], claim.notability == "high")
          |> where([claim], not is_nil(claim.object_slug))
          |> Repo.all()
          |> Enum.group_by(& &1.audience_scope)
          |> Enum.filter(fn {_scope, claims} -> length(claims) >= @patterns_min_items end)

        pages =
          Enum.count(buckets, fn {scope, claims} ->
            synthesize_pattern_page(model, scope, claims) == :ok
          end)

        %{status: :ok, pages: pages, buckets: length(buckets)}
    end
  end

  defp synthesize_pattern_page(model, scope, claims) do
    date = Date.to_iso8601(Date.utc_today())
    scope_hash = NativeKernel.xxh3_128_hex(scope) |> String.slice(0, 8)
    slug = "analysis/dreaming-#{date}-#{scope_hash}"

    if Repo.exists?(Object |> where([object], object.slug == ^slug)) do
      :skip
    else
      evidence =
        claims
        |> Enum.take(40)
        |> Enum.map_join("\n", fn claim -> "- [#{claim.holder}] #{claim.claim}" end)

      prompt = """
      You are the Dreaming maintenance of an organizational memory. Below are
      recent notable facts sharing one audience. Write one short synthesis in
      Markdown that connects them into higher-level observations useful for
      current work (for example how an external event chain affects an
      ongoing task). Do not invent facts. Return one JSON object:
      {"title": "...", "body": "..."}

      Facts:
      #{evidence}
      """

      with {:ok, output} <- ModelCalls.complete_json(model, prompt),
           title when is_binary(title) <- output["title"],
           body when is_binary(body) <- output["body"] do
        case Objects.create_object(
               %{slug: slug, type: "analysis", title: title, body: Markdoc.wrap(body, scope)},
               :system
             ) do
          {:ok, _object} ->
            claims
            |> Enum.map(& &1.object_slug)
            |> Enum.uniq()
            |> Enum.each(fn evidence_slug ->
              Links.upsert_link(%{
                from_object_slug: slug,
                to_object_slug: evidence_slug,
                link_type: "derived_from",
                link_source: "dreaming"
              })
            end)

            :ok

          {:error, _reason} ->
            :skip
        end
      else
        _invalid -> :skip
      end
    end
  end

  # Phase 3: link and timeline extraction

  # The phase contract covers wikilinks, name mentions, and timeline events.
  # The timeline half needs the model, so a missing model skips the whole
  # phase without advancing the watermark: `links_extracted_at` keeps one
  # meaning — phase 3 fully processed this body state.
  @doc false
  def phase_extract_links do
    case Config.dreaming_model() do
      nil ->
        %{status: :skipped, reason: :dreaming_model_not_configured}

      model ->
        objects =
          Object
          |> where([object], is_nil(object.deleted_at))
          |> where(
            [object],
            is_nil(object.links_extracted_at) or object.links_extracted_at < object.updated_at
          )
          |> limit(200)
          |> Repo.all()

        timelines =
          Enum.reduce(objects, 0, fn object, count ->
            count + extract_object_links(model, object)
          end)

        %{status: :ok, objects: length(objects), timelines: timelines}
    end
  end

  defp extract_object_links(model, %Object{} = object) do
    # Wikilinks materialize as markdown edges through the alias redirect.
    object.body
    |> Markdoc.wikilinks()
    |> Enum.each(fn target ->
      Links.upsert_link(%{
        from_object_slug: object.slug,
        to_object_slug: target,
        link_type: "",
        link_source: "markdown",
        origin_object_slug: object.slug,
        origin_field: "body",
        resolution_type: "qualified"
      })
    end)

    # Name mentions resolve through normalized aliases.
    mention_targets(object)
    |> Enum.each(fn target ->
      Links.upsert_link(%{
        from_object_slug: object.slug,
        to_object_slug: target,
        link_type: "mentions",
        link_source: "mentions",
        link_kind: "plain",
        origin_object_slug: object.slug,
        origin_field: "body",
        resolution_type: "unqualified"
      })
    end)

    case extract_object_timelines(model, object) do
      {:ok, written} ->
        object
        |> Ecto.Changeset.change(links_extracted_at: DateTime.utc_now(:microsecond))
        |> Repo.update!()

        written

      :skip ->
        # A failed extraction leaves the watermark, so the object retries
        # next round; the link upserts above are idempotent.
        0
    end
  end

  # Timeline events extract per Markdoc segment, so each written row
  # inherits the scope of the passage it came from. The timeline dedup key
  # (object, date, summary, provenance) makes reruns idempotent.
  defp extract_object_timelines(model, %Object{} = object) do
    case Markdoc.segments(object.body) do
      {:ok, segments} ->
        segments
        |> Enum.filter(fn segment -> String.trim(segment.text) != "" end)
        |> Enum.reduce_while({:ok, 0}, fn segment, {:ok, count} ->
          case extract_segment_timelines(model, object, segment) do
            {:ok, written} -> {:cont, {:ok, count + written}}
            :skip -> {:halt, :skip}
          end
        end)

      {:error, _reason} ->
        # An unparseable stored body has no segments to extract; the stamp
        # advances so the object cannot wedge the phase forever.
        {:ok, 0}
    end
  end

  defp extract_segment_timelines(model, object, segment) do
    prompt = """
    Extract dated events from one memory page passage. Only an event with an
    explicit calendar date qualifies; do not infer dates. Return one JSON
    object: {"items":[{"date":"YYYY-MM-DD","summary":"one line","detail":"optional expansion"}]}
    Return {"items":[]} when the passage has none.

    Page: #{object.title}
    Passage:
    #{segment.text}
    """

    case ModelCalls.complete_json(model, prompt) do
      {:ok, output} ->
        written =
          output["items"]
          |> List.wrap()
          |> Enum.count(fn item ->
            with date_text when is_binary(date_text) <- item["date"],
                 {:ok, date} <- Date.from_iso8601(date_text),
                 summary when is_binary(summary) <- item["summary"] do
              attrs = %{
                object_slug: object.slug,
                date: date,
                summary: summary,
                detail: item["detail"] || "",
                provenance: "dreaming timeline extraction",
                audience_scope: segment.scope
              }

              match?({:ok, _timeline}, Timelines.write_timeline(attrs, :system))
            else
              _invalid -> false
            end
          end)

        {:ok, written}

      {:error, _reason} ->
        :skip
    end
  end

  defp mention_targets(%Object{} = object) do
    object.body
    |> Links.match_aliases_in_text()
    |> Enum.reject(&(&1 == object.slug))
  end

  # Phase 4: emotional weight

  # Only the scoring fields load (never the bodies or vectors), changed
  # weights write individually, and one statement stamps the whole pass:
  # per-row stamp writes made this phase a daily N-round-trip rewrite.
  @doc false
  def phase_emotional_weight do
    objects =
      Object
      |> where([object], is_nil(object.deleted_at))
      |> select([object], %{
        id: object.id,
        slug: object.slug,
        emotional_weight: object.emotional_weight
      })
      |> Repo.all()

    takes_by_object =
      Claim
      |> where([claim], claim.claim_type == "take" and claim.active == true)
      |> where([claim], not is_nil(claim.object_slug))
      |> select([claim], %{
        object_slug: claim.object_slug,
        weight: claim.weight,
        holder: claim.holder
      })
      |> Repo.all()
      |> Enum.group_by(& &1.object_slug)

    tags_by_object =
      Tag
      |> select([tag], {tag.object_slug, tag.tag})
      |> Repo.all()
      |> Enum.group_by(fn {slug, _tag} -> slug end, fn {_slug, tag} -> tag end)

    now = DateTime.utc_now(:microsecond)

    changed =
      Enum.flat_map(objects, fn object ->
        takes = Map.get(takes_by_object, object.slug, [])
        tags = Map.get(tags_by_object, object.slug, [])
        weight = emotional_weight(tags, takes)

        if abs(weight - object.emotional_weight) > 1.0e-9,
          do: [{object.id, weight}],
          else: []
      end)

    Enum.each(changed, fn {id, weight} ->
      Object
      |> where([object], object.id == ^id)
      |> Repo.update_all(set: [emotional_weight: weight, salience_touched_at: now])
    end)

    Object
    |> where([object], is_nil(object.deleted_at))
    |> Repo.update_all(set: [emotional_weight_recomputed_at: now])

    %{status: :ok, updated: length(changed), objects: length(objects)}
  end

  @doc """
  GBrain emotional-weight formula: high-emotion tag adds 0.5, active-take
  density adds 0.1 per take capped at 0.3, average take weight scales into
  0..0.1, and the share of takes held by organization members scales into
  0..0.1; the sum clamps to 0..1.
  """
  @spec emotional_weight([String.t()], [%{weight: float(), holder: String.t()}]) :: float()
  def emotional_weight(tags, takes) do
    tag_boost =
      if Enum.any?(tags, &MapSet.member?(@high_emotion_tags, String.downcase(&1))),
        do: 0.5,
        else: 0.0

    take_density = min(length(takes) * 0.1, 0.3)

    average_weight =
      case takes do
        [] -> 0.0
        takes -> Enum.sum(Enum.map(takes, &min(max(&1.weight, 0.0), 1.0))) / length(takes) * 0.1
      end

    member_ratio =
      case takes do
        [] ->
          0.0

        takes ->
          members =
            Enum.count(takes, fn take ->
              String.starts_with?(take.holder, "people/") or
                String.starts_with?(take.holder, "agents/")
            end)

          members / length(takes) * 0.1
      end

    (tag_boost + take_density + average_weight + member_ratio)
    |> max(0.0)
    |> min(1.0)
  end

  # Phase 7: contradictions

  @doc false
  def phase_contradictions do
    case Config.dreaming_model() do
      nil ->
        %{status: :skipped, reason: :dreaming_model_not_configured}

      model ->
        pairs = contradiction_candidates()
        written = Enum.count(pairs, &(probe_pair(model, &1) == :ok))
        %{status: :ok, pairs: length(pairs), written: written}
    end
  end

  @doc false
  def contradiction_candidates do
    existing =
      Contradiction
      |> select([c], {c.a_claim_id, c.b_claim_id})
      |> Repo.all()
      |> MapSet.new()

    Claim
    |> Claims.current_external_facts()
    |> where([claim], not is_nil(claim.object_slug))
    |> order_by([claim], desc: claim.created_at)
    |> limit(400)
    |> Repo.all()
    |> Enum.group_by(& &1.object_slug)
    |> Enum.flat_map(fn {_slug, claims} ->
      for a <- claims, b <- claims, a.id < b.id, a.holder == b.holder, do: {a, b}
    end)
    |> Enum.reject(fn {a, b} ->
      MapSet.member?(existing, {a.id, b.id}) or MapSet.member?(existing, {b.id, a.id})
    end)
    |> Enum.take(@contradiction_batch_limit)
  end

  defp probe_pair(model, {a, b}) do
    prompt = """
    Compare two memory claims about one entity from one holder and decide
    whether they contradict. Most pairs do not: use the verdict
    "no_contradiction" for unrelated or compatible claims. Return one JSON
    object:
    {"verdict":"no_contradiction|contradiction|temporal_regression|temporal_supersession|evolution|negation_artifact",
     "axis":"one-sentence axis of disagreement",
     "severity":"info|low|medium|high",
     "confidence":0.8}

    Claim A (valid from #{a.valid_from}): #{a.claim}
    Claim B (valid from #{b.valid_from}): #{b.claim}
    """

    with {:ok, output} <- ModelCalls.complete_json(model, prompt),
         verdict when verdict in @contradiction_verdicts <- output["verdict"],
         confidence when is_number(confidence) <- output["confidence"] do
      record_contradiction_verdict(a.id, b.id, verdict, confidence, output)
    else
      # A malformed model answer records nothing; the pair re-probes.
      _invalid -> :skip
    end
  end

  # Every valid verdict is recorded, so a judged pair never re-probes: claim
  # rows are immutable (supersession inserts new rows), one verdict per id
  # pair stays valid forever, and without a record the same newest pairs
  # would burn the same model calls every round. Negative and low-confidence
  # verdicts land as dismissed rows — remembered, outside the open triage
  # queue.
  @doc false
  def record_contradiction_verdict(a_claim_id, b_claim_id, verdict, confidence, output) do
    status =
      if verdict != "no_contradiction" and confidence >= @contradiction_min_confidence,
        do: "open",
        else: "dismissed"

    %Contradiction{
      id: UUIDv7.autogenerate(),
      a_claim_id: a_claim_id,
      b_claim_id: b_claim_id,
      verdict: verdict,
      axis: to_string(output["axis"] || ""),
      severity: normalize_severity(output["severity"]),
      confidence: min(max(confidence * 1.0, 0.0), 1.0),
      status: status,
      created_at: DateTime.utc_now(:microsecond)
    }
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:a_claim_id, :b_claim_id])

    :ok
  end

  defp normalize_severity(severity) when severity in ["info", "low", "medium", "high"],
    do: severity

  defp normalize_severity(_severity), do: "info"

  @doc """
  Records an operator verdict for one open contradiction.

  Only an `open` row is decidable: automatic negative verdicts land as
  `dismissed` and stay out of triage, and a decided row must not flip again.
  """
  @spec decide_contradiction(Ecto.UUID.t(), String.t(), String.t() | nil) ::
          {:ok, Contradiction.t()} | {:error, :not_found | :conflict | term()}
  def decide_contradiction(contradiction_id, status, resolution_note)
      when status in ["resolved", "dismissed"] do
    Repo.transact(fn repo ->
      Contradiction
      |> where([contradiction], contradiction.id == ^contradiction_id)
      |> lock("FOR UPDATE")
      |> repo.one()
      |> case do
        %Contradiction{status: "open"} = contradiction ->
          contradiction
          |> Ecto.Changeset.change(
            status: status,
            resolution_note: resolution_note,
            decided_at: DateTime.utc_now(:microsecond)
          )
          |> repo.update()

        %Contradiction{} ->
          {:error, :conflict}

        nil ->
          {:error, :not_found}
      end
    end)
  end

  # Phase 8: schema suggestions

  @doc false
  def phase_schema_suggest do
    vocabulary_terms = vocabulary_terms()

    installed =
      SchemaType
      |> Repo.all()
      |> Enum.flat_map(fn type -> [type.name | type.subtypes] end)
      |> MapSet.new()

    usable_terms = Enum.reject(vocabulary_terms, &MapSet.member?(installed, &1))

    usage =
      Tag
      |> where([tag], tag.tag in ^usable_terms)
      |> group_by([tag], tag.tag)
      |> select([tag], {tag.tag, count(tag.object_slug, :distinct)})
      |> Repo.all()
      |> Map.new()

    subtype_usage =
      Object
      |> where([object], is_nil(object.deleted_at))
      |> where([object], object.subtype in ^usable_terms)
      |> group_by([object], object.subtype)
      |> select([object], {object.subtype, count(object.id)})
      |> Repo.all()

    combined =
      Enum.reduce(subtype_usage, usage, fn {term, count}, acc ->
        Map.update(acc, term, count, &(&1 + count))
      end)

    suggested =
      Enum.count(combined, fn {term, count} ->
        cond do
          count >= @suggest_type_threshold ->
            insert_suggestion(term, "new_type", count) == :ok

          count >= @suggest_subtype_threshold ->
            insert_suggestion(term, "new_subtype", count) == :ok

          true ->
            false
        end
      end)

    %{status: :ok, suggested: suggested, terms: map_size(combined)}
  end

  defp insert_suggestion(term, kind, count) do
    rejected_before =
      SchemaSuggestion
      |> where([s], s.term == ^term and s.kind == ^kind and s.status == "rejected")
      |> Repo.exists?()

    if rejected_before do
      :skip
    else
      threshold =
        if kind == "new_type", do: @suggest_type_threshold, else: @suggest_subtype_threshold

      %SchemaSuggestion{
        id: UUIDv7.autogenerate(),
        kind: kind,
        term: term,
        evidence_count: count,
        rationale:
          "The vocabulary term \"#{term}\" names #{count} pages, at or above the #{threshold}-page promotion threshold.",
        status: "pending",
        created_at: DateTime.utc_now(:microsecond)
      }
      |> Repo.insert(on_conflict: :nothing)

      :ok
    end
  end

  @doc false
  @spec vocabulary_terms() :: [String.t()]
  defdelegate vocabulary_terms, to: Ankole.Brain.Vocabulary, as: :terms

  # Phase 9: purge

  @doc false
  def phase_purge do
    ttl_hours = Map.get(Config.forgetting(), "purge_soft_delete_ttl_hours", 72)
    threshold = DateTime.add(DateTime.utc_now(), -round(ttl_hours * 3600), :second)

    {purged, _rows} =
      Object
      |> where([object], not is_nil(object.deleted_at))
      |> where([object], object.deleted_at < ^threshold)
      # A soft-deleted library-managed page is a withdrawn projection, not a
      # forgotten memory: purge would destroy the instance periphery attached
      # to its slug, and re-enabling the shipped set restores the page.
      |> where([object], is_nil(object.managed_by_source_id))
      |> Repo.delete_all()

    # Chunks of soft-deleted objects survive until this hard delete; expired
    # facts and superseded claims are never hard-deleted.
    %{status: :ok, purged: purged}
  end
end
