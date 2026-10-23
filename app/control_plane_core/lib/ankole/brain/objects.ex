defmodule Ankole.Brain.Objects do
  @moduledoc """
  Object writes and body history in the Brain knowledge space.

  Instance writes validate the object type against the installed instance
  ontology, parse the Markdoc body for audience scopes, and validate the
  writer's scope eligibility. Instance updates snapshot the previous body into
  `brain_object_versions` and use the content hash as a compare-and-swap
  anchor: several writers on one shared page are the normal case.

  A generic action on `Ankole.Brain.Schemas.Object` owns the transaction of
  each write. The `_in_tx` functions give the steps of these actions; another
  action calls them in its own transaction.
  """

  require Ash.Query

  alias Ankole.Brain.Chunks
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Links
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Schemas.SlugAlias
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Sources
  alias Ankole.Brain.Vocabulary
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @slug_format ~r|\A[^\s/]+(/[^\s/]+)*\z|
  @library_projection_type "agent-skills"
  @lazy_skill_prefix "lazyload-agent-skills/"
  @reserved_types ~w(agent agent-skills)

  @type writer :: String.t() | :system

  @doc """
  Fetches one object by exact slug.
  """
  @spec get_by_slug(String.t(), keyword()) :: {:ok, Object.t()} | {:error, :not_found}
  def get_by_slug(slug, opts \\ []) do
    visibility = Keyword.get(opts, :lazy_skill_visibility, %LazySkillVisibility{})

    object =
      Object
      |> Ash.Query.filter(slug == ^slug)
      |> LazySkillVisibility.filter_objects(visibility)
      |> Ankole.Ash.read_one!()

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
    |> Ash.Query.sort(slug: :asc)
    |> Ash.Query.limit(limit)
    |> Ankole.Ash.read!()
  end

  @doc "Lists one Object's stored versions for the Console read model."
  @spec list_versions_for_console(String.t(), keyword()) ::
          {:ok, [ObjectVersion.t()]} | {:error, :not_found}
  def list_versions_for_console(slug, opts) when is_binary(slug) and is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)

    with {:ok, object} <- resolve_slug(slug) do
      versions =
        ObjectVersion
        |> Ash.Query.filter(object_id == ^object.id)
        |> Ash.Query.sort(snapshot_at: :desc)
        |> Ash.Query.limit(limit)
        |> Ankole.Ash.read!()

      {:ok, versions}
    end
  end

  @doc """
  Resolves a slug through the redirect ladder: exact slug, then slug alias.
  """
  @spec resolve_slug(String.t(), keyword()) :: {:ok, Object.t()} | {:error, :not_found}
  def resolve_slug(slug, opts \\ []) do
    case get_by_slug(slug, opts) do
      {:ok, object} ->
        {:ok, object}

      {:error, :not_found} ->
        case SlugAlias |> Ash.Query.filter(alias_slug == ^slug) |> Ankole.Ash.read_one!() do
          %SlugAlias{canonical_slug: canonical} -> get_by_slug(canonical, opts)
          nil -> {:error, :not_found}
        end
    end
  end

  @candidate_limit 5

  @doc """
  Resolves a slug-or-name reference through the full ladder: exact slug,
  slug-alias redirect, normalized natural-language alias, then exact title.
  Ambiguity returns candidates instead of a guess.

  Model-visible surfaces that promise "slug or name" share this one
  interface; the caller decides the product behavior for `:ambiguous` and
  `:not_found`. Stable internal identity paths keep `resolve_slug/2`.
  """
  @spec resolve_reference(String.t(), keyword()) ::
          {:ok, Object.t()} | {:ambiguous, [map()]} | {:error, :not_found}
  def resolve_reference(reference, opts \\ []) when is_binary(reference) do
    reference = String.trim(reference)

    case resolve_slug(reference, opts) do
      {:ok, object} ->
        {:ok, object}

      {:error, :not_found} ->
        with :alias_miss <- natural_alias(reference, opts) do
          exact_title(reference, opts)
        end
    end
  end

  defp natural_alias(reference, opts) do
    slugs = Ankole.Brain.Links.lookup_alias(reference)

    objects =
      Object
      |> Ash.Query.filter(is_nil(deleted_at) and slug in ^slugs)
      |> LazySkillVisibility.filter_objects(
        Keyword.get(opts, :lazy_skill_visibility, %LazySkillVisibility{})
      )
      |> Ash.Query.sort(slug: :asc)
      |> Ankole.Ash.read!()

    case objects do
      [] ->
        :alias_miss

      [object] ->
        {:ok, object}

      objects ->
        {:ambiguous, Enum.map(objects, &candidate_entry/1)}
    end
  end

  defp exact_title(reference, opts) do
    matches =
      Object
      |> Ash.Query.filter(is_nil(deleted_at))
      |> LazySkillVisibility.filter_objects(
        Keyword.get(opts, :lazy_skill_visibility, %LazySkillVisibility{})
      )
      |> Ash.Query.filter(title == ^reference)
      |> Ash.Query.sort(slug: :asc)
      |> Ash.Query.limit(@candidate_limit)
      |> Ankole.Ash.read!()

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
  Creates one object in the caller's transaction.

  `writer` is the Principal whose scope eligibility applies; `:system`
  validates scope existence only, because system learning paths derive their
  scopes deterministically. The new object's chunks are reconciled in the
  same transaction; embeddings follow asynchronously.
  """
  @spec create_object_in_tx(map(), writer()) :: {:ok, Object.t()} | {:error, term()}
  def create_object_in_tx(attrs, writer) when is_map(attrs) do
    slug = attrs[:slug]
    body = attrs[:body] || ""
    meta = attrs[:meta] || %{}

    with :ok <- Repo.require_transaction(Repo),
         :ok <- validate_slug(slug),
         {:ok, tags} <- Links.normalize_tags(Map.get(attrs, :tags, [])),
         {:ok, type} <- validate_type(attrs[:type]),
         :ok <- validate_body_scopes(body, writer),
         :ok <- validate_slug_available(slug) do
      object =
        %{
          id: UUIDv7.autogenerate(),
          slug: slug,
          type: type.name,
          subtype: normalize_optional(attrs[:subtype]),
          title: attrs[:title],
          body: body,
          meta: meta,
          effective_date: attrs[:effective_date],
          updated_at: DateTime.utc_now(:microsecond)
        }
        |> content_changes(%{}, tags)

      with {:ok, object} <- Ankole.Ash.create(Object, :create, object),
           :ok <- Links.replace_tags_in_tx(Repo, object.slug, tags) do
        Chunks.reconcile_in_tx(object)
      end
    end
  end

  @doc """
  Updates one object's logical content in the caller's transaction, with a
  content-hash compare-and-swap.

  The caller sends the hash it read; a mismatch returns
  `{:error, :content_hash_conflict}` so the caller re-reads and replays. The
  previous body and meta enter `brain_object_versions` with the writer's
  audit identity before the row changes. `author:` names the audit identity
  of a `:system` writer.
  """
  @spec update_object_in_tx(String.t(), map(), writer(), keyword()) ::
          {:ok, Object.t()} | {:error, term()}
  def update_object_in_tx(slug, attrs, writer, opts \\ []) when is_map(attrs) do
    author = Ankole.ActorRef.from_writer(writer, Repo.tenant_id!(), opts)
    expected_hash = attrs[:expected_content_hash]

    with :ok <- Repo.require_transaction(Repo),
         {:ok, object} <- lock_object_in_tx(Repo, slug),
         :ok <- guard_editable(object),
         :ok <- Object.verify_content_hash(object, expected_hash),
         {:ok, tags} <- updated_tags(attrs, object),
         new_title = Map.get(attrs, :title, object.title),
         new_body = Map.get(attrs, :body, object.body),
         new_meta = Map.get(attrs, :meta, object.meta),
         :ok <- validate_body_scopes(new_body, writer),
         {:ok, subtype} <- updated_subtype(attrs, object),
         {:ok, _version} <- snapshot_version(object, author) do
      changes =
        %{
          title: new_title,
          body: new_body,
          meta: new_meta,
          subtype: subtype,
          effective_date: Map.get(attrs, :effective_date, object.effective_date),
          updated_at: DateTime.utc_now(:microsecond)
        }
        |> content_changes(object, tags)

      with {:ok, object} <-
             Ankole.Ash.update(
               object,
               :edit,
               Map.put(changes, :expected_content_hash, expected_hash)
             ),
           :ok <- Links.replace_tags_in_tx(Repo, object.slug, tags) do
        Chunks.reconcile_in_tx(object)
      end
    end
  end

  @doc """
  Projects the page of a file, URL, or OIDC Client Source in the caller's
  transaction. The Source and Object locks keep archive decisions current.
  """
  @spec upsert_source_projection_in_tx(Source.t(), map()) ::
          {:ok, Object.t()} | {:error, term()}
  def upsert_source_projection_in_tx(%Source{kind: kind} = source, attrs)
      when kind in ["file", "url", "oidc_client"] and is_map(attrs) do
    slug = attrs[:slug]
    body = attrs[:body] || ""

    with :ok <- Repo.require_transaction(Repo),
         :ok <- validate_slug(slug),
         {:ok, type} <- validate_type("media"),
         :ok <- validate_body_scopes(body, :system),
         {:ok, source} <- Sources.lock_active(Repo, source) do
      case lock_object_in_tx(Repo, slug) do
        {:error, :not_found} ->
          insert_source_projection(source, attrs, type.name, body)

        {:ok, %Object{managed_by_source_id: owner} = object} when owner == source.id ->
          update_source_projection(object, attrs, type.name, body)

        {:ok, %Object{}} ->
          {:error, {:source_object_conflict, slug}}
      end
    end
  end

  def upsert_source_projection_in_tx(%Source{}, _attrs),
    do: {:error, :unsupported_source_projection}

  @doc """
  Projects one parsed Library page while its Source still owns the body.

  Source and Object locks keep archive decisions current through the write.
  LibraryKnowledge validates the inventory. Published Skills own their
  history, so this projection does not create instance version snapshots.
  """
  @spec upsert_library_projection_in_tx(Source.t(), map()) ::
          {:ok, :projected | :unchanged | :shadowed | :conflicted} | {:error, term()}
  def upsert_library_projection_in_tx(%Source{kind: "library"} = source, page) do
    with :ok <- Repo.require_transaction(Repo),
         {:ok, source} <- Sources.lock_active(Repo, source) do
      case lock_object_in_tx(Repo, page.slug) do
        {:error, :not_found} ->
          with {:ok, _object} <-
                 insert_source_projection(source, page, page.type, page.body) do
            add_library_aliases(page)
            {:ok, :projected}
          end

        {:ok, %Object{managed_by_source_id: nil}} ->
          {:ok, :shadowed}

        {:ok, %Object{managed_by_source_id: owner} = object} when owner == source.id ->
          update_library_projection(object, page)

        {:ok, %Object{}} ->
          {:ok, :conflicted}
      end
    end
  end

  @doc """
  Withdraws managed Library pages absent from the current set in one
  statement, and gives the number of withdrawn pages.
  """
  @spec withdraw_library_projection(Source.t(), [String.t()]) :: non_neg_integer()
  def withdraw_library_projection(%Source{kind: "library", id: source_id}, live_slugs) do
    {:ok, withdrawn} =
      Object
      |> Ash.Query.filter(
        managed_by_source_id == ^source_id and is_nil(deleted_at) and slug not in ^live_slugs
      )
      |> Ankole.Ash.update_where(:withdraw_projection, %{source_id: source_id})

    length(withdrawn)
  end

  @doc "Returns the server-owned edit state for one Object."
  @spec editability(Object.t()) :: %{
          editable: boolean(),
          edit_block_reason: String.t() | nil
        }
  def editability(%Object{} = object) do
    cond do
      object.deleted_at != nil ->
        %{editable: false, edit_block_reason: "deleted"}

      object.managed_by_source_id == nil ->
        %{editable: true, edit_block_reason: nil}

      object.type == @library_projection_type ->
        %{editable: false, edit_block_reason: "agent_skills_managed"}

      source_kind(object.managed_by_source_id) == "library" ->
        %{editable: false, edit_block_reason: "library_managed"}

      true ->
        %{editable: false, edit_block_reason: "source_managed"}
    end
  end

  @doc """
  Soft-deletes one object in the caller's transaction: it leaves ordinary
  recall but keeps a recovery window until purge. Chunks stay for restore;
  recall filters them out. `reason:` and `by:` land in the meta as
  `forgotten_reason` and `forgotten_by` for the recovery window; restore
  removes them.
  """
  @spec soft_delete_in_tx(String.t(), keyword()) :: {:ok, Object.t()} | {:error, term()}
  def soft_delete_in_tx(slug, opts \\ []) do
    reason = Keyword.get(opts, :reason)

    with :ok <- Repo.require_transaction(Repo),
         {:ok, object} <- lock_object_in_tx(Repo, slug),
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

      changes =
        %{deleted_at: DateTime.utc_now(:microsecond), meta: meta}
        |> content_changes(object, Links.tags_for_object(object.slug))

      Ankole.Ash.update(object, :forget, Map.delete(changes, :deleted_at))
    end
  end

  @doc """
  Rolls one object back to a stored version in the caller's transaction: the
  current state snapshots first, then only the selected version's body and
  meta restore.
  """
  @spec rollback_in_tx(String.t(), Ecto.UUID.t(), writer(), keyword()) ::
          {:ok, Object.t()} | {:error, term()}
  def rollback_in_tx(slug, version_id, writer, opts \\ []) do
    author = Ankole.ActorRef.from_writer(writer, Repo.tenant_id!(), opts)

    with :ok <- Repo.require_transaction(Repo),
         {:ok, object} <- lock_object_in_tx(Repo, slug),
         :ok <- guard_editable(object),
         %ObjectVersion{} = version <-
           Ankole.Ash.read_one!(Ash.Query.filter(ObjectVersion, id == ^version_id)),
         true <- version.object_id == object.id or {:error, :version_object_mismatch},
         {:ok, _snapshot} <- snapshot_version(object, author) do
      changes =
        %{
          body: version.body,
          meta: version.meta,
          updated_at: DateTime.utc_now(:microsecond)
        }
        |> content_changes(object, Links.tags_for_object(object.slug))

      with {:ok, object} <-
             Ankole.Ash.update(
               object,
               :edit,
               Map.put(changes, :expected_content_hash, object.content_hash)
             ) do
        Chunks.reconcile_in_tx(object)
      end
    else
      nil -> {:error, :version_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Forks a library-managed page into instance ownership in the caller's
  transaction: the marker clears, the page leaves the product upgrade flow,
  and the ordinary write paths apply from then on. The library sync's
  shadowing keeps the slug with the instance afterwards.
  """
  @spec fork_library_page_in_tx(String.t()) :: {:ok, Object.t()} | {:error, term()}
  def fork_library_page_in_tx(slug) do
    with :ok <- Repo.require_transaction(Repo),
         {:ok, object} <- lock_object_in_tx(Repo, slug) do
      case object do
        %Object{managed_by_source_id: nil} ->
          {:error, :not_library_managed}

        %Object{type: @library_projection_type} ->
          {:error, {:reserved_object_type, @library_projection_type}}

        %Object{managed_by_source_id: source_id} ->
          if source_kind(source_id) == "library" do
            Ankole.Ash.update(object, :fork, %{})
          else
            {:error, :not_library_managed}
          end
      end
    end
  end

  @doc """
  Restores a soft-deleted object in the caller's transaction and removes the
  forget bookkeeping.
  """
  @spec restore_in_tx(String.t()) :: {:ok, Object.t()} | {:error, term()}
  def restore_in_tx(slug) do
    with :ok <- Repo.require_transaction(Repo),
         {:ok, object} <- lock_object_in_tx(Repo, slug),
         :ok <- guard_unmanaged(object) do
      meta = Map.drop(object.meta, ["forgotten_reason", "forgotten_by"])

      changes =
        %{deleted_at: nil, meta: meta}
        |> content_changes(object, Links.tags_for_object(object.slug))

      Ankole.Ash.update(object, :restore, Map.delete(changes, :deleted_at))
    end
  end

  @doc """
  Ensures the canonical Object of one Principal exists, inside a caller
  transaction. Humans use `people/<uid>`, Agents use `agents/<uid>`.
  """
  @spec ensure_canonical_object_in_tx(module(), String.t(), :human | :agent, String.t() | nil) ::
          :ok | {:error, term()}
  def ensure_canonical_object_in_tx(repo, principal_uid, principal_type, display_name) do
    case Ankole.Principals.get_principal(principal_uid) do
      {:ok, %Principal{type: ^principal_type}} when principal_type in [:human, :agent] ->
        insert_canonical_object(repo, principal_uid, principal_type, display_name)

      _principal ->
        {:error, :invalid_canonical_principal}
    end
  end

  @doc """
  Tells whether a slug is the canonical page of an existing Principal of the
  type that the slug names.
  """
  @spec canonical_principal_page?(String.t()) :: boolean()
  def canonical_principal_page?(slug) do
    with {:ok, {type, uid}} <- Scope.parse_principal_page_slug(slug),
         {:ok, %Principal{type: ^type}} <- Ankole.Principals.get_principal(uid) do
      true
    else
      _other -> false
    end
  end

  defp insert_canonical_object(_repo, principal_uid, principal_type, display_name) do
    slug = Scope.principal_page_slug(principal_type, principal_uid)
    type = if principal_type == :human, do: "person", else: "agent"

    row =
      %{
        id: UUIDv7.autogenerate(),
        slug: slug,
        type: type,
        subtype: "internal",
        title: display_name || principal_uid,
        body: "",
        meta: %{},
        created_at: DateTime.utc_now(:microsecond),
        updated_at: DateTime.utc_now(:microsecond)
      }
      |> content_changes(%{}, [])

    with {:ok, object} <- Ankole.Ash.create(Object, :ensure_canonical, row) do
      case object do
        %Object{type: ^type, subtype: "internal", deleted_at: nil} -> :ok
        _object -> {:error, :canonical_object_conflict}
      end
    end
  end

  # A token covers every field replaced by an ordinary content save. Status
  # and retrieval projections do not enter it. The migration freezes this
  # encoding so installed rows and new writes have the same baseline.
  defp content_hash(object, tags) do
    canonical_meta =
      object.meta
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> inspect(limit: :infinity, printable_limit: :infinity)

    encoded =
      "#{object.title}\u0000#{object.body}\u0000#{canonical_meta}\u0000#{Map.get(object, :subtype)}\u0000#{Map.get(object, :effective_date)}"

    encoded =
      if tags == [],
        do: encoded,
        else:
          encoded <> "\u0000tags:" <> inspect(tags, limit: :infinity, printable_limit: :infinity)

    NativeKernel.xxh3_128_hex(encoded)
  end

  defp content_changes(changes, object, tags) do
    changes
    |> Map.put(:content_hash, content_hash(Map.merge(object, changes), tags))
    |> preserve_extraction_progress(object)
  end

  # Keep completed projections current when none of their inputs changed.
  # A pending projection stays pending, including work for an earlier body.
  defp preserve_extraction_progress(%{updated_at: _} = changes, %{body: body} = object) do
    if Map.get(changes, :body, body) == body do
      changes = carry_extraction_watermark(changes, object, :links_extracted_at)

      if Map.get(changes, :title, object.title) == object.title,
        do: carry_extraction_watermark(changes, object, :timelines_extracted_at),
        else: changes
    else
      changes
    end
  end

  defp preserve_extraction_progress(changes, _object), do: changes

  defp carry_extraction_watermark(changes, object, key) do
    case Map.get(object, key) do
      %DateTime{} = extracted_at ->
        if DateTime.compare(extracted_at, object.updated_at) in [:eq, :gt],
          do: Map.put(changes, key, changes.updated_at),
          else: changes

      nil ->
        changes
    end
  end

  @doc false
  def refresh_content_hash_in_tx(repo, object) do
    with :ok <- Repo.require_transaction(repo) do
      Ankole.Ash.update(
        object,
        :refresh_hash,
        content_changes(%{}, object, Links.tags_for_object(object.slug))
      )
    end
  end

  defp validate_slug(@lazy_skill_prefix <> _rest = slug),
    do: {:error, {:reserved_object_slug, slug}}

  defp validate_slug("agents/" <> _rest = slug),
    do: {:error, {:reserved_object_slug, slug}}

  defp validate_slug(slug) when is_binary(slug) do
    if Regex.match?(@slug_format, slug), do: :ok, else: {:error, {:invalid_slug, slug}}
  end

  defp validate_slug(_slug), do: {:error, :missing_slug}

  defp validate_slug_available(slug) do
    taken =
      present?(Ash.Query.filter(Object, slug == ^slug)) or
        present?(Ash.Query.filter(SlugAlias, alias_slug == ^slug))

    if taken, do: {:error, {:slug_taken, slug}}, else: :ok
  end

  defp present?(query),
    do: query |> Ash.Query.select([]) |> Ash.Query.limit(1) |> Ankole.Ash.read!() != []

  defp maybe_console_prefix(query, prefix) when is_binary(prefix) and prefix != "" do
    Ash.Query.filter(query, fragment("? LIKE ?", slug, ^(prefix <> "%")))
  end

  defp maybe_console_prefix(query, _prefix), do: query

  defp maybe_console_search(query, term) when is_binary(term) and term != "" do
    pattern = "%" <> Repo.escape_like(term) <> "%"

    Ash.Query.filter(
      query,
      fragment("? ILIKE ?", title, ^pattern) or fragment("? ILIKE ?", slug, ^pattern)
    )
  end

  defp maybe_console_search(query, _term), do: query

  defp filter_console_deleted(query, true),
    do: Ash.Query.filter(query, not is_nil(deleted_at))

  defp filter_console_deleted(query, _other),
    do: Ash.Query.filter(query, is_nil(deleted_at))

  @doc """
  Lists the installed object type names that writes accept, in name order.
  """
  @spec installed_type_names() :: [String.t()]
  def installed_type_names do
    Enum.map(writable_types(), & &1.name)
  end

  @doc "Lists the installed types available to generic object creators."
  @spec writable_types() :: [SchemaType.t()]
  def writable_types do
    SchemaType
    |> Ash.Query.filter(name not in ^@reserved_types)
    |> Ash.Query.sort(:name)
    |> Ankole.Ash.read!()
  end

  # The error carries the installed types so the caller can select one.
  defp validate_type(type) when type in @reserved_types,
    do: {:error, {:reserved_object_type, type}}

  defp validate_type(type) when is_binary(type) and type != "" do
    case Ankole.Ash.read_one!(Ash.Query.filter(SchemaType, name == ^type)) do
      %SchemaType{} = schema_type ->
        {:ok, schema_type}

      nil ->
        {:error,
         {:unknown_object_type, type,
          %{
            installed_types: installed_type_names(),
            vocabulary_terms: Vocabulary.closest_terms(type),
            hint:
              "Use an installed type. For an unmodeled concept, use type \"note\" with a vocabulary term as tag; vocabulary_terms lists the canonical terms closest to the rejected type."
          }}}
    end
  end

  defp validate_type(_type), do: {:error, :missing_object_type}

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

  defp insert_source_projection(source, attrs, type, body) do
    object =
      %{
        id: UUIDv7.autogenerate(),
        slug: attrs[:slug],
        type: type,
        subtype: normalize_optional(attrs[:subtype]),
        title: attrs[:title],
        body: body,
        meta: attrs[:meta] || %{},
        managed_by_source_id: source.id,
        updated_at: DateTime.utc_now(:microsecond)
      }
      |> content_changes(%{}, [])

    with {:ok, object} <- Ankole.Ash.create(Object, :create_projection, object) do
      Chunks.reconcile_in_tx(object)
    end
  end

  defp update_library_projection(object, page) do
    changes =
      %{
        type: page.type,
        subtype: page.subtype,
        title: page.title,
        body: page.body,
        meta: %{},
        deleted_at: nil,
        updated_at: DateTime.utc_now(:microsecond)
      }
      |> content_changes(object, Links.tags_for_object(object.slug))

    if object.content_hash == changes.content_hash and object.deleted_at == nil and
         object.type == page.type do
      add_library_aliases(page)
      {:ok, :unchanged}
    else
      with {:ok, object} <-
             Ankole.Ash.update(
               object,
               :project,
               Map.put(changes, :source_id, object.managed_by_source_id)
             ),
           {:ok, _object} <- Chunks.reconcile_in_tx(object) do
        add_library_aliases(page)
        {:ok, :projected}
      end
    end
  end

  # Instance aliases remain when the shipped file changes its alias list.
  defp add_library_aliases(page) do
    Enum.each(page.aliases, &Links.add_alias(page.slug, &1))
  end

  defp update_source_projection(object, attrs, type, body) do
    meta = Map.get(attrs, :meta, object.meta)

    changes =
      %{
        type: type,
        subtype: normalize_optional(attrs[:subtype]),
        title: attrs[:title],
        body: body,
        meta: meta,
        deleted_at: nil,
        updated_at: DateTime.utc_now(:microsecond)
      }
      |> content_changes(object, Links.tags_for_object(object.slug))

    with {:ok, object} <-
           Ankole.Ash.update(
             object,
             :project,
             Map.put(changes, :source_id, object.managed_by_source_id)
           ) do
      Chunks.reconcile_in_tx(object)
    end
  end

  # This is the ordinary write gate, checked after taking the Object lock.
  # Restore and managed projections have their own lifecycle entry points.
  defp guard_editable(%Object{deleted_at: deleted_at}) when not is_nil(deleted_at),
    do: {:error, :object_deleted}

  defp guard_editable(object), do: guard_unmanaged(object)

  # A Source-managed page takes its body from the Source, so every instance
  # edit path refuses it. Claims, links, and timelines stay open as
  # instance-owned periphery.
  defp guard_unmanaged(%Object{managed_by_source_id: nil}), do: :ok

  defp guard_unmanaged(%Object{slug: slug, managed_by_source_id: source_id}) do
    if source_kind(source_id) == "library" do
      library_managed_error(slug)
    else
      {:error,
       {:source_managed, slug,
        %{
          hint:
            "This page body is owned by a Brain Source. Relearn or archive the Source instead of editing the body."
        }}}
    end
  end

  defp library_managed_error(slug) do
    {:error,
     {:library_managed, slug,
      %{
        hint:
          "This page is product-shipped library knowledge and updates with the product. Attach claims, links, or timeline entries instead of editing the body, or fork the page in the Console to take it over."
      }}}
  end

  defp source_kind(source_id) do
    case Source |> Ash.Query.filter(id == ^source_id) |> Ankole.Ash.read_one!() do
      %Source{kind: kind} -> kind
      nil -> nil
    end
  end

  defp updated_subtype(%{subtype: subtype}, %Object{type: "agent"})
       when subtype != "internal",
       do: {:error, {:reserved_object_type, "agent"}}

  defp updated_subtype(attrs, object) do
    case Map.fetch(attrs, :subtype) do
      {:ok, subtype} -> {:ok, normalize_optional(subtype)}
      :error -> {:ok, object.subtype}
    end
  end

  defp updated_tags(attrs, object) do
    case Map.fetch(attrs, :tags) do
      {:ok, tags} -> Links.normalize_tags(tags)
      :error -> {:ok, Links.tags_for_object(object.slug)}
    end
  end

  defp snapshot_version(%Object{} = object, author) do
    Ankole.Ash.create(ObjectVersion, :snapshot, %{
      object_id: object.id,
      author: author,
      body: object.body,
      meta: object.meta,
      tags: Links.tags_for_object(object.slug)
    })
  end

  @doc false
  @spec lock_object_in_tx(module(), String.t()) :: {:ok, Object.t()} | {:error, :not_found}
  def lock_object_in_tx(_repo, slug) do
    Object
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
    |> case do
      %Object{} = object -> {:ok, object}
      nil -> {:error, :not_found}
    end
  end

  defp normalize_optional(nil), do: nil

  defp normalize_optional(value) when is_binary(value), do: Ankole.Attrs.optional_text(value)
end
