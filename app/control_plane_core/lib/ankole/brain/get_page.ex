defmodule Ankole.Brain.GetPage do
  @moduledoc """
  Full-page reads with two-layer filtering.

  Reference resolution goes through `Objects.resolve_reference/2`; ambiguity
  returns candidates instead of guessing. The rendered page prunes the
  Markdoc body by the querier's reachable set, then by disclosure, and keeps
  the remaining text in original order. Page metadata (slug, title, type,
  existence) stays instance-visible.
  """

  require Ash.Query

  alias Ankole.Brain.Access
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Contradiction
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Brain.Config

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

    with {:ok, access} <- Access.for_readers(querier_uid, disclosure),
         {:ok, visibility} <- LazySkillVisibility.for_querier(querier_uid) do
      case Objects.resolve_reference(reference, lazy_skill_visibility: visibility) do
        # A forgotten (soft-deleted) page leaves ordinary recall, so the model
        # read must not return its body, timelines, or links either; only the
        # Console admin path (get_page_admin/1) sees soft-deleted pages so an
        # operator can restore them inside the purge window.
        {:ok, %Object{deleted_at: deleted_at}} when not is_nil(deleted_at) ->
          {:error, :not_found}

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
        editability = Objects.editability(object)

        {:ok,
         Map.merge(page_shell(object, %LazySkillVisibility{}), %{
           body: object.body,
           rendered: render_markdoc(object, object.body),
           library_managed: object.managed_by_source_id != nil,
           editable: editability.editable,
           edit_block_reason: editability.edit_block_reason,
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
    |> Ash.Query.filter(object_slug == ^object.slug and claim_type == :fact)
    |> Ash.Query.sort(valid_from: :desc)
    |> Ankole.Ash.read!()
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
        author: claim.author && Map.from_struct(claim.author)
      }
    end)
  end

  defp admin_takes(object) do
    Claim
    |> Ash.Query.filter(object_slug == ^object.slug and claim_type == :take)
    |> Ash.Query.sort(created_at: :desc)
    |> Ankole.Ash.read!()
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
        author: claim.author && Map.from_struct(claim.author)
      }
    end)
  end

  defp admin_timelines(object) do
    Timeline
    |> Ash.Query.filter(object_slug == ^object.slug)
    |> Ash.Query.sort(date: :desc)
    |> Ankole.Ash.read!()
    |> Enum.map(fn timeline ->
      %{
        id: timeline.id,
        date: timeline.date,
        summary: timeline.summary,
        detail: timeline.detail,
        provenance: timeline.provenance,
        event_object_slug: timeline.event_object_slug,
        audience_scope: timeline.audience_scope,
        author: timeline.author && Map.from_struct(timeline.author)
      }
    end)
  end

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

    facts = page_facts(object, access, disclosure)
    takes = page_takes(object, access, disclosure)

    keep_counterpart = fn %Claim{} = counterpart ->
      Access.reachable?(access, %{
        audience_scope: counterpart.audience_scope,
        author: counterpart.author
      }) and Access.disclosable?(counterpart.audience_scope, disclosure)
    end

    Map.merge(page_shell(object, visibility), %{
      rendered: render_markdoc(object, body),
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
  # The counterpart claim must be visible (live parent, lazy Skill
  # visibility) and pass the caller's keep check: the filtered page applies
  # the two-layer filter so a contradiction row cannot leak a claim the
  # querier cannot reach, and the admin page keeps everything.
  defp page_contradictions(claim_ids, keep_counterpart?, visibility) do
    if claim_ids == [] do
      []
    else
      open =
        Contradiction
        |> Ash.Query.filter(
          status == :open and (a_claim_id in ^claim_ids or b_claim_id in ^claim_ids)
        )
        |> Ash.Query.sort(created_at: :desc)
        |> Ankole.Ash.read!()

      counterpart_ids = open |> Enum.map(&counterpart_id(&1, claim_ids)) |> Enum.uniq()

      counterparts =
        Claim
        |> Ash.Query.filter(id in ^counterpart_ids and live_parent?)
        |> LazySkillVisibility.filter_claims(visibility)
        |> Ankole.Ash.read!()
        |> Map.new(&{&1.id, &1})

      open
      |> Enum.filter(&Map.has_key?(counterparts, counterpart_id(&1, claim_ids)))
      |> Enum.take(20)
      |> Enum.flat_map(fn contradiction ->
        counterpart = Map.fetch!(counterparts, counterpart_id(contradiction, claim_ids))

        if keep_counterpart?.(counterpart) do
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
        else
          []
        end
      end)
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
    |> Ash.Query.filter(
      object_slug == ^object.slug and claim_type == :fact and is_nil(expired_at)
    )
    |> Access.filter_claims(access)
    |> Ash.Query.sort(valid_from: :desc)
    |> Ankole.Ash.read!()
    |> Access.filter_disclosable(& &1.audience_scope, disclosure)
    |> Enum.map(fn claim ->
      %{
        id: claim.id,
        claim: claim.claim,
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
    |> Ash.Query.filter(object_slug == ^object.slug and claim_type == :take and active == true)
    |> Access.filter_claims(access)
    |> Ash.Query.sort(weight: :desc)
    |> Ankole.Ash.read!()
    |> Access.filter_disclosable(& &1.audience_scope, disclosure)
    |> Enum.map(fn claim ->
      %{
        id: claim.id,
        claim: claim.claim,
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
    |> Ash.Query.filter(object_slug == ^object.slug)
    |> Access.filter_timelines(access)
    |> Ash.Query.sort(date: :desc)
    |> Ankole.Ash.read!()
    |> Access.filter_disclosable(& &1.audience_scope, disclosure)
    |> Enum.map(fn timeline ->
      %{
        id: timeline.id,
        date: timeline.date,
        summary: timeline.summary,
        detail: timeline.detail || "",
        provenance: timeline.provenance,
        event_object_slug: timeline.event_object_slug,
        audience_scope: timeline.audience_scope
      }
    end)
  end

  defp page_links(object, visibility) do
    outgoing =
      Link
      |> Ash.Query.filter(from_object_slug == ^object.slug)
      |> LazySkillVisibility.filter_links(visibility)
      |> Ankole.Ash.read!()

    incoming =
      Link
      |> Ash.Query.filter(to_object_slug == ^object.slug)
      |> LazySkillVisibility.filter_links(visibility)
      |> Ankole.Ash.read!()

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

  defp page_tags(object), do: Ankole.Brain.Links.tags_for_object(object.slug)
end
