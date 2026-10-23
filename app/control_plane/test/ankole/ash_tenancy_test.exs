defmodule Ankole.AshTenancyTest do
  use Ankole.DataCase, async: false

  alias Ecto.Adapters.SQL

  alias TenantIsolationFixture.{Probe, SiteProbe}

  setup do
    SQL.query!(Repo, """
    CREATE TEMP TABLE ash_tenant_probes (
      id uuid PRIMARY KEY,
      tenant_id uuid NOT NULL,
      global_key text NOT NULL UNIQUE,
      value text,
      note text,
      status text NOT NULL DEFAULT 'queued'
    ) ON COMMIT DROP
    """)

    SQL.query!(
      Repo,
      "CREATE UNIQUE INDEX ash_tenant_probes_calculated_key_index ON ash_tenant_probes ((global_key || '/identity'))"
    )

    SQL.query!(Repo, """
    CREATE TEMP TABLE ash_site_probes (
      id uuid PRIMARY KEY,
      value text NOT NULL,
      data jsonb
    ) ON COMMIT DROP
    """)

    :ok
  end

  test "site resources use their declared scope without a tenant or a forged tenant option" do
    assert SiteProbe.__tenancy__() == :site

    row =
      Repo.without_tenant(fn ->
        assert {:ok, row} = Ankole.Ash.create(SiteProbe, :create, %{value: "site"})
        assert {:ok, found} = Ankole.Ash.read_one(SiteProbe)
        assert found.id == row.id
        row
      end)

    other = create_tenant()

    assert [found] = Repo.with_tenant(other.id, fn -> Ankole.Ash.read!(SiteProbe) end)
    assert found.id == row.id

    assert_raise ArgumentError, ~r/action tenant/, fn ->
      Ankole.Ash.read!(SiteProbe, tenant: other.id)
    end

    assert {:ok, %{value: "outside"}} =
             Repo.without_tenant(fn -> Ankole.Ash.update(row, :rename, %{value: "outside"}) end)

    assert {:ok, :committed} =
             Repo.without_tenant(fn ->
               Repo.transact(fn _repo ->
                 assert {:ok, _audit} =
                          Ankole.Ash.create(SiteProbe, :create, %{value: "audit"})

                 assert {:error, _rejected} = Ankole.Ash.update(row, :rename, %{value: "x"})
                 assert {:ok, renamed} = Ankole.Ash.update(row, :rename, %{value: "renamed"})
                 assert {:ok, destroyed} = Ankole.Ash.destroy(renamed, :remove)
                 assert destroyed.id == row.id
                 {:ok, :committed}
               end)
             end)

    assert [%{value: "audit"}] = Repo.without_tenant(fn -> Ankole.Ash.read!(SiteProbe) end)
  end

  test "atomic row updates run as one statement or in the caller's transaction" do
    {:ok, row} = Ankole.Ash.create(Probe, :upsert_global, %{global_key: "atomic transaction"})

    assert {:ok, %{note: "outside"}} = Ankole.Ash.update(row, :set_note, %{note: "outside"})
    assert Repo.get!(Probe, row.id).note == "outside"
    {:ok, row} = Ankole.Ash.update(row, :set_note, %{note: nil})

    assert {:error, :rollback} =
             Repo.transact(fn _repo ->
               assert {:ok, updated} = Ankole.Ash.update(row, :set_note, %{note: "inside"})
               assert updated.note == "inside"
               {:error, :rollback}
             end)

    assert Repo.get!(Probe, row.id).note == nil
  end

  test "site declarations cannot include a tenant primary key" do
    assert_raise ArgumentError, ~r/site resources cannot include tenant_id/, fn ->
      Code.compile_string("""
      defmodule InvalidSitePrimaryKey#{System.unique_integer([:positive])} do
        use Ankole.Ash.Resource, tenancy: :site, tenant_in_primary_key: true
      end
      """)
    end
  end

  test "JSON byte limits apply to the encoded normalized object" do
    value = %{"text" => "界\n"}
    {:ok, encoded} = Torque.encode(value)
    limit = byte_size(encoded)

    for callback <- [:cast_input, :cast_stored, :dump_to_native] do
      assert {:ok, ^value} =
               apply(Ankole.Ash.Types.JSONMap, callback, [value, [max_bytes: limit]])

      assert {:error, message: "is too large"} =
               apply(Ankole.Ash.Types.JSONMap, callback, [value, [max_bytes: limit - 1]])
    end

    assert {:error, message: "is too large"} =
             Ankole.Ash.Types.JSONMap.cast_atomic(value, max_bytes: limit - 1)

    assert {:ok, ^value} = Ankole.Ash.Types.JSONMap.cast_input(value, [])
  end

  test "tenant reads and destruction bind the caller before Ash constructs an action" do
    assert {:ok, row} =
             Ankole.Ash.create(Probe, :upsert_global, %{global_key: "destroy-owner"})

    assert_raise Ankole.TenantContextMissing, fn ->
      Repo.without_tenant(fn -> Ankole.Ash.read_one(Probe) end)
    end

    assert_raise Ankole.TenantContextMissing, fn ->
      Repo.without_tenant(fn -> Ankole.Ash.destroy(row, :remove) end)
    end

    other = create_tenant()

    assert_raise ArgumentError, ~r/action tenant/, fn ->
      Ankole.Ash.destroy(row, :remove, tenant: other.id)
    end

    assert {:error, _foreign_record} =
             Repo.with_tenant(other.id, fn -> Ankole.Ash.destroy(row, :remove) end)

    assert Repo.get!(Probe, row.id).global_key == "destroy-owner"
    assert {:ok, destroyed} = Ankole.Ash.destroy(row, :remove)
    assert destroyed.id == row.id
    refute Repo.exists?(Probe)
  end

  test "generic actions read only the process tenant, whatever tenant option Ash receives" do
    assert {:ok, _row} =
             Ankole.Ash.create(Probe, :upsert_global, %{global_key: "generic-owner"})

    assert {:ok, 1} = Ankole.Ash.run_action(Probe, :count_rows, %{})
    other = create_tenant()

    assert {:ok, 1} =
             Probe
             |> Ash.ActionInput.for_action(:count_rows, %{}, tenant: other.id, authorize?: false)
             |> Ash.run_action()

    assert_raise ArgumentError, ~r/action tenant/, fn ->
      Ankole.Ash.run_action(Probe, :count_rows, %{}, tenant: other.id)
    end

    selected_tenant = Repo.tenant_id!()

    Repo.without_tenant(fn ->
      assert_raise Ash.Error.Unknown, ~r/no tenant context/, fn ->
        Probe
        |> Ash.ActionInput.for_action(:count_rows, %{},
          tenant: selected_tenant,
          authorize?: false
        )
        |> Ash.run_action()
      end

      assert_raise Ankole.TenantContextMissing, fn ->
        Ankole.Ash.run_action(Probe, :count_rows, %{})
      end
    end)

    assert {:ok, 0} =
             Repo.with_tenant(other.id, fn -> Ankole.Ash.run_action(Probe, :count_rows, %{}) end)
  end

  test "JSON object datetime normalization is explicit and keeps the strict default" do
    now = ~U[2026-10-22 01:02:03.123456Z]
    input = %{"at" => now}
    expected = %{"at" => DateTime.to_iso8601(now)}

    for callback <- [:cast_input, :cast_stored, :dump_to_native] do
      assert {:error, message: "must be JSON-serializable object: unsupported_struct"} =
               apply(Ankole.Ash.Types.JSONMap, callback, [input, []])

      assert {:ok, ^expected} =
               apply(Ankole.Ash.Types.JSONMap, callback, [input, [allow_datetime?: true]])

      assert {:error, message: "must be JSON-serializable object: unsupported_runtime_value"} =
               apply(Ankole.Ash.Types.JSONMap, callback, [
                 %{"invalid" => self()},
                 [allow_datetime?: true]
               ])
    end

    assert {:ok, [^expected]} =
             Ash.Type.cast_input({:array, Ankole.Ash.Types.JSONMap}, [input],
               items: [allow_datetime?: true]
             )
  end

  test "arbitrary JSON values retain the shared codec through Ash persistence" do
    values = [nil, true, 42, 1.5, "text", [1, %{"nested" => false}], %{"key" => [nil, 2]}]

    for {value, index} <- Enum.with_index(values) do
      assert {:ok, row} =
               Ankole.Ash.create(SiteProbe, :create, %{value: "shape-#{index}", data: value})

      assert Repo.get!(SiteProbe, row.id).data == value
    end

    for invalid <- [%{atom_key: "invalid"}, DateTime.utc_now(), {:not, "json"}] do
      assert {:error, "is invalid"} =
               Ash.Type.cast_input(Ankole.Ash.Types.JSONValue, invalid, [])
    end
  end

  test "JSON values reject invalid PostgreSQL strings in values and object keys" do
    for invalid <- [
          "before\0after",
          <<255>>,
          %{"before\0after" => "value"},
          %{<<255>> => "value"},
          [%{"nested" => <<255>>}]
        ] do
      for callback <- [:cast, :load, :dump],
          do: assert(:error == apply(Ankole.Types.JSONValue, callback, [invalid]))

      assert {:error, "is invalid"} =
               Ash.Type.cast_input(Ankole.Ash.Types.JSONValue, invalid, [])

      assert {:error, %Ash.Error.Invalid{}} =
               Ankole.Ash.create(SiteProbe, :create, %{value: "invalid-json", data: invalid})
    end

    refute Repo.get_by(SiteProbe, value: "invalid-json")
  end

  test "resource UUID storage and default tenant use the existing Repo contract" do
    assert Probe.__tenancy__() == :tenant
    assert Probe.__schema__(:type, :tenant_id) == Ankole.Ecto.UUIDv7
    assert Ankole.Ash.Types.UUIDv7.ecto_type() == Ankole.Ecto.UUIDv7

    assert {:ok, row} =
             Ankole.Ash.create(Probe, :upsert_global, %{global_key: "same", value: "own"})

    assert row.tenant_id == Repo.tenant_id!()

    assert_raise Ankole.TenantContextMissing, fn ->
      Repo.without_tenant(fn -> Ankole.Ash.read!(Probe) end)
    end

    other = create_tenant()

    assert_raise ArgumentError, ~r/action tenant/, fn ->
      Ankole.Ash.read!(Probe, tenant: other.id)
    end

    assert Repo.with_tenant(other.id, fn -> Ankole.Ash.read!(Probe) end) == []

    {:ok, foreign} =
      Repo.with_tenant(other.id, fn ->
        Ankole.Ash.create(Probe, :upsert_global, %{global_key: "foreign", value: "other"})
      end)

    global =
      Repo.across_tenants(fn -> Ash.read!(Probe, action: :global, authorize?: false) end)

    fields = Probe.__schema__(:fields)

    assert global |> Enum.map(&Map.take(&1, fields)) |> MapSet.new() ==
             MapSet.new([Map.take(row, fields), Map.take(foreign, fields)])

    assert [scoped] = Ash.read!(Probe, action: :global, authorize?: false)
    assert scoped.id == row.id
  end

  test "global identity and primary key upserts cannot transfer or change another tenant's row" do
    {:ok, row} = Ankole.Ash.create(Probe, :upsert_global, %{global_key: "global", value: "first"})
    other = create_tenant()

    for {action, attrs} <- [
          {:upsert_global, %{global_key: "global", value: "stolen"}},
          {:upsert_id, %{id: row.id, global_key: "other", value: "stolen"}}
        ] do
      Repo.with_tenant(other.id, fn ->
        assert {:error, %Ash.Error.Invalid{}} = Ankole.Ash.create(Probe, action, attrs)
        assert Ankole.Ash.read!(Probe) == []
      end)

      assert Repo.get!(Probe, row.id).value == "first"
      assert Repo.get!(Probe, row.id).tenant_id == row.tenant_id
    end

    assert {:ok, updated} =
             Ankole.Ash.create(Probe, :upsert_global, %{
               global_key: "global",
               value: "same tenant"
             })

    assert updated.id == row.id
    assert updated.value == "same tenant"
  end

  test "ordinary actions retain operation metadata and every persisted field" do
    assert {:ok, inserted} =
             Ankole.Ash.create(Probe, :upsert_global, %{
               global_key: "metadata",
               value: "inserted"
             })

    assert Ash.Resource.get_metadata(inserted, :upsert_action) == :insert

    assert {:ok, updated} =
             Ankole.Ash.create(Probe, :upsert_global, %{
               global_key: "metadata",
               value: "updated"
             })

    assert updated.id == inserted.id
    assert Ash.Resource.get_metadata(updated, :upsert_action) == :update

    assert {:ok, ordinary} =
             Ankole.Ash.create(Probe, :upsert_global, %{global_key: "metadata", value: "ordinary"})

    Ankole.DataCase.assert_persisted_equal(
      ordinary,
      Repo.get!(Probe, ordinary.id, prefix: "pg_temp")
    )

    assert {:ok, read} = Ankole.Ash.read_one(Probe)
    assert_persisted_equal(read, ordinary)
    assert_persisted_equal(Ankole.Ash.read!(Probe), [ordinary])

    assert {:ok, finished} =
             Repo.transact(fn _repo -> Ankole.Ash.update(ordinary, :finish, %{}) end)

    Ankole.DataCase.assert_persisted_equal(
      finished,
      Repo.get!(Probe, finished.id, prefix: "pg_temp")
    )
  end

  test "an explicit false upsert condition preserves immutable rows and tenant isolation" do
    assert {:ok, frozen} =
             Ankole.Ash.create(Probe, :insert_once, %{global_key: "frozen", value: "original"})

    assert {:ok, replayed} =
             Ankole.Ash.create(Probe, :insert_once, %{global_key: "frozen", value: "replacement"})

    assert replayed.id == frozen.id
    assert replayed.value == "original"
    assert Repo.get!(Probe, frozen.id).value == "original"

    other = create_tenant()

    for {action, attrs} <- [
          {:insert_once, %{global_key: "frozen", value: "foreign"}},
          {:insert_once_id, %{id: frozen.id, global_key: "frozen", value: "foreign"}}
        ] do
      Repo.with_tenant(other.id, fn ->
        assert {:error, %Ash.Error.Invalid{errors: [%Ankole.Errors.Invalid.Stale{}]}} =
                 Ankole.Ash.create(Probe, action, attrs)

        assert Ankole.Ash.read!(Probe) == []
      end)
    end

    assert Repo.get!(Probe, frozen.id).value == "original"
    assert Repo.get!(Probe, frozen.id).tenant_id == frozen.tenant_id
  end

  test "immutable calculated identities resolve skipped writes without crossing tenants" do
    attrs = %{global_key: "calculated", lookup_key: "calculated/identity", value: "first"}
    assert {:ok, first} = Ankole.Ash.create(Probe, :insert_once_calculated, attrs)

    assert {:ok, repeated} =
             Ankole.Ash.create(Probe, :insert_once_calculated, %{attrs | value: "replacement"})

    assert repeated.id == first.id
    assert repeated.value == "first"

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert {:error, %Ash.Error.Invalid{errors: [%Ankole.Errors.Invalid.Stale{}]}} =
               Ankole.Ash.create(Probe, :insert_once_calculated, attrs)

      assert Ankole.Ash.read!(Probe) == []
    end)

    assert Repo.get!(Probe, first.id).value == "first"
  end

  test "a rejected non-atomic action leaves the caller's compensation transaction usable" do
    {:ok, row} = Ankole.Ash.create(Probe, :upsert_global, %{global_key: "terminal"})

    assert {:ok, :compensated} =
             Repo.transact(fn repo ->
               locked = repo.one!(from(p in Probe, where: p.id == ^row.id, lock: "FOR UPDATE"))

               assert {:ok, _} =
                        Ankole.Ash.create(Probe, :upsert_global, %{
                          global_key: "audit",
                          value: "committed"
                        })

               assert {:ok, done} = Ankole.Ash.update(locked, :finish, %{})
               assert {:error, _} = Ankole.Ash.update(done, :finish, %{})

               {:ok, :compensated}
             end)

    assert Repo.get_by!(Probe, global_key: "audit").value == "committed"
    assert Repo.get!(Probe, row.id).status == :done
  end

  test "calculations can evaluate literal inputs through the data layer" do
    assert {:ok, 7} =
             Ash.calculate(Probe, :value_length,
               refs: %{value: "literal"},
               data_layer?: true,
               tenant: Repo.tenant_id!(),
               authorize?: false
             )
  end

  test "atomic writes commit without notification warnings and return requested notifications" do
    # The test configuration ignores missed notifications; this check needs the warning.
    Application.put_env(:ash, :missed_notifications, :warn)
    on_exit(fn -> Application.put_env(:ash, :missed_notifications, :ignore) end)
    assert {:ok, row} = Ankole.Ash.create(Probe, :upsert_global, %{global_key: "notifications"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, updated} =
                 Repo.transact(fn -> Ankole.Ash.update(row, :touch, %{value: "atomic"}) end)

        assert updated.value == "atomic"
      end)

    refute log =~ "Missed"
    assert Repo.get!(Probe, row.id).value == "atomic"

    assert {:ok, {_updated, [notification]}} =
             Repo.transact(fn ->
               assert {:ok, updated, notifications} =
                        Ankole.Ash.update(row, :touch, %{value: "requested"},
                          return_notifications?: true
                        )

               {:ok, {updated, notifications}}
             end)

    assert notification.for == []
    assert notification.data.value == "requested"
  end

  test "runtime upsert subsets preserve every other declared field" do
    assert {:ok, row} =
             Ankole.Ash.create(Probe, :upsert_global, %{
               global_key: "partial",
               value: "original value",
               note: "original note"
             })

    assert {:ok, updated} =
             Ankole.Ash.create(
               Probe,
               :upsert_global,
               %{global_key: "partial", value: "new value", note: "must not replace"},
               upsert_fields: [:value]
             )

    assert updated.id == row.id
    assert updated.value == "new value"
    assert updated.note == "original note"

    assert {:ok, updated} =
             Ankole.Ash.create(
               Probe,
               :upsert_global,
               %{global_key: "partial", value: "must not replace", note: "new note"},
               upsert_fields: [:note]
             )

    assert updated.value == "new value"
    assert updated.note == "new note"
    assert Repo.get!(Probe, row.id).value == "new value"

    for fields <- [[], [:value, :note, :global_key]] do
      assert_raise Ash.Error.Unknown, ~r/tenant upserts/, fn ->
        Ankole.Ash.create(
          Probe,
          :upsert_global,
          %{global_key: "partial", value: "bad replacement"},
          upsert_fields: fields
        )
      end
    end

    assert Repo.get!(Probe, row.id).note == "new note"
  end

  test "runtime upsert fields cannot replace the resource action's declared contract" do
    assert_raise Ash.Error.Unknown, ~r/declared fields/, fn ->
      Ankole.Ash.create(Probe, :upsert_global, %{global_key: "override", value: "data"},
        upsert_fields: [:global_key]
      )
    end

    refute Repo.exists?(Probe)
  end

  test "limited atomic bulk operations use the scoped CTE without requiring its tenant column" do
    for key <- ["a", "b", "c"], do: Ankole.Ash.create(Probe, :upsert_global, %{global_key: key})
    query = Ash.Query.limit(Probe, 1)

    result =
      Ankole.Ash.bulk_update(query, :touch, %{value: "updated"},
        return_errors?: true,
        return_records?: true
      )

    assert result.status == :success
    assert length(result.records) == 1
    assert Enum.count(Ankole.Ash.read!(Probe), &(&1.value == "updated")) == 1

    result =
      Ankole.Ash.bulk_destroy(query, :remove, %{}, return_errors?: true, return_records?: true)

    assert result.status == :success
    assert length(Ankole.Ash.read!(Probe)) == 2
  end

  test "unbound processes fail closed even when Ash async is enabled" do
    previous = Application.fetch_env!(:ash, :disable_async?)
    Application.put_env(:ash, :disable_async?, false)
    on_exit(fn -> Application.put_env(:ash, :disable_async?, previous) end)
    tenant = Repo.tenant_id!()

    assert {:error, Ankole.TenantContextMissing} ==
             Task.async(fn ->
               try do
                 Ankole.Ash.read!(Probe, tenant: tenant)
               rescue
                 error in Ankole.TenantContextMissing -> {:error, error.__struct__}
               end
             end)
             |> Task.await()
  end

  test "compile-time contracts reject writable ownership, accepted ownership, policies, and unsafe upserts" do
    for {definition, expected} <- [
          {"actions do create :create do accept [:tenant_id] end end", "tenant_id"},
          {"actions do create :create do upsert? true end end", "upsert_fields"},
          {"actions do create :create do upsert? true; upsert_fields [:tenant_id] end end",
           "tenant_id"},
          {"actions do create :create do upsert? true; upsert_fields [:value]; change atomic_set(:value, expr(\"unsafe\")) end end",
           "atomics"},
          {"actions do update :unsafe do change before_action(fn changeset -> changeset end) end end",
           "action hooks"},
          {"actions do update :unsafe do change after_action(fn _changeset, record -> {:ok, record} end) end end",
           "action hooks"},
          {"actions do update :unsafe do validate present(:value), before_action?: true end end",
           "before_action\\?"},
          {"validations do validate present(:value), before_action?: true end; actions do update :unsafe do end end",
           "before_action\\?"},
          {"actions do create :unsafe do change before_transaction(fn changeset -> changeset end) end end",
           "transaction hooks"}
        ] do
      name = "Ankole.AshContractProbe#{System.unique_integer([:positive])}"

      assert_raise Spark.Error.DslError, ~r/#{expected}/, fn ->
        Code.compile_string("""
        defmodule #{name} do
          use Ankole.Ash.Resource, tenancy: :tenant
          postgres do table "ash_tenant_probes"; repo Ankole.Repo; migrate? false end
          attributes do attribute :id, :integer, primary_key?: true, allow_nil?: false; attribute :value, :string end
          #{definition}
        end
        """)
      end
    end
  end

  test "compile-time contracts reject a writable tenant attribute and a second authorization model" do
    for {options, writable, extra, expected} <- [
          {"", "true", "", "tenant_id must not be writable"},
          {", authorizers: [Ash.Policy.Authorizer]", "false",
           "policies do policy always() do authorize_if always() end end", "Principal/AuthZ"}
        ] do
      name = "Ankole.AshContractProbe#{System.unique_integer([:positive])}"

      assert_raise Spark.Error.DslError, ~r/#{Regex.escape(expected)}/, fn ->
        Code.compile_string("""
        defmodule #{name} do
          use Ash.Resource, domain: nil, data_layer: AshPostgres.DataLayer,
            extensions: [Ankole.Ash.Extension]#{options}
          @persist {:ankole_tenancy, :tenant}
          postgres do table "ash_tenant_probes"; repo Ankole.Repo; migrate? false end
          attributes do
            attribute :id, :integer, primary_key?: true, allow_nil?: false
            attribute :tenant_id, Ankole.Ash.Types.UUIDv7, writable?: #{writable}
          end
          multitenancy do strategy :attribute; attribute :tenant_id; global? false end
          #{extra}
        end
        """)
      end
    end
  end
end
