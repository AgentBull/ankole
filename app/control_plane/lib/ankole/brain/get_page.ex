defmodule Ankole.Brain.GetPage do
  @moduledoc """
  Full-page reads with two-layer filtering.

  Reference resolution goes through `Objects.resolve_reference/2`; ambiguity
  returns candidates instead of guessing. The rendered page prunes the
  Markdoc body by the querier's reachable set, then by disclosure, and keeps
  the remaining text in original order. Page metadata (slug, title, type,
  existence) stays instance-visible.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Access
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Sanitize
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Contradiction
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.Tag
  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Brain.Config
  alias Ankole.Repo

  @type disclosure :: Ankole.Brain.Access.disclosure()

  @doc """
  Reads one page by slug or natural-language name for one querier.

  Returns `{:ok, page}`, `{:ambiguous, candidates}` when the name maps to
  several objects, or `{:error, :not_found}`.
  """
  @spec get_page(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:ambiguous, [map()]} | {:error, term()}
  def get_page(querier_uid, reference, opts \\ []) do
    disclosure = Keyword.get(opts, :disclosure, Access.open_disclosure())

    with {:ok, access} <- Access.for_querier(querier_uid),
         {:ok, visibility} <- LazySkillVisibility.for_querier(querier_uid) do
      case Objects.resolve_reference(reference, lazy_skill_visibility: visibility) do
        {:ok, object} ->
          {:ok, render_page(object, access, disclosure, visibility)}

        {:ambiguous, candidates} ->
          {:ambiguous, candidates}

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Reads one page unfiltered for Console administration. Admin management
  reads the complete current state; the search preview is the surface for
  per-principal projections.
  """
  @spec get_page_admin(String.t()) :: {:ok, map()} | {:ambiguous, [map()]} | {:error, term()}
  def get_page_admin(reference) do
    case Objects.resolve_reference(reference) do
      {:ok, object} ->
        facts = admin_facts(object)
        takes = admin_takes(object)

        {:ok,
         Map.merge(page_shell(object, %LazySkillVisibility{}), %{
           rendered: render_markdoc(object, object.body),
           library_managed: object.managed_by_source_id != nil,
           facts: facts,
           takes: takes,
           contradictions:
             page_contradictions(
               claim_ids(facts, takes),
               fn _counterpart -> true end,
               %LazySkillVisibility{}
             ),
           timelines: admin_timelines(object)
         })}

      other ->
        other
    end
  end

  defp admin_facts(object) do
    Claim
    |> where([claim], claim.object_slug == ^object.slug)
    |> where([claim], claim.claim_type == "fact")
    |> order_by([claim], desc: claim.valid_from)
    |> Repo.all()
    |> Enum.map(fn claim ->
      %{
        id: claim.id,
        claim: claim.claim,
        kind: claim.kind,
        holder: claim.holder,
        notability: claim.notability,
        confidence: claim.confidence,
        valid_from: claim.valid_from,
        valid_until: claim.valid_until,
        expired_at: claim.expired_at,
        superseded_by: claim.superseded_by,
        provenance: claim.provenance,
        audience_scope: claim.audience_scope,
        author_uid: claim.author_uid
      }
    end)
  end

  defp admin_takes(object) do
    Claim
    |> where([claim], claim.object_slug == ^object.slug)
    |> where([claim], claim.claim_type == "take")
    |> order_by([claim], desc: claim.created_at)
    |> Repo.all()
    |> Enum.map(fn claim ->
      %{
        id: claim.id,
        claim: claim.claim,
        kind: claim.kind,
        holder: claim.holder,
        weight: claim.weight,
        active: claim.active,
        since_date: claim.since_date,
        until_date: claim.until_date,
        graded_quality: claim.graded_quality,
        graded_confidence: claim.graded_confidence,
        graded_at: claim.graded_at,
        resolved_quality: claim.resolved_quality,
        resolved_outcome: claim.resolved_outcome,
        resolved_at: claim.resolved_at,
        superseded_by: claim.superseded_by,
        provenance: claim.provenance,
        audience_scope: claim.audience_scope,
        author_uid: claim.author_uid
      }
    end)
  end

  defp admin_timelines(object) do
    Timeline
    |> where([timeline], timeline.object_slug == ^object.slug)
    |> order_by([timeline], desc: timeline.date)
    |> Repo.all()
    |> Enum.map(fn timeline ->
      %{
        id: timeline.id,
        date: timeline.date,
        summary: timeline.summary,
        detail: timeline.detail,
        provenance: timeline.provenance,
        event_object_slug: timeline.event_object_slug,
        audience_scope: timeline.audience_scope,
        author_uid: timeline.author_uid
      }
    end)
  end

  # Rendering

  defp render_page(%Object{} = object, access, disclosure, visibility) do
    keep = fn scope ->
      Access.scope_reachable?(access, scope) and Access.disclosable?(scope, disclosure)
    end

    body =
      case Markdoc.prune(object.body, keep) do
        {:ok, pruned} -> pruned
        # A stored body that no longer parses is projected empty instead of
        # leaking unfiltered content.
        {:error, _reason} -> ""
      end

    {sanitized_body, _matched} = Sanitize.sanitize(body)

    facts = page_facts(object, access, disclosure)
    takes = page_takes(object, access, disclosure)

    keep_counterpart = fn %Claim{} = counterpart ->
      Access.reachable?(access, %{
        audience_scope: counterpart.audience_scope,
        author_uid: counterpart.author_uid
      }) and Access.disclosable?(counterpart.audience_scope, disclosure)
    end

    Map.merge(page_shell(object, visibility), %{
      rendered: render_markdoc(object, sanitized_body),
      facts: facts,
      takes: takes,
      contradictions: page_contradictions(claim_ids(facts, takes), keep_counterpart, visibility),
      timelines: page_timelines(object, access, disclosure)
    })
  end

  # The scope-independent page projection: metadata is instance-visible, so
  # the filtered and the admin page share it.
  defp page_shell(%Object{} = object, visibility) do
    %{
      slug: object.slug,
      type: object.type,
      subtype: object.subtype,
      title: object.title,
      deleted: object.deleted_at != nil,
      effective_date: object.effective_date,
      content_hash: object.content_hash,
      meta: object.meta,
      links: page_links(object, visibility),
      tags: page_tags(object)
    }
  end

  defp claim_ids(facts, takes), do: Enum.map(facts, & &1.id) ++ Enum.map(takes, & &1.id)

  # Open contradiction findings annotate the page's own claims, so a reader
  # sees that a recalled fact is contested instead of trusting it blindly.
  # The counterpart claim passes the caller's keep check: the filtered page
  # applies the two-layer filter so a contradiction row cannot leak a claim
  # the querier cannot reach, and the admin page keeps everything.
  defp page_contradictions(claim_ids, keep_counterpart?, visibility) do
    if claim_ids == [] do
      []
    else
      visible_claim_ids =
        Claim
        |> LazySkillVisibility.filter_claims(visibility)
        |> select([claim], claim.id)

      Contradiction
      |> where([contradiction], contradiction.status == "open")
      |> where(
        [contradiction],
        (contradiction.a_claim_id in ^claim_ids and
           contradiction.b_claim_id in subquery(visible_claim_ids)) or
          (contradiction.b_claim_id in ^claim_ids and
             contradiction.a_claim_id in subquery(visible_claim_ids))
      )
      |> order_by([contradiction], desc: contradiction.created_at)
      |> limit(20)
      |> Repo.all()
      |> Enum.flat_map(fn contradiction ->
        own_id =
          if contradiction.a_claim_id in claim_ids,
            do: contradiction.a_claim_id,
            else: contradiction.b_claim_id

        counterpart_id =
          if own_id == contradiction.a_claim_id,
            do: contradiction.b_claim_id,
            else: contradiction.a_claim_id

        with %Claim{} = counterpart <- Repo.get(Claim, counterpart_id),
             true <- keep_counterpart?.(counterpart) do
          {text, _matched} = Sanitize.sanitize(counterpart.claim)

          [
            %{
              id: contradiction.id,
              verdict: contradiction.verdict,
              axis: contradiction.axis,
              severity: contradiction.severity,
              claim_id: own_id,
              counterpart: %{id: counterpart.id, claim: text, holder: counterpart.holder}
            }
          ]
        else
          _unreachable -> []
        end
      end)
    end
  end

  # The full document is a template projection of the database current
  # state: frontmatter from the row, then the pruned body.
  defp render_markdoc(%Object{} = object, body) do
    frontmatter =
      ["---", "slug: #{object.slug}", "type: #{object.type}"] ++
        subtype_line(object.subtype) ++ ["---", ""]

    Enum.join(frontmatter, "\n") <> "# " <> object.title <> "\n\n" <> body
  end

  defp subtype_line(nil), do: []
  defp subtype_line(subtype), do: ["subtype: #{subtype}"]

  defp page_facts(object, access, disclosure) do
    forgetting = Config.forgetting()
    now = DateTime.utc_now()

    Claim
    |> where([claim], claim.object_slug == ^object.slug)
    |> where([claim], claim.claim_type == "fact" and is_nil(claim.expired_at))
    |> Access.filter_claims(access)
    |> order_by([claim], desc: claim.valid_from)
    |> Repo.all()
    |> Access.filter_disclosable(& &1.audience_scope, disclosure)
    |> Enum.map(fn claim ->
      {text, _matched} = Sanitize.sanitize(claim.claim)

      %{
        id: claim.id,
        claim: text,
        kind: claim.kind,
        holder: claim.holder,
        notability: claim.notability,
        confidence: claim.confidence,
        effective_confidence: Recall.effective_confidence(claim, forgetting, now),
        valid_from: claim.valid_from,
        valid_until: claim.valid_until,
        provenance: claim.provenance,
        audience_scope: claim.audience_scope
      }
    end)
  end

  defp page_takes(object, access, disclosure) do
    Claim
    |> where([claim], claim.object_slug == ^object.slug)
    |> where([claim], claim.claim_type == "take" and claim.active == true)
    |> Access.filter_claims(access)
    |> order_by([claim], desc: claim.weight)
    |> Repo.all()
    |> Access.filter_disclosable(& &1.audience_scope, disclosure)
    |> Enum.map(fn claim ->
      {text, _matched} = Sanitize.sanitize(claim.claim)

      %{
        id: claim.id,
        claim: text,
        kind: claim.kind,
        holder: claim.holder,
        weight: claim.weight,
        since_date: claim.since_date,
        until_date: claim.until_date,
        provenance: claim.provenance,
        audience_scope: claim.audience_scope
      }
    end)
  end

  defp page_timelines(object, access, disclosure) do
    Timeline
    |> where([timeline], timeline.object_slug == ^object.slug)
    |> Access.filter_timelines(access)
    |> order_by([timeline], desc: timeline.date)
    |> Repo.all()
    |> Access.filter_disclosable(& &1.audience_scope, disclosure)
    |> Enum.map(fn timeline ->
      {summary, _matched} = Sanitize.sanitize(timeline.summary)
      {detail, _matched} = Sanitize.sanitize(timeline.detail || "")

      %{
        id: timeline.id,
        date: timeline.date,
        summary: summary,
        detail: detail,
        provenance: timeline.provenance,
        event_object_slug: timeline.event_object_slug,
        audience_scope: timeline.audience_scope
      }
    end)
  end

  defp page_links(object, visibility) do
    outgoing =
      Link
      |> where([link], link.from_object_slug == ^object.slug)
      |> LazySkillVisibility.filter_links(visibility)
      |> Repo.all()

    incoming =
      Link
      |> where([link], link.to_object_slug == ^object.slug)
      |> LazySkillVisibility.filter_links(visibility)
      |> Repo.all()

    %{
      outgoing:
        Enum.map(outgoing, fn link ->
          %{to: link.to_object_slug, link_type: link.link_type, context: link.context}
        end),
      incoming:
        Enum.map(incoming, fn link ->
          %{from: link.from_object_slug, link_type: link.link_type, context: link.context}
        end)
    }
  end

  defp page_tags(object) do
    Tag
    |> where([tag], tag.object_slug == ^object.slug)
    |> order_by([tag], asc: tag.tag)
    |> select([tag], tag.tag)
    |> Repo.all()
  end
end
