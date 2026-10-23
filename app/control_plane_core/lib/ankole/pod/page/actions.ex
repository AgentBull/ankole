defmodule Ankole.Pod.Page.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Pod.Page`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:create_page, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Pages.create_in_tx(a.uid, a.attrs)
    end)
  end

  defp action(:update_page, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Pages.update_in_tx(a.uid, a.id, a.attrs)
    end)
  end

  defp action(:move_page, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Pages.move_in_tx(a.uid, a.id, a.attrs)
    end)
  end

  defp action(:delete_page, %{arguments: a}, _context),
    do: Ankole.Pod.Access.write(a.authority, fn -> Ankole.Pod.Pages.delete_in_tx(a.uid, a.id) end)

  defp action(:delete_embedded_page, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Pages.delete_embed_in_tx(a.uid, a.parent_id, a.child_id)
    end)
  end

  defp action(:restore_page, %{arguments: a}, _context),
    do:
      Ankole.Pod.Access.write(a.authority, fn -> Ankole.Pod.Pages.restore_in_tx(a.uid, a.id) end)

  defp action(:set_page_sharing, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Pages.set_sharing_in_tx(a.uid, a.id, a.attrs)
    end)
  end

  defp action(:set_space_role, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Pages.set_space_in_tx(a.uid, a.role)
    end)
  end

  defp action(:set_space_agent, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Pages.space_agent_in_tx(a.uid, a.agent_uid, a.role)
    end)
  end

  defp action(:remove_space_agent, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Pages.remove_space_agent_in_tx(a.uid, a.agent_uid)
    end)
  end

  defp action(:read_page, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Pod.Pages.get_in_tx(a.uid, a.id))

  defp action(:read_page_changes, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Pod.Documents.since_in_tx(a.uid, a.id, a.revision))

  defp action(:read_page_files, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Pod.Files.manifest_in_tx(a.uid, a.id))

  defp action(:read_applet, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Pod.Applets.published_in_tx(a.uid, a.id, a.revision))

  defp action(:write_document, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Documents.write_in_tx(a.uid, a.id, a.base_revision, a.validation)
    end)
  end

  defp action(:apply_document_changes, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Documents.apply_in_tx(a.uid, a.id, a.batch)
    end)
  end

  defp action(:commit_page_file, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Files.commit_upload_in_tx(a.uid, a.id, a.upload)
    end)
  end

  defp action(:publish_applet, %{arguments: a}, _context) do
    Ankole.Pod.Access.write(a.authority, fn ->
      Ankole.Pod.Files.publish_in_tx(a.uid, a.id, a.base_revision, a.upserts)
    end)
  end

  defp action(:start_purge, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Pod.Jobs.PurgePage.start_in_tx(a.id))

  defp action(:purge_page_references, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Pod.Jobs.PurgePage.remove_references_in_tx(a.id))

  defp action(:purge_pages, %{arguments: a}, _context),
    do: Ankole.Errors.wrap(Ankole.Pod.Jobs.PurgePage.remove_pages_in_tx(a.ids))
end
