defmodule Ankole.Brain.SupervisionTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain

  setup do
    %{principal: owner} = agent_fixture()
    %{principal: actor} = human_fixture()
    %{principal: peer} = human_fixture()

    %{owner_uid: owner.uid, actor_uid: actor.uid, peer_uid: peer.uid}
  end

  test "public supervision seam owns paging and returns schema-free read models", ctx do
    first_id = create_entry(ctx, "Paged Alpha", "public")
    second_id = create_entry(ctx, "Paged Beta", "public")

    assert {:ok, %{entries: [first], next_cursor: cursor}} =
             Brain.list_entries(ctx.owner_uid, query: "Paged", limit: 1)

    assert is_binary(first.id)
    assert is_binary(first.updated_at)
    assert {%DateTime{}, _id} = cursor

    assert {:ok, %{entries: [second], next_cursor: nil}} =
             Brain.list_entries(ctx.owner_uid, query: "Paged", limit: 1, cursor: cursor)

    assert MapSet.new([first.id, second.id]) == MapSet.new([first_id, second_id])
    refute Map.has_key?(first, :__struct__)
  end

  test "block-only operations derive the writable store inside Brain", ctx do
    entry_id = create_entry(ctx, "Block routing", "public")

    assert {:ok,
            %{
              results: [
                %{
                  block_id: block_id,
                  block_lock_version: block_version
                }
              ]
            }} =
             Brain.apply_human_operations(
               ctx.owner_uid,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 body: "Before",
                 expected_entry_lock_version: 1
               },
               ctx.actor_uid
             )

    assert {:ok, %{results: [%{operation: "edit_block"}]}} =
             Brain.apply_human_operations(
               ctx.owner_uid,
               %{
                 operation: "edit_block",
                 block_id: block_id,
                 body: "After",
                 expected_block_lock_version: block_version
               },
               ctx.actor_uid
             )

    assert {:ok, %{blocks: [%{body: "After", author_uid: actor_uid}]}} =
             Brain.open_entry(ctx.owner_uid, entry_id)

    assert actor_uid == ctx.actor_uid
  end

  test "mixed stores are rejected before any operation in the batch commits", ctx do
    public_id = create_entry(ctx, "Public topic", "public")
    dm_store = "dm:#{ctx.peer_uid}"
    dm_id = create_entry(ctx, "DM topic", dm_store)

    assert {:error, :mixed_store_operations} =
             Brain.apply_human_operations(
               ctx.owner_uid,
               [
                 %{
                   operation: "set_summary",
                   entry_id: public_id,
                   summary: "changed",
                   expected_entry_lock_version: 1
                 },
                 %{
                   operation: "set_summary",
                   entry_id: dm_id,
                   summary: "changed",
                   expected_entry_lock_version: 1
                 }
               ],
               ctx.actor_uid
             )

    assert {:ok, %{entry: %{summary: ""}}} = Brain.open_entry(ctx.owner_uid, public_id)
    assert {:ok, %{entry: %{summary: ""}}} = Brain.open_entry(ctx.owner_uid, dm_id)
  end

  test "single-audit recovery derives the audited store behind the public seam", ctx do
    store_key = "dm:#{ctx.peer_uid}"
    entry_id = create_entry(ctx, "Recover me", store_key)

    assert {:ok, %{results: [%{operation: "delete_entry"}]}} =
             Brain.apply_human_operations(
               ctx.owner_uid,
               %{
                 operation: "delete_entry",
                 entry_id: entry_id,
                 expected_entry_lock_version: 1
               },
               ctx.actor_uid
             )

    assert {:ok, %{audit_log: audits}} =
             Brain.list_audit(ctx.owner_uid,
               entry_id: entry_id,
               action: "delete_entry"
             )

    assert [%{id: audit_id, store_key: ^store_key}] = audits

    assert {:ok, %{restored: "delete_entry"}} =
             Brain.restore_audit(ctx.owner_uid, audit_id, ctx.actor_uid)

    assert {:ok, %{entry: %{id: ^entry_id, store_key: ^store_key}}} =
             Brain.open_entry(ctx.owner_uid, entry_id)
  end

  defp create_entry(ctx, name, store_key) do
    assert {:ok, %{results: [%{entry_id: entry_id}]}} =
             Brain.apply_human_operations(
               ctx.owner_uid,
               %{operation: "create_entry", name: name, type: "topic"},
               ctx.actor_uid,
               store_key: store_key
             )

    entry_id
  end
end
