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

  test "primary fields keep their text type while their name and position can change", ctx do
    for mode <- [:inline, :physical] do
      if mode == :physical do
        assert {:ok, _} =
                 Bases.create_field(ctx.actor, ctx.table.id, %{
                   name: "Related",
                   type: "link",
                   config: %{"table_id" => ctx.table.id}
                 })
      end

      primary = Enum.find(Bases.fields(ctx.table.id), & &1.is_primary)
      assert {:ok, before} = Bases.get_table(ctx.actor, ctx.table.id)

      for type <- ~w(number datetime checkbox attachment user select formula auto_number link) do
        assert {:error, _} =
                 Bases.update_field(ctx.actor, primary.id, %{
                   version: primary.version,
                   type: type
                 })
      end

      assert {:ok, after_rejection} = Bases.get_table(ctx.actor, ctx.table.id)
      assert after_rejection == before

      assert {:ok, renamed} =
               Bases.update_field(ctx.actor, primary.id, %{
                 version: primary.version,
                 name: "Title #{mode}",
                 position: "A"
               })

      assert renamed.type == :text
      assert renamed.name == "Title #{mode}"
      assert renamed.position == "A"
    end
  end

  test "PostgreSQL rejects a non-text primary field even outside the domain action", ctx do
    assert_raise Postgrex.Error, ~r/base_fields_primary_text/, fn ->
      Repo.query!(
        "UPDATE base_fields SET type='number' WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
        [Repo.tenant_id!(), ctx.primary.id]
      )
    end
  end

  test "the primary index supports C ordering when the column has another collation", ctx do
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

          BaseRepo.query!("SET LOCAL enable_seqscan=off", [])

          plan =
            BaseRepo.query!(
              ~s|EXPLAIN (COSTS OFF) SELECT id FROM #{BaseRepo.table(ctx.table.id)} ORDER BY #{BaseRepo.column(ctx.primary.id)} COLLATE "C"|,
              []
            ).rows

          assert Enum.any?(plan, fn [line] ->
                   String.contains?(line, "ix_#{BaseRepo.hex(ctx.primary.id)}")
                 end)

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

  test "primary UTF-8 bytes have the same limit before and after a link promotes the table",
       ctx do
    value = String.duplicate("界", 682) <> "ab"
    assert byte_size(value) == 2048

    for mode <- [:inline, :physical] do
      if mode == :physical do
        assert {:ok, _} =
                 Bases.create_field(ctx.actor, ctx.table.id, %{
                   name: "Link",
                   type: "link",
                   config: %{"table_id" => ctx.table.id}
                 })
      end

      assert {:ok, _} =
               Bases.write_records(ctx.actor, ctx.table.id, %{
                 creates: [%{data: %{ctx.primary.id => value}}]
               })

      assert {:error, :primary_field_size_limit} =
               Bases.write_records(ctx.actor, ctx.table.id, %{
                 creates: [%{data: %{ctx.primary.id => value <> "x"}}]
               })
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
end
