defmodule Ankole.Brain.Merge do
  @moduledoc """
  Duplicate-page detection and Console-reviewed merge.

  The Dreaming phase is the mechanical backstop behind the write-time
  known-page injection: it pairs live objects of one type that share a
  normalized alias, and records each pair
  once in `brain_merge_suggestions`. Nothing merges automatically.

  Approval runs one transaction that keeps every attached memory: claims,
  holder attributions, timelines, aliases, and links repoint to the
  surviving page, the duplicate's name stays matchable as a natural alias,
  the duplicate row is deleted, and its slug becomes a `brain_slug_aliases`
  redirect so stored references keep resolving. A generic action on
  `Ankole.Brain.Schemas.MergeSuggestion` owns the transaction of each
  decision.

  The duplicate scan is a read model over pairs of rows (M4), and the
  repoint steps are set maintenance in the owning domain (M8). Both stay SQL
  and are registered in the persistence boundary.
  """

  import Ecto.Query, warn: false
  require Ash.Query

  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.MergeSuggestion
  alias Ankole.Brain.Schemas.Page, as: Object
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Schemas.SlugAlias
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @candidate_scan_limit 200
  @suggestion_batch_limit 50

  @doc """
  Gives the slug, the title, and the type of the page that a suggestion
  names. A missing page keeps only its slug.
  """
  @spec page_summary(String.t()) :: map()
  def page_summary(slug) do
    case Objects.resolve_slug(slug) do
      {:ok, object} ->
        %{
          page_id: object.id,
          slug: object.slug,
          title: object.title,
          type: object.type,
          pod_url:
            AnkoleWeb.PodURL.current_tenant_url(
              AnkoleWeb.PodURL.page_path(object.id, object.title)
            )
        }

      {:error, :not_found} ->
        %{page_id: slug, slug: slug, title: nil, type: nil, pod_url: nil}
    end
  end

  @doc """
  Runs one mechanical duplicate scan and records fresh pairs as pending
  suggestions. Zero model calls; a judged pair (any status) never returns.
  """
  @spec run_phase() :: map()
  def run_phase do
    candidates = alias_candidates()

    fresh =
      candidates
      |> Enum.uniq_by(fn {a, b, _reason} -> {a, b} end)
      |> Enum.take(@suggestion_batch_limit)

    now = DateTime.utc_now(:microsecond)

    written =
      Enum.count(fresh, fn {a, b, reason} ->
        case Ankole.Ash.insert_if_absent(MergeSuggestion, :suggest, %{
               a_slug: a,
               b_slug: b,
               reason: reason,
               created_at: now
             }) do
          {:ok, _suggestion, status} -> status == :created
          {:error, error} -> raise error
        end
      end)

    %{status: :ok, suggested: written, candidates: length(candidates)}
  end

  @doc """
  Approves one pending suggestion and merges the pair in the caller's
  transaction. `attrs.canonical_page_id` names the surviving page and must be
  one of the pair; the other page is the duplicate that merges away.
  """
  @spec approve_in_tx(Ecto.UUID.t(), Ankole.ActorRef.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def approve_in_tx(suggestion_id, decided_by, attrs) do
    Ankole.Files.Nodes.lock_tree()

    with :ok <- Repo.require_transaction(),
         {:ok, suggestion} <- fetch_pending(suggestion_id),
         {:ok, target_slug} <- required_canonical(attrs),
         {:ok, first} <- resolve_live(suggestion.a_slug),
         {:ok, second} <- resolve_live(suggestion.b_slug),
         :ok <- guard_pair_unmanaged(first, second) do
      if first.id == second.id do
        # Both slugs already resolve to one page: an earlier merge or slug
        # redirect settled this pair, so approval only closes the row.
        with {:ok, _suggestion} <-
               Ankole.Ash.update(suggestion, :approve, %{decided_by: decided_by}) do
          {:ok, %{status: :already_merged, canonical_page_id: first.id}}
        end
      else
        with {:ok, canonical, duplicate} <- orient(first, second, target_slug),
             {:ok, canonical, duplicate} <- lock_pair(canonical, duplicate),
             :ok <- guard_pair_live(canonical, duplicate),
             :ok <- guard_pair_unmanaged(canonical, duplicate),
             :ok <- guard_duplicate_mergeable(canonical, duplicate),
             {:ok, _alias} <- keep_duplicate_name(canonical, duplicate),
             {:ok, canonical} <- Objects.get_by_slug(canonical.id),
             {:ok, moved} <- repoint_children(canonical, duplicate),
             :ok <- move_page_children(canonical, duplicate),
             {:ok, _duplicate} <- Objects.soft_delete_in_tx(duplicate.id),
             {:ok, _redirect} <- insert_redirect(canonical, duplicate),
             {:ok, canonical} <-
               consolidate_duplicate_body_in_tx(canonical, duplicate, decided_by),
             {:ok, _suggestion} <-
               Ankole.Ash.update(suggestion, :approve, %{decided_by: decided_by}) do
          {:ok,
           %{
             status: :merged,
             canonical_page_id: canonical.id,
             merged_slug: duplicate.slug,
             moved: moved
           }}
        end
      end
    end
  end

  @doc """
  Rejects one pending suggestion in the caller's transaction; the record
  stays, so the same pair is not suggested again.
  """
  @spec reject_in_tx(Ecto.UUID.t(), Ankole.ActorRef.t()) ::
          {:ok, MergeSuggestion.t()} | {:error, term()}
  def reject_in_tx(suggestion_id, decided_by) do
    with :ok <- Repo.require_transaction(),
         {:ok, suggestion} <- fetch_pending(suggestion_id) do
      Ankole.Ash.update(suggestion, :reject, %{decided_by: decided_by})
    end
  end

  defp alias_candidates do
    ObjectAlias
    |> join(:inner, [x], y in ObjectAlias,
      on:
        x.tenant_id == y.tenant_id and x.alias_norm == y.alias_norm and
          x.subject_page_id < y.subject_page_id
    )
    |> join(:inner, [x, y], a in Object,
      as: :merge_candidate_a,
      on: a.tenant_id == x.tenant_id and a.id == x.subject_page_id
    )
    |> join(:inner, [x, y, a], b in Object,
      as: :merge_candidate_b,
      on: b.tenant_id == y.tenant_id and b.id == y.subject_page_id
    )
    |> join(:inner, [x, y, a, b], type in SchemaType,
      on: type.tenant_id == a.tenant_id and type.name == a.type
    )
    |> where(
      [x, y, a, b, type],
      is_nil(a.deleted_at) and is_nil(b.deleted_at) and is_nil(a.managed_by_source_id) and
        is_nil(b.managed_by_source_id)
    )
    |> where([x, y, a, b, type], a.type == b.type)
    |> merge_scan_scope()
    |> exclude_recorded_and_principal_pairs()
    |> group_by([x, y], [x.subject_page_id, y.subject_page_id])
    |> order_by([x, y], asc: x.subject_page_id, asc: y.subject_page_id)
    |> limit(@candidate_scan_limit)
    |> select([x, y], {x.subject_page_id, y.subject_page_id, min(x.alias_norm)})
    |> Repo.all()
    |> Enum.map(fn {a, b, alias_norm} -> {a, b, ~s(shared alias "#{alias_norm}")} end)
  end

  # Media-primitive pages (media, document, analysis) stay out: each has an
  # owning lifecycle — source relearning and Dreaming synthesis recreate
  # them under their own slugs — so a merge would not survive the owner.
  defp merge_scan_scope(query) do
    where(query, [..., type], type.primitive != "media")
  end

  # The scan limit applies only after pairs that cannot become suggestions
  # leave the query. Otherwise the same judged or Principal-only prefix can
  # occupy every sweep and prevent later candidates from moving forward.
  defp exclude_recorded_and_principal_pairs(query) do
    principal_parents =
      case Ankole.AIAgent.Library.Knowledge.root() do
        {:ok, root} ->
          for name <- ~w(people agents),
              {:ok, node} <- [Ankole.Files.Nodes.child(root.id, name)],
              do: node.id

        {:error, :not_found} ->
          []
      end

    query
    |> where(
      [merge_candidate_a: _a, merge_candidate_b: _b],
      not exists(
        from(suggestion in MergeSuggestion,
          where:
            suggestion.a_slug == fragment("?::text", parent_as(:merge_candidate_a).id) and
              suggestion.b_slug == fragment("?::text", parent_as(:merge_candidate_b).id),
          select: 1
        )
      )
    )
    |> where(
      [merge_candidate_a: a, merge_candidate_b: b],
      not (a.parent_id in ^principal_parents and b.parent_id in ^principal_parents and
             exists(
               from(principal in Principal,
                 where:
                   (principal.type == :human and
                      parent_as(:merge_candidate_a).slug ==
                        fragment("'people/' || ?", principal.uid)) or
                     (principal.type == :agent and
                        parent_as(:merge_candidate_a).slug ==
                          fragment("'agents/' || ?", principal.uid)),
                 select: 1
               )
             ) and
             exists(
               from(principal in Principal,
                 where:
                   (principal.type == :human and
                      parent_as(:merge_candidate_b).slug ==
                        fragment("'people/' || ?", principal.uid)) or
                     (principal.type == :agent and
                        parent_as(:merge_candidate_b).slug ==
                          fragment("'agents/' || ?", principal.uid)),
                 select: 1
               )
             ))
    )
  end

  defp required_canonical(attrs) do
    case attrs[:canonical_page_id] do
      slug when is_binary(slug) and slug != "" -> {:ok, slug}
      _missing -> {:error, :canonical_page_id_required}
    end
  end

  defp resolve_live(slug) do
    with {:ok, object} <- Objects.resolve_slug(slug) do
      case object.deleted_at do
        nil -> {:ok, object}
        _deleted -> {:error, {:object_deleted, object.slug}}
      end
    end
  end

  defp orient(first, second, target_slug) do
    case Objects.resolve_slug(target_slug) do
      {:ok, %Object{id: id}} when id == first.id -> {:ok, first, second}
      {:ok, %Object{id: id}} when id == second.id -> {:ok, second, first}
      _other -> {:error, {:canonical_page_id_not_in_pair, target_slug}}
    end
  end

  defp lock_pair(canonical, duplicate) do
    for id <- Enum.sort([canonical.id, duplicate.id]), do: Ankole.Files.Nodes.lock(id)

    with {:ok, canonical} <- Objects.get_by_slug(canonical.id),
         {:ok, duplicate} <- Objects.get_by_slug(duplicate.id),
         do: {:ok, canonical, duplicate}
  end

  defp guard_pair_live(%Object{deleted_at: nil}, %Object{deleted_at: nil}), do: :ok
  defp guard_pair_live(%Object{}, %Object{}), do: {:error, :not_found}

  defp guard_duplicate_mergeable(_canonical, duplicate) do
    if Objects.canonical_principal_page?(duplicate.id),
      do: {:error, {:principal_canonical_page, duplicate.slug}},
      else: :ok
  end

  defp consolidate_duplicate_body_in_tx(canonical, duplicate, decided_by) do
    xml = "<page>" <> xml_children(canonical.xml) <> xml_children(duplicate.xml) <> "</page>"

    aliases =
      ObjectAlias
      |> Ash.Query.filter(subject_page_id == ^canonical.id)
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.alias_norm)

    metadata =
      canonical.meta
      |> Map.put("tags", Links.tags_for_object(canonical.id))
      |> Map.put("aliases", aliases)

    with {:ok, _} <-
           Ankole.Pod.Knowledge.put_in_tx(
             canonical.id,
             %{xml: xml, metadata: metadata},
             author: decided_by,
             base_revision: canonical.revision
           ),
         do: Objects.get_by_slug(canonical.id)
  end

  defp xml_children("<page />"), do: ""
  defp xml_children("<page>" <> rest), do: String.trim_trailing(rest, "</page>")

  defp move_page_children(canonical, duplicate) do
    duplicate.id
    |> Ankole.Files.Nodes.list_children()
    |> Enum.reduce_while(:ok, fn node, :ok ->
      result =
        with {:ok, old_path} <- Ankole.Files.Nodes.path(node),
             {:ok, moved} <-
               Ankole.Files.Access.update_anchor_in_tx(node, :move, %{
                 parent_id: canonical.id,
                 name: Ankole.Files.Nodes.available_name(canonical.id, node.name, node.id)
               }),
             :ok <- Ankole.Files.ContentOwner.move_node_in_tx(node.id, old_path),
             do: {:ok, moved}

      case result do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp guard_pair_unmanaged(%Object{managed_by_source_id: nil}, %Object{managed_by_source_id: nil}),
       do: :ok

  defp guard_pair_unmanaged(%Object{managed_by_source_id: source_id, slug: slug}, _duplicate)
       when not is_nil(source_id),
       do: {:error, {:library_managed, slug}}

  defp guard_pair_unmanaged(_canonical, %Object{slug: slug}),
    do: {:error, {:library_managed, slug}}

  defp repoint_children(canonical, duplicate) do
    canon = canonical.id
    dup = duplicate.id

    {claims, holders} = Ankole.Brain.Claims.repoint_in_tx(duplicate, canonical)

    redirects =
      SlugAlias
      |> Ash.Query.filter(canonical_page_id == ^dup)
      |> Ankole.Ash.update_where(:repoint, %{canonical_page_id: canon})

    case redirects do
      {:ok, redirects} ->
        timelines = repoint_timelines(canon, dup)
        aliases = repoint_unique_rows("brain_object_aliases", "alias_norm", canon, dup)
        tags = repoint_unique_rows("brain_tags", "tag", canon, dup)
        links = repoint_links(canon, dup)

        {:ok,
         %{
           claims: claims,
           holders: holders,
           redirects: length(redirects),
           timelines: timelines,
           aliases: aliases,
           tags: tags,
           links: links
         }}

      {:error, _error} = error ->
        error
    end
  end

  defp repoint_timelines(canon, dup) do
    params = [Ecto.UUID.dump!(dup), Ecto.UUID.dump!(canon), Ecto.UUID.dump!(Repo.tenant_id!())]

    projected = fn row, field ->
      "CASE WHEN #{row}.#{field} = $1 THEN $2 ELSE #{row}.#{field} END"
    end

    same_source =
      "#{projected.("moved", "source_node_id")} = #{projected.("kept", "source_node_id")}"

    same_subject =
      "#{projected.("moved", "subject_page_id")} IS NOT DISTINCT FROM #{projected.("kept", "subject_page_id")}"

    same_event =
      "#{projected.("moved", "event_page_id")} = #{projected.("kept", "event_page_id")}"

    Repo.query!(
      """
      DELETE FROM brain_timelines moved USING brain_timelines kept
      WHERE moved.tenant_id=$3 AND kept.tenant_id=$3 AND moved.id > kept.id
        AND #{same_subject} AND #{same_source}
        AND moved.date=kept.date AND moved.summary=kept.summary AND moved.provenance=kept.provenance
      """,
      params
    )

    Repo.query!(
      """
      UPDATE brain_timelines moved SET event_page_id=NULL
      WHERE moved.tenant_id=$3 AND moved.event_page_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM brain_timelines kept WHERE kept.tenant_id=$3 AND moved.id > kept.id
          AND #{same_event} AND #{same_source} AND moved.date=kept.date
      )
      """,
      params
    )

    %{num_rows: moved} =
      Repo.query!(
        """
        UPDATE brain_timelines moved
        SET subject_page_id=#{projected.("moved", "subject_page_id")},
            source_node_id=#{projected.("moved", "source_node_id")},
            event_page_id=#{projected.("moved", "event_page_id")}
        WHERE tenant_id=$3 AND ($1 IN (subject_page_id,source_node_id,event_page_id))
        """,
        params
      )

    moved
  end

  defp repoint_unique_rows(table, value_column, canon, dup) do
    Repo.query!(
      """
      DELETE FROM #{table} AS moved
      WHERE moved.tenant_id = $3 AND moved.subject_page_id = $1
        AND EXISTS (
          SELECT 1 FROM #{table} AS kept
          WHERE kept.tenant_id = $3 AND kept.subject_page_id = $2
            AND kept.#{value_column} = moved.#{value_column}
        )
      """,
      [Ecto.UUID.dump!(dup), Ecto.UUID.dump!(canon), Ecto.UUID.dump!(Repo.tenant_id!())]
    )

    %{num_rows: moved} =
      Repo.query!(
        "UPDATE #{table} SET subject_page_id = $2 WHERE tenant_id = $3 AND subject_page_id = $1",
        [Ecto.UUID.dump!(dup), Ecto.UUID.dump!(canon), Ecto.UUID.dump!(Repo.tenant_id!())]
      )

    moved
  end

  @link_key_columns ~w(from_page_id to_page_id link_type link_source origin_page_id)

  defp repoint_links(canon, dup) do
    # Edges inside the merged pair would become self-links; they carry no
    # information once the pair is one page.
    Repo.query!(
      """
      DELETE FROM brain_links
      WHERE tenant_id = $3 AND ((from_page_id = $1 AND to_page_id IN ($1, $2))
         OR (from_page_id = $2 AND to_page_id = $1))
      """,
      [Ecto.UUID.dump!(dup), Ecto.UUID.dump!(canon), Ecto.UUID.dump!(Repo.tenant_id!())]
    )

    Enum.reduce(@link_key_columns -- ~w(link_type link_source), 0, fn column, count ->
      count + repoint_link_column(column, canon, dup)
    end)
  end

  # Repoints one slug column of the edge table, first dropping rows whose
  # full dedup-key twin (equal NULLs equal) already sits on the canonical
  # side.
  defp repoint_link_column(column, canon, dup) do
    twin_match =
      (@link_key_columns -- [column])
      |> Enum.map_join(" AND ", fn key -> "kept.#{key} IS NOT DISTINCT FROM moved.#{key}" end)

    Repo.query!(
      """
      DELETE FROM brain_links AS moved
      WHERE moved.tenant_id = $3 AND moved.#{column} = $1
        AND EXISTS (
          SELECT 1 FROM brain_links AS kept
          WHERE kept.tenant_id = $3 AND kept.#{column} = $2 AND #{twin_match}
        )
      """,
      [Ecto.UUID.dump!(dup), Ecto.UUID.dump!(canon), Ecto.UUID.dump!(Repo.tenant_id!())]
    )

    %{num_rows: moved} =
      Repo.query!(
        "UPDATE brain_links SET #{column} = $2 WHERE tenant_id = $3 AND #{column} = $1",
        [Ecto.UUID.dump!(dup), Ecto.UUID.dump!(canon), Ecto.UUID.dump!(Repo.tenant_id!())]
      )

    moved
  end

  defp keep_duplicate_name(canonical, duplicate) do
    case Links.normalize_alias(duplicate.title || "") do
      "" -> {:ok, :untitled}
      _name -> Links.add_alias_in_tx(canonical.id, duplicate.title)
    end
  end

  defp insert_redirect(canonical, duplicate) do
    with {:ok, node} <- Ankole.Files.Nodes.fetch(duplicate.id),
         {:ok, path} <- Ankole.Files.Nodes.path(node) do
      case Ankole.Brain.Knowledge.brain_path(path) do
        nil ->
          {:ok, :outside_brain_namespace}

        slug ->
          Ankole.Ash.create(SlugAlias, :add, %{
            alias_slug: slug,
            canonical_page_id: canonical.id,
            notes: "merge of duplicate page",
            created_at: DateTime.utc_now(:microsecond)
          })
      end
    end
  end

  defp fetch_pending(suggestion_id) do
    MergeSuggestion
    |> Ash.Query.filter(id == ^suggestion_id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
    |> case do
      %MergeSuggestion{status: :pending} = suggestion -> {:ok, suggestion}
      %MergeSuggestion{} -> {:error, :suggestion_not_pending}
      nil -> {:error, :not_found}
    end
  end
end
