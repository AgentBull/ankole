defmodule Ankole.Brain.Merge do
  @moduledoc """
  Duplicate-page detection and Console-reviewed merge.

  The Dreaming phase is the mechanical backstop behind the write-time
  known-page injection: it pairs live objects of one type that share a
  normalized alias, and records each pair
  once in `brain_merge_suggestions`. Nothing merges automatically.

  Approval runs one transaction that keeps every attached memory: claims,
  holder attributions, timelines, tags, aliases, and links repoint to the
  surviving page, the duplicate's name stays matchable as a natural alias,
  the duplicate row is deleted, and its slug becomes a `brain_slug_aliases`
  redirect so stored references keep resolving.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.MergeSuggestion
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Schemas.SlugAlias
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @candidate_scan_limit 200
  @suggestion_batch_limit 50

  @doc "Lists merge suggestions for the Console read model."
  @spec list_for_console(String.t(), keyword()) :: [MergeSuggestion.t()]
  def list_for_console(status, opts) when is_binary(status) and is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)

    MergeSuggestion
    |> where([suggestion], suggestion.status == ^status)
    |> order_by([suggestion], desc: suggestion.created_at)
    |> limit(^limit)
    |> Repo.all()
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

    Enum.each(fresh, fn {a, b, reason} ->
      Repo.insert!(
        %MergeSuggestion{
          id: UUIDv7.autogenerate(),
          a_slug: a,
          b_slug: b,
          reason: reason,
          status: "pending",
          created_at: now
        },
        on_conflict: :nothing,
        conflict_target: [:a_slug, :b_slug]
      )
    end)

    %{status: :ok, suggested: length(fresh), candidates: length(candidates)}
  end

  @doc """
  Approves one pending suggestion and merges the pair. `attrs.canonical_slug`
  names the surviving page and must be one of the pair; the other page is
  the duplicate that merges away.
  """
  @spec approve(Ecto.UUID.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def approve(suggestion_id, decided_by, attrs \\ %{}) do
    Repo.transact(fn repo ->
      with {:ok, suggestion} <- fetch_pending(repo, suggestion_id),
           {:ok, target_slug} <- required_canonical(attrs),
           {:ok, first} <- resolve_live(repo, suggestion.a_slug),
           {:ok, second} <- resolve_live(repo, suggestion.b_slug),
           :ok <- guard_pair_unmanaged(first, second) do
        if first.id == second.id do
          # Both slugs already resolve to one page: an earlier merge or slug
          # redirect settled this pair, so approval only closes the row.
          with {:ok, _suggestion} <- decide(repo, suggestion, "approved", decided_by) do
            {:ok, %{status: :already_merged, canonical_slug: first.slug}}
          end
        else
          with {:ok, canonical, duplicate} <- orient(repo, first, second, target_slug),
               {:ok, canonical, duplicate} <- lock_pair(repo, canonical, duplicate),
               :ok <- guard_duplicate_mergeable(duplicate),
               {:ok, moved} <- repoint_children(repo, canonical, duplicate),
               {:ok, _alias} <- keep_duplicate_name(repo, canonical, duplicate),
               {:ok, _duplicate} <- repo.delete(duplicate),
               {:ok, _redirect} <- insert_redirect(repo, canonical, duplicate),
               {:ok, _object} <- Objects.reconcile_chunks(canonical, repo: repo),
               {:ok, _suggestion} <- decide(repo, suggestion, "approved", decided_by) do
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
    end)
  end

  @doc """
  Rejects one pending suggestion; the record stays, so the same pair is not
  suggested again.
  """
  @spec reject(Ecto.UUID.t(), String.t()) :: {:ok, MergeSuggestion.t()} | {:error, term()}
  def reject(suggestion_id, decided_by) do
    Repo.transact(fn repo ->
      with {:ok, suggestion} <- fetch_pending(repo, suggestion_id) do
        decide(repo, suggestion, "rejected", decided_by)
      end
    end)
  end

  # Candidate scan

  defp alias_candidates do
    ObjectAlias
    |> join(:inner, [x], y in ObjectAlias,
      on: x.alias_norm == y.alias_norm and x.object_slug < y.object_slug
    )
    |> join(:inner, [x, y], a in Object,
      as: :merge_candidate_a,
      on: a.slug == x.object_slug
    )
    |> join(:inner, [x, y, a], b in Object,
      as: :merge_candidate_b,
      on: b.slug == y.object_slug
    )
    |> join(:inner, [x, y, a, b], type in SchemaType, on: type.name == a.type)
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
        from suggestion in MergeSuggestion,
          where:
            suggestion.a_slug == parent_as(:merge_candidate_a).slug and
              suggestion.b_slug == parent_as(:merge_candidate_b).slug,
          select: 1
      )
    )
    |> where(
      [merge_candidate_a: _a, merge_candidate_b: _b],
      not (exists(
             from principal in Principal,
               where:
                 (principal.type == :human and
                    parent_as(:merge_candidate_a).slug ==
                      fragment("'people/' || ?", principal.uid)) or
                   (principal.type == :agent and
                      parent_as(:merge_candidate_a).slug ==
                        fragment("'agents/' || ?", principal.uid)),
               select: 1
           ) and
             exists(
               from principal in Principal,
                 where:
                   (principal.type == :human and
                      parent_as(:merge_candidate_b).slug ==
                        fragment("'people/' || ?", principal.uid)) or
                     (principal.type == :agent and
                        parent_as(:merge_candidate_b).slug ==
                          fragment("'agents/' || ?", principal.uid)),
                 select: 1
             ))
    )
  end

  # Merge execution

  defp required_canonical(attrs) do
    case attrs[:canonical_slug] do
      slug when is_binary(slug) and slug != "" -> {:ok, slug}
      _missing -> {:error, :canonical_slug_required}
    end
  end

  defp resolve_live(repo, slug) do
    with {:ok, object} <- Objects.resolve_slug(slug, repo: repo) do
      case object.deleted_at do
        nil -> {:ok, object}
        _deleted -> {:error, {:object_deleted, object.slug}}
      end
    end
  end

  defp orient(repo, first, second, target_slug) do
    case Objects.resolve_slug(target_slug, repo: repo) do
      {:ok, %Object{id: id}} when id == first.id -> {:ok, first, second}
      {:ok, %Object{id: id}} when id == second.id -> {:ok, second, first}
      _other -> {:error, {:canonical_slug_not_in_pair, target_slug}}
    end
  end

  defp lock_pair(repo, canonical, duplicate) do
    locked =
      Object
      |> where([object], object.slug in ^[canonical.slug, duplicate.slug])
      |> order_by([object], asc: object.slug)
      |> lock("FOR UPDATE")
      |> repo.all()
      |> Map.new(&{&1.slug, &1})

    with %Object{} = canonical <- Map.get(locked, canonical.slug) || {:error, :not_found},
         %Object{} = duplicate <- Map.get(locked, duplicate.slug) || {:error, :not_found} do
      {:ok, canonical, duplicate}
    end
  end

  defp guard_duplicate_mergeable(%Object{} = duplicate) do
    cond do
      canonical_principal_page?(duplicate.slug) ->
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

  defp repoint_children(repo, canonical, duplicate) do
    now = DateTime.utc_now(:microsecond)
    canon = canonical.slug
    dup = duplicate.slug

    {claims, _rows} =
      Claim
      |> where([claim], claim.object_slug == ^dup)
      |> repo.update_all(set: [object_slug: canon, updated_at: now])

    {holders, _rows} =
      Claim
      |> where([claim], claim.holder == ^dup)
      |> repo.update_all(set: [holder: canon, updated_at: now])

    {redirects, _rows} =
      SlugAlias
      |> where([alias], alias.canonical_slug == ^dup)
      |> repo.update_all(set: [canonical_slug: canon])

    {:ok,
     %{
       claims: claims,
       holders: holders,
       redirects: redirects,
       timelines: repoint_timelines(repo, canon, dup),
       tags: repoint_unique_rows(repo, "brain_tags", "tag", canon, dup),
       aliases: repoint_unique_rows(repo, "brain_object_aliases", "alias_norm", canon, dup),
       links: repoint_links(repo, canon, dup)
     }}
  end

  defp repoint_timelines(repo, canon, dup) do
    # A row whose (date, summary, provenance) twin already exists on the
    # canonical page is the duplicate this merge removes.
    repo.query!(
      """
      DELETE FROM brain_timelines AS moved
      WHERE moved.object_slug = $1
        AND EXISTS (
          SELECT 1 FROM brain_timelines AS kept
          WHERE kept.object_slug = $2
            AND kept.date = moved.date
            AND kept.summary = moved.summary
            AND kept.provenance = moved.provenance
        )
      """,
      [dup, canon]
    )

    # Event back-references follow their foreign key's nilify semantics when
    # repointing would collide with the one-event-per-day key.
    repo.query!(
      """
      UPDATE brain_timelines AS moved SET event_object_slug = NULL
      WHERE moved.event_object_slug = $1
        AND EXISTS (
          SELECT 1 FROM brain_timelines AS kept
          WHERE kept.event_object_slug = $2 AND kept.date = moved.date
        )
      """,
      [dup, canon]
    )

    repo.query!(
      "UPDATE brain_timelines SET event_object_slug = $2 WHERE event_object_slug = $1",
      [dup, canon]
    )

    %{num_rows: moved} =
      repo.query!(
        "UPDATE brain_timelines SET object_slug = $2 WHERE object_slug = $1",
        [dup, canon]
      )

    moved
  end

  defp repoint_unique_rows(repo, table, value_column, canon, dup) do
    repo.query!(
      """
      DELETE FROM #{table} AS moved
      WHERE moved.object_slug = $1
        AND EXISTS (
          SELECT 1 FROM #{table} AS kept
          WHERE kept.object_slug = $2
            AND kept.#{value_column} = moved.#{value_column}
        )
      """,
      [dup, canon]
    )

    %{num_rows: moved} =
      repo.query!("UPDATE #{table} SET object_slug = $2 WHERE object_slug = $1", [dup, canon])

    moved
  end

  @link_key_columns ~w(from_object_slug to_object_slug link_type link_source origin_object_slug)

  defp repoint_links(repo, canon, dup) do
    # Edges inside the merged pair would become self-links; they carry no
    # information once the pair is one page.
    repo.query!(
      """
      DELETE FROM brain_links
      WHERE (from_object_slug = $1 AND to_object_slug IN ($1, $2))
         OR (from_object_slug = $2 AND to_object_slug = $1)
      """,
      [dup, canon]
    )

    Enum.reduce(@link_key_columns -- ~w(link_type link_source), 0, fn column, count ->
      count + repoint_link_column(repo, column, canon, dup)
    end)
  end

  # Repoints one slug column of the edge table, first dropping rows whose
  # full dedup-key twin (equal NULLs equal) already sits on the canonical
  # side.
  defp repoint_link_column(repo, column, canon, dup) do
    twin_match =
      (@link_key_columns -- [column])
      |> Enum.map_join(" AND ", fn key -> "kept.#{key} IS NOT DISTINCT FROM moved.#{key}" end)

    repo.query!(
      """
      DELETE FROM brain_links AS moved
      WHERE moved.#{column} = $1
        AND EXISTS (
          SELECT 1 FROM brain_links AS kept
          WHERE kept.#{column} = $2 AND #{twin_match}
        )
      """,
      [dup, canon]
    )

    %{num_rows: moved} =
      repo.query!("UPDATE brain_links SET #{column} = $2 WHERE #{column} = $1", [dup, canon])

    moved
  end

  defp keep_duplicate_name(repo, canonical, duplicate) do
    case Links.normalize_alias(duplicate.title || "") do
      "" -> {:ok, :untitled}
      _name -> Links.add_alias(canonical.slug, duplicate.title, repo: repo)
    end
  end

  defp insert_redirect(repo, canonical, duplicate) do
    repo.insert(%SlugAlias{
      id: UUIDv7.autogenerate(),
      alias_slug: duplicate.slug,
      canonical_slug: canonical.slug,
      notes: "merge of duplicate page",
      created_at: DateTime.utc_now(:microsecond)
    })
  end

  # Bookkeeping

  defp canonical_principal_page?(slug) do
    case String.split(slug, "/", parts: 2) do
      ["people", uid] -> principal_type(uid) == :human
      ["agents", uid] -> principal_type(uid) == :agent
      _other -> false
    end
  end

  defp principal_type(uid) do
    Principal
    |> where([principal], principal.uid == ^uid)
    |> select([principal], principal.type)
    |> Repo.one()
  end

  defp fetch_pending(repo, suggestion_id) do
    MergeSuggestion
    |> where([suggestion], suggestion.id == ^suggestion_id)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %MergeSuggestion{status: "pending"} = suggestion -> {:ok, suggestion}
      %MergeSuggestion{} -> {:error, :suggestion_not_pending}
      nil -> {:error, :not_found}
    end
  end

  defp decide(repo, suggestion, status, decided_by) do
    suggestion
    |> Ecto.Changeset.change(
      status: status,
      decided_by: decided_by,
      decided_at: DateTime.utc_now(:microsecond)
    )
    |> repo.update()
  end
end
