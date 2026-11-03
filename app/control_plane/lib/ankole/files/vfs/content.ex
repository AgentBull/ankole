defmodule Ankole.Files.Vfs.Content do
  @moduledoc "Projects immutable file objects and Pod revisions for WebDAV reads and replacements."
  require Ash.Query
  alias Ankole.{Files, Kernel, Pod}
  alias Ankole.Files.Vfs.Namespace
  alias Ankole.Pod.Pages

  def stats(entries) do
    ids = for %{node: %{type: kind, id: id}} <- entries, kind in [:doc, :knowledge], do: id
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

      node.type == :file ->
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

      node.type in [:doc, :knowledge] ->
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

  def read(%{kind: kind})
      when kind in [:root, :folder, :children, :base, :applet, :virtual_directory],
      do: {:error, :is_a_directory}

  def read(%{node: %{type: :file, object_id: nil}}), do: {:ok, {:bytes, ""}}
  def read(%{content: content}), do: {:ok, content}
  def read(%{node: %{type: :file, object_id: id}, size: size}), do: {:ok, {:object, id, size}}

  def read(%{node: %{type: kind} = node}) when kind in [:doc, :knowledge] do
    with {:ok, markdown} <- markdown(node), do: {:ok, {:bytes, markdown}}
  end

  def read(_), do: {:error, :is_a_directory}

  def replace_version_in_tx(scope, node, prepared, expected, current) do
    if expected in [nil, "*", current],
      do: replace_in_tx(scope, node, prepared),
      else: {:error, :precondition_failed}
  end

  def replace_in_tx(scope, %{type: :file} = node, prepared),
    do:
      Ankole.Pod.commit_node_object_in_tx(
        scope.actor,
        node.id,
        prepared.stored,
        Map.take(prepared, [:content_type])
      )

  def replace_in_tx(scope, %{type: :doc} = node, prepared),
    do: Pod.write_vfs_markdown_in_tx(scope.actor, node.id, prepared.bytes)

  def replace_in_tx(_, _, _), do: {:error, :is_a_directory}

  def clear_in_tx(scope, %{type: :doc} = page),
    do:
      Pod.Documents.write_in_tx(
        scope.actor,
        page.id,
        page.revision,
        Kernel.page_validate("<page />")
      )

  def create_in_tx(scope, parent, name, :doc, prepared) do
    with {:ok, parsed} <- Kernel.vfs_document_reconcile("<page />", prepared.bytes) do
      Pages.create_in_tx(
        scope.actor,
        %{
          parent_id: parent.id,
          title: name,
          type: :doc,
          xml: parsed.xml
        },
        exact_name: true
      )
    end
  end
end
