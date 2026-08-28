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

  import Ecto.Query, warn: false

  alias Ankole.Brain.Access
  alias Ankole.Brain.Config
  alias Ankole.Brain.Links
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.ModelCalls
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Sanitize
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Timeline
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
         {:ok, recall} <-
           Recall.recall(querier_uid, %{query: question, limit: 40}, disclosure: disclosure) do
      evidence = scoped_evidence(recall)

      evidence_claims =
        Enum.map_join(evidence.claims, "\n", fn claim -> "- [#{claim.holder}] #{claim.claim}" end)

      evidence_chunks =
        Enum.map_join(evidence.chunks, "\n\n", fn chunk ->
          "From #{chunk.object_slug}:\n#{chunk.text}"
        end)

      prompt = """
      Answer one question from organizational memory. Reason only from the
      evidence; say what is missing instead of inventing it. Return one JSON
      object: {"title":"...","body":"<markdown analysis>"}

      Question: #{question}

      Evidence claims:
      #{evidence_claims}

      Evidence passages:
      #{evidence_chunks}
      """

      with {:ok, output} <- ModelCalls.complete_json(model, prompt),
           title when is_binary(title) <- output["title"],
           body when is_binary(body) <- output["body"] do
        # The scope enters the slug so one question asked inside two
        # audiences produces two pages: reusing the taken slug would hand
        # the second asker a page they may not read and discard their own.
        hash =
          NativeKernel.xxh3_128_hex(question <> "\n" <> evidence.scope) |> String.slice(0, 10)

        slug = "analysis/synthesis-#{Date.to_iso8601(Date.utc_today())}-#{hash}"

        result =
          case Objects.create_object(
                 %{
                   slug: slug,
                   type: "analysis",
                   title: title,
                   body: Markdoc.wrap(body, evidence.scope)
                 },
                 querier_uid
               ) do
            {:ok, object} ->
              evidence.chunks
              |> Enum.map(& &1.object_slug)
              |> Enum.uniq()
              |> Enum.each(fn evidence_slug ->
                Links.upsert_link(%{
                  from_object_slug: object.slug,
                  to_object_slug: evidence_slug,
                  link_type: "derived_from",
                  link_source: "synthesis"
                })
              end)

              {:ok, object}

            {:error, {:slug_taken, _slug}} ->
              Objects.get_by_slug(slug)

            {:error, _reason} = error ->
              error
          end

        with {:ok, object} <- result do
          {:ok,
           %{
             slug: object.slug,
             title: title,
             body: body,
             audience_scope: evidence.scope,
             dropped_evidence: evidence.dropped
           }}
        end
      else
        {:error, _reason} = error -> error
        _invalid -> {:error, :synthesis_output_invalid}
      end
    end
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

    with {:ok, access} <- Access.for_querier(querier_uid),
         {:ok, visibility} <- LazySkillVisibility.for_querier(querier_uid),
         {:ok, slugs} <- delta_slugs(params[:entity], visibility) do
      base =
        Claim
        |> Access.filter_claims(access)
        |> LazySkillVisibility.filter_claims(visibility)
        |> maybe_slugs([:object_slug], slugs)

      new_claims =
        base
        |> where([claim], claim.created_at >= ^since and claim.created_at <= ^until_at)
        |> order_by([claim], desc: claim.created_at)
        |> limit(50)
        |> Repo.all()

      expired_claims =
        base
        |> where(
          [claim],
          not is_nil(claim.expired_at) and claim.expired_at >= ^since and
            claim.expired_at <= ^until_at
        )
        |> limit(50)
        |> Repo.all()

      timelines =
        Timeline
        |> Access.filter_timelines(access)
        |> LazySkillVisibility.filter_timelines(visibility)
        |> maybe_slugs([:object_slug], slugs)
        |> where([timeline], timeline.created_at >= ^since and timeline.created_at <= ^until_at)
        |> order_by([timeline], desc: timeline.date)
        |> limit(50)
        |> Repo.all()
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
               summary: elem(Sanitize.sanitize(timeline.summary), 0)
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
    scopes =
      Enum.map(recall.claims, & &1.audience_scope) ++
        Enum.map(recall.chunks, & &1.audience_scope)

    case narrowest_scope(scopes) do
      "world" ->
        %{scope: "world", claims: recall.claims, chunks: recall.chunks, dropped: 0}

      scope ->
        keep? = fn row -> row.audience_scope in [scope, "world"] end
        claims = Enum.filter(recall.claims, keep?)
        chunks = Enum.filter(recall.chunks, keep?)

        %{
          scope: scope,
          claims: claims,
          chunks: chunks,
          dropped:
            length(recall.claims) - length(claims) + (length(recall.chunks) - length(chunks))
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
    do: where(query, [row], row.object_slug in ^slugs)

  defp claim_summary(claim) do
    {text, _matched} = Sanitize.sanitize(claim.claim)

    %{
      id: claim.id,
      claim_type: claim.claim_type,
      claim: text,
      kind: claim.kind,
      holder: claim.holder,
      object_slug: claim.object_slug,
      created_at: claim.created_at,
      expired_at: claim.expired_at
    }
  end
end
