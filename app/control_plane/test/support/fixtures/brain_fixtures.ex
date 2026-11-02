defmodule Ankole.BrainFixtures do
  @moduledoc false
  alias Ankole.{Brain, Repo}
  alias Ankole.AIAgent.Library.Knowledge, as: Library
  alias Ankole.Files.{Access, Nodes}

  def page_fixture_result(attrs, writer) do
    Repo.transact(fn ->
      with {:ok, page} <- Brain.Objects.create_object_in_tx(attrs, :system) do
        if is_binary(writer),
          do: :ok = Access.put_role(%{principal_uid: writer}, "drive:**:#{page.id}:**", "manage")

        {:ok, page}
      end
    end)
  end

  def page_id(reference) do
    {:ok, page} = Brain.Objects.resolve_reference(reference)
    page.id
  end

  def source_node("world") do
    {:ok, %{root: root}} = Repo.transact(fn -> Library.ensure_namespace_in_tx() end)
    root.id
  end

  def source_node("principal:" <> uid) do
    {:ok, node} = Repo.transact(fn -> Nodes.ensure_private_root_in_tx(uid) end)
    node.id
  end

  def source_node("group:" <> name) do
    {:ok, node} =
      Repo.transact(fn ->
        {:ok, root} = Library.root()

        {:ok, node} =
          Library.ensure_child_in_tx(root.id, "Test source " <> name, :folder,
            inherit_permissions: false
          )

        {:ok, group} = Ankole.AuthZ.get_principal_group(name)
        :ok = Access.put_role(%{group_id: group.id}, "drive:**:#{node.id}:**", "view")
        {:ok, node}
      end)

    node.id
  end
end
