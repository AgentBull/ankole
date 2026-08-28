defmodule Ankole.Brain.Objects do
  @moduledoc """
  Object write path and chunk projection of the Brain knowledge space.

  Every write validates the object type against the installed instance
  ontology, parses the Markdoc body for audience scopes, and validates the
  writer's scope eligibility. Updates snapshot the previous body into
  `brain_object_versions` and use the content hash as a compare-and-swap
  anchor: several writers on one shared page are the normal case.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Chunker
  alias Ankole.Brain.Config
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Schemas.SlugAlias
  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Vocabulary
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Repo

  @slug_format ~r|\A[^\s/]+(/[^\s/]+)*\z|
  @library_projection_type "agent-skills"
  @lazy_skill_prefix "lazyload-agent-skills/"

  @type writer :: String.t() | :system

  @doc """
  Fetches one object by exact slug.
  """
  @spec get_by_slug(String.t(), keyword()) :: {:ok, Object.t()} | {:error, :not_found}
  def get_by_slug(slug, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    visibility = Keyword.get(opts, :lazy_skill_visibility, %LazySkillVisibility{})

    object =
      Object
      |> where([object], object.slug == ^slug)
      |> LazySkillVisibility.filter_objects(visibility)
      |> repo.one()

    case object do
      %Object{} = object -> {:ok, object}
      nil -> {:error, :not_found}
    end
  end

  @doc "Lists the Objects for the Console read model."
  @spec list_for_console(keyword()) :: [Object.t()]
  def list_for_console(opts) when is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)

    Object
    |> maybe_console_prefix(Keyword.get(opts, :prefix))
    |> maybe_console_search(Keyword.get(opts, :search))
    |> filter_console_deleted(Keyword.get(opts, :deleted, false))
    |> order_by([object], asc: object.slug)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Lists one Object's stored versions for the Console read model."
  @spec list_versions_for_console(String.t(), keyword()) ::
          {:ok, [ObjectVersion.t()]} | {:error, :not_found}
  def list_versions_for_console(slug, opts) when is_binary(slug) and is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)

    with {:ok, object} <- resolve_slug(slug) do
      versions =
        ObjectVersion
        |> where([version], version.object_id == ^object.id)
        |> order_by([version], desc: version.snapshot_at)
        |> limit(^limit)
        |> Repo.all()

      {:ok, versions}
    end
  end

  @doc """
  Resolves a slug through the redirect ladder: exact slug, then slug alias.
  """
  @spec resolve_slug(String.t(), keyword()) :: {:ok, Object.t()} | {:error, :not_found}
  def resolve_slug(slug, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case get_by_slug(slug, opts) do
      {:ok, object} ->
        {:ok, object}

      {:error, :not_found} ->
        case repo.get_by(SlugAlias, alias_slug: slug) do
          %SlugAlias{canonical_slug: canonical} -> get_by_slug(canonical, opts)
          nil -> {:error, :not_found}
        end
    end
  end

  @title_similarity_floor 0.3
  @candidate_limit 5

  @doc """
  Resolves a slug-or-name reference through the full ladder: exact slug,
  slug-alias redirect, normalized natural-language alias, then title
  trigram similarity. Ambiguity returns candidates instead of a guess.

  Model-visible surfaces that promise "slug or name" share this one
  interface; the caller decides the product behavior for `:ambiguous` and
  `:not_found`. Stable internal identity paths keep `resolve_slug/2`.
  """
  @spec resolve_reference(String.t(), keyword()) ::
          {:ok, Object.t()} | {:ambiguous, [map()]} | {:error, :not_found}
  def resolve_reference(reference, opts \\ []) when is_binary(reference) do
    repo = Keyword.get(opts, :repo, Repo)
    reference = String.trim(reference)

    case resolve_slug(reference, opts) do
      {:ok, object} ->
        {:ok, object}

      {:error, :not_found} ->
        with :alias_miss <- natural_alias(repo, reference, opts) do
          title_similarity(repo, reference, opts)
        end
    end
  end

  defp natural_alias(repo, reference, opts) do
    slugs = Ankole.Brain.Links.lookup_alias(reference, repo: repo)

    objects =
      Object
      |> where([object], is_nil(object.deleted_at))
      |> where([object], object.slug in ^slugs)
      |> LazySkillVisibility.filter_objects(
        Keyword.get(opts, :lazy_skill_visibility, %LazySkillVisibility{})
      )
      |> order_by([object], asc: object.slug)
      |> repo.all()

    case objects do
      [] ->
        :alias_miss

      [object] ->
        {:ok, object}

      objects ->
        {:ambiguous, Enum.map(objects, &candidate_entry/1)}
    end
  end

  defp title_similarity(repo, reference, opts) do
    matches =
      Object
      |> where([object], is_nil(object.deleted_at))
      |> LazySkillVisibility.filter_objects(
        Keyword.get(opts, :lazy_skill_visibility, %LazySkillVisibility{})
      )
      |> where(
        [object],
        fragment("similarity(?, ?) > ?", object.title, ^reference, @title_similarity_floor)
      )
      |> order_by([object], desc: fragment("similarity(?, ?)", object.title, ^reference))
      |> limit(@candidate_limit)
      |> repo.all()

    case matches do
      [] -> {:error, :not_found}
      [object] -> {:ok, object}
      objects -> {:ambiguous, Enum.map(objects, &candidate_entry/1)}
    end
  end

  defp candidate_entry(%Object{} = object) do
    %{slug: object.slug, title: object.title, type: object.type, subtype: object.subtype}
  end

  @doc """
  Returns whether a holder value is valid: `world`, `brain`, or a slug that
  resolves in the knowledge space.
  """
  @spec valid_holder?(String.t(), keyword()) :: boolean()
  def valid_holder?(holder, opts \\ [])
  def valid_holder?(holder, _opts) when holder in ["world", "brain"], do: true

  def valid_holder?(holder, opts) when is_binary(holder) do
    match?({:ok, _object}, resolve_slug(holder, opts))
  end

  @doc """
  Creates one object through the shared write contract.

  `writer` is the Principal whose scope eligibility applies; `:system`
  validates scope existence only, because system learning paths derive their
  scopes deterministically. The new object's chunks are reconciled in the
  same transaction; embeddings follow asynchronously.
  """
  @spec create_object(map(), writer(), keyword()) :: {:ok, Object.t()} | {:error, term()}
  def create_object(attrs, writer, opts \\ []) when is_map(attrs) do
    repo = Keyword.get(opts, :repo, Repo)

    slug = attrs[:slug]
    body = attrs[:body] || ""
    meta = attrs[:meta] || %{}

    with :ok <- validate_slug(slug),
         {:ok, type} <- validate_type(attrs[:type], repo),
         :ok <- validate_body_scopes(body, writer),
         :ok <- validate_slug_available(slug, repo) do
      repo.transact(fn repo ->
        object = %Object{
          id: UUIDv7.autogenerate(),
          slug: slug,
          type: type.name,
          subtype: normalize_optional(attrs[:subtype]),
          title: attrs[:title],
          body: body,
          meta: meta,
          effective_date: attrs[:effective_date],
          content_hash: content_hash(attrs[:title], body, meta),
          updated_at: DateTime.utc_now(:microsecond)
        }

        with {:ok, object} <- repo.insert(Object.changeset(object, %{})) do
          reconcile_chunks(object, repo: repo)
        end
      end)
    end
  end

  @doc """
  Updates one object's logical content with a content-hash compare-and-swap.

  The caller sends the hash it read; a mismatch returns
  `{:error, :content_hash_conflict}` so the caller re-reads and replays. The
  previous body and meta enter `brain_object_versions` with the writer's
  audit identity before the row changes.
  """
  @spec update_object(String.t(), map(), writer(), keyword()) ::
          {:ok, Object.t()} | {:error, term()}
  def update_object(slug, attrs, writer, opts \\ []) when is_map(attrs) do
    repo = Keyword.get(opts, :repo, Repo)
    author_uid = author_uid(writer, opts)
    expected_hash = attrs[:expected_content_hash]

    repo.transact(fn repo ->
      with {:ok, object} <- lock_object(repo, slug),
           :ok <- guard_unmanaged(object),
           :ok <- verify_content_hash(object, expected_hash),
           new_title = Map.get(attrs, :title, object.title),
           new_body = Map.get(attrs, :body, object.body),
           new_meta = Map.get(attrs, :meta, object.meta),
           :ok <- validate_body_scopes(new_body, writer),
           {:ok, subtype} <- updated_subtype(attrs, object),
           {:ok, _version} <- snapshot_version(repo, object, author_uid) do
        changes = %{
          title: new_title,
          body: new_body,
          meta: new_meta,
          subtype: subtype,
          effective_date: Map.get(attrs, :effective_date, object.effective_date),
          content_hash: content_hash(new_title, new_body, new_meta),
          updated_at: DateTime.utc_now(:microsecond)
        }

        with {:ok, object} <- repo.update(Object.changeset(object, changes)) do
          reconcile_chunks(object, repo: repo)
        end
      end
    end)
  end

  @doc """
  Soft-deletes one object: it leaves ordinary recall but keeps a recovery
  window until purge. Chunks stay for restore; recall filters them out.
  `reason:` and `by:` land in the meta as `forgotten_reason` and
  `forgotten_by` for the recovery window; restore removes them.
  """
  @spec soft_delete(String.t(), keyword()) :: {:ok, Object.t()} | {:error, term()}
  def soft_delete(slug, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    reason = Keyword.get(opts, :reason)

    repo.transact(fn repo ->
      with {:ok, object} <- lock_object(repo, slug),
           :ok <- guard_unmanaged(object) do
        meta =
          case reason do
            nil ->
              object.meta

            reason ->
              object.meta
              |> Map.put("forgotten_reason", reason)
              |> Map.put("forgotten_by", Keyword.get(opts, :by))
          end

        object
        |> Ecto.Changeset.change(
          deleted_at: DateTime.utc_now(:microsecond),
          meta: meta,
          content_hash: content_hash(object.title, object.body, meta)
        )
        |> repo.update()
      end
    end)
  end

  @doc """
  Rolls one object back to a stored version: the current state snapshots
  first, then only the selected version's body and meta restore.
  """
  @spec rollback(String.t(), Ecto.UUID.t(), writer(), keyword()) ::
          {:ok, Object.t()} | {:error, term()}
  def rollback(slug, version_id, writer, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    author_uid = author_uid(writer, opts)

    repo.transact(fn repo ->
      with {:ok, object} <- lock_object(repo, slug),
           :ok <- guard_unmanaged(object),
           %ObjectVersion{} = version <- repo.get(ObjectVersion, version_id),
           true <- version.object_id == object.id or {:error, :version_object_mismatch},
           {:ok, _snapshot} <- snapshot_version(repo, object, author_uid) do
        changes = %{
          body: version.body,
          meta: version.meta,
          content_hash: content_hash(object.title, version.body, version.meta),
          updated_at: DateTime.utc_now(:microsecond)
        }

        with {:ok, object} <- repo.update(Object.changeset(object, changes)) do
          reconcile_chunks(object, repo: repo)
        end
      else
        nil -> {:error, :version_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Forks a library-managed page into instance ownership: the marker clears,
  the page leaves the product upgrade flow, and the ordinary write paths
  apply from then on. The library sync's shadowing keeps the slug with the
  instance afterwards.
  """
  @spec fork_library_page(String.t(), keyword()) :: {:ok, Object.t()} | {:error, term()}
  def fork_library_page(slug, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.transact(fn repo ->
      with {:ok, object} <- lock_object(repo, slug) do
        case object do
          %Object{managed_by_source_id: nil} ->
            {:error, :not_library_managed}

          %Object{type: @library_projection_type} ->
            {:error, {:reserved_object_type, @library_projection_type}}

          %Object{} ->
            object
            |> Ecto.Changeset.change(managed_by_source_id: nil)
            |> repo.update()
        end
      end
    end)
  end

  @doc """
  Restores a soft-deleted object and removes the forget bookkeeping.
  """
  @spec restore(String.t(), keyword()) :: {:ok, Object.t()} | {:error, term()}
  def restore(slug, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.transact(fn repo ->
      with {:ok, object} <- lock_object(repo, slug),
           :ok <- guard_unmanaged(object) do
        meta = Map.drop(object.meta, ["forgotten_reason", "forgotten_by"])

        object
        |> Ecto.Changeset.change(
          deleted_at: nil,
          meta: meta,
          content_hash: content_hash(object.title, object.body, meta)
        )
        |> repo.update()
      end
    end)
  end

  @doc """
  Ensures the canonical Object of one Principal exists, inside a caller
  transaction. Humans use `people/<uid>`, Agents use `agents/<uid>`.
  """
  @spec ensure_canonical_object_in_tx(module(), String.t(), :human | :agent, String.t() | nil) ::
          :ok | {:error, term()}
  def ensure_canonical_object_in_tx(repo, principal_uid, principal_type, display_name) do
    {slug, type} =
      case principal_type do
        :human -> {"people/" <> principal_uid, "person"}
        :agent -> {"agents/" <> principal_uid, "agent"}
      end

    row = %{
      id: UUIDv7.autogenerate(),
      slug: slug,
      type: type,
      subtype: "internal",
      title: display_name || principal_uid,
      body: "",
      meta: %{},
      content_hash: content_hash(display_name || principal_uid, "", %{}),
      created_at: DateTime.utc_now(:microsecond),
      updated_at: DateTime.utc_now(:microsecond)
    }

    repo.insert_all(Object, [row], on_conflict: :nothing, conflict_target: :slug)
    :ok
  end

  @doc """
  Computes the change-detection hash over the canonical title, body, and
  meta of one object state.
  """
  @spec content_hash(String.t() | nil, String.t(), map()) :: String.t()
  def content_hash(title, body, meta) do
    canonical_meta =
      meta
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> inspect(limit: :infinity)

    NativeKernel.xxh3_128_hex("#{title}\u0000#{body}\u0000#{canonical_meta}")
  end

  @doc """
  Rebuilds the chunk projection of one object from its current body and
  visible timeline rows.

  Reconciliation is by `(object_id, chunk_index)`: an unchanged position
  keeps its row and embedding, a changed position clears its vector state,
  new positions insert, and vanished positions delete. Embeddings never move
  across positions.
  """
  @spec reconcile_chunks(Object.t(), keyword()) :: {:ok, Object.t()} | {:error, term()}
  def reconcile_chunks(%Object{} = object, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    chunking = Keyword.get(opts, :chunking, Config.chunking())

    with {:ok, desired} <- desired_chunks(object, chunking, repo) do
      existing =
        Chunk
        |> where([chunk], chunk.object_id == ^object.id)
        |> repo.all()
        |> Map.new(&{&1.chunk_index, &1})

      now = DateTime.utc_now(:microsecond)

      desired_by_index = Map.new(desired, &{&1.chunk_index, &1})

      stale_indexes =
        existing
        |> Map.keys()
        |> Enum.reject(&Map.has_key?(desired_by_index, &1))

      if stale_indexes != [] do
        Chunk
        |> where([chunk], chunk.object_id == ^object.id and chunk.chunk_index in ^stale_indexes)
        |> repo.delete_all()
      end

      Enum.each(desired, fn spec ->
        case Map.get(existing, spec.chunk_index) do
          nil ->
            repo.insert!(%Chunk{
              id: UUIDv7.autogenerate(),
              object_id: object.id,
              chunk_index: spec.chunk_index,
              content_kind: spec.content_kind,
              audience_scope: spec.audience_scope,
              chunk_text: spec.text,
              token_count: spec.token_count,
              created_at: now
            })

          %Chunk{} = chunk ->
            if chunk.chunk_text == spec.text and chunk.content_kind == spec.content_kind and
                 chunk.audience_scope == spec.audience_scope do
              :ok
            else
              chunk
              |> Ecto.Changeset.change(
                content_kind: spec.content_kind,
                audience_scope: spec.audience_scope,
                chunk_text: spec.text,
                token_count: spec.token_count,
                embedding: nil,
                embedding_signature: nil,
                embedding_error: nil,
                embedded_at: nil
              )
              |> repo.update!()
            end
        end
      end)

      object
      |> Ecto.Changeset.change(chunking_signature: Chunker.signature(chunking))
      |> repo.update()
    end
  end

  # Body chunks come first; timeline chunks continue the same index sequence
  # in stable (date, id) order, each carrying the timeline row's own scope.
  defp desired_chunks(object, chunking, repo) do
    with {:ok, segments} <- Markdoc.segments(object.body) do
      body_specs =
        Enum.flat_map(segments, fn segment ->
          segment.text
          |> Chunker.chunk_text(chunking)
          |> Enum.map(fn chunk ->
            %{content_kind: "body", audience_scope: segment.scope, text: chunk.text}
          end)
        end)

      timeline_specs =
        Timeline
        |> where([timeline], timeline.object_slug == ^object.slug)
        |> order_by([timeline], asc: timeline.date, asc: timeline.id)
        |> repo.all()
        |> Enum.flat_map(fn timeline ->
          timeline
          |> timeline_text()
          |> Chunker.chunk_text(chunking)
          |> Enum.map(fn chunk ->
            %{
              content_kind: "timeline",
              audience_scope: timeline.audience_scope,
              text: chunk.text
            }
          end)
        end)

      specs =
        (body_specs ++ timeline_specs)
        |> Enum.with_index()
        |> Enum.map(fn {spec, index} ->
          spec
          |> Map.put(:chunk_index, index)
          |> Map.put(:token_count, Chunker.estimate_tokens(spec.text))
        end)

      {:ok, specs}
    end
  end

  defp timeline_text(%Timeline{} = timeline) do
    date = Date.to_iso8601(timeline.date)

    case String.trim(timeline.detail || "") do
      "" -> "[#{date}] #{timeline.summary}"
      detail -> "[#{date}] #{timeline.summary} — #{detail}"
    end
  end

  # Validation

  defp validate_slug(@lazy_skill_prefix <> _rest = slug),
    do: {:error, {:reserved_object_slug, slug}}

  defp validate_slug(slug) when is_binary(slug) do
    if Regex.match?(@slug_format, slug), do: :ok, else: {:error, {:invalid_slug, slug}}
  end

  defp validate_slug(_slug), do: {:error, :missing_slug}

  defp validate_slug_available(slug, repo) do
    exists =
      repo.exists?(Object |> where([object], object.slug == ^slug)) or
        repo.exists?(SlugAlias |> where([alias], alias.alias_slug == ^slug))

    if exists, do: {:error, {:slug_taken, slug}}, else: :ok
  end

  defp maybe_console_prefix(query, prefix) when is_binary(prefix) and prefix != "" do
    where(query, [object], like(object.slug, ^(prefix <> "%")))
  end

  defp maybe_console_prefix(query, _prefix), do: query

  defp maybe_console_search(query, term) when is_binary(term) and term != "" do
    pattern = "%" <> term <> "%"

    where(
      query,
      [object],
      ilike(object.title, ^pattern) or ilike(object.slug, ^pattern)
    )
  end

  defp maybe_console_search(query, _term), do: query

  defp filter_console_deleted(query, true),
    do: where(query, [object], not is_nil(object.deleted_at))

  defp filter_console_deleted(query, _other),
    do: where(query, [object], is_nil(object.deleted_at))

  # Type is a closed validation against the installed ontology. The error
  # carries the installed type set and the closest vocabulary terms so a tool
  # caller can re-choose explicitly at the moment of the mistake instead of
  # silently degrading or needing a separate vocabulary lookup.
  defp validate_type(type, repo) when is_binary(type) and type != "" do
    case repo.get_by(SchemaType, name: type) do
      %SchemaType{name: @library_projection_type} ->
        {:error, {:reserved_object_type, type}}

      %SchemaType{} = schema_type ->
        {:ok, schema_type}

      nil ->
        installed =
          repo.all(
            SchemaType
            |> where([t], t.name != @library_projection_type)
            |> select([t], t.name)
            |> order_by([t], asc: t.name)
          )

        {:error,
         {:unknown_object_type, type,
          %{
            installed_types: installed,
            vocabulary_terms: Vocabulary.closest_terms(type),
            hint:
              "Use an installed type. For an unmodeled concept, use type \"note\" with a vocabulary term as tag; vocabulary_terms lists the canonical terms closest to the rejected type."
          }}}
    end
  end

  defp validate_type(_type, _repo), do: {:error, :missing_object_type}

  defp validate_body_scopes(body, writer) do
    with {:ok, scopes} <- Markdoc.scopes(body) do
      scopes
      |> Enum.reject(&(&1 == "world"))
      |> Enum.reduce_while(:ok, fn scope, :ok ->
        result =
          case writer do
            :system -> Scope.validate(scope)
            writer_uid when is_binary(writer_uid) -> Scope.validate_writable(scope, writer_uid)
          end

        case result do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  # A library-managed page is a projection of a shipped okf file: the file is
  # the authority, so every instance edit path refuses it. Claims, links,
  # timelines, and tags on the slug stay open — they are instance periphery,
  # not the page body. Taking the page over is the explicit fork operation,
  # which clears the marker.
  defp guard_unmanaged(%Object{managed_by_source_id: nil}), do: :ok

  defp guard_unmanaged(%Object{slug: slug}) do
    {:error,
     {:library_managed, slug,
      %{
        hint:
          "This page is product-shipped library knowledge and updates with the product. Attach claims, links, or timeline entries instead of editing the body, or fork the page in the Console to take it over."
      }}}
  end

  defp verify_content_hash(_object, nil), do: {:error, :missing_expected_content_hash}

  defp verify_content_hash(%Object{content_hash: current}, expected) do
    if current == expected, do: :ok, else: {:error, :content_hash_conflict}
  end

  defp updated_subtype(attrs, object) do
    case Map.fetch(attrs, :subtype) do
      {:ok, subtype} -> {:ok, normalize_optional(subtype)}
      :error -> {:ok, object.subtype}
    end
  end

  defp snapshot_version(repo, %Object{} = object, author_uid) do
    repo.insert(%ObjectVersion{
      id: UUIDv7.autogenerate(),
      object_id: object.id,
      author_uid: author_uid,
      body: object.body,
      meta: object.meta,
      snapshot_at: DateTime.utc_now(:microsecond)
    })
  end

  defp lock_object(repo, slug) do
    Object
    |> where([object], object.slug == ^slug)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %Object{} = object -> {:ok, object}
      nil -> {:error, :not_found}
    end
  end

  defp author_uid(:system, opts), do: Keyword.get(opts, :author_uid)
  defp author_uid(writer, _opts) when is_binary(writer), do: writer

  defp normalize_optional(nil), do: nil

  defp normalize_optional(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
