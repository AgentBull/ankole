defmodule Ankole.BrainFixtures do
  @moduledoc false
  alias Ankole.{Brain, Repo}
  alias Ankole.Brain.Namespace, as: Library
  alias Ankole.Pod.Access
  alias Ankole.Pod.Pages.Tree, as: Nodes

  def category_fixture(uid, name \\ "notes") do
    {:ok, _} = Brain.SchemaPacks.install_packs([])
    {:ok, category} = Brain.ObjectWrites.category(name)

    {:ok, :ok} =
      Repo.transact(fn ->
        :ok = Access.put_role(%{principal_uid: uid}, "drive:**:#{category.id}:**", "manage")
        {:ok, :ok}
      end)

    category
  end

  def page_fixture_result(attrs, writer) do
    {:ok, _} = Brain.SchemaPacks.install_packs([])

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
          Library.ensure_child_in_tx(root.id, "Test source " <> name, :knowledge,
            inherit_permissions: false
          )

        {:ok, group} = Ankole.AuthZ.get_principal_group(name)
        :ok = Access.put_role(%{group_id: group.id}, "drive:**:#{node.id}:**", "view")
        {:ok, node}
      end)

    node.id
  end
end
