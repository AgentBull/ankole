defmodule Ankole.Files.Schemas.DriveFile.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Files.Schemas.DriveFile`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:commit_paths, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Files.commit(Ankole.Repo, a.drive, a.upserts, a.deletes))

  defp action(:move_paths, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Files.move_in_tx(a.drive, a.from, a.to))

  defp action(:delete_paths, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Files.delete_in_tx(a.drive, a.path))

  defp action(:list_snapshot, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Files.list_snapshot_in_tx(a.drive, a.prefix, a.opts))
end
