defmodule Ankole.Files.Vfs.Applet do
  @moduledoc "Read-only views of the applet owner's published file manifest."
  alias Ankole.Files.Vfs.Namespace

  def resolve(scope, node, parts) do
    path = Enum.join(parts, "/")

    with {:ok, files} <- visible_files(scope, node) do
      cond do
        file = Enum.find(files, &(&1.path == path)) ->
          {:ok,
           %{
             node: node,
             kind: :virtual_file,
             name: List.last(parts),
             content: {:object, file.object_id, file.size},
             size: file.size,
             etag: "\"applet:#{node.id}:#{file.object_id}\"",
             modified: node.updated_at,
             content_type: MIME.from_path(file.path)
           }}

        Enum.any?(files, &String.starts_with?(&1.path, path <> "/")) ->
          {:ok,
           %{node: node, kind: :virtual_directory, name: List.last(parts), applet_path: parts}}

        true ->
          {:error, :not_found}
      end
    end
  end

  def children(scope, entry) do
    parts = Map.get(entry, :applet_path, [])
    prefix = if parts == [], do: "", else: Enum.join(parts, "/") <> "/"

    with {:ok, files} <- visible_files(scope, entry.node) do
      files
      |> Enum.filter(&String.starts_with?(&1.path, prefix))
      |> Enum.map(&(String.replace_prefix(&1.path, prefix, "") |> String.split("/") |> hd()))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, entries} ->
        case resolve(scope, entry.node, parts ++ [name]) do
          {:ok, item} -> {:cont, {:ok, [item | entries]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        error -> error
      end
    end
  end

  defp visible_files(scope, node) do
    with {:ok, files} <- Ankole.Pod.Files.list_files(node.id) do
      {:ok,
       Enum.filter(files, fn file ->
         with {:ok, action} <- Ankole.Pod.Files.required_read_action(%{type: :applet}, file.path),
              {:ok, _} <- Namespace.authorize(scope, node, action),
              do: true,
              else: (_ -> false)
       end)}
    end
  end
end
