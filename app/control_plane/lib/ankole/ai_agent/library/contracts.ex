defmodule Ankole.AIAgent.Library.Contracts do
  @moduledoc "Composes whole Agent contracts from organization and Agent pages."
  alias Ankole.AIAgent.Library.{Knowledge, SourceReader}
  alias Ankole.Files.Nodes
  alias Ankole.Pod

  def initialize_in_tx do
    with {:ok, namespace} <- Knowledge.ensure_namespace_in_tx(),
         {:ok, _} <- reconcile_template(namespace.root.id, "AGENTS.md", default_agents()),
         {:ok, _} <-
           reconcile_template(
             namespace.root.id,
             "DESIGN.md",
             SourceReader.load_default_design_template()
           ),
         do: :ok
  end

  def seed_agent_in_tx(uid, type) do
    with :ok <- initialize_in_tx(),
         {:ok, node} <- Knowledge.ensure_agent_in_tx(uid, type),
         :ok <- seed_personal_contract(node, type),
         do: :ok
  end

  def effective(uid) do
    with {:ok, namespace} <- Knowledge.root(),
         {:ok, agents} <- Knowledge.system_node("ankole_brain_agents"),
         {:ok, agent} <- Knowledge.child(agents.id, uid),
         {:ok, instructions} <- compose(uid, namespace.id, agent.id, "AGENTS"),
         {:ok, design} <- compose(uid, namespace.id, agent.id, "DESIGN") do
      {:ok, %{"agents" => instructions, "design" => design}}
    end
  end

  def default_agents do
    join(
      SourceReader.load_default_soul_template(),
      SourceReader.load_default_mission_template(),
      "\n\n"
    )
  end

  @doc "Agent objects merge recursively; arrays/scalars replace and null removes a key."
  def merge_metadata(global, local) do
    Enum.reduce(local, global, fn
      {key, nil}, merged ->
        Map.delete(merged, key)

      {key, value}, merged ->
        Map.update(merged, key, value, fn old ->
          if is_map(old) and is_map(value), do: merge_metadata(old, value), else: value
        end)
    end)
  end

  defp compose(uid, global_id, agent_id, name) do
    case read_optional(uid, agent_id, name <> ".override.md") do
      {:ok, local} when not is_nil(local) ->
        payload(name, local, [local.page.id])

      {:ok, nil} ->
        with {:ok, global} <- read_optional(uid, global_id, name <> ".md"),
             {:ok, local} <- read_optional(uid, agent_id, name <> ".md") do
          combine(name, global, local)
        end

      error ->
        error
    end
  end

  defp combine(_name, nil, nil), do: {:error, :agent_contract_missing}
  defp combine(name, global, nil), do: payload(name, global, [global.page.id])
  defp combine(name, nil, local), do: payload(name, local, [local.page.id])

  defp combine(name, global, local) do
    separator = if name == "DESIGN", do: "\n\n---\n\n", else: "\n\n"

    with {:ok, global_body} <- Ankole.Kernel.knowledge_export(global.content.content, %{}),
         {:ok, local_body} <- Ankole.Kernel.knowledge_export(local.content.content, %{}),
         {:ok, merged} <- Ankole.Kernel.knowledge_parse(join(global_body, local_body, separator)),
         {:ok, content} <-
           Ankole.Kernel.knowledge_export(
             merged.xml,
             merge_metadata(global.page.metadata, local.page.metadata)
           ) do
      {:ok, document(name, content, local.page.id, [global.page.id, local.page.id])}
    end
  end

  defp payload(name, data, ids) do
    with {:ok, content} <-
           Ankole.Kernel.knowledge_export(data.content.content, data.page.metadata),
         do: {:ok, document(name, content, data.page.id, ids)}
  end

  defp document(name, content, page_id, ids),
    do: %{
      "kind" => String.downcase(name),
      "content" => content,
      "content_hash" => SourceReader.hash(content),
      "page_id" => page_id,
      "page_ids" => ids
    }

  defp read_optional(uid, parent_id, name) do
    case Knowledge.child(parent_id, name) do
      {:error, :not_found} ->
        {:ok, nil}

      {:ok, node} ->
        with {:ok, _} <- Nodes.authorize(uid, node.id, "node_view"),
             do: Pod.Knowledge.read_in_tx(node.id)
    end
  end

  defp seed_personal_contract(node, :personal_assistant) do
    case Knowledge.child(node.id, "AGENTS.override.md") do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        markdown =
          join(
            SourceReader.load_personal_assistant_template("SOUL.md"),
            SourceReader.load_personal_assistant_template("MISSION.md"),
            "\n\n"
          )

        with {:ok, page} <-
               Knowledge.ensure_child_in_tx(node.id, "AGENTS.override.md", :knowledge),
             {:ok, _} <- Knowledge.put_markdown_in_tx(page, markdown),
             do: :ok
    end
  end

  defp seed_personal_contract(_node, _type), do: :ok

  defp reconcile_template(parent, name, markdown) do
    with {:ok, parsed} <- Ankole.Kernel.knowledge_parse(markdown),
         {:ok, canonical} <- Ankole.Kernel.knowledge_export(parsed.xml, parsed.metadata) do
      hash = SourceReader.hash(canonical)

      case Knowledge.child(parent, name) do
        {:error, :not_found} ->
          with {:ok, node} <- Knowledge.ensure_child_in_tx(parent, name, :knowledge),
               do: Knowledge.put_markdown_in_tx(node, markdown, %{"upstream_base_hash" => hash})

        {:ok, node} ->
          with {:ok, %{page: page}} <- Pod.Knowledge.read_in_tx(node.id) do
            if page.upstream_state["upstream_base_hash"] == hash,
              do: {:ok, page},
              else: update_template(node, markdown, hash)
          end
      end
    end
  end

  defp update_template(node, markdown, hash) do
    with {:ok, _} <- Nodes.lock(node.id),
         {:ok, %{page: page, content: content}} <- Pod.Knowledge.read_in_tx(node.id) do
      if is_nil(content) do
        Knowledge.put_markdown_in_tx(node, markdown, %{"upstream_base_hash" => hash})
      else
        with {:ok, current} <- Pod.Knowledge.export(node.id) do
          if SourceReader.hash(current) == page.upstream_state["upstream_base_hash"],
            do: Knowledge.put_markdown_in_tx(node, markdown, %{"upstream_base_hash" => hash}),
            else: {:ok, page}
        end
      end
    end
  end

  defp join(left, right, separator) do
    [left, right] |> Enum.reject(&(String.trim(&1) == "")) |> Enum.join(separator)
  end
end
