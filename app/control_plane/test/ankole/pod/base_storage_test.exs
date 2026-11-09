defmodule Ankole.Pod.BaseStorageTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Bases, BaseRepo, BaseTable, Pages}

  setup do
    actor = actor_fixture(human_fixture().principal.uid)
    {:ok, page} = Pages.create(actor, %{type: "base"})
    {:ok, %{tables: [table]}} = Bases.list_tables(actor, page.id)
    primary = Enum.find(Bases.fields(table.id), & &1.is_primary)
    %{actor: actor, page: page, table: table, primary: primary}
  end

  for mode <- [:inline, :physical] do
    test "#{mode} disjoint patches commute and a rejected batch preserves every stored row",
         ctx do
      if unquote(mode) == :physical do
        assert {:ok, _} =
                 Bases.create_field(ctx.actor, ctx.table.id, %{
                   name: "Peer",
                   type: "link",
                   config: %{"table_id" => ctx.table.id}
                 })
      end

      {:ok, number} =
        Bases.create_field(ctx.actor, ctx.table.id, %{name: "Count", type: "number"})

      {:ok, flag} =
        Bases.create_field(ctx.actor, ctx.table.id, %{name: "Checked", type: "checkbox"})

      for order <- [[number.id, flag.id], [flag.id, number.id]] do
        {:ok, %{records: [record, unrelated]}} =
          Bases.write_records(ctx.actor, ctx.table.id, %{
            creates: [
              %{data: %{ctx.primary.id => "原始 🌱", number.id => 7, flag.id => true}},
              %{data: %{ctx.primary.id => "untouched", number.id => 99}}
            ]
          })

        values = %{number.id => 0, flag.id => false}

        for id <- order do
          assert {:ok, _} =
                   Bases.write_records(ctx.actor, ctx.table.id, %{
                     updates: [
                       %{
                         id: record.id,
                         data: %{id => values[id]},
                         expected_versions: %{id => record.versions[id]}
                       }
                     ]
                   })
        end

        assert {:ok, %{records: before}} =
                 Bases.query(ctx.actor, ctx.table.id, %{})

        saved = Enum.find(before, &(&1["id"] == record.id))
        other = Enum.find(before, &(&1["id"] == unrelated.id))
        assert saved["data"] == Map.merge(record.data, values)

        assert saved["versions"] ==
                 Map.merge(record.versions, %{number.id => 2, flag.id => 2})

        assert other["data"] == unrelated.data
        assert other["versions"] == unrelated.versions
        {:ok, table_before} = Bases.get_table(ctx.actor, ctx.table.id)
        assert table_before.table.storage_mode == unquote(mode)

        assert {:error, {:field_conflict, _}} =
                 Bases.write_records(ctx.actor, ctx.table.id, %{
                   creates: [%{data: %{ctx.primary.id => "must roll back"}}],
                   updates: [
                     %{
                       id: record.id,
                       data: %{number.id => 8},
                       expected_versions: %{number.id => 2}
                     },
                     %{
                       id: record.id,
                       data: %{flag.id => true},
                       expected_versions: %{flag.id => 1}
                     }
                   ]
                 })

        assert {:ok, %{records: ^before}} =
                 Bases.query(ctx.actor, ctx.table.id, %{})

        {:ok, table_after} = Bases.get_table(ctx.actor, ctx.table.id)
        assert table_after.table.record_count == table_before.table.record_count
        assert table_after.table.data_version == table_before.table.data_version
      end
    end
  end

  test "single-valued links have independent constraints across fields and tables", ctx do
    {:ok, target} = Bases.create_table(ctx.actor, ctx.page.id, %{name: "People"})
    {:ok, other} = Bases.create_table(ctx.actor, ctx.page.id, %{name: "Other work"})

    for table <- [ctx.table, other], number <- 1..2 do
      assert {:ok, field} =
               Bases.create_field(ctx.actor, table.id, %{
                 name: "Owner #{number}",
                 type: "link",
                 config: %{"table_id" => target.id, "multiple" => false, "bidirectional" => true}
               })

      reverse = Enum.find(Bases.fields(target.id), &(&1.id == field.config["reverse_field_id"]))

      assert {:ok, _} =
               Bases.update_field(ctx.actor, reverse.id, %{
                 version: reverse.version,
                 config: Map.put(reverse.config, "multiple", false)
               })

      assert {:ok, %{records: [person]}} =
               Bases.write_records(ctx.actor, target.id, %{creates: [%{data: %{}}]})

      assert {:ok, %{records: [work]}} =
               Bases.write_records(ctx.actor, table.id, %{
                 creates: [%{data: %{field.id => [person.id]}}]
               })

      assert {:ok, %{records: [saved]}} =
               Bases.query(ctx.actor, target.id, %{ids: [person.id]})

      assert saved["data"][reverse.id] == [work.id]

      assert {:error, :link_cardinality} =
               Bases.write_records(ctx.actor, table.id, %{
                 creates: [%{data: %{field.id => [person.id]}}]
               })
    end
  end

  test "deleting a single-valued field removes its cardinality from the surviving link", ctx do
    {:ok, target} = Bases.create_table(ctx.actor, ctx.page.id, %{name: "People"})

    {:ok, field} =
      Bases.create_field(ctx.actor, ctx.table.id, %{
        name: "Owner",
        type: "link",
        config: %{"table_id" => target.id, "multiple" => false, "bidirectional" => true}
      })

    {:ok, %{records: [person, second_person]}} =
      Bases.write_records(ctx.actor, target.id, %{creates: [%{data: %{}}, %{data: %{}}]})

    {:ok, %{records: [work]}} =
      Bases.write_records(ctx.actor, ctx.table.id, %{
        creates: [%{data: %{field.id => [person.id]}}]
      })

    assert {:ok, _} = Bases.delete_field(ctx.actor, field.id, field.version)

    assert {:ok, _} =
             Bases.write_records(ctx.actor, target.id, %{
               updates: [
                 %{
                   id: second_person.id,
                   data: %{field.config["reverse_field_id"] => [work.id]},
                   expected_versions: second_person.versions
                 }
               ]
             })

    assert {:ok, %{records: saved}} =
             Bases.query(ctx.actor, target.id, %{ids: [person.id, second_person.id]})

    assert length(saved) == 2
    assert Enum.all?(saved, &(&1["data"][field.config["reverse_field_id"]] == [work.id]))
  end

  test "stored legacy single-link constraints can change cardinality without losing links", ctx do
    {:ok, target} = Bases.create_table(ctx.actor, ctx.page.id, %{name: "People"})

    {:ok, field} =
      Bases.create_field(ctx.actor, ctx.table.id, %{
        name: "Owner",
        type: "link",
        config: %{"table_id" => target.id, "multiple" => false, "bidirectional" => true}
      })

    reverse = Enum.find(Bases.fields(target.id), &(&1.id == field.config["reverse_field_id"]))

    {:ok, reverse} =
      Bases.update_field(ctx.actor, reverse.id, %{
        version: reverse.version,
        config: Map.put(reverse.config, "multiple", false)
      })

    {:ok, %{records: [person, second_person]}} =
      Bases.write_records(ctx.actor, target.id, %{creates: [%{data: %{}}, %{data: %{}}]})

    {:ok, %{records: [work]}} =
      Bases.write_records(ctx.actor, ctx.table.id, %{
        creates: [%{data: %{field.id => [person.id]}}]
      })

    BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
      for link <- [field, reverse] do
        BaseRepo.query!(
          "ALTER TABLE #{BaseRepo.edge(link.config["edge_table"])} RENAME CONSTRAINT single_#{BaseRepo.hex(link.id)} TO #{link.config["edge_role"]}_single",
          []
        )
      end
    end)

    for link <- [field, reverse] do
      assert {:ok, _} =
               Bases.update_field(ctx.actor, link.id, %{
                 version: link.version,
                 config: Map.put(link.config, "multiple", true)
               })
    end

    assert {:ok, %{records: [current_work]}} =
             Bases.query(ctx.actor, ctx.table.id, %{ids: [work.id]})

    assert {:ok, %{records: records}} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               updates: [
                 %{
                   id: work.id,
                   data: %{field.id => [person.id, second_person.id]},
                   expected_versions: current_work["versions"]
                 }
               ],
               creates: [%{data: %{field.id => [person.id]}}]
             })

    updated = Enum.find(records, &(&1.id == work.id))
    assert updated.data[field.id] == [person.id, second_person.id]

    for {link, conflicting_id} <- [{field, work.id}, {reverse, person.id}] do
      current = Enum.find(Bases.fields(link.table_id), &(&1.id == link.id))

      assert {:error, {:conversion_failed, [^conflicting_id]}} =
               Bases.update_field(ctx.actor, link.id, %{
                 version: current.version,
                 config: Map.put(current.config, "multiple", false)
               })
    end

    assert {:ok, %{records: [saved]}} = Bases.query(ctx.actor, ctx.table.id, %{ids: [work.id]})
    assert saved["data"][field.id] == [person.id, second_person.id]

    second_work = Enum.find(records, &(&1.id != work.id))

    assert {:ok, _} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               updates: [
                 %{
                   id: work.id,
                   data: %{field.id => [person.id]},
                   expected_versions: saved["versions"]
                 }
               ],
               deletes: [%{id: second_work.id, expected_versions: second_work.versions}]
             })

    for link <- [field, reverse] do
      current = Enum.find(Bases.fields(link.table_id), &(&1.id == link.id))

      assert {:ok, _} =
               Bases.update_field(ctx.actor, link.id, %{
                 version: current.version,
                 config: Map.put(current.config, "multiple", false)
               })
    end

    assert {:ok, %{records: [saved]}} = Bases.query(ctx.actor, ctx.table.id, %{ids: [work.id]})
    assert saved["data"][field.id] == [person.id]
  end

  for mode <- [:inline, :physical] do
    test "#{mode} text-to-number conversion keeps PostgreSQL numeric precision", ctx do
      if unquote(mode) == :physical do
        assert {:ok, _} =
                 Bases.create_field(ctx.actor, ctx.table.id, %{
                   name: "Peer",
                   type: "link",
                   config: %{"table_id" => ctx.table.id}
                 })
      end

      assert {:ok, field} =
               Bases.create_field(ctx.actor, ctx.table.id, %{name: "Exact", type: "text"})

      number = "12345678901234567890.12345678901234567890"

      assert {:ok, _} =
               Bases.write_records(ctx.actor, ctx.table.id, %{
                 creates: [%{data: %{ctx.primary.id => "Precision", field.id => number}}]
               })

      assert {:ok, _} = Bases.update_field(ctx.actor, field.id, %{version: 1, type: "number"})

      stored =
        if unquote(mode) == :inline do
          Repo.query!(
            "SELECT data->>$3::text FROM base_records WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid",
            [Repo.tenant_id!(), ctx.table.id, field.id]
          ).rows
        else
          BaseRepo.with_shard(BaseRepo.shard!(), fn ->
            BaseRepo.query!(
              "SELECT #{BaseRepo.column(field.id)}::text FROM #{BaseRepo.table(ctx.table.id)}",
              []
            ).rows
          end)
        end

      assert stored == [[number]]
    end
  end

  test "display fields can change type, switch columns, and be deleted when other fields remain",
       ctx do
    assert {:error, :primary_field_required} =
             Bases.delete_field(ctx.actor, ctx.primary.id, ctx.primary.version)

    assert {:error, :primary_field_required} =
             Bases.update_field(ctx.actor, ctx.primary.id, %{
               version: ctx.primary.version,
               is_primary: false
             })

    assert {:ok, select_primary} =
             Bases.update_field(ctx.actor, ctx.primary.id, %{
               version: ctx.primary.version,
               name: "Category",
               type: "select",
               config: %{"options" => [%{"id" => "a", "name" => "Hardware"}]}
             })

    assert select_primary.is_primary
    assert select_primary.type == :select

    assert {:ok, number_primary} =
             Bases.update_field(ctx.actor, select_primary.id, %{
               version: select_primary.version,
               type: "number"
             })

    assert number_primary.is_primary
    assert number_primary.type == :number

    assert {:ok, _attachment} =
             Bases.create_field(ctx.actor, ctx.table.id, %{name: "Files", type: "attachment"})

    assert {:ok, promoted_on_create} =
             Bases.create_field(ctx.actor, ctx.table.id, %{
               name: "Code",
               type: "text",
               is_primary: true
             })

    assert promoted_on_create.is_primary
    refute Enum.find(Bases.fields(ctx.table.id), &(&1.id == number_primary.id)).is_primary

    reloaded_number = Enum.find(Bases.fields(ctx.table.id), &(&1.id == number_primary.id))

    assert {:ok, promoted_on_update} =
             Bases.update_field(ctx.actor, reloaded_number.id, %{
               version: reloaded_number.version,
               is_primary: true
             })

    assert promoted_on_update.is_primary
    refute Enum.find(Bases.fields(ctx.table.id), &(&1.id == promoted_on_create.id)).is_primary

    # Renaming a referenced field while promoting it over a formula display field updates the formula once.
    assert {:ok, formula_primary} =
             Bases.create_field(ctx.actor, ctx.table.id, %{
               name: "Summary",
               type: "formula",
               config: %{"source" => "[Code]"},
               is_primary: true
             })

    assert formula_primary.is_primary
    reloaded_code = Enum.find(Bases.fields(ctx.table.id), &(&1.id == promoted_on_create.id))

    assert {:ok, renamed_code} =
             Bases.update_field(ctx.actor, reloaded_code.id, %{
               version: reloaded_code.version,
               name: "SKU",
               is_primary: true
             })

    assert renamed_code.is_primary
    demoted_formula = Enum.find(Bases.fields(ctx.table.id), &(&1.id == formula_primary.id))
    refute demoted_formula.is_primary
    assert demoted_formula.config["source"] == "[SKU]"
    assert demoted_formula.version == formula_primary.version + 1

    # Promote to physical storage and verify altering a primary column drops any legacy collated index cleanly.
    assert {:ok, _} =
             Bases.create_field(ctx.actor, ctx.table.id, %{
               name: "Related",
               type: "link",
               config: %{"table_id" => ctx.table.id}
             })

    reloaded_code = Enum.find(Bases.fields(ctx.table.id), &(&1.id == promoted_on_create.id))
    assert reloaded_code.is_primary

    BaseRepo.with_shard(BaseRepo.shard!(), fn ->
      BaseRepo.query!(
        ~s|CREATE INDEX "ix_#{BaseRepo.hex(reloaded_code.id)}" ON #{BaseRepo.table(ctx.table.id)} (#{BaseRepo.column(reloaded_code.id)} COLLATE "C")|,
        []
      )
    end)

    assert {:ok, physical_auto} =
             Bases.update_field(ctx.actor, reloaded_code.id, %{
               version: reloaded_code.version,
               type: "auto_number"
             })

    assert physical_auto.is_primary
    assert physical_auto.type == :auto_number

    assert {:error, :field_referenced} =
             Bases.delete_field(ctx.actor, physical_auto.id, physical_auto.version)

    demoted_formula = Enum.find(Bases.fields(ctx.table.id), &(&1.id == formula_primary.id))
    assert {:ok, _} = Bases.delete_field(ctx.actor, demoted_formula.id, demoted_formula.version)

    # Deleting the active display field promotes the first remaining non-attachment/non-link field.
    assert {:ok, _} = Bases.delete_field(ctx.actor, physical_auto.id, physical_auto.version)
    remaining = Bases.fields(ctx.table.id)
    assert Enum.find(remaining, & &1.is_primary).id == number_primary.id
  end

  test "physical text queries order in C collation even when the column has another collation",
       ctx do
    {:ok, _} =
      Bases.write_records(ctx.actor, ctx.table.id, %{
        creates: Enum.map(["ä", "z", "a"], &%{data: %{ctx.primary.id => &1}})
      })

    {:ok, _} =
      Bases.create_field(ctx.actor, ctx.table.id, %{
        name: "Related",
        type: "link",
        config: %{"table_id" => ctx.table.id}
      })

    BaseRepo.with_shard(BaseRepo.shard!(), fn ->
      {:ok, :ok} =
        BaseRepo.transact(fn ->
          BaseRepo.query!(
            ~s|ALTER TABLE #{BaseRepo.table(ctx.table.id)} ALTER COLUMN #{BaseRepo.column(ctx.primary.id)} TYPE text COLLATE "POSIX"|,
            []
          )

          {:ok, :ok}
        end)
    end)

    assert {:ok, %{records: records}} =
             Bases.query(ctx.actor, ctx.table.id, %{
               sort: [%{field_id: ctx.primary.id, direction: "asc"}]
             })

    assert Enum.map(records, & &1["data"][ctx.primary.id]) == ["a", "z", "ä"]
  end

  test "small linked tables support complete browser snapshots", ctx do
    assert {:ok, %{records: [record]}} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               creates: [%{data: %{ctx.primary.id => "A linked title"}}]
             })

    assert {:ok, link} =
             Bases.create_field(ctx.actor, ctx.table.id, %{
               name: "Related",
               type: "link",
               config: %{"table_id" => ctx.table.id}
             })

    assert {:ok, _} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               updates: [
                 %{
                   id: record.id,
                   data: %{link.id => [record.id]},
                   expected_versions: record.versions
                 }
               ]
             })

    assert {:ok, %{mode: "local", table: %{storage_mode: :physical}}} =
             Bases.get_table(ctx.actor, ctx.table.id)

    assert {:ok, %{complete: true, records: [saved]}} =
             Bases.query(ctx.actor, ctx.table.id, %{local: true})

    assert saved["data"][link.id] == [record.id]
  end

  test "browser snapshot size includes computed values in both storage modes", ctx do
    {:ok, body} = Bases.create_field(ctx.actor, ctx.table.id, %{name: "Body", type: "text"})

    assert {:ok, _} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               creates: List.duplicate(%{data: %{body.id => String.duplicate("x", 900_000)}}, 3)
             })

    assert {:ok, %{complete: true}} = Bases.query(ctx.actor, ctx.table.id, %{local: true})

    assert {:ok, _} =
             Bases.create_field(ctx.actor, ctx.table.id, %{
               name: "Computed body",
               type: "formula",
               config: %{"source" => "[Body]"}
             })

    for mode <- [:inline, :physical] do
      if mode == :physical do
        assert {:ok, _} =
                 Bases.create_field(ctx.actor, ctx.table.id, %{
                   name: "Related",
                   type: "link",
                   config: %{"table_id" => ctx.table.id}
                 })
      end

      assert {:error, :local_table_changed} = Bases.query(ctx.actor, ctx.table.id, %{local: true})

      assert {:ok, %{records: [_], complete: false}} =
               Bases.query(ctx.actor, ctx.table.id, %{page_size: 1})
    end
  end

  test "row 2001 promotes atomically, counters stay on the shard, and a small copy is inline",
       ctx do
    for _ <- 1..10 do
      assert {:ok, _} =
               Bases.write_records(ctx.actor, ctx.table.id, %{
                 creates: List.duplicate(%{data: %{}}, 200)
               })
    end

    assert {:ok, %{mode: "local"}} = Bases.get_table(ctx.actor, ctx.table.id)

    assert {:ok, %{resync: true, records: [record]}} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               creates: [%{data: %{ctx.primary.id => "last"}}]
             })

    assert {:ok, %{mode: "remote", table: %{record_count: 2001}}} =
             Bases.get_table(ctx.actor, ctx.table.id)

    assert Repo.aggregate(
             from(r in Ankole.Pod.BaseRecord, where: r.table_id == ^ctx.table.id),
             :count
           ) == 0

    assert {:ok, large_copy} = Bases.copy_table(ctx.actor, ctx.table.id, %{})
    assert large_copy.table.storage_mode == :physical
    assert large_copy.table.record_count == 2001

    assert Repo.aggregate(
             from(r in Ankole.Pod.BaseRecord, where: r.table_id == ^large_copy.table.id),
             :count
           ) == 0

    assert {:ok, %{tables: tables}} = Bases.list_tables(ctx.actor, ctx.page.id)
    assert Enum.find(tables, &(&1.id == ctx.table.id)).record_count == 2001

    before = Repo.get!(BaseTable, ctx.table.id)

    assert {:ok, _} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               deletes: [%{id: record.id, expected_versions: record.versions}]
             })

    assert_persisted_equal(Repo.get!(BaseTable, ctx.table.id), before)

    assert {:ok, %{mode: "local", table: %{record_count: 2000}}} =
             Bases.get_table(ctx.actor, ctx.table.id)

    assert {:ok, copied} = Bases.copy_table(ctx.actor, ctx.table.id, %{})
    assert copied.table.storage_mode == :inline
    assert copied.table.record_count == 2000
  end

  test "saved views notify readers without changing the storage schema in either mode", ctx do
    Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-room:table:#{ctx.table.id}")

    for mode <- [:inline, :physical] do
      if mode == :physical do
        assert {:ok, _} =
                 Bases.create_field(ctx.actor, ctx.table.id, %{
                   name: "Link",
                   type: "link",
                   config: %{"table_id" => ctx.table.id}
                 })

        assert_receive {:room_event, "schema_changed", _}
      end

      assert {:ok, before} = Bases.get_table(ctx.actor, ctx.table.id)
      assert before.table.storage_mode == mode

      assert {:ok, view} =
               Bases.create_view(ctx.actor, ctx.table.id, %{name: "Work", type: "grid"})

      assert {:ok, saved} =
               Bases.update_view(ctx.actor, view.id, %{
                 version: view.version,
                 name: "Sorted work",
                 config: %{"sort" => [%{"field_id" => ctx.primary.id, "direction" => "desc"}]}
               })

      assert {:ok, current} = Bases.get_table(ctx.actor, ctx.table.id)
      assert_persisted_equal(Enum.find(current.views, &(&1.id == view.id)), saved)

      assert {:ok, _} = Bases.delete_view(ctx.actor, saved.id, saved.version)
      assert {:ok, after_delete} = Bases.get_table(ctx.actor, ctx.table.id)
      refute Enum.any?(after_delete.views, &(&1.id == view.id))
      assert after_delete.table.schema_version == before.table.schema_version
      assert after_delete.table.record_count == before.table.record_count

      for offset <- 1..3 do
        version = before.table.data_version + offset
        assert_receive {:room_event, "schema_changed", %{data_version: ^version}}
      end

      assert after_delete.table.data_version == before.table.data_version + 3

      assert {:ok, %{tables: versions}} =
               Pages.reconcile_versions(ctx.actor, [ctx.page.id], [ctx.table.id])

      assert versions == [%{id: ctx.table.id, data_version: after_delete.table.data_version}]
    end
  end

  test "retrying a create ID rejects the whole batch in either storage mode", ctx do
    for mode <- [:inline, :physical] do
      if mode == :physical do
        assert {:ok, _} =
                 Bases.create_field(ctx.actor, ctx.table.id, %{
                   name: "Link",
                   type: "link",
                   config: %{"table_id" => ctx.table.id}
                 })
      end

      id = Ankole.Ecto.UUIDv7.autogenerate()
      attrs = %{id: id, data: %{ctx.primary.id => "One submission"}}

      assert {:ok, %{records: [record]}} =
               Bases.write_records(ctx.actor, ctx.table.id, %{creates: [attrs]})

      assert {:ok, before} = Bases.get_table(ctx.actor, ctx.table.id)

      assert {:error, {:record_exists, ^id}} =
               Bases.write_records(ctx.actor, ctx.table.id, %{
                 creates: [%{data: %{ctx.primary.id => "Must roll back"}}, attrs]
               })

      assert {:ok, after_retry} = Bases.get_table(ctx.actor, ctx.table.id)
      assert after_retry.table.record_count == before.table.record_count
      assert after_retry.table.data_version == before.table.data_version
      assert after_retry.table.next_auto_number == before.table.next_auto_number
      assert {:ok, %{records: [saved]}} = Bases.query(ctx.actor, ctx.table.id, %{ids: [id]})
      assert saved["data"] == record.data
      assert saved["versions"] == record.versions
    end
  end

  test "display text fields accept large UTF-8 values before and after a link promotes the table",
       ctx do
    value = String.duplicate("界", 2000)
    assert byte_size(value) == 6000

    for mode <- [:inline, :physical] do
      if mode == :physical do
        assert {:ok, _} =
                 Bases.create_field(ctx.actor, ctx.table.id, %{
                   name: "Link",
                   type: "link",
                   config: %{"table_id" => ctx.table.id}
                 })
      end

      assert {:ok, %{records: [saved]}} =
               Bases.write_records(ctx.actor, ctx.table.id, %{
                 creates: [%{data: %{ctx.primary.id => value}}]
               })

      assert saved.data[ctx.primary.id] == value
    end
  end

  test "failed physical batches roll back records, auto numbers, edges, and versions", ctx do
    {:ok, auto} =
      Bases.create_field(ctx.actor, ctx.table.id, %{name: "Sequence", type: "auto_number"})

    {:ok, link} =
      Bases.create_field(ctx.actor, ctx.table.id, %{
        name: "Link",
        type: "link",
        config: %{"table_id" => ctx.table.id, "bidirectional" => true}
      })

    {:ok, %{records: [record]}} =
      Bases.write_records(ctx.actor, ctx.table.id, %{creates: [%{data: %{}}]})

    {:ok, before} = Bases.get_table(ctx.actor, ctx.table.id)

    assert {:error, :invalid_link} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               creates: [
                 %{data: %{link.id => [record.id]}},
                 %{data: %{link.id => [Ecto.UUID.generate()]}}
               ]
             })

    {:ok, after_schema} = Bases.get_table(ctx.actor, ctx.table.id)
    assert after_schema.table.data_version == before.table.data_version
    assert after_schema.table.record_count == 1
    {:ok, %{records: [unchanged]}} = Bases.query(ctx.actor, ctx.table.id, %{})
    assert unchanged["versions"] == record.versions

    {:ok, %{records: [next]}} =
      Bases.write_records(ctx.actor, ctx.table.id, %{creates: [%{data: %{}}]})

    assert next.data[auto.id] == 2
  end

  test "a schema mismatch fails closed and tenant schema names require process context", ctx do
    {:ok, _} =
      Bases.create_field(ctx.actor, ctx.table.id, %{
        name: "Link",
        type: "link",
        config: %{"table_id" => ctx.table.id}
      })

    BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
      BaseRepo.query!("UPDATE #{BaseRepo.states()} SET schema_version=schema_version+1", [])
    end)

    assert {:error, :base_schema_mismatch} = Bases.query(ctx.actor, ctx.table.id, %{})

    assert_raise Ankole.TenantContextMissing, fn ->
      Repo.without_tenant(&BaseRepo.tenant_schema!/0)
    end

    original = BaseRepo.table(ctx.table.id)

    refute Repo.with_tenant(Ecto.UUID.generate(), fn -> BaseRepo.table(ctx.table.id) end) ==
             original
  end

  test "deletion cleanup is repeatable and hides a marked table", ctx do
    {:ok, link} =
      Bases.create_field(ctx.actor, ctx.table.id, %{
        name: "Link",
        type: "link",
        config: %{"table_id" => ctx.table.id}
      })

    {:ok, _} = Bases.delete_field(ctx.actor, link.id, link.version)
    {:ok, table} = Bases.fetch_table(ctx.table.id)
    {:ok, _} = Ankole.Ash.update(table, :begin_delete, %{})
    assert {:error, :not_found} = Bases.query(ctx.actor, table.id, %{})

    assert {:error, :not_found} =
             Bases.write_records(ctx.actor, table.id, %{creates: [%{data: %{}}]})

    assert {:ok, _} = Ankole.Pod.Bases.Delete.cleanup(table.id)
    assert {:ok, :deleted} = Ankole.Pod.Bases.Delete.cleanup(table.id)

    BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
      assert [[nil]] =
               BaseRepo.query!("SELECT to_regclass($1)::text", [BaseRepo.table(table.id)]).rows
    end)
  end

  @tag timeout: 120_000
  test "deleting a parent with 2001 one-way children requests resync without rewriting each child",
       ctx do
    {:ok, children} = Bases.create_table(ctx.actor, ctx.page.id, %{name: "Children"})

    {:ok, parent} =
      Bases.create_field(ctx.actor, children.id, %{
        name: "Parent",
        type: "link",
        config: %{"table_id" => ctx.table.id, "multiple" => false}
      })

    {:ok, %{records: [record]}} =
      Bases.write_records(ctx.actor, ctx.table.id, %{creates: [%{data: %{}}]})

    for _ <- 1..10 do
      assert {:ok, _} =
               Bases.write_records(ctx.actor, children.id, %{
                 creates: List.duplicate(%{data: %{parent.id => [record.id]}}, 200)
               })
    end

    {:ok, %{records: [child]}} =
      Bases.write_records(ctx.actor, children.id, %{
        creates: [%{data: %{parent.id => [record.id]}}]
      })

    assert {:ok, %{related: [%{id: id, resync: true, changed_ids: []}]}} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               deletes: [%{id: record.id, expected_versions: record.versions}]
             })

    assert id == children.id
    {:ok, %{records: [saved]}} = Bases.query(ctx.actor, children.id, %{ids: [child.id]})
    assert saved["versions"] == child.versions
    refute Map.has_key?(saved["data"], parent.id)
  end

  test "changing select options preserves unaffected cell versions in either storage mode", ctx do
    for mode <- [:inline, :physical] do
      if mode == :physical do
        {:ok, _} =
          Bases.create_field(ctx.actor, ctx.table.id, %{
            name: "Link",
            type: "link",
            config: %{"table_id" => ctx.table.id}
          })
      end

      options = [%{"id" => "a", "name" => "A"}, %{"id" => "b", "name" => "B"}]

      {:ok, field} =
        Bases.create_field(ctx.actor, ctx.table.id, %{
          name: "Status #{mode}",
          type: "select",
          config: %{"options" => options}
        })

      {:ok, %{records: [a, b, blank]}} =
        Bases.write_records(ctx.actor, ctx.table.id, %{
          creates: [%{data: %{field.id => "a"}}, %{data: %{field.id => "b"}}, %{data: %{}}]
        })

      assert {:ok, field} =
               Bases.update_field(ctx.actor, field.id, %{
                 version: field.version,
                 config: %{"options" => options ++ [%{"id" => "c", "name" => "C"}]}
               })

      for original <- [a, b, blank] do
        assert {:ok, %{records: [saved]}} =
                 Bases.query(ctx.actor, ctx.table.id, %{ids: [original.id]})

        assert saved["data"] == original.data
        assert saved["versions"] == original.versions
      end

      assert {:ok, %{records: [edited]}} =
               Bases.write_records(ctx.actor, ctx.table.id, %{
                 updates: [%{id: a.id, data: %{field.id => "c"}, expected_versions: a.versions}]
               })

      assert {:ok, _} =
               Bases.update_field(ctx.actor, field.id, %{
                 version: field.version,
                 config: %{"options" => [%{"id" => "c", "name" => "C"}]},
                 clear_invalid: true
               })

      assert {:ok, %{records: [saved]}} = Bases.query(ctx.actor, ctx.table.id, %{ids: [a.id]})
      assert saved["versions"] == edited.versions
      assert saved["data"] == edited.data
      assert {:ok, %{records: [cleared]}} = Bases.query(ctx.actor, ctx.table.id, %{ids: [b.id]})
      refute Map.has_key?(cleared["data"], field.id)
      assert cleared["versions"][field.id] == b.versions[field.id] + 1
      assert {:ok, %{records: [empty]}} = Bases.query(ctx.actor, ctx.table.id, %{ids: [blank.id]})
      assert empty["versions"] == blank.versions
    end
  end

  test "computed fields replace stored values and cell versions in either storage mode", ctx do
    for mode <- [:inline, :physical] do
      if mode == :physical do
        {:ok, _} =
          Bases.create_field(ctx.actor, ctx.table.id, %{
            name: "Link",
            type: "link",
            config: %{"table_id" => ctx.table.id}
          })
      end

      for type <- ["formula", "created_at"] do
        {:ok, field} =
          Bases.create_field(ctx.actor, ctx.table.id, %{name: "#{mode} #{type}", type: "text"})

        {:ok, %{records: [record]}} =
          Bases.write_records(ctx.actor, ctx.table.id, %{
            creates: [%{data: %{field.id => "old stored value"}}]
          })

        attrs = %{version: field.version, type: type}

        attrs =
          if type == "formula", do: Map.put(attrs, :config, %{"source" => "42"}), else: attrs

        assert {:ok, _} = Bases.update_field(ctx.actor, field.id, attrs)

        assert {:ok, %{records: [saved]}} =
                 Bases.query(ctx.actor, ctx.table.id, %{ids: [record.id]})

        expected = if type == "formula", do: 42, else: saved["created_at"]

        assert {:ok, %{records: [matched]}} =
                 Bases.query(ctx.actor, ctx.table.id, %{
                   ids: [record.id],
                   filter: %{conditions: [%{field_id: field.id, operator: "is", value: expected}]}
                 })

        assert matched["id"] == record.id

        if type == "formula",
          do: assert(saved["data"][field.id] == 42),
          else: refute(Map.has_key?(saved["data"], field.id))

        refute Map.has_key?(saved["versions"], field.id)
      end
    end
  end

  test "a failed physical conversion rolls back earlier batches and can be retried", ctx do
    {:ok, text} = Bases.create_field(ctx.actor, ctx.table.id, %{name: "Value", type: "text"})

    {:ok, _} =
      Bases.create_field(ctx.actor, ctx.table.id, %{
        name: "Related",
        type: "link",
        config: %{"table_id" => ctx.table.id}
      })

    {:ok, _} =
      Bases.write_records(ctx.actor, ctx.table.id, %{
        creates: List.duplicate(%{data: %{text.id => "12"}}, 200)
      })

    {:ok, %{records: [bad]}} =
      Bases.write_records(ctx.actor, ctx.table.id, %{creates: [%{data: %{text.id => "invalid"}}]})

    {:ok, before} = Bases.query(ctx.actor, ctx.table.id, %{page_size: 300})

    assert {:error, {:conversion_failed, [id]}} =
             Bases.update_field(ctx.actor, text.id, %{version: text.version, type: "number"})

    assert id == bad.id
    assert {:ok, ^before} = Bases.query(ctx.actor, ctx.table.id, %{page_size: 300})

    assert {:ok, _} =
             Bases.update_field(ctx.actor, text.id, %{
               version: text.version,
               type: "number",
               clear_invalid: true
             })

    assert {:ok, %{records: records, complete: true}} =
             Bases.query(ctx.actor, ctx.table.id, %{page_size: 300})

    assert length(records) == 201
    assert Enum.all?(records, &(&1["versions"][text.id] == 2))
    assert Enum.count(records, &(&1["data"][text.id] == 12)) == 200
    refute Enum.find(records, &(&1["id"] == bad.id))["data"][text.id]
  end

  test "physical type conversion preserves other native numbers and failed conversions roll back",
       ctx do
    {:ok, number} = Bases.create_field(ctx.actor, ctx.table.id, %{name: "Number", type: "number"})
    {:ok, text} = Bases.create_field(ctx.actor, ctx.table.id, %{name: "Text", type: "text"})

    {:ok, %{records: [record]}} =
      Bases.write_records(ctx.actor, ctx.table.id, %{creates: [%{data: %{text.id => "invalid"}}]})

    Repo.query!(
      "UPDATE base_records SET data=data || jsonb_build_object($3::text,0.123456789012345678901234567890::numeric) WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid",
      [Repo.tenant_id!(), ctx.table.id, number.id]
    )

    {:ok, _} =
      Bases.create_field(ctx.actor, ctx.table.id, %{
        name: "Link",
        type: "link",
        config: %{"table_id" => ctx.table.id}
      })

    assert {:error, {:conversion_failed, [_]}} =
             Bases.update_field(ctx.actor, text.id, %{version: 1, type: "number"})

    assert Enum.find(Bases.fields(ctx.table.id), &(&1.id == text.id)).type == :text

    assert {:ok, _} =
             Bases.update_field(ctx.actor, text.id, %{
               version: 1,
               type: "number",
               clear_invalid: true
             })

    assert {:ok, _} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               updates: [
                 %{id: record.id, data: %{ctx.primary.id => "changed"}, expected_versions: %{}}
               ]
             })

    BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
      assert [["0.123456789012345678901234567890"]] =
               BaseRepo.query!(
                 "SELECT #{BaseRepo.column(number.id)}::text FROM #{BaseRepo.table(ctx.table.id)}",
                 []
               ).rows
    end)
  end

  test "an interrupted link promotion can retry or delete without leftover edge tables", ctx do
    for recovery <- [:retry, :delete] do
      {:ok, table} = Bases.create_table(ctx.actor, ctx.page.id, %{name: "Interrupted"})
      attrs = %{name: "Link", type: "link", config: %{"table_id" => table.id}}
      owner = self()

      assert {:error, :interrupted} =
               Ankole.Pod.Access.write(
                 nil,
                 fn ->
                   {:ok, %{written: field}} =
                     Ankole.Pod.Bases.Schema.create_field_in_tx(ctx.actor, table.id, attrs)

                   send(owner, {:orphan_edge, field.config["edge_table"]})
                   {:error, :interrupted}
                 end,
                 timeout: 60_000
               )

      assert_receive {:orphan_edge, edge}
      assert {:ok, %{mode: "local"}} = Bases.get_table(ctx.actor, table.id)

      BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
        assert [[true]] =
                 BaseRepo.query!("SELECT to_regclass($1) IS NOT NULL", [BaseRepo.edge(edge)]).rows
      end)

      case recovery do
        :retry -> assert {:ok, _} = Bases.create_field(ctx.actor, table.id, attrs)
        :delete -> assert {:ok, _} = Bases.delete_table(ctx.actor, table.id)
      end

      BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
        assert [[nil]] =
                 BaseRepo.query!("SELECT to_regclass($1)::text", [BaseRepo.edge(edge)]).rows
      end)
    end
  end

  @tag timeout: 120_000
  test "2000 rows and 200 fields promote through the public write path", ctx do
    for index <- 1..199 do
      assert {:ok, _} =
               Bases.create_field(ctx.actor, ctx.table.id, %{
                 name: "Field #{index}",
                 type: "number"
               })
    end

    assert {:error, :field_limit} =
             Bases.create_field(ctx.actor, ctx.table.id, %{name: "Extra", type: "number"})

    for _ <- 1..10 do
      assert {:ok, _} =
               Bases.write_records(ctx.actor, ctx.table.id, %{
                 creates: List.duplicate(%{data: %{}}, 200)
               })
    end

    assert {:ok, %{mode: "local"}} = Bases.get_table(ctx.actor, ctx.table.id)
    assert {:ok, _} = Bases.write_records(ctx.actor, ctx.table.id, %{creates: [%{data: %{}}]})

    assert {:ok, %{mode: "remote", table: %{record_count: 2001}}} =
             Bases.get_table(ctx.actor, ctx.table.id)

    assert {:ok, %{records: records}} = Bases.query(ctx.actor, ctx.table.id, %{page_size: 1000})
    assert length(records) == 1000
  end

  test "retargeting a link clears invalid targets only with explicit clear_invalid", ctx do
    {:ok, target} = Bases.create_table(ctx.actor, ctx.page.id, %{name: "New targets"})

    {:ok, link} =
      Bases.create_field(ctx.actor, ctx.table.id, %{
        name: "Link",
        type: "link",
        config: %{"table_id" => ctx.table.id}
      })

    {:ok, %{records: [peer]}} =
      Bases.write_records(ctx.actor, ctx.table.id, %{creates: [%{data: %{}}]})

    {:ok, %{records: [record]}} =
      Bases.write_records(ctx.actor, ctx.table.id, %{creates: [%{data: %{link.id => [peer.id]}}]})

    attrs = %{version: link.version, config: %{"table_id" => target.id}}
    assert {:error, {:conversion_failed, [id]}} = Bases.update_field(ctx.actor, link.id, attrs)
    assert id == record.id
    assert {:ok, _} = Bases.update_field(ctx.actor, link.id, Map.put(attrs, :clear_invalid, true))
    {:ok, %{records: [saved]}} = Bases.query(ctx.actor, ctx.table.id, %{ids: [record.id]})
    refute Map.has_key?(saved["data"], link.id)
  end

  test "query values, locale rules, date buckets, and keyset cursors survive promotion", ctx do
    {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("system.timezone", "America/New_York")
    {:ok, amount} = Bases.create_field(ctx.actor, ctx.table.id, %{name: "Amount", type: "number"})
    {:ok, date} = Bases.create_field(ctx.actor, ctx.table.id, %{name: "Date", type: "datetime"})

    {:ok, _lower} =
      Bases.create_field(ctx.actor, ctx.table.id, %{
        name: "Lower",
        type: "formula",
        config: %{"source" => "LOWER([Name])"}
      })

    {:ok, _} =
      Bases.write_records(ctx.actor, ctx.table.id, %{
        creates: [
          %{
            data: %{
              ctx.primary.id => "ÄÖ",
              amount.id => 1,
              date.id => "2026-10-01T01:30:00.123456Z"
            }
          },
          %{
            data: %{
              ctx.primary.id => "ascii",
              amount.id => 2,
              date.id => "2026-10-01T08:30:00.654321Z"
            }
          },
          %{data: %{ctx.primary.id => "", amount.id => nil}},
          %{data: %{ctx.primary.id => "null"}}
        ]
      })

    queries = [
      %{},
      %{sort: [%{field_id: ctx.primary.id, direction: "desc"}]},
      %{
        filter: %{
          conditions: [%{field_id: ctx.primary.id, operator: "text_contains", value: "ä"}]
        }
      },
      %{filter: %{conditions: [%{field_id: amount.id, operator: "is_empty"}]}},
      %{
        filter: %{
          conditions: [%{field_id: date.id, operator: "gt", value: "2026-10-01T05:00:00Z"}]
        }
      }
    ]

    before =
      for attrs <- queries do
        {:ok, result} = Bases.query(ctx.actor, ctx.table.id, attrs)
        result.records
      end

    aggregate = %{
      group_by: [%{field_id: date.id, bucket: "day"}],
      metrics: [%{field_id: amount.id, operation: "sum", alias: "sum"}]
    }

    {:ok, sums} = Bases.aggregate(ctx.actor, ctx.table.id, aggregate)
    cursor_query = %{sort: [%{field_id: amount.id, direction: "asc"}], page_size: 1}
    {:ok, first} = Bases.query(ctx.actor, ctx.table.id, cursor_query)
    next = Map.put(cursor_query, :page_token, first.page_token)
    {:ok, next_before} = Bases.query(ctx.actor, ctx.table.id, next)

    assert {:ok, _} =
             Bases.create_field(ctx.actor, ctx.table.id, %{
               name: "Link",
               type: "link",
               config: %{"table_id" => ctx.table.id}
             })

    for {attrs, expected} <- Enum.zip(queries, before) do
      assert {:ok, result} = Bases.query(ctx.actor, ctx.table.id, attrs)
      assert result.records == expected
    end

    assert {:ok, sums_after} = Bases.aggregate(ctx.actor, ctx.table.id, aggregate)
    assert Enum.sort(sums_after.groups) == Enum.sort(sums.groups)
    assert {:ok, next_after} = Bases.query(ctx.actor, ctx.table.id, next)
    assert next_after.records == next_before.records
  end

  test "exhausted physical column history directs the user to an independent copy", ctx do
    assert {:ok, _} =
             Bases.create_field(ctx.actor, ctx.table.id, %{
               name: "Link",
               type: "link",
               config: %{"table_id" => ctx.table.id}
             })

    assert {:ok, _} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               creates: [%{data: %{ctx.primary.id => "Preserved"}}]
             })

    BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
      [[attnum]] =
        BaseRepo.query!(
          "SELECT max(attnum) FROM pg_attribute WHERE attrelid=$1::text::regclass",
          [BaseRepo.table(ctx.table.id)]
        ).rows

      names = Enum.map((attnum + 1)..1600, &"history_#{&1}")

      BaseRepo.query!(
        "ALTER TABLE #{BaseRepo.table(ctx.table.id)} " <>
          Enum.map_join(names, ",", &"ADD COLUMN #{&1} text"),
        []
      )

      BaseRepo.query!(
        "ALTER TABLE #{BaseRepo.table(ctx.table.id)} " <>
          Enum.map_join(names, ",", &"DROP COLUMN #{&1}"),
        []
      )
    end)

    assert {:error, :field_history_limit} =
             Bases.create_field(ctx.actor, ctx.table.id, %{name: "Next", type: "text"})

    refute Enum.any?(Bases.fields(ctx.table.id), &(&1.name == "Next"))

    assert {:ok, %{table: copy}} =
             Bases.copy_table(ctx.actor, ctx.table.id, %{title: "Fresh table"})

    assert {:ok, _} = Bases.create_field(ctx.actor, copy.id, %{name: "Next", type: "text"})
    assert {:ok, %{records: [record]}} = Bases.query(ctx.actor, copy.id, %{})
    primary = Enum.find(Bases.fields(copy.id), & &1.is_primary)
    assert record["data"][primary.id] == "Preserved"
  end

  test "stored JSON bytes promote a table before its row threshold", ctx do
    {:ok, body} = Bases.create_field(ctx.actor, ctx.table.id, %{name: "Body", type: "text"})
    creates = List.duplicate(%{data: %{body.id => String.duplicate("x", 900_000)}}, 4)
    assert {:ok, _} = Bases.write_records(ctx.actor, ctx.table.id, %{creates: creates})
    assert {:ok, %{mode: "local"}} = Bases.get_table(ctx.actor, ctx.table.id)

    assert {:ok, _} =
             Bases.write_records(ctx.actor, ctx.table.id, %{creates: Enum.take(creates, 1)})

    assert {:ok, %{table: %{storage_mode: :physical, record_count: 5}}} =
             Bases.get_table(ctx.actor, ctx.table.id)

    assert {:error, :local_table_changed} = Bases.query(ctx.actor, ctx.table.id, %{local: true})
  end

  test "relax_base_primary_field_types drops legacy physical display-field B-tree indexes so >2704-byte values write cleanly while preserving auto_number indexes",
       ctx do
    {:ok, seq} =
      Bases.create_field(ctx.actor, ctx.table.id, %{name: "Seq", type: "auto_number"})

    assert {:ok, _} =
             Bases.create_field(ctx.actor, ctx.table.id, %{
               name: "Peer",
               type: "link",
               config: %{"table_id" => ctx.table.id}
             })

    tenant_schema = BaseRepo.tenant_schema!()
    legacy_index = ~s("#{tenant_schema}"."ix_#{BaseRepo.hex(ctx.primary.id)}")
    auto_index = ~s("#{tenant_schema}"."ix_#{BaseRepo.hex(seq.id)}")
    high_entropy_text = Base.encode64(:crypto.strong_rand_bytes(4_500))

    BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
      BaseRepo.query!(
        ~s[CREATE INDEX "ix_#{BaseRepo.hex(ctx.primary.id)}" ON #{BaseRepo.table(ctx.table.id)} (#{BaseRepo.column(ctx.primary.id)} COLLATE "C")],
        []
      )

      assert BaseRepo.query!("SELECT to_regclass($1)::text", [legacy_index]).rows != [[nil]]
      assert BaseRepo.query!("SELECT to_regclass($1)::text", [auto_index]).rows != [[nil]]

      error =
        assert_raise Postgrex.Error, fn ->
          BaseRepo.query!(
            "INSERT INTO #{BaseRepo.table(ctx.table.id)} (id, #{BaseRepo.column(ctx.primary.id)}, #{BaseRepo.column(seq.id)}, versions, created_by, updated_by, created_at, updated_at) VALUES ($1::text::uuid, $2, 1, '{}'::jsonb, 'u', 'u', now(), now())",
            [Ankole.Ecto.UUIDv7.autogenerate(), high_entropy_text]
          )
        end

      assert Exception.message(error) =~ "index row size"
    end)

    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20261109164500_relax_base_primary_field_types.exs",
        __DIR__
      )
    )

    apply(Ankole.Repo.Migrations.RelaxBasePrimaryFieldTypes, :drop_legacy_field_indexes, [
      Ankole.Repo
    ])

    BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
      assert BaseRepo.query!("SELECT to_regclass($1)::text", [legacy_index]).rows == [[nil]]
      assert BaseRepo.query!("SELECT to_regclass($1)::text", [auto_index]).rows != [[nil]]
    end)

    assert {:ok, %{records: [created]}} =
             Bases.write_records(ctx.actor, ctx.table.id, %{
               creates: [%{data: %{ctx.primary.id => high_entropy_text}}]
             })

    assert created.data[ctx.primary.id] == high_entropy_text
  end

  for mode <- [:inline, :physical] do
    test "#{mode} record search filters primary display labels before pagination across non-text field types",
         ctx do
      colleague = human_fixture(%{display_name: "Zelda Nightingale"})

      if unquote(mode) == :physical do
        assert {:ok, _} =
                 Bases.create_field(ctx.actor, ctx.table.id, %{
                   name: "Peer",
                   type: "link",
                   config: %{"table_id" => ctx.table.id}
                 })
      end

      {:ok, select_primary} =
        Bases.update_field(ctx.actor, ctx.primary.id, %{
          version: ctx.primary.version,
          type: "select",
          config: %{
            "options" => [
              %{"id" => "opt_std", "name" => "Standard"},
              %{"id" => "opt_ent", "name" => "Enterprise Tier"}
            ]
          }
        })

      noise = List.duplicate(%{data: %{select_primary.id => "opt_std"}}, 105)

      {:ok, %{records: inserted}} =
        Bases.write_records(ctx.actor, ctx.table.id, %{
          creates: noise ++ [%{data: %{select_primary.id => "opt_ent"}}, %{data: %{}}]
        })

      target = Enum.at(inserted, 105)
      empty_row = Enum.at(inserted, 106)

      assert {:ok, %{records: [found], complete: true, page_token: nil}} =
               Bases.query(ctx.actor, ctx.table.id, %{
                 page_size: 100,
                 search: "enterprise"
               })

      assert found["id"] == target.id

      short_id = "#" <> String.slice(empty_row.id, -6, 6)

      assert {:ok, %{records: [found_empty]}} =
               Bases.query(ctx.actor, ctx.table.id, %{page_size: 100, search: short_id})

      assert found_empty["id"] == empty_row.id

      assert {:ok, page1} =
               Bases.query(ctx.actor, ctx.table.id, %{page_size: 50, search: "standard"})

      assert length(page1.records) == 50
      assert is_binary(page1.page_token)

      assert {:error, :invalid_page_token} =
               Bases.query(ctx.actor, ctx.table.id, %{
                 page_size: 50,
                 search: "enterprise",
                 page_token: page1.page_token
               })

      assert {:ok, page2} =
               Bases.query(ctx.actor, ctx.table.id, %{
                 page_size: 60,
                 search: "standard",
                 page_token: page1.page_token
               })

      assert length(page2.records) == 55
      assert page2.complete

      # Verify user, number, formula, and datetime primary display fields
      {:ok, people_table} = Bases.create_table(ctx.actor, ctx.page.id, %{name: "Directory"})
      people_primary = Enum.find(Bases.fields(people_table.id), & &1.is_primary)

      if unquote(mode) == :physical do
        assert {:ok, _} =
                 Bases.create_field(ctx.actor, people_table.id, %{
                   name: "Peer",
                   type: "link",
                   config: %{"table_id" => people_table.id}
                 })
      end

      {:ok, people_primary} =
        Bases.update_field(ctx.actor, people_primary.id, %{
          version: people_primary.version,
          type: "user"
        })

      {:ok, qty} = Bases.create_field(ctx.actor, people_table.id, %{name: "Qty", type: "number"})

      {:ok, scheduled_at} =
        Bases.create_field(ctx.actor, people_table.id, %{name: "When", type: "datetime"})

      {:ok, code_formula} =
        Bases.create_field(ctx.actor, people_table.id, %{
          name: "Double Qty",
          type: "formula",
          config: %{"source" => "[Qty] * 2"}
        })

      people_noise =
        List.duplicate(
          %{data: %{people_primary.id => [ctx.actor.principal.uid], qty.id => 1}},
          102
        )

      {:ok, %{records: people_rows}} =
        Bases.write_records(ctx.actor, people_table.id, %{
          creates:
            people_noise ++
              [
                %{
                  data: %{
                    people_primary.id => [colleague.principal.uid],
                    qty.id => 456,
                    scheduled_at.id => "2026-11-09T14:30:00Z"
                  }
                }
              ]
        })

      zelda_row = List.last(people_rows)

      assert {:ok, %{records: [matched_person]}} =
               Bases.query(ctx.actor, people_table.id, %{page_size: 100, search: "nightingale"})

      assert matched_person["id"] == zelda_row.id

      {:ok, qty} =
        Bases.update_field(ctx.actor, qty.id, %{version: qty.version, is_primary: true})

      assert qty.is_primary

      assert {:ok, %{records: [matched_number]}} =
               Bases.query(ctx.actor, people_table.id, %{page_size: 100, search: "456"})

      assert matched_number["id"] == zelda_row.id

      {:ok, _} =
        Bases.update_field(ctx.actor, code_formula.id, %{
          version: code_formula.version,
          is_primary: true
        })

      assert {:ok, %{records: [matched_formula]}} =
               Bases.query(ctx.actor, people_table.id, %{page_size: 100, search: "912"})

      assert matched_formula["id"] == zelda_row.id

      {:ok, _} =
        Bases.update_field(ctx.actor, scheduled_at.id, %{
          version: scheduled_at.version,
          is_primary: true
        })

      assert {:ok, %{records: [matched_date]}} =
               Bases.query(ctx.actor, people_table.id, %{page_size: 100, search: "Nov 9, 2026"})

      assert matched_date["id"] == zelda_row.id
    end
  end
end
