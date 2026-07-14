defmodule Ankole.Brain.SupervisionTest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  import Ankole.PrincipalsFixtures

  alias Ankole.Brain
  alias Ankole.Brain.Schemas.AuditLog
  alias Ankole.Repo

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

  test "dreaming fitness judges survival only on matured writes and attributes per run", ctx do
    run_a = Ecto.UUID.generate()
    run_b = Ecto.UUID.generate()

    # run A, matured, corrected within horizon
    a_corrected = dreaming_append!(ctx, run_a)
    backdate!(a_corrected.block_id, "append_block", :dreaming, 30)
    human_edit = human_edit!(ctx, a_corrected.block_id, a_corrected.block_version)
    backdate!(a_corrected.block_id, "edit_block", :human, 28)
    _ = human_edit

    # run A, matured, survived (never touched)
    a_survived = dreaming_append!(ctx, run_a)
    backdate!(a_survived.block_id, "append_block", :dreaming, 30)

    # run B, matured, human edit lands after the horizon so it counts as survived
    b_late = dreaming_append!(ctx, run_b)
    backdate!(b_late.block_id, "append_block", :dreaming, 30)
    human_edit!(ctx, b_late.block_id, b_late.block_version)
    backdate!(b_late.block_id, "edit_block", :human, 20)

    # run B, still within the horizon: pending, excluded from the rate
    b_pending = dreaming_append!(ctx, run_b)
    backdate!(b_pending.block_id, "append_block", :dreaming, 2)

    assert {:ok, fitness} = Brain.dreaming_fitness(ctx.owner_uid)

    assert fitness.horizon_days == 7
    assert fitness.produced_block_writes == 4
    assert fitness.matured_block_writes == 3
    assert fitness.pending_block_writes == 1
    assert fitness.corrected_block_writes == 1
    assert fitness.survived_block_writes == 2
    assert fitness.survival_rate == Float.round(2 / 3, 4)

    by_run = Map.new(fitness.runs, &{&1.run_id, &1})

    assert %{
             produced_block_writes: 2,
             matured_block_writes: 2,
             corrected_block_writes: 1,
             survived_block_writes: 1
           } = by_run[run_a]

    assert %{
             produced_block_writes: 2,
             matured_block_writes: 1,
             pending_block_writes: 1,
             corrected_block_writes: 0,
             survived_block_writes: 1
           } = by_run[run_b]

    assert by_run[run_b].survival_rate == 1.0
  end

  test "a human correction is attributed only to the latest preceding dreaming write", ctx do
    old_run = Ecto.UUID.generate()
    new_run = Ecto.UUID.generate()

    written = dreaming_append!(ctx, old_run)
    backdate!(written.block_id, "append_block", :dreaming, 30)

    rewritten_version = dreaming_edit!(ctx, written.block_id, written.block_version, new_run)
    backdate!(written.block_id, "edit_block", :dreaming, 29)

    human_edit!(ctx, written.block_id, rewritten_version)
    backdate!(written.block_id, "edit_block", :human, 28)

    assert {:ok, fitness} = Brain.dreaming_fitness(ctx.owner_uid)

    by_run = Map.new(fitness.runs, &{&1.run_id, &1})

    # The old run's write was superseded by the new run before the human edit, so
    # the correction is attributed to the new run only.
    assert %{corrected_block_writes: 0, survived_block_writes: 1} = by_run[old_run]
    assert %{corrected_block_writes: 1, survived_block_writes: 0} = by_run[new_run]
    assert fitness.corrected_block_writes == 1
    assert fitness.matured_block_writes == 2
  end

  test "dreaming fitness reports an empty signal and rejects out-of-range windows", ctx do
    assert {:ok, fitness} = Brain.dreaming_fitness(ctx.owner_uid, horizon_days: 14)
    assert fitness.horizon_days == 14
    assert fitness.matured_block_writes == 0
    assert fitness.survival_rate == nil
    assert fitness.runs == []

    assert {:error, :invalid_horizon_days} =
             Brain.dreaming_fitness(ctx.owner_uid, horizon_days: 0)

    assert {:error, :invalid_horizon_days} =
             Brain.dreaming_fitness(ctx.owner_uid, horizon_days: 91)

    assert {:error, :invalid_lookback_days} =
             Brain.dreaming_fitness(ctx.owner_uid, lookback_days: 999)
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

  defp dreaming_append!(ctx, run_id) do
    entry_id = create_entry(ctx, "Fitness #{Ecto.UUID.generate()}", "public")

    {:ok, %{results: [%{block_id: block_id, block_lock_version: block_version}]}} =
      Ankole.Brain.Knowledge.apply_operations(
        scope(ctx),
        %{
          operation: "append_block",
          entry_id: entry_id,
          body: "Dreaming inference #{run_id}",
          expected_entry_lock_version: 1
        },
        %{kind: :dreaming, uid: ctx.owner_uid},
        metadata: %{"surface" => "dreaming", "run_id" => run_id}
      )

    %{entry_id: entry_id, block_id: block_id, block_version: block_version}
  end

  defp dreaming_edit!(ctx, block_id, block_version, run_id) do
    {:ok, %{results: [%{block_lock_version: next_version}]}} =
      Ankole.Brain.Knowledge.apply_operations(
        scope(ctx),
        %{
          operation: "edit_block",
          block_id: block_id,
          body: "Dreaming rewrite #{run_id}",
          expected_block_lock_version: block_version
        },
        %{kind: :dreaming, uid: ctx.owner_uid},
        metadata: %{"surface" => "dreaming", "run_id" => run_id}
      )

    next_version
  end

  defp human_edit!(ctx, block_id, block_version) do
    {:ok, %{results: [%{block_lock_version: next_version}]}} =
      Brain.apply_human_operations(
        ctx.owner_uid,
        %{
          operation: "edit_block",
          block_id: block_id,
          body: "Human correction",
          expected_block_lock_version: block_version
        },
        ctx.actor_uid
      )

    next_version
  end

  defp scope(ctx) do
    {:ok, scope} = Ankole.Brain.Scope.for_store(ctx.owner_uid, "public")
    scope
  end

  defp backdate!(block_id, action, actor_kind, age_days) do
    at =
      DateTime.utc_now()
      |> DateTime.add(-age_days * 86_400, :second)
      |> DateTime.to_naive()

    {count, _} =
      Repo.update_all(
        from(log in AuditLog,
          where:
            log.block_id == ^block_id and log.action == ^action and log.actor_kind == ^actor_kind
        ),
        set: [inserted_at: at]
      )

    assert count >= 1
  end
end
