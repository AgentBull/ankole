defmodule Ankole.Brain.Objects do
  @moduledoc "Resolves knowledge identities and composes writes through the Pod page owner."
  require Ash.Query
  alias Ankole.Brain.Namespace, as: LibraryKnowledge
  alias Ankole.Brain.{Access, Links, Scope}
  alias Ankole.Brain.Schemas.{Page, SlugAlias, ObjectAlias, SchemaType}
  alias Ankole.Pod.Pages.Tree, as: Nodes
  alias Ankole.Pod.Knowledge

  def get_by_slug(reference, opts \\ [])
  def get_by_slug(reference, _opts) when not is_binary(reference), do: {:error, :not_found}

  def get_by_slug(reference, opts) do
    with {:ok, id} <- reference_id(reference) do
      query = Ash.Query.filter(Page, id == ^id)
      query = if opts[:select], do: Ash.Query.select(query, opts[:select]), else: query

      query =
        case Keyword.get(opts, :access) do
          nil -> query
          access -> Access.filter_objects(query, access)
        end

      case Ankole.Ash.read_one(query) do
        {:ok, nil} -> {:error, :not_found}
        {:ok, page} -> if(opts[:select], do: {:ok, page}, else: hydrate(page))
        error -> error
      end
    end
  end

  defp reference_id(reference) do
    case Ecto.UUID.cast(reference) do
      # Ecto also accepts arbitrary 16-byte binaries as UUIDs; references are text paths or UUIDs.
      {:ok, id} when byte_size(reference) == 36 ->
        {:ok, id}

      _ ->
        with {:ok, root} <- LibraryKnowledge.root(),
             {:ok, node} <- Ankole.Files.Paths.resolve(root, normalize_path(reference)),
             do: {:ok, node.id}
    end
  end

  def resolve_slug(reference, opts \\ []) do
    case get_by_slug(reference, opts) do
      {:error, :not_found} ->
        resolve_alias(reference, opts)

      {:ok, %{deleted_at: deleted}} = result when not is_nil(deleted) ->
        case resolve_alias(reference, opts) do
          {:error, :not_found} -> result
          redirected -> redirected
        end

      result ->
        result
    end
  end

  defp resolve_alias(reference, opts) do
    case Ankole.Ash.read_one!(
           Ash.Query.filter(SlugAlias, alias_slug == ^normalize_path(reference))
         ) do
      nil -> {:error, :not_found}
      redirect -> get_by_slug(redirect.canonical_page_id, opts)
    end
  end

  def resolve_reference(reference, opts \\ []) do
    case resolve_slug(reference, opts) do
      {:error, :not_found} -> resolve_name(reference, opts)
      result -> result
    end
  end

  defp resolve_name(reference, opts) do
    normalized = Links.normalize_alias(reference)

    ids =
      ObjectAlias
      |> Ash.Query.filter(alias_norm == ^normalized)
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.subject_page_id)

    query = Page |> Ash.Query.filter((id in ^ids or title == ^reference) and is_nil(deleted_at))
    query = if opts[:access], do: Access.filter_objects(query, opts[:access]), else: query

    case Ankole.Ash.read!(query) do
      [] -> {:error, :not_found}
      [page] -> hydrate(page)
      pages -> {:ambiguous, Enum.map(pages, &Map.take(&1, [:id, :slug, :title, :type]))}
    end
  end

  defp hydrate(%{kind: kind} = page) when kind != :knowledge, do: {:ok, page}

  defp hydrate(page) do
    case Ankole.Kernel.knowledge_export(page.xml, %{}) do
      {:ok, markdown} -> {:ok, %{page | body: markdown}}
      {:error, _} = error -> error
    end
  end

  def create_object_in_tx(attrs, writer) do
    with {:ok, _} <- LibraryKnowledge.ensure_namespace_in_tx(),
         {:ok, root} <- LibraryKnowledge.root(),
         :ok <- validate_category(attrs[:slug], writer),
         {:ok, parent, name} <- destination(root, attrs[:slug]),
         :ok <- authorize(writer, parent.id, "node_edit"),
         :ok <- vacant_path(parent.id, name, attrs[:slug]),
         {:ok, node} <- LibraryKnowledge.ensure_child_in_tx(parent.id, name, :knowledge),
         {:ok, parsed} <- Ankole.Kernel.knowledge_parse(attrs[:body] || ""),
         metadata = metadata(attrs, parsed.metadata),
         {:ok, _} <-
           Knowledge.put_in_tx(
             node.id,
             %{xml: parsed.xml, metadata: metadata, title: attrs[:title] || name},
             actor: actor(writer),
             author: writer_author(writer)
           ),
         {:ok, page} <- get_by_slug(node.id) do
      {:ok, page}
    end
  end

  defp validate_category(slug, writer) when is_binary(slug) do
    category = slug |> normalize_path() |> String.split("/", trim: true) |> List.first()

    prefixes =
      SchemaType |> Ankole.Ash.read!() |> Enum.map(&String.trim_trailing(&1.slug_prefix, "/"))

    if category in prefixes or (writer == :system and category in ["people", "agents"]),
      do: :ok,
      else: {:error, :unknown_brain_category}
  end

  defp validate_category(_, _), do: {:error, :unknown_brain_category}

  defp vacant_path(parent_id, name, slug) do
    case LibraryKnowledge.child(parent_id, name) do
      {:ok, _} -> {:error, {:slug_taken, slug}}
      {:error, :not_found} -> :ok
    end
  end

  defp destination(root, slug) when is_binary(slug) and slug != "" do
    parts = slug |> normalize_path() |> String.split("/", trim: true)
    {folders, [name]} = Enum.split(parts, -1)

    Enum.reduce_while(folders, {:ok, root}, fn part, {:ok, parent} ->
      result =
        case LibraryKnowledge.child(parent.id, part) do
          {:ok, %{type: :file}} -> {:error, :not_a_directory}
          {:ok, node} -> {:ok, node}
          {:error, :not_found} -> LibraryKnowledge.ensure_child_in_tx(parent.id, part, :knowledge)
        end

      case result do
        {:ok, node} -> {:cont, {:ok, node}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parent} -> {:ok, parent, name}
      error -> error
    end
  end

  defp destination(_, _), do: {:error, :missing_slug}

  def update_object_in_tx(reference, attrs, writer, opts \\ []) do
    with {:ok, page} <- lock_object_in_tx(reference),
         :ok <- guard_editable(page),
         :ok <- authorize(writer, page.id, "node_edit"),
         {:ok, parsed} <- Ankole.Kernel.knowledge_parse(Map.get(attrs, :body, page.body)),
         base_revision = Map.get(attrs, :base_revision, page.revision),
         {:ok, _} <-
           Knowledge.put_in_tx(
             page.id,
             %{
               xml: parsed.xml,
               metadata: metadata(attrs, Map.get(attrs, :meta, page.meta)),
               title: Map.get(attrs, :title, page.title)
             },
             actor: actor(writer),
             author: opts[:author] || writer_author(writer),
             base_revision: base_revision
           ),
         do: get_by_slug(page.id)
  end

  def upsert_source_projection_in_tx(source, attrs) do
    Nodes.lock_tree()
    attrs = Map.put_new(attrs, :type, "media")

    result =
      case get_by_slug(attrs.slug) do
        {:ok, page} -> update_object_in_tx(page.id, attrs, :system)
        {:error, :not_found} -> create_object_in_tx(attrs, :system)
      end

    with {:ok, page} <- result,
         {:ok, _} <-
           Ankole.Pod.Knowledge.sync_upstream_in_tx(
             page.id,
             Map.put(attrs[:upstream_state] || %{}, "source_id", source.id)
           ),
         {:ok, node} <- Nodes.fetch(page.id),
         {:ok, _} <-
           Ankole.Pod.Access.update_anchor_in_tx(node, :sharing, %{inherit_permissions: false}),
         :ok <-
           share_source_in_tx(
             page.id,
             attrs[:source_node_id] || source.default_source_node_id || Scope.world()
           ),
         do: get_by_slug(page.id)
  end

  def share_source_in_tx(page_id, source_id) do
    Enum.reduce_while(
      [{"node_view", "view"}, {"node_edit", "edit"}, {"node_manage", "manage"}],
      :ok,
      fn {action, role}, :ok ->
        case Ankole.Pod.Access.put_role(
               %{source_node_id: source_id, source_action: action},
               "drive:**:#{page_id}:**",
               role
             ) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    )
  end

  def ensure_canonical_object_in_tx(uid, type, display_name) do
    case get_by_slug(Scope.principal_page_slug(type, uid)) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        case create_object_in_tx(
               %{
                 slug: Scope.principal_page_slug(type, uid),
                 type: if(type == :human, do: "person", else: "agent"),
                 title: display_name || uid,
                 subtype: "internal",
                 meta: %{"uid" => uid},
                 body: ""
               },
               :system
             ) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  def canonical_principal_page?(reference) do
    with {:ok, page} <- get_by_slug(reference),
         {:ok, {type, uid}} <- Scope.parse_principal_page_slug(page.slug),
         {:ok, %{type: ^type}} <- Ankole.Principals.get_principal(uid),
         {:ok, id} <- Scope.canonical_page_id(uid),
         do: id == page.id,
         else: (_ -> false)
  end

  def lock_object_in_tx(reference) do
    with {:ok, page} <- get_by_slug(reference),
         {:ok, _} <- Nodes.lock(page.id),
         do: get_by_slug(page.id)
  end

  def soft_delete_in_tx(reference, opts \\ []) do
    Nodes.lock_tree()

    with {:ok, page} <- get_by_slug(reference),
         {:ok, node} <- Nodes.lock(page.id),
         {:ok, node} <- record_forgetting_in_tx(node, page, opts),
         {:ok, trashed} <-
           Ankole.Pod.Access.update_anchor_in_tx(node, :trash, %{
             deleted_at: DateTime.utc_now(:microsecond)
           }),
         :ok <- Ankole.Pod.Pages.Lifecycle.trash_node_in_tx(page.id),
         :ok <- Nodes.schedule_purge(trashed),
         do: get_by_slug(page.id)
  end

  defp record_forgetting_in_tx(node, page, opts) do
    case Keyword.fetch(opts, :reason) do
      {:ok, reason} ->
        forgotten = %{
          "reason" => reason,
          "by" => opts[:by],
          "at" => DateTime.to_iso8601(DateTime.utc_now())
        }

        with {:ok, %{page: updated}} <-
               Knowledge.put_in_tx(page.id, %{
                 xml: page.xml,
                 metadata: Map.put(page.meta, "forgotten", forgotten)
               }),
             do: {:ok, updated}

      :error ->
        {:ok, node}
    end
  end

  def valid_holder?(holder, _opts \\ []) do
    holder in ["world", "brain"] or match?({:ok, _}, resolve_reference(holder))
  end

  def installed_type_names, do: SchemaType |> Ankole.Ash.read!() |> Enum.map(& &1.name)

  def writable_types,
    do:
      SchemaType
      |> Ash.Query.filter(name != "agent")
      |> Ash.Query.sort(:name)
      |> Ankole.Ash.read!()

  def guard_editable(%{deleted_at: nil}), do: :ok
  def guard_editable(_), do: {:error, :not_found}

  defp metadata(attrs, original) do
    original
    |> Map.merge(Map.get(attrs, :meta, %{}))
    |> maybe_metadata("tags", attrs[:tags])
    |> maybe_metadata("entity_type", attrs[:type])
    |> maybe_metadata("subtype", attrs[:subtype])
    |> maybe_metadata(
      "effective_date",
      attrs[:effective_date] && to_string(attrs[:effective_date])
    )
  end

  defp maybe_metadata(meta, _key, nil), do: meta
  defp maybe_metadata(meta, key, value), do: Map.put(meta, key, value)

  defp normalize_path(path),
    do:
      path
      |> String.trim_leading("/")
      |> String.replace_prefix("drive/Brain/", "")
      |> String.replace_prefix("Brain/", "")
      |> String.replace_prefix("AnkoleBrain/", "")

  defp authorize(:system, _, _), do: :ok

  defp authorize(uid, id, action) do
    with {:ok, _} <- Nodes.authorize(uid, id, action), do: :ok
  end

  defp writer_author(:system), do: Ankole.Brain.Config.execution_author!()

  defp writer_author(uid),
    do: Ankole.ActorRef.from_principal(%{tenant_id: Ankole.Repo.tenant_id!(), uid: uid})

  defp actor(:system), do: nil

  defp actor(uid) do
    {:ok, principal} = Ankole.Principals.get_principal(uid)
    Ankole.AuthZ.Actor.new(principal)
  end
end
