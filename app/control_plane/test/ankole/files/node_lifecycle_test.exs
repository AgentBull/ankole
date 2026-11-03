defmodule Ankole.Files.NodeLifecycleTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{Files, Repo}
  alias Ankole.Pod.Pages.Tree, as: Nodes

  setup do
    principal = human_fixture().principal
    {:ok, root} = Nodes.private_root(principal.uid)
    %{principal: principal, actor: actor_fixture(principal), root: root}
  end

  test "private root deletion cascades through nested ACL anchors and retains immutable objects",
       ctx do
    {outer, inner, file} = subtree(ctx.root)
    assert {:ok, _} = Ankole.Pod.write_node(ctx.actor, file.id, "retained for object GC")
    assert {:ok, file} = Nodes.fetch(file.id)

    assert :ok =
             Repo.transact_top_level(fn ->
               Ankole.Pod.delete_private_root_in_tx(ctx.principal.uid)
             end)

    for node <- [ctx.root, outer, inner, file],
        do: assert({:error, :not_found} == Nodes.fetch(node.id))

    assert {:ok, "retained for object GC"} = Files.read_object(file.object_id)
  end

  test "conversation root deletion cascades through nested ACL anchors", ctx do
    agent = Ankole.SessionsCase.agent_fixture().principal
    Ankole.ConversationsFixtures.grant_chat(ctx.principal.uid, agent.uid)
    conversation_id = Ankole.Ecto.UUIDv7.autogenerate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.create(ctx.principal, %{
               conversation_id: conversation_id,
               agent_uid: agent.uid,
               message_id: Ankole.Ecto.UUIDv7.autogenerate(),
               text: "Shared files"
             })

    assert {:ok, root} =
             Repo.transact_top_level(fn ->
               Ankole.Pod.ensure_conversation_root_in_tx(conversation_id)
             end)

    {outer, inner, file} = subtree(root)

    assert :ok =
             Repo.transact_top_level(fn ->
               Ankole.Pod.delete_conversation_root_in_tx(conversation_id)
             end)

    for node <- [root, outer, inner, file],
        do: assert({:error, :not_found} == Nodes.fetch(node.id))

    assert {:ok, _} = Nodes.fetch(ctx.root.id)
  end

  test "purge deletes nested ACL anchors in leaf batches without removing the live root", ctx do
    {outer, inner, file} = subtree(ctx.root)
    assert {:ok, _} = Nodes.trash(ctx.actor, outer.id)
    assert {:ok, _} = Nodes.purge(ctx.actor, outer.id)
    assert :ok = Ankole.Pod.Jobs.PurgeTree.run(%Oban.Job{args: %{"node_id" => outer.id}})

    for node <- [outer, inner, file], do: assert({:error, :not_found} == Nodes.fetch(node.id))
    assert {:ok, _} = Nodes.fetch(ctx.root.id)
  end

  test "an empty file in the trash cannot receive its first object", ctx do
    assert {:ok, file} =
             Nodes.create(ctx.actor, %{parent_id: ctx.root.id, type: :file, name: "empty.txt"})

    assert {:ok, _} = Nodes.trash(ctx.actor, file.id)
    assert {:error, :not_found} = Ankole.Pod.write_node(ctx.actor, file.id, "must not attach")
    assert {:ok, %{object_id: nil}} = Nodes.fetch(file.id)
  end

  defp subtree(root) do
    assert {:ok, nodes} =
             Repo.transact_top_level(fn ->
               {:ok, outer} =
                 Nodes.create_in_tx(%{
                   parent_id: root.id,
                   type: :doc,
                   name: "outer",
                   has_local_acl: true
                 })

               {:ok, passthrough} =
                 Nodes.create_in_tx(%{
                   parent_id: outer.id,
                   type: :doc,
                   name: "pass-through"
                 })

               {:ok, inner} =
                 Nodes.create_in_tx(%{
                   parent_id: passthrough.id,
                   type: :doc,
                   name: "inner",
                   has_local_acl: true
                 })

               {:ok, leaf_parent} =
                 Nodes.create_in_tx(%{
                   parent_id: inner.id,
                   type: :doc,
                   name: "leaf-parent"
                 })

               {:ok, file} =
                 Nodes.create_in_tx(%{parent_id: leaf_parent.id, type: :file, name: "file"})

               {:ok, {outer, inner, file}}
             end)

    {outer, inner, file} = nodes
    assert outer.acl_anchor_id == outer.id
    assert inner.acl_anchor_id == inner.id
    assert inner.parent_anchor_id == outer.id
    assert file.acl_anchor_id == inner.id
    nodes
  end
end
