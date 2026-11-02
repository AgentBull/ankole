defmodule Ankole.AIAgent.Library.Knowledge do
  @moduledoc "Owns the shared knowledge namespace and the Agent identity pages."
  alias Ankole.{ActorRef, Repo}
  alias Ankole.AuthZ.Root
  alias Ankole.Files.{Access, Nodes}
  alias Ankole.Pod.{Knowledge, Pages}

  def root, do: system_node("ankole_brain")

  defdelegate system_node(key), to: Nodes

  def ensure_namespace_in_tx do
    Nodes.lock_tree()

    with {:ok, public} <- Nodes.ensure_public_root_in_tx(),
         {:ok, root} <- ensure_root_in_tx(public.id),
         {:ok, agents} <- ensure_system_in_tx(root.id, "agents", "ankole_brain_agents"),
         {:ok, skills} <- ensure_system_in_tx(root.id, "skills", "ankole_brain_skills") do
      {:ok, %{root: root, agents: agents, skills: skills}}
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
         {:ok, _page} <- ensure_empty_content(node, %{"entity_type" => "agent", "uid" => uid}) do
      {:ok, node}
    end
  end

  defdelegate child(parent_id, name), to: Nodes

  def ensure_child_in_tx(parent_id, name, kind, attrs \\ []) do
    Nodes.lock_tree()

    case child(parent_id, name) do
      {:ok, %{kind: ^kind} = node} ->
        {:ok, node}

      {:ok, _node} ->
        {:error, {:knowledge_path_kind_conflict, name, kind}}

      {:error, :not_found} ->
        with {:ok, node} <-
               Nodes.create_in_tx(
                 Map.merge(Map.new(attrs), %{
                   parent_id: parent_id,
                   name: name,
                   kind: kind,
                   created_by: system_author()
                 })
               ),
             {:ok, _} <- Pages.ensure_properties_in_tx(node.id, %{title: name}),
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

  defp ensure_root_in_tx(public_id) do
    case root() do
      {:ok, root} ->
        {:ok, root}

      {:error, :not_found} ->
        with {:ok, root} <- ensure_system_in_tx(public_id, "AnkoleBrain", "ankole_brain", false),
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
               ensure_child_in_tx(parent, name, :folder,
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
      {:ok, %{page: page, content: content}} when not is_nil(content) ->
        {:ok, page}

      {:ok, %{content: nil}} ->
        with {:ok, parsed} <- Ankole.Kernel.knowledge_parse(""),
             {:ok, %{page: page}} <-
               Knowledge.put_in_tx(node.id, %{xml: parsed.xml, metadata: metadata},
                 author: system_author()
               ),
             do: {:ok, page}
    end
  end
end
