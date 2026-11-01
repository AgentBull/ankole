defmodule Ankole.AppConfigureTest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.GeneratedSecret
  alias Ankole.AppConfigure.Registry
  alias Ankole.AppConfigure.Schema

  setup do
    Registry.clear_for_test()

    {:ok, prefix: "__test.app_configure.#{System.unique_integer([:positive])}"}
  end

  test "an Agent rename re-encrypts settings and invalidates both cached scopes", %{
    prefix: prefix
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "renamed-secret"),
        encrypted: true,
        scope: :tenant,
        schema: Schema.non_empty_string()
      )

    assert :ok = Registry.register_definitions([definition])

    assert {:ok, old} =
             Ankole.Ash.create(AppConfig, :put, %{
               scope: "agent:before",
               key: definition.key,
               input: "secret-to-preserve"
             })

    Cache.refresh("agent:before", definition.key)
    Cache.refresh("agent:after", definition.key)

    assert {:ok, _keys} =
             Repo.transact_top_level(
               fn -> AppConfigure.rename_agent_in_tx("before", "after") end,
               after_commit: &AppConfigure.publish_agent_rename/1
             )

    assert nil == AppConfigure.get_app_config!("agent:before", definition.key)
    moved = AppConfigure.get_app_config!("agent:after", definition.key)
    refute moved.value == old.value

    assert {:ok, "secret-to-preserve"} =
             Ankole.AppConfigure.Codec.load(
               definition,
               "agent:after",
               definition.key,
               moved.value
             )

    assert {:ok, :absent} = Cache.lookup("agent:before", definition.key)
    assert {:ok, {:row, _}} = Cache.lookup("agent:after", definition.key)
  end

  test "resource writes own declaration validation, scope, and encryption", %{prefix: prefix} do
    secret =
      AppConfigure.define(
        key: key(prefix, "action-secret"),
        encrypted: true,
        scope: :global,
        schema: Schema.non_empty_string()
      )

    assert :ok = Registry.register_definitions([secret])

    assert {:ok, row} =
             Ankole.Ash.create(Ankole.AppConfigure.SiteConfig, :put, %{
               scope: "global",
               key: secret.key,
               input: "private-value"
             })

    assert %{"type" => "cipher", "value" => ciphertext} = row.value
    refute ciphertext == "private-value"

    assert {:ok, "private-value"} =
             Ankole.AppConfigure.Codec.load(secret, "global", secret.key, row.value)

    Ankole.DataCase.assert_persisted_equal(
      Repo.get_by!(Ankole.AppConfigure.SiteConfig, scope: "global", key: secret.key),
      row
    )

    assert {:error, {:global_scope_only, rejected_key}} =
             Ankole.Ash.create(AppConfig, :put, %{
               scope: "tenant:" <> Repo.tenant_id!(),
               key: secret.key,
               input: "rejected"
             })

    assert rejected_key == secret.key

    unknown_key = key(prefix, "undeclared")

    assert {:error, {:unknown_key, ^unknown_key}} =
             Ankole.Ash.create(Ankole.AppConfigure.SiteConfig, :put, %{
               scope: "global",
               key: unknown_key,
               input: "rejected"
             })

    refute Repo.get_by(Ankole.AppConfigure.SiteConfig, scope: "global", key: unknown_key)

    assert MapSet.new(AppConfig.__schema__(:primary_key)) ==
             MapSet.new([:tenant_id, :scope, :key])

    assert MapSet.new(Ankole.AppConfigure.SiteConfig.__schema__(:primary_key)) ==
             MapSet.new([:scope, :key])
  end

  test "atomic platform identity metadata preserves encrypted envelopes in both scopes", %{
    prefix: prefix
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "platform-metadata"),
        encrypted: true,
        scope: :tenant,
        schema: Schema.non_empty_string()
      )

    assert :ok = Registry.register_definitions([definition])

    for scope <- ["global", "tenant:" <> Repo.tenant_id!()] do
      resource = AppConfig.for_scope(scope)

      assert {:ok, row} =
               Ankole.Ash.create(resource, :put, %{
                 scope: scope,
                 key: definition.key,
                 input: "secret"
               })

      envelope = row.value
      query = Ash.Query.filter(resource, scope == ^scope and key == ^definition.key)

      assert {:ok, :recorded} =
               Repo.transact(fn _repo ->
                 result =
                   Ankole.Ash.bulk_update(
                     query,
                     :record_platform_application,
                     %{application: "provider:application"},
                     strategy: [:atomic],
                     return_errors?: true,
                     return_records?: true
                   )

                 assert %{status: :success, records: [updated]} = result

                 assert updated.value ==
                          Map.put(envelope, "platform_application", "provider:application")

                 assert {:ok, "secret"} =
                          Ankole.AppConfigure.Codec.load(
                            definition,
                            scope,
                            definition.key,
                            updated.value
                          )

                 {:ok, :recorded}
               end)

      assert {:ok, :removed} =
               Repo.transact(fn _repo ->
                 assert %{status: :success} =
                          Ankole.Ash.bulk_destroy(query, :remove, %{},
                            strategy: [:atomic],
                            return_errors?: true
                          )

                 {:ok, :removed}
               end)

      assert [] = Ankole.Ash.read!(query)
    end
  end

  test "tenant platform identity writes preserve envelopes across production calls", %{
    prefix: prefix,
    tenant: tenant
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "platform-production-metadata"),
        encrypted: true,
        scope: :tenant,
        schema: Schema.non_empty_string()
      )

    assert :ok = Registry.register_definitions([definition])
    scope = "tenant:" <> tenant.id

    assert {:ok, envelope} =
             Repo.transact(fn _repo ->
               with {:ok, write} <-
                      AppConfigure.put_tenant_by_key_in_tx(definition.key, "secret"),
                    {:ok, row} <- AppConfigure.get_app_config(scope, definition.key),
                    :ok <-
                      Ankole.Signals.Bindings.record_platform_application_in_tx(
                        write,
                        "provider:first"
                      ),
                    :ok <-
                      Ankole.Signals.Bindings.record_platform_application_in_tx(
                        write,
                        "provider:second"
                      ) do
                 {:ok, row.value}
               end
             end)

    updated = Repo.get_by!(AppConfig, scope: scope, key: definition.key)

    assert updated.value ==
             Map.put(envelope, "platform_application", "provider:second")

    assert {:ok, "secret"} =
             Ankole.AppConfigure.Codec.load(definition, scope, definition.key, updated.value)
  end

  @tag sandbox: false
  test "committed E2E cleanup restores changed and deleted global values and removes new keys", %{
    prefix: prefix
  } do
    definitions =
      for suffix <- ["changed", "deleted", "created"] do
        AppConfigure.define(
          key: key(prefix, suffix),
          encrypted: false,
          scope: :global,
          schema: Schema.object()
        )
      end

    [changed, deleted, created] = definitions
    assert :ok = Registry.register_definitions(definitions)
    assert {:ok, _} = AppConfigure.put_global(changed, %{"value" => "before"})
    assert {:ok, _} = AppConfigure.put_global(deleted, %{"value" => "before"})

    # Register verification first: ExUnit runs the real Harness cleanup before it.
    on_exit(fn ->
      try do
        assert {:ok, %{"value" => "before"}} =
                 AppConfigure.get_global_by_key_in_tx(changed.key)

        assert {:ok, %{"value" => "before"}} =
                 AppConfigure.get_global_by_key_in_tx(deleted.key)

        assert :error = AppConfigure.get_global_by_key_in_tx(created.key)
      after
        Enum.each(definitions, &delete_unboxed_global_row(&1.key))
        Cache.clear_for_test()
      end
    end)

    Ankole.E2E.Harness.cleanup_committed_fixtures_on_exit!()

    assert {:ok, _} = AppConfigure.put_global(changed, %{"value" => "after"})
    assert :ok = AppConfigure.delete_global(deleted)
    assert {:ok, _} = AppConfigure.put_global(created, %{"value" => "new"})

    assert {:ok, %{"value" => "after"}} =
             AppConfigure.get_global_by_key_in_tx(changed.key)

    assert :error = AppConfigure.get_global_by_key_in_tx(deleted.key)

    assert {:ok, %{"value" => "new"}} =
             AppConfigure.get_global_by_key_in_tx(created.key)
  end

  @tag timeout: 15_000
  test "committed writes without invalidation converge within the cache age bound", %{
    prefix: prefix
  } do
    definitions =
      for suffix <- ["changed", "deleted", "created"] do
        AppConfigure.define(
          key: key(prefix, suffix),
          encrypted: false,
          scope: :global,
          schema: Schema.object()
        )
      end

    [changed, deleted, created] = definitions
    :ok = Ankole.AppConfigure.Registry.register_definitions(definitions)
    on_exit(fn -> Enum.each(definitions, &delete_unboxed_global_row(&1.key)) end)

    Sandbox.unboxed_run(Repo, fn ->
      {:ok, _} = AppConfigure.put_global(changed, %{"value" => "before"})
      {:ok, _} = AppConfigure.put_global(deleted, %{"value" => "before"})
    end)

    assert {:ok, %{"value" => "before"}} = AppConfigure.get(changed)
    assert {:ok, %{"value" => "before"}} = AppConfigure.get(deleted)
    assert :error = AppConfigure.get(created)
    # Commit at PostgreSQL without running the caller's after-commit refresh.
    Sandbox.unboxed_run(Repo, fn ->
      Repo.update_all(from(c in Ankole.AppConfigure.SiteConfig, where: c.key == ^changed.key),
        set: [value: %{"type" => "plaintext", "value" => %{"value" => "after"}}]
      )

      Repo.delete_all(from(c in Ankole.AppConfigure.SiteConfig, where: c.key == ^deleted.key))

      {:ok, _row} =
        Ankole.Ash.create(Ankole.AppConfigure.SiteConfig, :put, %{
          scope: "global",
          key: created.key,
          input: %{"value" => "created"}
        })
    end)

    assert {:ok, %{"value" => "before"}} = AppConfigure.get(changed)
    assert :error = AppConfigure.get(created)
    Process.sleep(5_050)
    assert {:ok, %{"value" => "after"}} = AppConfigure.get(changed)
    assert :error = AppConfigure.get(deleted)
    assert {:ok, %{"value" => "created"}} = AppConfigure.get(created)
  end

  test "concurrent generated global initialization returns one persisted winner", %{
    prefix: prefix
  } do
    counter = :atomics.new(1, [])

    definition =
      AppConfigure.define(
        key: key(prefix, "generated-once"),
        encrypted: false,
        scope: :global,
        schema: Schema.non_empty_string(),
        generator: fn ->
          :atomics.add_get(counter, 1, 1)
          Ankole.Ecto.UUIDv7.autogenerate()
        end
      )

    :ok = Ankole.AppConfigure.Registry.register_definitions([definition])
    on_exit(fn -> delete_unboxed_global_row(definition.key) end)

    results =
      1..8
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn -> AppConfigure.ensure_generated_global(definition) end)
        end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert [{:ok, winner}] = Enum.uniq(results)
    assert :atomics.get(counter, 1) == 1
    assert {:ok, ^winner} = AppConfigure.get(definition)
  end

  test "rejects duplicate exact keys and duplicate pattern ids", %{prefix: prefix} do
    definition =
      AppConfigure.define(
        key: key(prefix, "duplicate"),
        encrypted: false,
        schema: Ankole.AppConfigure.Schema.non_empty_string()
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])

    definition_key = definition.key

    assert {:error, {:duplicate_key, ^definition_key}} =
             Ankole.AppConfigure.Registry.register_definitions([definition])

    pattern =
      AppConfigure.define_pattern(
        id: key(prefix, "pattern"),
        key_pattern: ~r/\Aduplicate-pattern\.[a-z]+\z/,
        encrypted: false,
        schema: Ankole.AppConfigure.Schema.non_empty_string()
      )

    assert :ok = Ankole.AppConfigure.Registry.register_patterns([pattern])
    pattern_id = pattern.id

    assert {:error, {:duplicate_pattern, ^pattern_id}} =
             Ankole.AppConfigure.Registry.register_patterns([pattern])
  end

  test "validates defaults and rejects unknown keys before persistence" do
    assert_raise ArgumentError, fn ->
      AppConfigure.define(
        key: "invalid.default",
        encrypted: false,
        schema:
          Ankole.AppConfigure.Schema.new(fn
            value when is_integer(value) -> {:ok, value}
            _value -> {:error, :not_integer}
          end),
        default_value: "not-an-integer"
      )
    end

    assert {:error, {:unknown_key, "unknown.runtime.key"}} =
             AppConfigure.put_global_by_key("unknown.runtime.key", "value")
  end

  test "roundtrips plaintext global values through the write-through cache", %{prefix: prefix} do
    definition =
      AppConfigure.define(
        key: key(prefix, "plaintext"),
        encrypted: false,
        schema: Schema.object(),
        default_value: %{"enabled" => false, "limit" => 0}
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])

    assert {:ok, %{value: %{"enabled" => false, "limit" => 0}, source: :default}} =
             AppConfigure.resolve(definition)

    assert {:ok, %{"enabled" => true, "limit" => 3}} =
             AppConfigure.put_global(definition, %{"enabled" => true, "limit" => 3})

    assert %{value: %{"type" => "plaintext", "value" => %{"limit" => 3}}} =
             get_row!("global", definition.key)

    assert {:ok, %{"enabled" => true, "limit" => 3}} = AppConfigure.get(definition)

    assert :ok = AppConfigure.delete_global(definition)
    assert {:ok, %{"enabled" => false, "limit" => 0}} = AppConfigure.get(definition)
  end

  test "committed put, update, and delete stay successful across cache refresh faults", %{
    prefix: prefix
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "after-commit-cache-fault"),
        encrypted: false,
        scope: :global,
        schema: Schema.object(),
        default_value: %{}
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])
    assert {:ok, :absent} = Cache.load("global", definition.key)

    assert :ok =
             Cache.fail_next_refresh_for_test(
               "global",
               definition.key,
               :injected_put_refresh_failure
             )

    assert {:ok, %{"put" => true}} = AppConfigure.put_global(definition, %{"put" => true})
    assert :miss = Cache.lookup("global", definition.key)
    assert {:ok, %{"put" => true}} = AppConfigure.get(definition)

    assert :ok =
             Cache.fail_next_refresh_for_test(
               "global",
               definition.key,
               :injected_update_refresh_failure
             )

    assert {:ok, %{"put" => true, "update" => true}} =
             AppConfigure.update_global(definition, fn current ->
               {:ok, Map.put(current, "update", true)}
             end)

    assert :miss = Cache.lookup("global", definition.key)
    assert {:ok, %{"put" => true, "update" => true}} = AppConfigure.get(definition)

    assert :ok =
             Cache.fail_next_refresh_for_test(
               "global",
               definition.key,
               :injected_delete_refresh_failure
             )

    assert :ok = AppConfigure.delete_global(definition)
    assert :miss = Cache.lookup("global", definition.key)
    assert {:ok, %{}} = AppConfigure.get(definition)
  end

  test "a cache miss that read before a failed refresh does not cache the pre-commit state", %{
    prefix: prefix
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "load-refresh-race"),
        encrypted: false,
        scope: :global,
        schema: Schema.object(),
        default_value: %{}
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])

    reader =
      Task.async(fn ->
        receive do
          :load -> Cache.load("global", definition.key)
        end
      end)

    pause_after_app_configure_read(reader.pid)
    send(reader.pid, :load)
    assert_receive {:app_configure_row_read, reader_pid}, 5_000

    assert :ok =
             Cache.fail_next_refresh_for_test(
               "global",
               definition.key,
               :injected_refresh_failure
             )

    assert {:ok, %{"committed" => true}} =
             AppConfigure.put_global(definition, %{"committed" => true})

    send(reader_pid, :publish)
    assert {:ok, :absent} = Task.await(reader)

    assert :miss = Cache.lookup("global", definition.key)
    assert {:ok, %{"committed" => true}} = AppConfigure.get(definition)

    %{value: committed_envelope} = get_row!("global", definition.key)
    assert {:ok, {:row, ^committed_envelope}} = Cache.lookup("global", definition.key)
  end

  @tag ownership_timeout: 10_000
  test "serializes concurrent global updates against the current database value", %{
    prefix: prefix
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "atomic-update"),
        encrypted: false,
        scope: :global,
        schema: Schema.object(),
        default_value: %{}
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])
    test_pid = self()

    on_exit(fn -> delete_unboxed_global_row(definition.key) end)

    first =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          AppConfigure.update_global(definition, fn current ->
            send(test_pid, {:global_update_entered, :first, current, self()})

            receive do
              :finish_first_global_update ->
                {:ok, Map.put(current, "alpha", false)}
            end
          end)
        end)
      end)

    assert_receive {:global_update_entered, :first, %{}, first_pid}, 5_000

    second =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          AppConfigure.update_global(definition, fn current ->
            send(test_pid, {:global_update_entered, :second, current})
            {:ok, Map.put(current, "beta", false)}
          end)
        end)
      end)

    refute_receive {:global_update_entered, :second, _current}, 200
    send(first_pid, :finish_first_global_update)

    assert {:ok, %{"alpha" => false}} = Task.await(first, 5_000)

    assert_receive {:global_update_entered, :second, %{"alpha" => false}}, 5_000

    assert {:ok, %{"alpha" => false, "beta" => false}} = Task.await(second, 5_000)
    assert {:ok, %{"alpha" => false, "beta" => false}} = AppConfigure.get(definition)
  end

  test "publishing committed writes out of order refreshes the current database row", %{
    prefix: prefix
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "cache-publish-order"),
        encrypted: false,
        scope: :global,
        schema: Schema.object(),
        default_value: %{}
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])

    assert {:ok, first_write} =
             Repo.transact(fn ->
               AppConfigure.put_global_by_key_in_tx(definition.key, %{"alpha" => false})
             end)

    assert {:ok, second_write} =
             Repo.transact(fn ->
               AppConfigure.put_global_by_key_in_tx(definition.key, %{
                 "alpha" => false,
                 "beta" => false
               })
             end)

    Cache.clear_for_test()

    assert {:ok, %{"alpha" => false, "beta" => false}} =
             AppConfigure.cache_committed_write(second_write)

    assert {:ok, %{"alpha" => false}} = AppConfigure.cache_committed_write(first_write)

    assert {:ok, %{"alpha" => false, "beta" => false}} = AppConfigure.get(definition)
  end

  test "committed write publication respects later database truth without changing commit result",
       %{
         prefix: prefix
       } do
    definition =
      AppConfigure.define(
        key: key(prefix, "cache-publish-db-truth"),
        encrypted: false,
        scope: :global,
        schema: Schema.object(),
        default_value: %{"default" => true}
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])

    assert {:ok, committed_write} =
             Repo.transact(fn ->
               AppConfigure.put_global_by_key_in_tx(definition.key, %{"stored" => true})
             end)

    Repo.delete_all(
      from(row in Ankole.AppConfigure.SiteConfig,
        where: row.scope == "global" and row.key == ^definition.key
      )
    )

    assert {:ok, %{"stored" => true}} = AppConfigure.cache_committed_write(committed_write)
    assert {:ok, %{"default" => true}} = AppConfigure.get(definition)

    insert_row!("global", definition.key, %{"type" => "plaintext", "value" => "bad"})

    assert {:ok, %{"stored" => true}} = AppConfigure.cache_committed_write(committed_write)

    assert {:error, {:storage_error, "global", _, :not_json_object}} =
             AppConfigure.get(definition)
  end

  test "resolves current tenant, global, then code default", %{prefix: prefix} do
    tenant_scope = "tenant:" <> Repo.tenant_id!()

    definition =
      AppConfigure.define(
        key: key(prefix, "scoped"),
        encrypted: false,
        scope: :tenant,
        schema: Ankole.AppConfigure.Schema.non_empty_string(),
        default_value: "default"
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])

    assert {:ok, %{value: "default", source: :default, scope: nil}} =
             AppConfigure.resolve(definition)

    assert {:ok, "global"} = AppConfigure.put_global(definition, "global")

    assert {:ok, %{value: "global", source: :global, scope: "global"}} =
             AppConfigure.resolve(definition)

    assert {:ok, "tenant"} = AppConfigure.put_tenant_by_key(definition.key, "tenant")

    assert {:ok, %{value: "tenant", source: :tenant, scope: ^tenant_scope}} =
             AppConfigure.resolve(definition)

    assert :ok = AppConfigure.delete_tenant_by_key(definition.key)

    assert {:ok, %{value: "global", source: :global}} =
             AppConfigure.resolve(definition)

    assert :ok = AppConfigure.delete_global(definition)

    assert {:ok, %{value: "default", source: :default}} =
             AppConfigure.resolve(definition)
  end

  test "global scope definitions reject tenant overrides", %{prefix: prefix} do
    tenant_scope = "tenant:" <> Repo.tenant_id!()

    definition =
      AppConfigure.define(
        key: key(prefix, "global-only"),
        encrypted: false,
        scope: :global,
        schema: Ankole.AppConfigure.Schema.non_empty_string(),
        default_value: "default"
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])

    assert {:error, {:global_scope_only, _key}} =
             AppConfigure.put_tenant_by_key(definition.key, "tenant")

    assert {:ok, "global"} = AppConfigure.put_global(definition, "global")

    insert_row!(tenant_scope, definition.key, %{"type" => "plaintext", "value" => "agent"})

    assert {:ok, %{value: "global", source: :global, scope: "global"}} =
             AppConfigure.resolve(definition)
  end

  test "pod scope definitions resolve only tenant rows and reject global or agent scope", %{
    prefix: prefix
  } do
    tenant_scope = "tenant:" <> Repo.tenant_id!()
    key_name = key(prefix, "pod-only")

    definition =
      AppConfigure.define(
        key: key_name,
        encrypted: false,
        scope: :pod,
        schema: Ankole.AppConfigure.Schema.non_empty_string(),
        default_value: "default"
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])

    assert {:error, {:pod_scope_only, ^key_name}} =
             AppConfigure.put_global(definition, "global")

    assert {:error, {:pod_scope_only, ^key_name}} =
             AppConfigure.resolve(definition, scope: :global)

    assert {:error, {:pod_scope_only, ^key_name}} =
             Ankole.Ash.create(AppConfig, :put, %{
               scope: "agent:some-agent",
               key: key_name,
               input: "agent"
             })

    insert_row!("global", key_name, %{"type" => "plaintext", "value" => "stale-global"})

    assert {:ok, %{value: "default", source: :default, scope: nil}} =
             AppConfigure.resolve(definition)

    assert {:ok, "pod-value"} = AppConfigure.put_tenant_by_key(key_name, "pod-value")

    assert {:ok, %{value: "pod-value", source: :tenant, scope: ^tenant_scope}} =
             AppConfigure.resolve(definition)
  end

  test "invalid scoped rows stop fallback instead of inheriting global", %{prefix: prefix} do
    tenant_scope = "tenant:" <> Repo.tenant_id!()

    definition =
      AppConfigure.define(
        key: key(prefix, "invalid-tenant-row"),
        encrypted: false,
        scope: :tenant,
        schema:
          Ankole.AppConfigure.Schema.new(fn
            value when is_integer(value) -> {:ok, value}
            _value -> {:error, :not_integer}
          end),
        default_value: 1
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])
    assert {:ok, 2} = AppConfigure.put_global(definition, 2)

    insert_row!(tenant_scope, definition.key, %{"type" => "plaintext", "value" => "bad"})

    assert {:error, {:storage_error, ^tenant_scope, _, :not_integer}} =
             AppConfigure.resolve(definition)
  end

  test "roundtrips encrypted values through the kernel without storing plaintext", %{
    prefix: prefix
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "encrypted"),
        encrypted: true,
        schema: Schema.object()
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])

    assert {:ok, %{"apiKey" => "secret-api-key"}} =
             AppConfigure.put_global(definition, %{"apiKey" => "secret-api-key"})

    assert %{value: %{"type" => "cipher", "value" => ciphertext}} =
             get_row!("global", definition.key)

    assert is_binary(ciphertext)
    refute String.contains?(ciphertext, "secret-api-key")

    Cache.clear_for_test()
    assert {:ok, %{"apiKey" => "secret-api-key"}} = AppConfigure.get(definition)
  end

  test "binds encrypted values to an unambiguous scope and key context", %{prefix: prefix} do
    key = key(prefix, "cipher")
    value = %{"token" => "source-token"}
    assert {:ok, ciphertext} = Ankole.AppConfigure.Crypto.seal(value, "agent:a/b", key)
    assert {:ok, ^value} = Ankole.AppConfigure.Crypto.unseal(ciphertext, "agent:a/b", key)
    assert {:error, _} = Ankole.AppConfigure.Crypto.unseal(ciphertext, "agent:a", "b/" <> key)
  end

  test "supports encrypted pattern-backed runtime keys", %{prefix: prefix} do
    pattern_prefix = key(prefix, "pattern")

    pattern =
      AppConfigure.define_pattern(
        id: pattern_prefix,
        key_pattern: Regex.compile!("\\A#{Regex.escape(pattern_prefix)}\\.[a-z]+\\z"),
        encrypted: true,
        scope: :tenant,
        schema: Schema.object(),
        default_value: %{}
      )

    runtime_key = pattern_prefix <> ".dynamic"

    assert :ok = Ankole.AppConfigure.Registry.register_patterns([pattern])
    assert {:ok, %{value: %{}, source: :default}} = AppConfigure.resolve_by_key(runtime_key)

    assert {:ok, %{"token" => "runtime-token"}} =
             AppConfigure.put_tenant_by_key(runtime_key, %{
               "token" => "runtime-token"
             })

    assert {:ok, %{value: %{"token" => "runtime-token"}, source: :tenant}} =
             AppConfigure.resolve_by_key(runtime_key)

    assert {:error, {:unknown_key, _key}} =
             AppConfigure.put_global_by_key(pattern_prefix <> ".BAD", %{})
  end

  test "tenant console cannot enumerate or decrypt global binding configuration" do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    key = Ankole.Plugins.LarkAdapter.Config.binding_config_key(agent.uid, "main")
    value = %{"appID" => "binding-config-boundary", "appSecret" => "binding-secret"}
    assert {:ok, stored_value} = AppConfigure.put_global_by_key(key, value)

    other =
      create_tenant(%{
        slug: "binding-config-#{Ecto.UUID.generate()}",
        display_name: "Other"
      })

    for tenant_id <- [Repo.tenant_id!(), other.id] do
      Repo.with_tenant(tenant_id, fn ->
        assert {:ok, items} = AppConfigure.list_console_items(:tenant)
        refute Enum.any?(items, &(&1.key == key))

        assert {:error, {:key_managed_by_owner, ^key}} =
                 AppConfigure.console_detail(:tenant, key)

        assert {:error, {:key_managed_by_owner, ^key}} =
                 AppConfigure.console_decrypt(:tenant, key)
      end)
    end

    assert {:ok, ^stored_value} = AppConfigure.console_decrypt(:global, key)

    missing =
      Ankole.Plugins.LarkAdapter.Config.binding_config_key(Ecto.UUID.generate(), "missing")

    assert {:error, {:key_managed_by_owner, ^missing}} =
             AppConfigure.console_update(:tenant, missing, %{"value" => value})

    assert {:error, {:key_managed_by_owner, ^missing}} =
             AppConfigure.console_delete(:tenant, missing)
  end

  test "rejects empty agent scope at the database boundary", %{prefix: prefix} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: "app_configurations_scope_check"}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO app_configurations (scope, key, value, tenant_id, inserted_at, updated_at)
               VALUES ($1, $2, jsonb_build_object('type', 'plaintext', 'value', 'bad'), $3::uuid, now(), now())
               """,
               [
                 "agent:",
                 key(prefix, "empty-agent-scope"),
                 Ecto.UUID.dump!(Repo.tenant_id!())
               ]
             )
  end

  test "generates secrets without persisting them during reads", %{prefix: prefix} do
    definition =
      AppConfigure.define(
        key: key(prefix, "generated-secret"),
        encrypted: true,
        schema: Schema.non_empty_string(),
        generator: GeneratedSecret.generator()
      )

    assert :ok = Ankole.AppConfigure.Registry.register_definitions([definition])
    assert {:ok, secret} = AppConfigure.generate(definition)
    assert secret =~ ~r/\A[0-9a-f]{64}\z/
    assert :error = AppConfigure.get(definition)

    refute Repo.exists?(
             from(row in Ankole.AppConfigure.SiteConfig,
               where: row.scope == "global" and row.key == ^definition.key
             )
           )
  end

  defp key(prefix, name), do: prefix <> "." <> name

  defp get_row!(scope, key) do
    Repo.one!(
      from(row in AppConfig.for_scope(scope), where: row.scope == ^scope and row.key == ^key)
    )
  end

  defp insert_row!(scope, key, value) do
    schema = AppConfig.for_scope(scope)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{scope: scope, key: key, value: value, inserted_at: now, updated_at: now}

    attrs =
      if schema.__tenancy__() == :tenant,
        do: Map.put(attrs, :tenant_id, Repo.tenant_id!()),
        else: attrs

    {1, [row]} = Repo.insert_all(schema, [attrs], returning: true)

    row
  end

  defp delete_unboxed_global_row(key) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(
        from(row in Ankole.AppConfigure.SiteConfig,
          where: row.scope == "global" and row.key == ^key
        )
      )
    end)
  end

  # Stops `reader` after its AppConfigure row query returns and before
  # `Cache.load/2` publishes the result, until the test sends `:publish`. Repo
  # telemetry runs in the querying process after the connection is checked in,
  # so the test can write while the reader waits.
  defp pause_after_app_configure_read(reader) do
    handler_id = {__MODULE__, :pause_after_app_configure_read, make_ref()}
    event = Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, {reader, test_pid} ->
          if self() == reader and metadata.source == "site_app_configurations" do
            send(test_pid, {:app_configure_row_read, reader})

            receive do
              :publish -> :ok
            end
          end
        end,
        {reader, self()}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
