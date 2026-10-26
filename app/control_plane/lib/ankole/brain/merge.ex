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

  alias Ankole.Brain.Chunks
  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.MergeSuggestion
  alias Ankole.Brain.Schemas.Object
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
      {:ok, object} -> %{slug: object.slug, title: object.title, type: object.type}
      {:error, :not_found} -> %{slug: slug, title: nil, type: nil}
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
  transaction. `attrs.canonical_slug` names the surviving page and must be
  one of the pair; the other page is the duplicate that merges away.
  """
  @spec approve_in_tx(Ecto.UUID.t(), Ankole.ActorRef.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def approve_in_tx(suggestion_id, decided_by, attrs) do
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
          {:ok, %{status: :already_merged, canonical_slug: first.slug}}
        end
      else
        with {:ok, canonical, duplicate} <- orient(first, second, target_slug),
             {:ok, canonical, duplicate} <- lock_pair(canonical, duplicate),
             :ok <- guard_duplicate_mergeable(duplicate),
             {:ok, moved} <- repoint_children(canonical, duplicate),
             {:ok, _alias} <- keep_duplicate_name(canonical, duplicate),
             {:ok, _duplicate} <- Ankole.Ash.destroy(duplicate, :merge_duplicate),
             {:ok, _redirect} <- insert_redirect(canonical, duplicate),
             {:ok, canonical} <- Objects.refresh_content_hash_in_tx(canonical),
             {:ok, _object} <- Chunks.reconcile_in_tx(canonical),
             {:ok, _suggestion} <-
               Ankole.Ash.update(suggestion, :approve, %{decided_by: decided_by}) do
          {:ok,
           %{
             status: :merged,
             canonical_slug: canonical.slug,
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
          x.object_slug < y.object_slug
    )
    |> join(:inner, [x, y], a in Object,
      as: :merge_candidate_a,
      on: a.tenant_id == x.tenant_id and a.slug == x.object_slug
    )
    |> join(:inner, [x, y, a], b in Object,
      as: :merge_candidate_b,
      on: b.tenant_id == y.tenant_id and b.slug == y.object_slug
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
    |> group_by([x, y], [x.object_slug, y.object_slug])
    |> order_by([x, y], asc: x.object_slug, asc: y.object_slug)
    |> limit(@candidate_scan_limit)
    |> select([x, y], {x.object_slug, y.object_slug, min(x.alias_norm)})
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
    query
    |> where(
      [merge_candidate_a: _a, merge_candidate_b: _b],
      not exists(
        from(suggestion in MergeSuggestion,
          where:
            suggestion.a_slug == parent_as(:merge_candidate_a).slug and
              suggestion.b_slug == parent_as(:merge_candidate_b).slug,
          select: 1
        )
      )
    )
    |> where(
      [merge_candidate_a: _a, merge_candidate_b: _b],
      not (exists(
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
    case attrs[:canonical_slug] do
      slug when is_binary(slug) and slug != "" -> {:ok, slug}
      _missing -> {:error, :canonical_slug_required}
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
      _other -> {:error, {:canonical_slug_not_in_pair, target_slug}}
    end
  end

  defp lock_pair(canonical, duplicate) do
    locked =
      Object
      |> Ash.Query.filter(slug in ^[canonical.slug, duplicate.slug])
      |> Ash.Query.sort(slug: :asc)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read!()
      |> Map.new(&{&1.slug, &1})

    with %Object{} = canonical <- Map.get(locked, canonical.slug) || {:error, :not_found},
         %Object{} = duplicate <- Map.get(locked, duplicate.slug) || {:error, :not_found} do
      {:ok, canonical, duplicate}
    end
  end

  defp guard_duplicate_mergeable(%Object{} = duplicate) do
    cond do
      Objects.canonical_principal_page?(duplicate.slug) ->
        {:error, {:principal_canonical_page, duplicate.slug}}

      String.trim(duplicate.body) != "" ->
        # A written body cannot merge mechanically; the operator moves the
        # text first, then approves. Extraction-created duplicates — the
        # class this queue exists for — carry empty bodies.
        {:error, {:merge_body_not_blank, duplicate.slug}}

      true ->
        :ok
    end
  end

  defp guard_pair_unmanaged(%Object{managed_by_source_id: nil}, %Object{managed_by_source_id: nil}),
       do: :ok

  defp guard_pair_unmanaged(%Object{managed_by_source_id: source_id, slug: slug}, _duplicate)
       when not is_nil(source_id),
       do: {:error, {:library_managed, slug}}

  defp guard_pair_unmanaged(_canonical, %Object{slug: slug}),
    do: {:error, {:library_managed, slug}}

  defp repoint_children(canonical, duplicate) do
    canon = canonical.slug
    dup = duplicate.slug

    {claims, holders} = Ankole.Brain.Claims.repoint_in_tx(dup, canon)

    redirects =
      SlugAlias
      |> Ash.Query.filter(canonical_slug == ^dup)
      |> Ankole.Ash.update_where(:repoint, %{canonical_slug: canon})

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
    # A row whose (date, summary, provenance) twin already exists on the
    # canonical page is the duplicate this merge removes.
    Repo.query!(
      """
      DELETE FROM brain_timelines AS moved
      WHERE moved.tenant_id = $3 AND moved.object_slug = $1
        AND EXISTS (
          SELECT 1 FROM brain_timelines AS kept
          WHERE kept.tenant_id = $3 AND kept.object_slug = $2
            AND kept.date = moved.date
            AND kept.summary = moved.summary
            AND kept.provenance = moved.provenance
        )
      """,
      [dup, canon, Ecto.UUID.dump!(Repo.tenant_id!())]
    )

    # Event back-references follow their foreign key's nilify semantics when
    # repointing would collide with the one-event-per-day key.
    Repo.query!(
      """
      UPDATE brain_timelines AS moved SET event_object_slug = NULL
      WHERE moved.tenant_id = $3 AND moved.event_object_slug = $1
        AND EXISTS (
          SELECT 1 FROM brain_timelines AS kept
          WHERE kept.tenant_id = $3 AND kept.event_object_slug = $2 AND kept.date = moved.date
        )
      """,
      [dup, canon, Ecto.UUID.dump!(Repo.tenant_id!())]
    )

    Repo.query!(
      "UPDATE brain_timelines SET event_object_slug = $2 WHERE tenant_id = $3 AND event_object_slug = $1",
      [dup, canon, Ecto.UUID.dump!(Repo.tenant_id!())]
    )

    %{num_rows: moved} =
      Repo.query!(
        "UPDATE brain_timelines SET object_slug = $2 WHERE tenant_id = $3 AND object_slug = $1",
        [dup, canon, Ecto.UUID.dump!(Repo.tenant_id!())]
      )

    moved
  end

  defp repoint_unique_rows(table, value_column, canon, dup) do
    Repo.query!(
      """
      DELETE FROM #{table} AS moved
      WHERE moved.tenant_id = $3 AND moved.object_slug = $1
        AND EXISTS (
          SELECT 1 FROM #{table} AS kept
          WHERE kept.tenant_id = $3 AND kept.object_slug = $2
            AND kept.#{value_column} = moved.#{value_column}
        )
      """,
      [dup, canon, Ecto.UUID.dump!(Repo.tenant_id!())]
    )

    %{num_rows: moved} =
      Repo.query!(
        "UPDATE #{table} SET object_slug = $2 WHERE tenant_id = $3 AND object_slug = $1",
        [dup, canon, Ecto.UUID.dump!(Repo.tenant_id!())]
      )

    moved
  end

  @link_key_columns ~w(from_object_slug to_object_slug link_type link_source origin_object_slug)

  defp repoint_links(canon, dup) do
    # Edges inside the merged pair would become self-links; they carry no
    # information once the pair is one page.
    Repo.query!(
      """
      DELETE FROM brain_links
      WHERE tenant_id = $3 AND ((from_object_slug = $1 AND to_object_slug IN ($1, $2))
         OR (from_object_slug = $2 AND to_object_slug = $1))
      """,
      [dup, canon, Ecto.UUID.dump!(Repo.tenant_id!())]
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
      [dup, canon, Ecto.UUID.dump!(Repo.tenant_id!())]
    )

    %{num_rows: moved} =
      Repo.query!(
        "UPDATE brain_links SET #{column} = $2 WHERE tenant_id = $3 AND #{column} = $1",
        [dup, canon, Ecto.UUID.dump!(Repo.tenant_id!())]
      )

    moved
  end

  defp keep_duplicate_name(canonical, duplicate) do
    case Links.normalize_alias(duplicate.title || "") do
      "" -> {:ok, :untitled}
      _name -> Links.add_alias(canonical.slug, duplicate.title)
    end
  end

  defp insert_redirect(canonical, duplicate) do
    Ankole.Ash.create(SlugAlias, :add, %{
      alias_slug: duplicate.slug,
      canonical_slug: canonical.slug,
      notes: "merge of duplicate page",
      created_at: DateTime.utc_now(:microsecond)
    })
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
