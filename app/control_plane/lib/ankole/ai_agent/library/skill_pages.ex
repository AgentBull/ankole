defmodule Ankole.AIAgent.Library.SkillPages do
  @moduledoc "Reconciles shipped Skill packages and reads shared Skills through Drive permissions."
  alias Ankole.AIAgent.Library.{Contracts, Knowledge, SourceReader}
  alias Ankole.Brain.Access
  alias Ankole.Files
  alias Ankole.Files.Nodes
  alias Ankole.Pod
  alias Ankole.Repo

  def sync(sources) do
    with {:ok, _} <-
           Repo.transact_top_level(fn ->
             with :ok <- Contracts.initialize_in_tx(), do: Knowledge.ensure_namespace_in_tx()
           end) do
      sources |> Enum.map(&sync_source/1) |> Ankole.Attrs.collect_results()
    end
  end

  def catalog do
    with {:ok, root} <- Knowledge.system_node("ankole_brain_skills") do
      Nodes.list_children(root.id)
      |> Enum.filter(&(&1.kind == :knowledge))
      |> Enum.map(fn node ->
        with {:ok, %{page: page}} <- Pod.Knowledge.read_in_tx(node.id),
             {:ok, markdown} <- Pod.Knowledge.export(node.id) do
          metadata = page.metadata

          {:ok,
           %{
             name: metadata["name"] || node.name,
             description: metadata["description"] || metadata["summary"] || node.name,
             default_enabled: Map.get(metadata, "default_enabled", true),
             relative_path: node.name,
             metadata: Map.merge(metadata, %{"page_id" => node.id, "skill_root" => "knowledge"}),
             source_hash: SourceReader.hash(markdown),
             files: [%{path: "SKILL.md", content: markdown}],
             source_kind:
               if(page.upstream_state["upstream_base_hash"], do: :builtin, else: :shared)
           }}
        end
      end)
      |> Ankole.Attrs.collect_results()
    end
  end

  def visible?(skill, context) do
    case skill["metadata"]["page_id"] do
      nil ->
        private_visible?(skill["agent_uid"], context)

      id ->
        with {:ok, node} <- Nodes.fetch(id),
             do: Access.visible_node?(context, node),
             else: (_ -> false)
    end
  end

  def private_visible?(uid, context) do
    with {:ok, root} <- Nodes.private_root(uid),
         do: Access.visible_node?(context, root),
         else: (_ -> false)
  end

  def read(skill, path, context) do
    with {:ok, root} <- Nodes.fetch(skill.metadata["page_id"]),
         true <- Access.visible_node?(context, root),
         {:ok, access} <- Access.for_context(context) do
      if path == "SKILL.md" do
        with {:ok, markdown} <- Pod.Knowledge.export(root.id),
             {:ok, supplements} <- supplements(root, access),
             do: {:ok, Enum.join([markdown | supplements], "\n\n---\n\n")}
      else
        with {:ok, node} <- resolve(root, String.split(path, "/")),
             true <- Access.visible_node?(access, node),
             do: read_node(node),
             else: (_ -> {:error, :skill_file_not_found})
      end
    else
      _ -> {:error, :skill_file_not_found}
    end
  end

  def bundle(skill, context) do
    with {:ok, root} <- Nodes.fetch(skill.metadata["page_id"]),
         {:ok, access} <- Access.for_context(context),
         true <- Access.visible_node?(access, root),
         {:ok, manifest} <- read(skill, "SKILL.md", context),
         {:ok, children} <- bundle_children(root, "", access) do
      {:ok,
       [%{"path" => "SKILL.md", "content" => Base.encode64(manifest), "mode" => 0o444} | children]}
    else
      _ -> {:error, :skill_not_found}
    end
  end

  defp bundle_children(root, prefix, access) do
    Nodes.list_children(root.id)
    |> Enum.filter(&Access.visible_node?(access, &1))
    |> Enum.map(fn node ->
      path = Path.join(prefix, node.name)

      case node.kind do
        :folder ->
          bundle_children(node, path, access)

        :file ->
          with {:ok, bytes} <- Files.read_object(node.object_id),
               do:
                 {:ok,
                  [%{"path" => path, "content" => Base.encode64(bytes), "mode" => node.mode}]}

        :knowledge ->
          with {:ok, bytes} <- Pod.Knowledge.export(node.id),
               {:ok, children} <- bundle_children(node, path, access),
               do:
                 {:ok,
                  [
                    %{
                      "path" => markdown_path(path),
                      "content" => Base.encode64(bytes),
                      "mode" => 0o444
                    }
                    | children
                  ]}

        _ ->
          {:ok, []}
      end
    end)
    |> Ankole.Attrs.collect_results()
    |> case do
      {:ok, files} -> {:ok, List.flatten(files)}
      error -> error
    end
  end

  defp markdown_path(path), do: if(String.ends_with?(path, ".md"), do: path, else: path <> ".md")

  defp supplements(root, access) do
    Nodes.list_children(root.id)
    |> Enum.filter(&(&1.kind == :knowledge and Access.visible_node?(access, &1)))
    |> Enum.map(fn node ->
      with {:ok, %{page: page}} <- Pod.Knowledge.read_in_tx(node.id) do
        if page.metadata["role"] == "reference",
          do: {:ok, "Reference: #{markdown_path(node.name)} — #{page.metadata["summary"] || ""}"},
          else: Pod.Knowledge.export(node.id)
      end
    end)
    |> Ankole.Attrs.collect_results()
  end

  defp resolve(node, []), do: {:ok, node}

  defp resolve(node, [name | tail]) do
    case Knowledge.child(node.id, name) do
      {:ok, child} ->
        resolve(child, tail)

      {:error, :not_found} when tail == [] ->
        Knowledge.child(node.id, String.trim_trailing(name, ".md"))

      error ->
        error
    end
  end

  defp read_node(%{kind: :knowledge, id: id}), do: Pod.Knowledge.export(id)
  defp read_node(%{kind: :file, object_id: id}), do: Files.read_object(id)
  defp read_node(_), do: {:error, :skill_file_not_found}

  defp sync_source(source) do
    {:ok, root} = Knowledge.system_node("ankole_brain_skills")

    case Knowledge.child(root.id, source.name) do
      {:ok, node} ->
        {:ok, %{page: page}} = Pod.Knowledge.read_in_tx(node.id)

        if source.source_hash in [
             page.upstream_state["upstream_base_hash"],
             page.upstream_state["pending_upstream_hash"]
           ], do: {:ok, page}, else: prepare_and_reconcile(root.id, source)

      {:error, :not_found} ->
        prepare_and_reconcile(root.id, source)
    end
  end

  defp prepare_and_reconcile(parent, source) do
    source.files
    |> Enum.reject(&(&1.path == "SKILL.md"))
    |> Enum.map(fn file ->
      with {:ok, stored} <- Files.store(file.content), do: {:ok, Map.put(file, :stored, stored)}
    end)
    |> Ankole.Attrs.collect_results()
    |> case do
      {:ok, files} -> Repo.transact_top_level(fn -> reconcile_in_tx(parent, source, files) end)
      error -> error
    end
  end

  defp reconcile_in_tx(parent, source, files) do
    with {:ok, node} <- Knowledge.ensure_child_in_tx(parent, source.name, :knowledge),
         {:ok, _} <- Nodes.lock(node.id),
         {:ok, %{page: page, content: content}} <- Pod.Knowledge.read_in_tx(node.id) do
      lock_managed_files(page)

      if is_nil(content) or
           (package_current?(node, page) and new_paths_available?(node, page, files)) do
        with {:ok, managed} <- put_files_in_tx(node, files),
             :ok <- remove_obsolete_in_tx(page.upstream_state["files"] || %{}, managed),
             manifest = Enum.find(source.files, &(&1.path == "SKILL.md")),
             {:ok, parsed} <- Ankole.Kernel.knowledge_parse(manifest.content),
             metadata = maybe_plugin(parsed.metadata, source.metadata["agent_plugin_id"]),
             {:ok, canonical} <- Ankole.Kernel.knowledge_export(parsed.xml, metadata),
             do:
               Knowledge.put_markdown_in_tx(node, canonical, %{
                 "upstream_base_hash" => source.source_hash,
                 "content_hash" => SourceReader.hash(canonical),
                 "files" => managed
               })
      else
        with {:ok, _} <-
               Pod.Pages.update_properties_in_tx(page, :sync_upstream, %{
                 upstream_state:
                   Map.put(page.upstream_state, "pending_upstream_hash", source.source_hash)
               }),
             do: {:ok, page}
      end
    end
  end

  defp lock_managed_files(page) do
    # File content edits take their own row locks, so lock them before comparing the package.
    (page.upstream_state["files"] || %{})
    |> Map.values()
    |> Enum.map(& &1["id"])
    |> Enum.sort()
    |> Enum.each(fn id ->
      case Nodes.lock(id) do
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
      end
    end)
  end

  defp maybe_plugin(metadata, nil), do: metadata
  defp maybe_plugin(metadata, id), do: Map.put(metadata, "agent_plugin_id", id)

  defp new_paths_available?(root, page, files) do
    managed = page.upstream_state["files"] || %{}

    Enum.all?(files, fn file ->
      case resolve(root, String.split(file.path, "/")) do
        {:error, :not_found} -> true
        {:ok, node} -> get_in(managed, [file.path, "id"]) == node.id
        _ -> false
      end
    end)
  end

  defp package_current?(node, page) do
    with {:ok, content} <- Pod.Knowledge.export(node.id),
         true <- SourceReader.hash(content) == page.upstream_state["content_hash"] do
      Enum.all?(page.upstream_state["files"] || %{}, fn {path, recorded} ->
        with {:ok, file} <- resolve(node, String.split(path, "/")),
             true <- file.kind == :file,
             {:ok, object} <- Files.fetch_object(file.object_id),
             do:
               file.id == recorded["id"] and file.mode == recorded["mode"] and
                 Base.encode16(object.sha256, case: :lower) == recorded["sha256"],
             else: (_ -> false)
      end)
    else
      _ -> false
    end
  end

  defp put_files_in_tx(root, files) do
    files
    |> Enum.map(fn file ->
      parts = String.split(file.path, "/")

      with {:ok, parent} <- ensure_folders(root, Enum.drop(parts, -1)),
           {:ok, object} <- Files.complete_object_in_tx(file.stored),
           {:ok, node} <- put_file(parent.id, List.last(parts), object, file.mode),
           do:
             {:ok,
              {file.path,
               %{
                 "id" => node.id,
                 "sha256" => Base.encode16(object.sha256, case: :lower),
                 "mode" => node.mode
               }}}
    end)
    |> Ankole.Attrs.collect_results()
    |> case do
      {:ok, files} -> {:ok, Map.new(files)}
      error -> error
    end
  end

  defp ensure_folders(node, []), do: {:ok, node}

  defp ensure_folders(node, [name | rest]) do
    with {:ok, child} <- Knowledge.ensure_child_in_tx(node.id, name, :folder),
         do: ensure_folders(child, rest)
  end

  defp put_file(parent_id, name, object, mode) do
    case Knowledge.child(parent_id, name) do
      {:ok, %{kind: :file} = node} ->
        Nodes.update_in_tx(node, :content, %{object_id: object.id, mode: mode})

      {:ok, _} ->
        {:error, :official_skill_path_conflict}

      {:error, :not_found} ->
        Knowledge.ensure_child_in_tx(parent_id, name, :file,
          object_id: object.id,
          mode: mode,
          content_type: MIME.from_path(name)
        )
    end
  end

  defp remove_obsolete_in_tx(previous, current) do
    Enum.each(previous, fn {path, item} ->
      if not Map.has_key?(current, path) do
        with {:ok, node} <- Nodes.fetch(item["id"]) do
          {:ok, _} = Ankole.Ash.destroy(node, :remove)
        end
      end
    end)

    :ok
  end
end
