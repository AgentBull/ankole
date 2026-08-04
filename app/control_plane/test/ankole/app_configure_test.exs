defmodule Ankole.AppConfigureTest do
  use Ankole.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.GeneratedSecret
  alias Ankole.AppConfigure.Registry
  alias Ankole.AppConfigure.Schema

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, prefix: "__test.app_configure.#{System.unique_integer([:positive])}"}
  end

  test "rejects duplicate exact keys and duplicate pattern ids", %{prefix: prefix} do
    definition =
      AppConfigure.define(
        key: key(prefix, "duplicate"),
        encrypted: false,
        schema: Schema.string()
      )

    assert :ok = AppConfigure.register_definitions([definition])

    definition_key = definition.key

    assert {:error, {:duplicate_key, ^definition_key}} =
             AppConfigure.register_definitions([definition])

    pattern =
      AppConfigure.define_pattern(
        id: key(prefix, "pattern"),
        key_pattern: ~r/\Aduplicate-pattern\.[a-z]+\z/,
        encrypted: false,
        schema: Schema.string()
      )

    assert :ok = AppConfigure.register_patterns([pattern])
    pattern_id = pattern.id
    assert {:error, {:duplicate_pattern, ^pattern_id}} = AppConfigure.register_patterns([pattern])
  end

  test "validates defaults and rejects unknown keys before persistence" do
    assert_raise ArgumentError, fn ->
      AppConfigure.define(
        key: "invalid.default",
        encrypted: false,
        schema: Schema.integer(),
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

    assert :ok = AppConfigure.register_definitions([definition])

    assert {:ok, %{value: %{"enabled" => false, "limit" => 0}, source: :default}} =
             AppConfigure.resolve(definition)

    assert {:ok, %{"enabled" => true, "limit" => 3}} =
             AppConfigure.put_global(definition, %{"enabled" => true, "limit" => 3})

    assert %AppConfig{value: %{"type" => "plaintext", "value" => %{"limit" => 3}}} =
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

    assert :ok = AppConfigure.register_definitions([definition])
    assert {:ok, :absent} = Cache.load("global", definition.key)

    assert :ok = Cache.fail_next_load_for_test(:injected_put_refresh_failure)
    assert {:ok, %{"put" => true}} = AppConfigure.put_global(definition, %{"put" => true})
    assert :miss = Cache.lookup("global", definition.key)
    assert {:ok, %{"put" => true}} = AppConfigure.get(definition)

    assert :ok = Cache.fail_next_load_for_test(:injected_update_refresh_failure)

    assert {:ok, %{"put" => true, "update" => true}} =
             AppConfigure.update_global(definition, fn current ->
               {:ok, Map.put(current, "update", true)}
             end)

    assert :miss = Cache.lookup("global", definition.key)
    assert {:ok, %{"put" => true, "update" => true}} = AppConfigure.get(definition)

    assert :ok = Cache.fail_next_load_for_test(:injected_delete_refresh_failure)
    assert :ok = AppConfigure.delete_global(definition)
    assert :miss = Cache.lookup("global", definition.key)
    assert {:ok, %{}} = AppConfigure.get(definition)
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

    assert :ok = AppConfigure.register_definitions([definition])
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

    assert :ok = AppConfigure.register_definitions([definition])

    assert {:ok, first_write} =
             Repo.transact(fn repo ->
               AppConfigure.put_global_by_key_in_tx(repo, definition.key, %{"alpha" => false})
             end)

    assert {:ok, second_write} =
             Repo.transact(fn repo ->
               AppConfigure.put_global_by_key_in_tx(repo, definition.key, %{
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

    assert :ok = AppConfigure.register_definitions([definition])

    assert {:ok, committed_write} =
             Repo.transact(fn repo ->
               AppConfigure.put_global_by_key_in_tx(repo, definition.key, %{"stored" => true})
             end)

    Repo.delete_all(
      from(row in AppConfig,
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

  test "resolves current agent, global, then code default", %{prefix: prefix} do
    definition =
      AppConfigure.define(
        key: key(prefix, "scoped"),
        encrypted: false,
        schema: Schema.string(),
        default_value: "default"
      )

    assert :ok = AppConfigure.register_definitions([definition])

    assert {:ok, %{value: "default", source: :default, scope: nil}} =
             AppConfigure.resolve(definition, agent_id: "agent-a")

    assert {:ok, "global"} = AppConfigure.put_global(definition, "global")

    assert {:ok, %{value: "global", source: :global, scope: "global"}} =
             AppConfigure.resolve(definition, agent_id: "agent-a")

    assert {:ok, "agent"} = AppConfigure.put_for_agent("agent-a", definition, "agent")

    assert {:ok, %{value: "agent", source: :agent, scope: "agent:agent-a"}} =
             AppConfigure.resolve(definition, agent_id: "agent-a")

    assert :ok = AppConfigure.delete_for_agent("agent-a", definition)

    assert {:ok, %{value: "global", source: :global}} =
             AppConfigure.resolve(definition, agent_id: "agent-a")

    assert :ok = AppConfigure.delete_global(definition)

    assert {:ok, %{value: "default", source: :default}} =
             AppConfigure.resolve(definition, agent_id: "agent-a")
  end

  test "global scope definitions reject agent overrides", %{prefix: prefix} do
    definition =
      AppConfigure.define(
        key: key(prefix, "global-only"),
        encrypted: false,
        scope: :global,
        schema: Schema.string(),
        default_value: "default"
      )

    assert :ok = AppConfigure.register_definitions([definition])

    assert {:error, {:global_scope_only, _key}} =
             AppConfigure.put_for_agent("agent-a", definition, "agent")

    assert {:ok, "global"} = AppConfigure.put_global(definition, "global")

    insert_row!("agent:agent-a", definition.key, %{"type" => "plaintext", "value" => "agent"})

    assert {:ok, %{value: "global", source: :global, scope: "global"}} =
             AppConfigure.resolve(definition, agent_id: "agent-a")
  end

  test "invalid scoped rows stop fallback instead of inheriting global", %{prefix: prefix} do
    definition =
      AppConfigure.define(
        key: key(prefix, "invalid-agent-row"),
        encrypted: false,
        schema: Schema.integer(),
        default_value: 1
      )

    assert :ok = AppConfigure.register_definitions([definition])
    assert {:ok, 2} = AppConfigure.put_global(definition, 2)

    insert_row!("agent:agent-a", definition.key, %{"type" => "plaintext", "value" => "bad"})

    assert {:error, {:storage_error, "agent:agent-a", _, :not_integer}} =
             AppConfigure.resolve(definition, agent_id: "agent-a")
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

    assert :ok = AppConfigure.register_definitions([definition])

    assert {:ok, %{"apiKey" => "secret-api-key"}} =
             AppConfigure.put_global(definition, %{"apiKey" => "secret-api-key"})

    assert %AppConfig{value: %{"type" => "cipher", "value" => ciphertext}} =
             get_row!("global", definition.key)

    assert is_binary(ciphertext)
    refute String.contains?(ciphertext, "secret-api-key")

    Cache.clear_for_test()
    assert {:ok, %{"apiKey" => "secret-api-key"}} = AppConfigure.get(definition)
  end

  test "binds encrypted values to an unambiguous scope and key context", %{prefix: prefix} do
    source_definition =
      AppConfigure.define(
        key: key(prefix, "cipher"),
        encrypted: true,
        schema: Schema.object()
      )

    target_key = "b/" <> source_definition.key

    target_definition =
      AppConfigure.define(
        key: target_key,
        encrypted: true,
        schema: Schema.object()
      )

    assert :ok = AppConfigure.register_definitions([source_definition, target_definition])

    assert {:ok, %{"token" => "source-token"}} =
             AppConfigure.put_for_agent("a/b", source_definition, %{"token" => "source-token"})

    %AppConfig{value: copied_envelope} = get_row!("agent:a/b", source_definition.key)
    insert_row!("agent:a", target_key, copied_envelope)

    assert {:error, {:storage_error, "agent:a", ^target_key, _reason}} =
             AppConfigure.resolve(target_definition, agent_id: "a")
  end

  test "supports encrypted pattern-backed runtime keys", %{prefix: prefix} do
    pattern_prefix = key(prefix, "pattern")

    pattern =
      AppConfigure.define_pattern(
        id: pattern_prefix,
        key_pattern: Regex.compile!("\\A#{Regex.escape(pattern_prefix)}\\.[a-z]+\\z"),
        encrypted: true,
        schema: Schema.object(),
        default_value: %{}
      )

    runtime_key = pattern_prefix <> ".dynamic"

    assert :ok = AppConfigure.register_patterns([pattern])
    assert {:ok, %{value: %{}, source: :default}} = AppConfigure.resolve_by_key(runtime_key)

    assert {:ok, %{"token" => "runtime-token"}} =
             AppConfigure.put_for_agent_by_key("agent-a", runtime_key, %{
               "token" => "runtime-token"
             })

    assert {:ok, %{value: %{"token" => "runtime-token"}, source: :agent}} =
             AppConfigure.resolve_by_key(runtime_key, agent_id: "agent-a")

    assert {:error, {:unknown_key, _key}} =
             AppConfigure.put_global_by_key(pattern_prefix <> ".BAD", %{})
  end

  test "rejects non-JSON Elixir values at the schema boundary", %{prefix: prefix} do
    definition =
      AppConfigure.define(
        key: key(prefix, "json"),
        encrypted: false,
        schema: Schema.json_value()
      )

    assert :ok = AppConfigure.register_definitions([definition])
    assert {:error, :not_json_value} = AppConfigure.put_global(definition, %{atom_key: "value"})
  end

  test "rejects empty agent scope at the database boundary", %{prefix: prefix} do
    assert {:error, %Postgrex.Error{postgres: %{constraint: "app_configurations_scope_check"}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO app_configurations (scope, key, value, inserted_at, updated_at)
               VALUES ($1, $2, jsonb_build_object('type', 'plaintext', 'value', 'bad'), now(), now())
               """,
               [
                 "agent:",
                 key(prefix, "empty-agent-scope")
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

    assert :ok = AppConfigure.register_definitions([definition])
    assert {:ok, secret} = AppConfigure.generate(definition)
    assert secret =~ ~r/\A[0-9a-f]{64}\z/
    assert :error = AppConfigure.get(definition)

    refute Repo.exists?(
             from(row in AppConfig, where: row.scope == "global" and row.key == ^definition.key)
           )
  end

  defp key(prefix, name), do: prefix <> "." <> name

  defp get_row!(scope, key) do
    Repo.one!(from(row in AppConfig, where: row.scope == ^scope and row.key == ^key))
  end

  defp insert_row!(scope, key, value) do
    %AppConfig{}
    |> AppConfig.changeset(%{scope: scope, key: key, value: value})
    |> Repo.insert!()
  end

  defp delete_unboxed_global_row(key) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.delete_all(from(row in AppConfig, where: row.scope == "global" and row.key == ^key))
    end)
  end
end
