defmodule Ankole.Files.Vfs.Content do
  @moduledoc "Projects immutable file objects and Pod revisions for WebDAV reads and replacements."
  require Ash.Query
  alias Ankole.{Files, Kernel, Pod}
  alias Ankole.Files.Vfs.Namespace
  alias Ankole.Pod.{Knowledge, Pages}

  def stats(entries) do
    ids = for %{node: %{kind: kind, id: id}} <- entries, kind in [:doc, :knowledge], do: id
    properties = Pod.vfs_properties(ids)
    object_ids = for %{node: %{object_id: id}} <- entries, is_binary(id), do: id

    objects =
      Files.Schemas.FileObject
      |> Ash.Query.filter(id in ^object_ids)
      |> Ankole.Ash.read!()
      |> Map.new(&{&1.id, &1})

    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case stat(entry, properties, objects) do
        {:ok, meta} -> {:cont, {:ok, [meta | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  def stat(entry) do
    with {:ok, [meta]} <- stats([entry]), do: {:ok, meta}
  end

  defp stat(%{kind: :root} = entry, _, _),
    do:
      {:ok,
       Map.merge(entry, %{
         etag: "\"root\"",
         size: 0,
         content_type: "httpd/unix-directory",
         modified: DateTime.from_unix!(0)
       })}

  defp stat(%{etag: _, size: _} = entry, _, _), do: {:ok, entry}

  defp stat(%{node: node} = entry, properties, objects) do
    cond do
      Namespace.collection?(entry) ->
        {:ok,
         metadata(
           entry,
           "\"directory:#{node.id}:#{DateTime.to_unix(node.updated_at, :microsecond)}\"",
           0,
           "httpd/unix-directory"
         )}

      node.kind == :file ->
        object = objects[node.object_id]

        {:ok,
         metadata(
           entry,
           "\"file:#{node.id}:#{node.object_id || "empty"}\"",
           if(object, do: object.size, else: 0),
           node.content_type || "application/octet-stream"
         )
         |> Map.put(
           :fingerprint,
           if(object, do: "sha256:" <> Base.encode16(object.sha256, case: :lower), else: "")
         )}

      node.kind in [:doc, :knowledge] ->
        with {:ok, property} <- Pod.vfs_property_in_tx(node, properties[node.id]) do
          {:ok,
           metadata(
             entry,
             "\"page:#{node.id}:rev:#{property.revision}\"",
             property.vfs_md_size,
             "text/markdown; charset=utf-8"
           )
           |> Map.put(:fingerprint, "blake3:" <> property.vfs_md_blake3)}
        end
    end
  end

  defp metadata(entry, etag, size, content_type),
    do:
      Map.merge(entry, %{
        etag: etag,
        size: size,
        content_type: content_type,
        modified: entry.node.updated_at
      })

  defdelegate markdown(node), to: Pod, as: :vfs_markdown

  def read(%{node: %{kind: :file, object_id: nil}}), do: {:ok, {:bytes, ""}}
  def read(%{content: content}), do: {:ok, content}
  def read(%{node: %{kind: :file, object_id: id}, size: size}), do: {:ok, {:object, id, size}}

  def read(%{node: %{kind: kind} = node}) when kind in [:doc, :knowledge] do
    with {:ok, markdown} <- markdown(node), do: {:ok, {:bytes, markdown}}
  end

  def read(_), do: {:error, :is_a_directory}

  def replace_version_in_tx(scope, node, prepared, expected, current) do
    cond do
      expected in [nil, "*", current] ->
        with {:ok, _} <- replace_in_tx(scope, node, prepared), do: {:ok, false}

      node.kind == :knowledge ->
        prefix = "\"page:#{node.id}:rev:"

        with true <- String.starts_with?(expected, prefix),
             {revision, "\""} <- Integer.parse(String.replace_prefix(expected, prefix, "")),
             {:ok, parsed} <- Kernel.knowledge_parse(prepared.bytes),
             {:ok, _} <- Pod.merge_vfs_knowledge_in_tx(scope.actor, node.id, revision, parsed),
             do: {:ok, true},
             else: (
               {:error, _} = error -> error
               _ -> {:error, :precondition_failed}
             )

      true ->
        {:error, :precondition_failed}
    end
  end

  def replace_in_tx(scope, %{kind: :file} = node, prepared),
    do:
      Files.commit_node_object_in_tx(
        scope.actor,
        node.id,
        prepared.stored,
        Map.take(prepared, [:content_type])
      )

  def replace_in_tx(scope, %{kind: :knowledge} = node, prepared) do
    with {:ok, parsed} <- Kernel.knowledge_parse(prepared.bytes),
         {:ok, page} <- Pages.lock(node.id),
         do:
           Knowledge.put_in_tx(page.id, parsed, actor: scope.actor, base_revision: page.revision)
  end

  def replace_in_tx(scope, %{kind: :doc} = node, prepared),
    do: Pod.write_vfs_markdown_in_tx(scope.actor, node.id, prepared.bytes)

  def replace_in_tx(_, _, _), do: {:error, :is_a_directory}

  def create_in_tx(scope, parent, name, kind, prepared) when kind in [:doc, :knowledge] do
    with {:ok, parsed} <- Kernel.knowledge_parse(prepared.bytes) do
      Pages.create_in_tx(
        scope.actor,
        %{
          parent_id: parent.id,
          title: name,
          type: kind,
          xml: parsed.xml,
          metadata: parsed.metadata
        },
        exact_name: true
      )
    end
  end
end
