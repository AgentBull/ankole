defmodule Ankole.RepoTenancyTest do
  use Ankole.DataCase, async: true

  alias Ankole.ActorRef
  alias Ankole.AuthZ.Group
  alias Ankole.Principals.Principal
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.{ExternalMessageRef, Message}
  alias Ankole.Tenants.Tenant

  test "Ecto can record and remove schema versions without a tenant context" do
    version = 9_900_000_000_000_000 + System.unique_integer([:positive])

    Repo.without_tenant(fn ->
      assert {:ok, %{version: ^version}} =
               Ecto.Migration.SchemaMigration.up(Repo, Repo.config(), version, [])

      assert Repo.get_by!(Ecto.Migration.SchemaMigration, version: version).version == version
      assert {1, nil} = Ecto.Migration.SchemaMigration.down(Repo, Repo.config(), version, [])
      refute Repo.get_by(Ecto.Migration.SchemaMigration, version: version)
    end)
  end

  test "context blocks and child closures restore the caller on success and failure", %{
    tenant: tenant
  } do
    other = new_tenant()
    assert Repo.tenant_id!() == tenant.id

    Repo.across_tenants(fn ->
      assert Repo.tenant_id() == nil
      assert Repo.with_tenant(other.id, &Repo.tenant_id!/0) == other.id
      assert Repo.tenant_id() == nil
    end)

    assert_raise RuntimeError, fn ->
      Repo.with_tenant(other.id, fn -> raise "interrupted" end)
    end

    assert Repo.tenant_id!() == tenant.id
    assert Keyword.get(Logger.metadata(), :tenant_id) == tenant.id
    assert Task.async(Repo.bind_tenant(&Repo.tenant_id!/0)) |> Task.await() == tenant.id
    assert Task.async(&Repo.tenant_id/0) |> Task.await() == nil

    Repo.without_tenant(fn ->
      assert_raise Ankole.TenantContextMissing, fn -> Repo.all(Principal) end

      assert_raise Ankole.TenantContextMissing, fn ->
        Ankole.Ash.create(Principal, :create_in_tx, %{uid: "missing-context", type: :human})
      end

      assert Repo.aggregate(Tenant, :count) >= 1
    end)
  end

  test "a system Principal is unique within its tenant, with one allowed in another tenant" do
    attrs = fn ->
      %{uid: Ankole.Ecto.UUIDv7.autogenerate(), type: :system, display_name: "System"}
    end

    assert {:ok, _} = create_principal(attrs.())
    other = new_tenant()

    assert {:ok, _} =
             Repo.with_tenant(other.id, fn ->
               create_principal(attrs.())
             end)

    assert {:error, changeset} = create_principal(attrs.())
    assert %{type: [_]} = errors_on(changeset)
  end

  test "the authenticated identity locator only establishes a tenant and restores the caller" do
    tenant_id = Repo.tenant_id!()
    other = new_tenant()

    principal =
      Repo.with_tenant(other.id, fn ->
        {:ok, principal} =
          create_principal(%{uid: Ankole.Ecto.UUIDv7.autogenerate(), type: :human})

        principal
      end)

    assert {:ok, other.id} == Ankole.Principals.resolve_tenant(principal.uid)
    assert Repo.tenant_id!() == tenant_id
    assert Repo.get(Principal, principal.uid) == nil

    assert {:error, :not_found} =
             Ankole.Principals.resolve_tenant(Ankole.Ecto.UUIDv7.autogenerate())
  end

  test "per-call context overrides an all-tenant block for reads and deletes", %{tenant: tenant} do
    other = new_tenant()
    group("shared")
    Repo.with_tenant(other.id, fn -> group("shared") end)

    Repo.across_tenants(fn ->
      assert [%Group{tenant_id: tenant_id}] =
               Repo.all(from(g in Group, where: g.name == "shared"), tenant: {:id, tenant.id})

      assert tenant_id == tenant.id

      assert {1, nil} =
               Repo.delete_all(from(g in Group, where: g.name == "shared"),
                 tenant: {:id, tenant.id}
               )

      query = from g in Group, where: g.tenant_id in ^[tenant.id, other.id] and g.name == "shared"
      assert [%Group{tenant_id: other_id}] = Repo.all(query)
      assert other_id == other.id
    end)
  end

  test "a tenant's same-name row does not suppress another tenant through EXISTS", %{
    tenant: tenant
  } do
    other = new_tenant()
    group("candidate")
    Repo.with_tenant(other.id, fn -> group("excluded") end)

    query =
      from g in Group,
        where: g.name == "candidate",
        where: not exists(from other in Group, where: other.name == "excluded", select: 1)

    assert [%Group{name: "candidate", tenant_id: tenant_id}] = Repo.all(query)
    assert tenant_id == tenant.id

    source_query =
      from(g in subquery(from g in Group, where: g.name == "candidate", select: %{name: g.name}))

    assert [%{name: "candidate"}] = Repo.all(source_query)
  end

  test "a site root still checks the tenant context of its subquery" do
    query = from t in Tenant, where: exists(from g in Group, select: 1)

    Repo.without_tenant(fn ->
      assert_raise Ankole.TenantContextMissing, fn -> Repo.all(query) end
      assert is_list(Repo.across_tenants(fn -> Repo.all(query) end))
    end)
  end

  test "composite primary keys protect conversation writes and tenant-scoped message joins", %{
    tenant: tenant
  } do
    other = new_tenant()
    id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()
    conversation = conversation(id, "first")
    message(id, message_id, "first")

    Repo.with_tenant(other.id, fn ->
      conversation(id, "second")
      message(id, message_id, "second")
    end)

    conversation |> Ecto.Changeset.change(title: "changed") |> Repo.update!()

    assert [%{text: "first", tenant_id: tenant_id}] =
             Repo.all(
               from m in Message,
                 join: ref in ExternalMessageRef,
                 on: ref.message_id == m.id and ref.tenant_id == m.tenant_id,
                 where: m.conversation_id == ^id,
                 select: %{text: m.text, tenant_id: m.tenant_id}
             )

    assert tenant_id == tenant.id

    assert Repo.with_tenant(other.id, fn -> Repo.get_by!(Conversation, id: id).title end) ==
             "second"

    Repo.delete!(conversation)
    assert Repo.get_by(Conversation, id: id) == nil

    assert Repo.with_tenant(other.id, fn -> Repo.get_by!(Conversation, id: id).title end) ==
             "second"

    assert Repo.with_tenant(other.id, fn -> Repo.get_by!(Message, id: message_id).text end) ==
             "second"
  end

  test "site and subquery roots reject direct tenant joins unless all tenants are explicit" do
    first = group("joined")
    other = new_tenant()
    second = Repo.with_tenant(other.id, fn -> group("joined") end)
    ids = [first.id, second.id]

    for source <- [Tenant, subquery(Tenant)] do
      query =
        from t in source,
          join: g in Group,
          on: g.tenant_id == t.id,
          where: g.id in ^ids,
          select: g

      assert_raise ArgumentError, ~r/tenant-scoped subquery/, fn -> Repo.all(query) end

      Repo.without_tenant(fn ->
        assert_raise Ankole.TenantContextMissing, fn -> Repo.all(query) end
      end)

      assert Repo.across_tenants(fn -> Repo.all(query) end) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([first.id, second.id])
    end
  end

  test "site and subquery roots join tenant-scoped subqueries without exposing another tenant" do
    first = group("joined")
    other = new_tenant()
    second = Repo.with_tenant(other.id, fn -> group("joined") end)
    ids = [first.id, second.id]

    for source <- [Tenant, subquery(Tenant)] do
      query =
        from t in source,
          join: g in subquery(Group),
          on: g.tenant_id == t.id,
          where: g.id in ^ids,
          select: g

      Ankole.DataCase.assert_persisted_equal(Repo.all(query), [first])

      Repo.without_tenant(fn ->
        assert_raise Ankole.TenantContextMissing, fn -> Repo.all(query) end
      end)

      assert Repo.across_tenants(fn -> Repo.all(query) end) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([first.id, second.id])
    end
  end

  test "direct nested tenant queries scope their rows before a site join", %{tenant: tenant} do
    first = group("direct-nested")
    other = new_tenant()
    second = Repo.with_tenant(other.id, fn -> group("direct-nested") end)
    ids = [first.id, second.id]
    nested = from(g in Group, where: g.id in ^ids)

    query = from(t in Tenant, join: g in Group, on: g.tenant_id == t.id, select: g)
    query = %{query | joins: [%{hd(query.joins) | source: nested}]}

    Ankole.DataCase.assert_persisted_equal(Repo.all(query), [first])
    assert first.tenant_id == tenant.id

    Ankole.DataCase.assert_persisted_equal(
      Repo.with_tenant(other.id, fn -> Repo.all(query) end),
      [second]
    )

    Repo.without_tenant(fn ->
      assert_raise Ankole.TenantContextMissing, fn -> Repo.all(query) end
    end)

    assert Repo.across_tenants(fn -> Repo.all(query) end) |> Enum.map(& &1.id) |> Enum.sort() ==
             Enum.sort(ids)
  end

  test "direct nested site queries retain site ownership inside a tenant join", %{tenant: tenant} do
    first = group("direct-site")
    other = new_tenant()
    second = Repo.with_tenant(other.id, fn -> group("direct-site") end)
    ids = [first.id, second.id]
    nested = from(t in Tenant)

    query =
      from(g in Group,
        join: t in Tenant,
        on: g.tenant_id == t.id,
        where: g.id in ^ids,
        select: {g.id, t.id}
      )

    query = %{query | joins: [%{hd(query.joins) | source: nested}]}

    assert Repo.all(query) == [{first.id, tenant.id}]
    assert Repo.with_tenant(other.id, fn -> Repo.all(query) end) == [{second.id, other.id}]

    Repo.without_tenant(fn ->
      assert_raise Ankole.TenantContextMissing, fn -> Repo.all(query) end
    end)
  end

  test "raw table queries use the explicit tenant context", %{tenant: tenant} do
    group("raw")
    other = new_tenant()
    Repo.with_tenant(other.id, fn -> group("raw") end)

    assert [tenant.id] ==
             Repo.all(
               from g in "principal_groups",
                 where: g.name == "raw",
                 select: type(g.tenant_id, Ecto.UUID)
             )
  end

  test "Oban options cannot bypass business queries or nested tenant sources", %{tenant: tenant} do
    own = group("oban-option")
    other = new_tenant()
    Repo.with_tenant(other.id, fn -> group("oban-option") end)

    Ankole.DataCase.assert_persisted_equal(
      Repo.all(from(g in Group, where: g.name == "oban-option"), oban: true),
      [own]
    )

    queries = [
      from(g in Group),
      from(j in Oban.Job, where: exists(from(g in Group, select: 1))),
      from(j in Oban.Job, join: g in Group, on: true),
      Oban.Job |> with_cte("tenant_groups", as: ^from(g in Group))
    ]

    Repo.without_tenant(fn ->
      for query <- queries do
        assert_raise Ankole.TenantContextMissing, fn -> Repo.all(query, oban: true) end
      end
    end)

    assert Repo.tenant_id!() == tenant.id
  end

  test "struct writes reject another tenant and missing context" do
    own = group("struct-write")
    other = new_tenant()
    changeset = Ecto.Changeset.change(own, name: "changed")

    for {context, exception} <- [
          {fn fun -> Repo.with_tenant(other.id, fun) end, ArgumentError},
          {&Repo.without_tenant/1, Ankole.TenantContextMissing}
        ],
        operation <- [
          :insert,
          :insert!,
          :insert_or_update,
          :insert_or_update!,
          :update,
          :update!,
          :delete,
          :delete!
        ] do
      context.(fn -> assert_raise exception, fn -> apply(Repo, operation, [changeset]) end end)
    end

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Group, own.id), own)
  end

  test "per-call insert context supplies ownership without changing the caller", %{tenant: tenant} do
    other = new_tenant()

    inserted =
      %Group{
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        name: "per-call-write",
        display_name: "Per-call write",
        domain: :operator,
        kind: :static,
        built_in: false,
        metadata: %{},
        inserted_at: DateTime.utc_now(:microsecond),
        updated_at: DateTime.utc_now(:microsecond)
      }
      |> AshPostgres.DataLayer.to_ecto()
      |> Repo.insert!(tenant: {:id, other.id})
      |> AshPostgres.DataLayer.from_ecto()

    assert inserted.tenant_id == other.id
    assert Repo.get(Group, inserted.id) == nil

    assert Repo.with_tenant(other.id, fn ->
             Repo.get!(Group, inserted.id) |> AshPostgres.DataLayer.from_ecto()
           end) == inserted

    assert Repo.tenant_id!() == tenant.id
  end

  test "struct writes include ownership in their database filters", %{tenant: tenant} do
    own = group("write-filter")
    other = new_tenant()
    wrong_owner = %{own | tenant_id: other.id}

    Repo.with_tenant(other.id, fn ->
      assert_raise Ecto.StaleEntryError, fn ->
        wrong_owner |> Ecto.Changeset.change(name: "changed") |> Repo.update!()
      end

      assert_raise Ecto.StaleEntryError, fn -> Repo.delete!(wrong_owner) end

      assert_raise ArgumentError, fn ->
        Repo.insert!(%Group{tenant_id: tenant.id, name: "foreign"})
      end
    end)

    assert_raise ArgumentError, fn ->
      own |> Ecto.Changeset.change(tenant_id: other.id) |> Repo.update!()
    end

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Group, own.id), own)
  end

  test "batch inserts validate every row's tenant", %{tenant: tenant} do
    own = group("batch-source")
    other = new_tenant()

    row =
      own
      |> Map.from_struct()
      |> Map.take(Group.__schema__(:fields))
      |> Map.merge(%{id: Ankole.Ecto.UUIDv7.autogenerate(), name: "batch"})

    foreign_row = %{row | id: Ankole.Ecto.UUIDv7.autogenerate(), tenant_id: other.id}
    assert_raise ArgumentError, fn -> Repo.insert_all(Group, [row, foreign_row]) end
    assert_raise ArgumentError, fn -> Repo.insert_all(Group, [Map.delete(row, :tenant_id)]) end

    Repo.without_tenant(fn ->
      assert_raise Ankole.TenantContextMissing, fn -> Repo.insert_all(Group, [row]) end
    end)

    assert {1, nil} = Repo.insert_all(Group, [row])
    assert Repo.get!(Group, row.id).tenant_id == tenant.id

    Repo.across_tenants(fn ->
      assert {1, nil} = Repo.insert_all(Group, [foreign_row])
    end)

    assert Repo.with_tenant(other.id, fn -> Repo.get!(Group, foreign_row.id).tenant_id end) ==
             other.id
  end

  test "tenant joins constrain the joined row and retain unmatched outer roots" do
    own = group("own-root")
    other = new_tenant()
    foreign = Repo.with_tenant(other.id, fn -> group("foreign-match") end)

    inner =
      from root in Group,
        join: joined in Group,
        on: joined.name == ^foreign.name,
        where: root.id == ^own.id,
        select: joined

    assert Repo.all(inner) == []

    outer =
      from root in Group,
        left_join: joined in Group,
        on: joined.name == ^foreign.name,
        where: root.id == ^own.id,
        select: {root.id, joined.id}

    assert Repo.all(outer) == [{own.id, nil}]

    Ankole.DataCase.assert_persisted_equal(Repo.across_tenants(fn -> Repo.all(inner) end), [
      foreign
    ])
  end

  test "compound ON parameters keep their binding and type across multiple outer joins" do
    own = group("compound-own")
    other = new_tenant()
    foreign = Repo.with_tenant(other.id, fn -> group("compound-foreign") end)
    names = [own.name]

    query =
      from root in Group,
        left_join: first in Group,
        on: first.name == ^foreign.name and (first.id != ^own.id or first.id == ^foreign.id),
        left_join: second in Group,
        on: second.name in ^names and second.id == ^own.id,
        where: root.id == ^own.id,
        select: {root.id, first.id, second.id}

    assert Repo.all(query) == [{own.id, nil, own.id}]
    assert Repo.across_tenants(fn -> Repo.all(query) end) == [{own.id, foreign.id, own.id}]
  end

  test "update_all and delete_all affect only the selected tenant" do
    own = group("batch-write")
    other = new_tenant()
    foreign = Repo.with_tenant(other.id, fn -> group("batch-write") end)
    rows = from(g in Group, where: g.name == "batch-write")
    assert {1, nil} = Repo.update_all(rows, set: [display_name: "Updated"])

    assert_persisted_equal(
      Repo.with_tenant(other.id, fn -> Repo.get!(Group, foreign.id) end),
      foreign
    )

    assert_raise ArgumentError, fn -> Repo.update_all(Group, set: [tenant_id: other.id]) end
    assert Repo.get!(Group, own.id).tenant_id == own.tenant_id
    assert {1, nil} = Repo.delete_all(rows)

    assert_persisted_equal(
      Repo.with_tenant(other.id, fn -> Repo.get!(Group, foreign.id) end),
      foreign
    )
  end

  test "conflict updates cannot take ownership of another tenant's global key" do
    other = new_tenant()
    uid = Ankole.Ecto.UUIDv7.autogenerate()
    now = DateTime.utc_now()

    foreign =
      Repo.with_tenant(other.id, fn ->
        %Principal{
          uid: uid,
          type: :human,
          display_name: "Foreign",
          inserted_at: now,
          updated_at: now
        }
        |> AshPostgres.DataLayer.to_ecto()
        |> Repo.insert!()
        |> AshPostgres.DataLayer.from_ecto()
      end)

    actions = [
      [set: [display_name: "Changed"]],
      {:replace, [:display_name]},
      {:replace_all_except, [:inserted_at]},
      from(p in Principal, update: [set: [display_name: "Changed"]])
    ]

    for action <- actions do
      assert_raise Ecto.StaleEntryError, fn ->
        Repo.insert!(
          AshPostgres.DataLayer.to_ecto(%Principal{
            uid: uid,
            type: :human,
            display_name: "Changed",
            inserted_at: now,
            updated_at: now
          }),
          on_conflict: action,
          conflict_target: [:uid]
        )
      end

      assert Repo.with_tenant(other.id, fn ->
               Repo.get!(Principal, uid) |> AshPostgres.DataLayer.from_ecto()
             end) == foreign
    end

    assert_raise ArgumentError, fn ->
      Repo.insert!(
        AshPostgres.DataLayer.to_ecto(%Principal{
          uid: uid,
          type: :human,
          inserted_at: now,
          updated_at: now
        }),
        on_conflict: [set: [tenant_id: other.id]],
        conflict_target: [:uid]
      )
    end
  end

  test "every tenant schema scopes roots, raw tables, joins and nested query forms", %{
    tenant: tenant
  } do
    for schema <- tenant_schemas() do
      table = schema.__schema__(:source)
      root = from(row in schema, select: row.tenant_id)

      shapes = [
        root,
        from(row in table, select: type(row.tenant_id, Ecto.UUID)),
        from(row in subquery(root), select: row.tenant_id),
        from(row in schema,
          where: exists(from(other in schema, select: 1)),
          select: row.tenant_id
        ),
        from(row in schema, where: row.tenant_id in subquery(root), select: row.tenant_id),
        union_all(root, ^root),
        root |> with_cte("scoped_rows", as: ^root),
        from(row in schema,
          join: other in ^schema,
          on: other.tenant_id == row.tenant_id,
          select: row.tenant_id
        ),
        from(row in schema, left_join: other in ^schema, on: true, select: row.tenant_id)
      ]

      for query <- shapes, operation <- [:all, :update_all, :delete_all] do
        assert_raise Ankole.TenantContextMissing, fn ->
          Repo.prepare_query(operation, query, tenant: nil)
        end

        {scoped, _} = Repo.prepare_query(operation, query, tenant: {:id, tenant.id})
        {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, scoped)
        assert sql =~ "tenant_id", "unscoped #{inspect(schema)} #{operation}"
        assert Ecto.UUID.dump!(tenant.id) in params
      end

      for name <- schema.__schema__(:associations) do
        query =
          from(row in schema, left_join: related in assoc(row, ^name), select: row.tenant_id)

        {scoped, _} = Repo.prepare_query(:all, query, tenant: {:id, tenant.id})
        {sql, _} = Ecto.Adapters.SQL.to_sql(:all, Repo, scoped)
        assert sql =~ "tenant_id"
      end
    end
  end

  test "every tenant schema rejects foreign and context-free struct and batch writes", %{
    tenant: tenant
  } do
    foreign = new_tenant()

    for schema <- tenant_schemas() do
      data = struct(schema, tenant_id: foreign.id)

      for operation <- [
            :insert,
            :insert!,
            :insert_or_update,
            :insert_or_update!,
            :update,
            :update!,
            :delete,
            :delete!
          ] do
        assert_raise ArgumentError, fn -> apply(Repo, operation, [data]) end

        Repo.without_tenant(fn ->
          assert_raise Ankole.TenantContextMissing, fn -> apply(Repo, operation, [data]) end
        end)
      end

      for source <- [schema, schema.__schema__(:source)] do
        assert_raise ArgumentError, fn -> Repo.insert_all(source, [%{tenant_id: foreign.id}]) end

        Repo.without_tenant(fn ->
          assert_raise Ankole.TenantContextMissing, fn ->
            Repo.insert_all(source, [%{tenant_id: tenant.id}])
          end
        end)

        assert_raise ArgumentError, fn ->
          Repo.insert_all(source, from(row in schema, select: %{tenant_id: ^foreign.id}))
        end
      end
    end
  end

  test "batch scalar queries and conflict scalar queries retain the caller's tenant", %{
    tenant: tenant
  } do
    own = group("scalar-source")
    other = new_tenant()

    Repo.with_tenant(other.id, fn ->
      group("scalar-source") |> Ecto.Changeset.change(display_name: "foreign") |> Repo.update!()
    end)

    value_query =
      from g in Group, where: g.name == "scalar-source", select: g.display_name, limit: 1

    now = DateTime.utc_now(:microsecond)
    id = Ankole.Ecto.UUIDv7.autogenerate()

    attrs = %{
      id: id,
      tenant_id: tenant.id,
      name: "scalar-result",
      display_name: value_query,
      domain: :operator,
      kind: :static,
      built_in: false,
      metadata: %{},
      inserted_at: now,
      updated_at: now
    }

    assert {1, nil} = Repo.insert_all(Group, [attrs])
    assert Repo.get!(Group, id).display_name == own.display_name

    conflict =
      from g in Group,
        where:
          exists(
            from source in Group,
              where: source.name == "scalar-source" and source.display_name == "foreign",
              select: 1
          ),
        update: [set: [display_name: "foreign"]]

    assert {0, nil} =
             Repo.insert_all(Group, [%{attrs | display_name: "replacement"}],
               on_conflict: conflict,
               conflict_target: [:tenant_id, :name]
             )

    assert Repo.get!(Group, id).display_name == own.display_name

    Repo.without_tenant(fn ->
      assert_raise Ankole.TenantContextMissing, fn ->
        Repo.insert_all(Tenant, [
          %{
            id: Ankole.Ecto.UUIDv7.autogenerate(),
            slug: "nested",
            display_name: value_query,
            inserted_at: now,
            updated_at: now
          }
        ])
      end
    end)
  end

  test "a CTE join selects only its declared columns and retains scoped inner rows" do
    own = group("cte-limited")
    other = new_tenant()
    Repo.with_tenant(other.id, fn -> group("cte-limited") end)
    limited = from g in Group, where: g.name == "cte-limited", select: %{id: g.id}
    query = Group |> with_cte("ash_limited_rows", as: ^limited)
    query = from g in query, join: limited in "ash_limited_rows", on: limited.id == g.id
    Ankole.DataCase.assert_persisted_equal(Repo.all(query), [own])
  end

  defp tenant_schemas do
    for schema <- Ankole.TestModules.all(),
        Code.ensure_loaded?(schema),
        function_exported?(schema, :__tenancy__, 0),
        schema.__tenancy__() == :tenant,
        function_exported?(schema, :__schema__, 1),
        schema.__schema__(:source) != nil,
        do: schema
  end

  test "actor references preserve an existing uid and reject malformed attribution", %{
    tenant: tenant
  } do
    reference = ActorRef.from_principal(%{tenant_id: tenant.id, uid: "legacy@example.com"})
    assert {:ok, ^reference} = ActorRef.cast(to_string(reference))
    assert {:ok, ^reference} = Ankole.Ecto.ActorRef.load(to_string(reference))
    assert {:ok, text} = Ankole.Ecto.ActorRef.dump(reference)
    assert text == "ankole:#{tenant.id}:principal/legacy@example.com"
    assert :error = ActorRef.cast("legacy@example.com")
    assert :error = ActorRef.cast("ankole:invalid:principal/legacy")
    assert :error = ActorRef.cast("ankole:#{tenant.id}:principal/")
  end

  defp new_tenant do
    create_tenant(%{
      slug: "other-" <> Ankole.Ecto.UUIDv7.autogenerate(),
      display_name: "Other"
    })
  end

  defp group(name) do
    {:ok, group} = Ankole.AuthZ.create_principal_group(%{name: name, display_name: name})
    group
  end

  defp conversation(id, title) do
    now = DateTime.utc_now(:microsecond)

    Ankole.ExternalConversationsFixtures.create_external_conversation!(%{
      id: id,
      title: title,
      external_kind: :im_group,
      reply_mode: :entry,
      provider_conversation_id: "lark:same",
      last_activity_at: now,
      first_seen_at: now,
      last_seen_at: now
    })
  end

  defp message(conversation_id, id, text) do
    now = DateTime.utc_now(:microsecond)

    assert {:ok, _} =
             Repo.transact(fn _repo ->
               Ankole.Ash.create(Message, :record, %{
                 id: id,
                 conversation_id: conversation_id,
                 seq: 1,
                 origin: :external,
                 author_type: :unknown,
                 text: text,
                 created_at: now
               })
             end)

    assert {:ok, _} =
             Repo.transact(fn _repo ->
               Ankole.Ash.create(ExternalMessageRef, :record, %{
                 message_id: id,
                 conversation_id: conversation_id,
                 provider_message_id: "same-message",
                 first_seen_at: now,
                 last_seen_at: now
               })
             end)
  end

  defp create_principal(attrs) do
    Repo.transact(fn _repo -> Ankole.Ash.create(Principal, :create_in_tx, attrs) end)
  end
end
