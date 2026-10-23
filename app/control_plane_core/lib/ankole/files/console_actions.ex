defmodule Ankole.Files.ConsoleActions do
  @moduledoc "Lists, moves, and deletes the real Agent drive while its Worker is stopped."
  use Ash.Resource.Actions.Implementation
  alias Ankole.{Files, Principals, Errors}
  @impl true
  def run(input, _opts, _context) do
    result =
      with {:ok, uid} <- Principals.normalize_uid(input.arguments.agent_uid),
           {:ok, _} <- Principals.get_agent(uid),
           do: execute(input, uid)

    Errors.wrap(result, &describe/1)
  end

  defp execute(%{action: %{name: :console_list}, arguments: attrs}, uid) do
    with {:ok, %{folders: folders, files: files, truncated: truncated}} <-
           Files.list_children(uid, attrs.path) do
      {:ok,
       %{
         file_listing: %{
           path: attrs.path,
           folders:
             Enum.map(
               folders,
               &%{name: &1, path: if(attrs.path == "", do: &1, else: attrs.path <> "/" <> &1)}
             ),
           files: Enum.map(files, &file_json/1),
           truncated: truncated
         }
       }}
    end
  end

  defp execute(%{action: %{name: :console_move}, arguments: attrs}, uid) do
    with {:ok, moved} <- Files.move(uid, attrs.from_path, attrs.to_path),
         do: {:ok, %{moved_files: moved}}
  end

  defp execute(%{action: %{name: :console_delete}, arguments: attrs}, uid) do
    with {:ok, deleted} <- Files.delete(uid, attrs.path), do: {:ok, %{deleted_files: deleted}}
  end

  @doc false
  def file_json(file) do
    %{
      path: file.path,
      size: file.size,
      content_type: file.content_type,
      source: file.source,
      conversation_id: file.conversation_id,
      message_id: file.message_id,
      updated_at: DateTime.to_iso8601(file.updated_at)
    }
  end

  defp describe(:not_found),
    do: Errors.Invalid.NotFound.exception(resource: Files.Schemas.DriveFile)

  defp describe(:already_exists), do: {:conflict, "A file already exists at the target path", []}

  defp describe({:path_conflict, parent, child}),
    do: {:conflict, "A file cannot also be a folder", [%{parent: parent, child: child}]}

  defp describe({:invalid_path, _}),
    do:
      {"Use a relative drive path without empty, dot, or parent segments",
       [%{path: "path", message: "is invalid"}]}

  defp describe(reason) when reason in [:same_path, :move_into_itself],
    do: {"Choose a different destination outside this folder", []}

  defp describe(:invalid_uid), do: {"The Agent identifier is invalid", []}
  defp describe(_), do: nil
end
