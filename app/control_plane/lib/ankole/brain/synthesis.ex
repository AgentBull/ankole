defmodule Ankole.Brain.Synthesis do
  @moduledoc """
  On-demand deduction over the knowledge space.

  `synthesize` answers one question by recalling evidence and writing an
  `analysis` page through the shared contract; it is the tool-shaped form of
  deduction and runs at task time, not in Dreaming. The page carries the
  narrowest audience scope of its evidence, because a conclusion can restate
  the facts it came from. `delta` summarizes what
  changed for one entity or topic between two instants from claim
  bitemporality and timelines, with no model call.
  """

  require Ash.Query

  alias Ankole.Brain.Access
  alias Ankole.Brain.Config
  alias Ankole.Brain.Links
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.ModelCalls
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Contradiction
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Repo

  @type disclosure :: Ankole.Brain.Access.disclosure()

  @doc """
  Synthesizes one analysis page for a question from recalled evidence.

  The page inherits the audience scope of its evidence, so a deduction is
  never readable by more people than the facts it rests on.
  """
  @spec synthesize(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def synthesize(querier_uid, question, opts \\ []) do
    disclosure = Keyword.get(opts, :disclosure, Access.open_disclosure())

    with {:ok, model} <- dreaming_model(),
         {:ok, access} <- Access.for_readers(querier_uid, disclosure),
         {:ok, visibility} <- LazySkillVisibility.for_querier(querier_uid),
         {:ok, recall} <-
           Recall.recall(querier_uid, %{query: question, limit: 40}, disclosure: disclosure) do
      evidence = scoped_evidence(recall)
      forgetting = Config.forgetting()
      now = DateTime.utc_now()
      contradictions = scoped_contradictions(evidence, access, disclosure, visibility)
      prompt = synthesis_prompt(question, evidence, contradictions, forgetting, now)

      with {:ok, output} <- ModelCalls.complete_json(model, prompt, caller: "brain.synthesis"),
           {:ok, clean_title, clean_body, wrapped_body} <-
             validate_synthesis_output(output, evidence.scope),
           {:ok, object} <-
             persist_synthesis_page(
               access,
               disclosure,
               question,
               clean_title,
               wrapped_body,
               evidence
             ) do
        {:ok,
         %{
           slug: object.slug,
           title: clean_title,
           body: clean_body,
           audience_scope: evidence.scope,
           dropped_evidence: evidence.dropped,
           open_contradictions: length(contradictions)
         }}
      else
        {:error, _reason} = error -> error
        _invalid -> {:error, :synthesis_output_invalid}
      end
    end
  end

  defp synthesis_prompt(question, evidence, contradictions, forgetting, now) do
    evidence_claims =
      Enum.map_join(evidence.claims, "\n", &format_evidence_claim(&1, forgetting, now))

    evidence_chunks =
      Enum.map_join(evidence.chunks, "\n\n", fn chunk ->
        "From #{chunk.object_slug}:\n#{chunk.text}"
      end)

    contradiction_block =
      case contradictions do
        [] ->
          "none"

        findings ->
          Enum.map_join(findings, "\n", fn finding ->
            "- [severity #{finding.severity}; axis #{finding.axis || "general"}; verdict #{finding.verdict}] " <>
              "claim #{finding.claim_id} conflicts with [claim #{finding.counterpart.id}; holder #{finding.counterpart.holder}] #{finding.counterpart.claim}"
          end)
      end

    """
    Answer one question from organizational memory. Reason only from the
    evidence; cite supporting page slugs as [[slug]] and name claim holders
    and validity windows where relevant. When open contradictions appear
    below, surface the contested positions explicitly rather than picking one
    silently. Close with a short "## Gaps & Open Questions" section naming
    what evidence is missing or uncertain. Do not emit {% audience %} tags;
    the system scopes the page automatically. Return one JSON object:
    {"title":"...","body":"<markdown analysis>"}

    Question: #{question}

    Evidence claims:
    #{evidence_claims}

    Open contradictions:
    #{contradiction_block}

    Evidence passages:
    #{evidence_chunks}
    """
  end

  defp format_evidence_claim(claim, forgetting, now) do
    {period, strength} =
      case claim.claim_type do
        "fact" ->
          decayed = decayed_fact_confidence(claim, forgetting, now)

          {"valid from #{claim.valid_from}, until #{claim.valid_until || "open"}",
           "effective_confidence #{decayed}"}

        "take" ->
          {"since #{claim.since_date || "not stated"}, until #{claim.until_date || "open"}",
           "weight #{claim.weight}"}
      end

    context_line =
      case Map.get(claim, :context) do
        context when is_binary(context) and context != "" -> "  Context: #{context}\n"
        _blank -> ""
      end

    "- [claim #{claim.id}; page #{claim.object_slug}; #{claim.holder}; #{claim.kind}; #{strength}; #{period}] #{claim.claim}\n" <>
      context_line <> "  Provenance: #{claim.provenance}"
  end

  defp decayed_fact_confidence(claim, forgetting, now) do
    synthetic = %Claim{
      claim_type: :fact,
      kind: claim.kind,
      confidence: claim.confidence || 0.75,
      valid_from: claim.valid_from,
      valid_until: claim.valid_until,
      expired_at: nil
    }

    synthetic
    |> Recall.effective_confidence(forgetting, now)
    |> Float.round(2)
  end

  defp scoped_contradictions(%{claims: []}, _access, _disclosure, _visibility), do: []

  defp scoped_contradictions(evidence, access, disclosure, visibility) do
    claim_ids = Enum.map(evidence.claims, & &1.id)

    open =
      Contradiction
      |> Ash.Query.filter(
        status == :open and (a_claim_id in ^claim_ids or b_claim_id in ^claim_ids)
      )
      |> Ash.Query.sort(created_at: :desc)
      |> Ankole.Ash.read!()

    if open == [] do
      []
    else
      counterpart_ids = open |> Enum.map(&counterpart_id(&1, claim_ids)) |> Enum.uniq()
      allowed_scopes = Enum.uniq([evidence.scope, "world"])

      counterparts =
        Claim
        |> Ash.Query.filter(id in ^counterpart_ids and audience_scope in ^allowed_scopes)
        |> Access.filter_claims(access)
        |> Access.filter_current_claims()
        |> LazySkillVisibility.filter_claims(visibility)
        |> Ankole.Ash.read!()
        |> Access.filter_disclosable(& &1.audience_scope, disclosure)
        |> Map.new(&{&1.id, &1})

      open
      |> Enum.flat_map(fn contradiction ->
        case Map.get(counterparts, counterpart_id(contradiction, claim_ids)) do
          %Claim{} = counterpart ->
            [
              %{
                id: contradiction.id,
                verdict: contradiction.verdict,
                axis: contradiction.axis,
                severity: Atom.to_string(contradiction.severity),
                claim_id: own_id(contradiction, claim_ids),
                counterpart: %{
                  id: counterpart.id,
                  claim: counterpart.claim,
                  holder: counterpart.holder
                }
              }
            ]

          nil ->
            []
        end
      end)
      |> Enum.take(20)
    end
  end

  defp own_id(contradiction, claim_ids) do
    if contradiction.a_claim_id in claim_ids,
      do: contradiction.a_claim_id,
      else: contradiction.b_claim_id
  end

  defp counterpart_id(contradiction, claim_ids) do
    if own_id(contradiction, claim_ids) == contradiction.a_claim_id,
      do: contradiction.b_claim_id,
      else: contradiction.a_claim_id
  end

  defp validate_synthesis_output(%{"title" => title, "body" => body}, scope)
       when is_binary(title) and is_binary(body) do
    clean_title = String.trim(title)

    with true <- clean_title != "",
         {:ok, raw_segments} <- Markdoc.raw_segments(body),
         clean_body = strip_audience_wrappers(body, raw_segments),
         true <- String.trim(clean_body) != "",
         wrapped_body = Markdoc.wrap(clean_body, scope),
         {:ok, [^scope]} <- Markdoc.scopes(wrapped_body) do
      {:ok, clean_title, clean_body, wrapped_body}
    else
      _invalid -> :invalid
    end
  end

  defp validate_synthesis_output(_output, _scope), do: :invalid

  defp strip_audience_wrappers(body, [%{scope: "world", text: body}]), do: body

  defp strip_audience_wrappers(_body, raw_segments) do
    raw_segments
    |> Enum.map_join("", & &1.text)
    |> String.trim()
  end

  defp persist_synthesis_page(access, disclosure, question, title, wrapped_body, evidence) do
    # The scope enters the slug so one question asked inside two audiences
    # produces two pages: reusing the taken slug would hand the second asker
    # a page they may not read and discard their own.
    hash =
      NativeKernel.xxh3_128_hex(question <> "\n" <> evidence.scope) |> String.slice(0, 10)

    slug = "analysis/synthesis-#{Date.to_iso8601(Date.utc_today())}-#{hash}"

    evidence_slugs =
      (Enum.map(evidence.chunks, & &1.object_slug) ++
         Enum.map(evidence.claims, & &1.object_slug))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Repo.transact_top_level(fn ->
      with {:ok, object} <-
             upsert_synthesis_object_in_tx(slug, title, wrapped_body, access, disclosure),
           {:ok, _reconciled} <- Links.reconcile_object_links_in_tx(object.slug),
           :ok <- reconcile_synthesis_derived_links_in_tx(object.slug, evidence_slugs) do
        {:ok, object}
      end
    end)
  end

  defp upsert_synthesis_object_in_tx(slug, title, wrapped_body, access, disclosure) do
    querier_uid = access.querier_uid

    case Objects.lock_object_in_tx(slug) do
      {:error, :not_found} ->
        case Objects.create_object_in_tx(
               %{slug: slug, type: "analysis", title: title, body: wrapped_body},
               querier_uid
             ) do
          {:error, {:slug_taken, _taken}} ->
            create_disambiguated_synthesis_in_tx(slug, title, wrapped_body, querier_uid)

          other ->
            other
        end

      {:ok, %Object{type: "analysis", deleted_at: nil, managed_by_source_id: nil} = existing} ->
        with :ok <- Access.guard_body_replacement(existing.body, access, disclosure) do
          Objects.update_object_in_tx(
            existing.slug,
            %{title: title, body: wrapped_body, expected_content_hash: existing.content_hash},
            querier_uid
          )
        end

      {:ok, %Object{}} ->
        create_disambiguated_synthesis_in_tx(slug, title, wrapped_body, querier_uid)
    end
  end

  defp create_disambiguated_synthesis_in_tx(base_slug, title, wrapped_body, querier_uid) do
    suffix = UUIDv7.autogenerate() |> String.slice(-8, 8)

    Objects.create_object_in_tx(
      %{slug: "#{base_slug}-#{suffix}", type: "analysis", title: title, body: wrapped_body},
      querier_uid
    )
  end

  defp reconcile_synthesis_derived_links_in_tx(slug, evidence_slugs) do
    {:ok, _removed} =
      Link
      |> Ash.Query.filter(
        from_object_slug == ^slug and link_source == "synthesis" and link_type == "derived_from"
      )
      |> Ankole.Ash.destroy_where(:remove)

    evidence_slugs
    |> Enum.reject(&(&1 == slug))
    |> Enum.reduce_while(:ok, fn evidence_slug, :ok ->
      case Links.upsert_link(%{
             from_object_slug: slug,
             to_object_slug: evidence_slug,
             link_type: "derived_from",
             link_source: "synthesis"
           }) do
        {:ok, _link} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Summarizes the changes for one entity or topic between two instants: new
  and expired facts, take movements, and timeline events, under the full
  two-layer filtering. Zero model calls.
  """
  @spec delta(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def delta(querier_uid, params, opts \\ []) do
    disclosure = Keyword.get(opts, :disclosure, Access.open_disclosure())
    since = params[:since] || DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
    until_at = params[:until] || DateTime.utc_now()

    with {:ok, access} <- Access.for_readers(querier_uid, disclosure),
         {:ok, visibility} <- LazySkillVisibility.for_querier(querier_uid),
         {:ok, slugs} <- delta_slugs(params[:entity], visibility) do
      base =
        Claim
        |> Ash.Query.new()
        |> Access.filter_claims(access)
        |> LazySkillVisibility.filter_claims(visibility)
        |> maybe_slugs([:object_slug], slugs)

      new_claims =
        base
        |> Ash.Query.filter(created_at >= ^since and created_at <= ^until_at)
        |> Ash.Query.sort(created_at: :desc)
        |> Ash.Query.limit(50)
        |> Ankole.Ash.read!()

      expired_claims =
        base
        |> Ash.Query.filter(
          not is_nil(expired_at) and expired_at >= ^since and expired_at <= ^until_at
        )
        |> Ash.Query.limit(50)
        |> Ankole.Ash.read!()

      timelines =
        Timeline
        |> Ash.Query.new()
        |> Access.filter_timelines(access)
        |> LazySkillVisibility.filter_timelines(visibility)
        |> maybe_slugs([:object_slug], slugs)
        |> Ash.Query.filter(created_at >= ^since and created_at <= ^until_at)
        |> Ash.Query.sort(date: :desc)
        |> Ash.Query.limit(50)
        |> Ankole.Ash.read!()
        |> Access.filter_disclosable(& &1.audience_scope, disclosure)

      {:ok,
       %{
         since: since,
         until: until_at,
         new_claims:
           new_claims
           |> Access.filter_disclosable(& &1.audience_scope, disclosure)
           |> Enum.map(&claim_summary/1),
         expired_claims:
           expired_claims
           |> Access.filter_disclosable(& &1.audience_scope, disclosure)
           |> Enum.map(&claim_summary/1),
         timeline_events:
           Enum.map(timelines, fn timeline ->
             %{
               object_slug: timeline.object_slug,
               date: timeline.date,
               summary: timeline.summary
             }
           end)
       }}
    end
  end

  defp dreaming_model do
    case Config.dreaming_model() do
      nil -> {:error, :dreaming_model_not_configured}
      model -> {:ok, model}
    end
  end

  # One analysis page carries one audience scope, and a deduction can restate
  # any evidence it saw, so the page takes the narrowest scope present and
  # the evidence outside that scope leaves the prompt. Narrowing the page
  # instead of widening it keeps a private fact from becoming instance-wide
  # knowledge through its own conclusion. `world` evidence always stays:
  # public knowledge inside a narrower page discloses nothing.
  defp scoped_evidence(recall) do
    evidence_chunks = Enum.reject(recall.chunks, &LazySkillVisibility.skill_record?/1)

    scopes =
      Enum.map(recall.claims, & &1.audience_scope) ++
        Enum.map(evidence_chunks, & &1.audience_scope)

    case narrowest_scope(scopes) do
      "world" ->
        %{scope: "world", claims: recall.claims, chunks: evidence_chunks, dropped: 0}

      scope ->
        keep? = fn row -> row.audience_scope in [scope, "world"] end
        claims = Enum.filter(recall.claims, keep?)
        chunks = Enum.filter(evidence_chunks, keep?)

        %{
          scope: scope,
          claims: claims,
          chunks: chunks,
          dropped:
            length(recall.claims) - length(claims) +
              (length(evidence_chunks) - length(chunks))
        }
    end
  end

  # Two scopes that neither contains the other (two Principals, two Groups)
  # have no common narrower value, so the one carrying the most evidence
  # wins and the rest drops. Ranking a Principal below a Group makes the
  # choice deterministic when both are present.
  defp narrowest_scope(scopes) do
    case scopes |> Enum.reject(&(&1 == "world")) |> Enum.frequencies() do
      empty when map_size(empty) == 0 ->
        "world"

      frequencies ->
        frequencies
        |> Enum.min_by(fn {scope, count} -> {scope_rank(scope), -count, scope} end)
        |> elem(0)
    end
  end

  defp scope_rank("principal:" <> _uid), do: 0
  defp scope_rank(_group), do: 1

  # An entity that does not resolve is an explicit error, never a silent
  # unfiltered report.
  defp delta_slugs(nil, _visibility), do: {:ok, nil}
  defp delta_slugs("", _visibility), do: {:ok, nil}

  defp delta_slugs(entity, visibility) do
    case Objects.resolve_reference(entity, lazy_skill_visibility: visibility) do
      {:ok, object} -> {:ok, [object.slug]}
      {:ambiguous, candidates} -> {:error, {:ambiguous_entity, candidates}}
      {:error, :not_found} -> {:error, {:entity_not_found, entity}}
    end
  end

  defp maybe_slugs(query, _fields, nil), do: query

  defp maybe_slugs(query, [:object_slug], slugs),
    do: Ash.Query.filter(query, object_slug in ^slugs)

  defp claim_summary(claim) do
    %{
      id: claim.id,
      claim_type: Atom.to_string(claim.claim_type),
      claim: claim.claim,
      kind: claim.kind,
      holder: claim.holder,
      object_slug: claim.object_slug,
      created_at: claim.created_at,
      expired_at: claim.expired_at
    }
  end
end
