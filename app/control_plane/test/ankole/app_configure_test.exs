defmodule Ankole.AppConfigureTest do
  use Ankole.DataCase, async: false

  import Ecto.Query

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

  test "put_many_global_by_key/1 commits multiple validated rows and refreshes cache", %{
    prefix: prefix
  } do
    string_definition =
      AppConfigure.define(
        key: key(prefix, "batch-string"),
        encrypted: false,
        schema: Schema.string()
      )

    integer_definition =
      AppConfigure.define(
        key: key(prefix, "batch-integer"),
        encrypted: false,
        schema: Schema.integer()
      )

    assert :ok = AppConfigure.register_definitions([string_definition, integer_definition])
    string_key = string_definition.key
    integer_key = integer_definition.key

    assert {:ok,
            %{
              ^string_key => "value",
              ^integer_key => 2
            }} =
             AppConfigure.put_many_global_by_key([
               {string_definition.key, "stale"},
               {string_definition.key, "value"},
               {integer_definition.key, 2}
             ])

    assert %AppConfig{value: %{"type" => "plaintext", "value" => "value"}} =
             get_row!("global", string_definition.key)

    assert %AppConfig{value: %{"type" => "plaintext", "value" => 2}} =
             get_row!("global", integer_definition.key)

    assert {:ok, "value"} = AppConfigure.get(string_definition)
    assert {:ok, 2} = AppConfigure.get(integer_definition)
  end

  test "put_many_global_by_key/1 validates the whole batch before writing any row", %{
    prefix: prefix
  } do
    valid_definition =
      AppConfigure.define(
        key: key(prefix, "batch-valid"),
        encrypted: false,
        schema: Schema.string()
      )

    invalid_definition =
      AppConfigure.define(
        key: key(prefix, "batch-invalid"),
        encrypted: false,
        schema: Schema.integer()
      )

    assert :ok = AppConfigure.register_definitions([valid_definition, invalid_definition])

    assert {:error, :not_integer} =
             AppConfigure.put_many_global_by_key([
               {valid_definition.key, "value"},
               {invalid_definition.key, "not-an-integer"}
             ])

    refute Repo.exists?(from row in AppConfig, where: row.key == ^valid_definition.key)
    refute Repo.exists?(from row in AppConfig, where: row.key == ^invalid_definition.key)
  end

  test "put_many_global_by_key/1 reports persisted-but-stale when cache projection fails", %{
    prefix: prefix
  } do
    definition =
      AppConfigure.define(
        key: key(prefix, "batch-stale"),
        encrypted: false,
        schema: Schema.string()
      )

    assert :ok = AppConfigure.register_definitions([definition])
    definition_key = definition.key

    with_unregistered_cache(fn ->
      assert {:ok,
              {:persisted_but_stale, %{^definition_key => "value"},
               {:app_configure_cache_projection_failed, "global", ^definition_key, _reason}}} =
               AppConfigure.put_many_global_by_key(%{definition.key => "value"})

      assert %AppConfig{value: %{"type" => "plaintext", "value" => "value"}} =
               get_row!("global", definition.key)
    end)
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
    assert {:error, %Postgrex.Error{postgres: %{constraint: "app_configure_scope_check"}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               INSERT INTO app_configure (scope, key, value, inserted_at, updated_at)
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
             from row in AppConfig, where: row.scope == "global" and row.key == ^definition.key
           )
  end

  defp key(prefix, name), do: prefix <> "." <> name

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end

  defp with_unregistered_cache(fun) when is_function(fun, 0) do
    pid = Process.whereis(Cache)
    true = Process.unregister(Cache)

    try do
      fun.()
    after
      true = Process.register(pid, Cache)
    end
  end

  defp get_row!(scope, key) do
    Repo.one!(from row in AppConfig, where: row.scope == ^scope and row.key == ^key)
  end

  defp insert_row!(scope, key, value) do
    %AppConfig{}
    |> AppConfig.changeset(%{scope: scope, key: key, value: value})
    |> Repo.insert!()
  end
end
