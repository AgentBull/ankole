defmodule Ankole.Brain.Namespace do
  @moduledoc "Owns the independent Brain root, ontology categories and internal identity pages."
  alias Ankole.{ActorRef, Repo}
  alias Ankole.AuthZ.Root
  alias Ankole.Pod.Access
  alias Ankole.Pod.Pages.Tree, as: Nodes
  alias Ankole.Pod.{Knowledge, Pages}

  def committed(_result) do
    with {:ok, root} <- root(), do: Pages.committed_tree(root)
  end

  def root, do: system_node("ankole_brain")

  defdelegate system_node(key), to: Nodes

  def object_metadata(parent, attrs) do
    metadata = Ankole.Attrs.get(attrs, :metadata, %{})

    if Ankole.Attrs.get(attrs, :type) in [:knowledge, "knowledge"] do
      with {:ok, [%{system_key: "ankole_brain"}, category | _]} <- Nodes.path(parent),
           %{} = type <-
             Ankole.Brain.Schemas.SchemaType
             |> Ankole.Ash.read!()
             |> Enum.find(&(String.trim_trailing(&1.slug_prefix, "/") == category.name)) do
        {:ok, Map.put_new(metadata, "entity_type", type.name)}
      else
        nil -> {:error, :unknown_brain_category}
        _ -> {:error, :invalid_page_domain}
      end
    else
      {:ok, metadata}
    end
  end

  def ensure_namespace_in_tx do
    Nodes.lock_tree()

    with {:ok, root} <- ensure_root_in_tx(),
         {:ok, agents} <- ensure_system_in_tx(root.id, "agents", "ankole_brain_agents") do
      {:ok, %{root: root, agents: agents}}
    end
  end

  def ensure_categories_in_tx do
    with {:ok, %{root: root}} <- ensure_namespace_in_tx() do
      Ankole.Brain.Schemas.SchemaType
      |> Ankole.Ash.read!()
      |> Enum.map(fn type ->
        name = String.trim_trailing(type.slug_prefix, "/")

        key =
          if name == "agents", do: "ankole_brain_agents", else: "ankole_brain_category:" <> name

        ensure_system_in_tx(root.id, name, key)
      end)
      |> Ankole.Attrs.collect_results()
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  def ensure_agent_in_tx(uid, type) do
    with {:ok, namespace} <- ensure_namespace_in_tx(),
         {:ok, %{agent: agent}} <- Ankole.Principals.get_agent(uid),
         {:ok, node} <-
           ensure_child_in_tx(namespace.agents.id, uid, :knowledge,
             inherit_permissions: type != :personal_assistant
           ),
         :ok <- agent_grants(node, agent),
         {:ok, _page} <-
           ensure_empty_content(node, %{
             "entity_type" => "agent",
             "subtype" => "internal",
             "uid" => uid
           }) do
      {:ok, node}
    end
  end

  defdelegate child(parent_id, name), to: Nodes

  def sync_principal_status_in_tx(principal) do
    assistant =
      if principal.type == :human, do: Ankole.Principals.personal_assistant(principal.uid)

    subjects = [principal | if(assistant, do: [assistant.principal], else: [])]

    subjects
    |> Enum.flat_map(fn subject ->
      slug = Ankole.Brain.Scope.principal_page_slug(subject.type, subject.uid)

      case Ankole.Brain.Objects.get_by_slug(slug) do
        {:ok, page} -> [{page.id, subject.status}]
        {:error, :not_found} -> []
      end
    end)
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {id, status}, :ok ->
      result =
        with {:ok, page} <- Nodes.lock(id),
             {:ok, %{content: content}} <- Knowledge.read_in_tx(id) do
          metadata =
            if status == :active,
              do: Map.delete(page.metadata, "archived"),
              else: Map.put(page.metadata, "archived", true)

          if metadata == page.metadata do
            :ok
          else
            with {:ok, _} <-
                   Knowledge.put_in_tx(id, %{xml: content.content, metadata: metadata},
                     author: system_author()
                   ),
                 do: :ok
          end
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def ensure_child_in_tx(parent_id, name, type, attrs \\ []) do
    Nodes.lock_tree()

    case child(parent_id, name) do
      {:ok, %{type: ^type} = node} ->
        {:ok, node}

      {:ok, _node} ->
        {:error, {:knowledge_path_kind_conflict, name, type}}

      {:error, :not_found} ->
        with {:ok, node} <-
               Nodes.create_in_tx(
                 Map.merge(Map.new(attrs), %{
                   parent_id: parent_id,
                   name: name,
                   type: type,
                   created_by: system_author()
                 })
               ),
             {:ok, _} <- Pages.initialize_metadata_in_tx(node.id, %{title: name}),
             do: {:ok, node}
    end
  end

  def put_markdown_in_tx(node, markdown, upstream_state \\ %{}) do
    with {:ok, parsed} <- Ankole.Kernel.knowledge_parse(markdown),
         {:ok, %{page: page}} <-
           Knowledge.put_in_tx(
             node.id,
             %{
               xml: parsed.xml,
               metadata: parsed.metadata,
               upstream_state: upstream_state
             },
             author: system_author()
           ),
         do: {:ok, page}
  end

  defp ensure_root_in_tx do
    case root() do
      {:ok, root} ->
        {:ok, root}

      {:error, :not_found} ->
        with {:ok, root} <- Nodes.ensure_brain_root_in_tx(),
             :ok <- root_grants(root),
             do: {:ok, root}
    end
  end

  defp ensure_system_in_tx(parent, name, key, inherit \\ true) do
    case system_node(key) do
      {:ok, node} ->
        {:ok, node}

      {:error, :not_found} ->
        with {:ok, node} <-
               ensure_child_in_tx(parent, name, :knowledge,
                 system_key: key,
                 inherit_permissions: inherit
               ) do
          if node.system_key == key,
            do: {:ok, node},
            else: Nodes.claim_system_in_tx(node, key)
        end
    end
  end

  defp system_author, do: ActorRef.from_principal(%{tenant_id: Repo.tenant_id!(), uid: "system"})

  defp root_grants(root) do
    with {:ok, root} <- restrict_inheritance(root),
         {:ok, humans} <- Root.ensure_all_humans_group(),
         {:ok, agents} <- Root.ensure_all_agents_group(),
         {:ok, admins} <- Root.ensure_pod_admin_group(),
         :ok <- Access.put_role(%{group_id: humans.id}, "drive:**:#{root.id}:**", "view"),
         :ok <- Access.put_role(%{group_id: agents.id}, "drive:**:#{root.id}:**", "view"),
         :ok <- Access.put_role(%{group_id: admins.id}, "drive:**:#{root.id}:**", "manage"),
         do: :ok
  end

  defp agent_grants(node, %{type: :personal_assistant, uid: uid, owner_principal_uid: owner}) do
    with {:ok, node} <- restrict_inheritance(node),
         :ok <- Access.put_role(%{principal_uid: owner}, "drive:**:#{node.id}:**", "manage"),
         :ok <- Access.put_role(%{principal_uid: uid}, "drive:**:#{node.id}:**", "view"),
         do: :ok
  end

  defp agent_grants(_node, _agent), do: :ok

  defp restrict_inheritance(%{inherit_permissions: false} = node), do: {:ok, node}

  defp restrict_inheritance(node),
    do: Access.update_anchor_in_tx(node, :sharing, %{inherit_permissions: false})

  defp ensure_empty_content(node, metadata) do
    case Knowledge.read_in_tx(node.id) do
      {:ok, %{page: page, content: content}} when not is_nil(content) and page.revision > 0 ->
        {:ok, page}

      {:ok, _} ->
        with {:ok, parsed} <- Ankole.Kernel.knowledge_parse(""),
             {:ok, %{page: page}} <-
               Knowledge.put_in_tx(node.id, %{xml: parsed.xml, metadata: metadata},
                 author: system_author()
               ),
             do: {:ok, page}
    end
  end
end
