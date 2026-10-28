defmodule Ankole.I18nTest do
  use Ankole.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.I18n
  alias Ankole.I18n.Config
  alias Ankole.I18n.Resolver

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()
    :ok = Ankole.I18n.Catalog.reload_locales()
    put_test_catalogs()

    on_exit(fn ->
      :ok = Ankole.I18n.Catalog.reload_locales()
    end)

    :ok
  end

  describe "t/3" do
    test "returns the default-locale message" do
      {:ok, _tag} = I18n.put_default_locale("en-US")
      assert I18n.t("test.greeting", %{"name" => "Alice"}) == "Hello, Alice!"
    end

    test "explicit locale option overrides the tenant locale" do
      {:ok, _tag} = I18n.put_default_locale("en-US")

      assert I18n.t("test.greeting", %{"name" => "Alice"}, locale: "zh-Hans-CN") ==
               "你好，Alice！"
    end

    test "scope option prepends to the key" do
      {:ok, _tag} = I18n.put_default_locale("en-US")
      assert I18n.t("greeting", %{"name" => "Bob"}, scope: "test") == "Hello, Bob!"
    end

    test "missing key returns the key literal and logs" do
      {:ok, _tag} = I18n.put_default_locale("en-US")

      log =
        capture_log([level: :error], fn ->
          assert I18n.t("does.not.exist") == "does.not.exist"
        end)

      assert log =~ "i18n missing" or log =~ "i18n_missing"
    end
  end

  describe "fallback chain" do
    test "uses __meta__.fallback when the requested locale misses a key" do
      Resolver.put_catalog("xx-Test", %{}, %{fallback: "en-US"})
      original = Resolver.loaded()
      Resolver.put_loaded(Enum.uniq(["xx-Test" | Map.keys(original)]))

      log =
        capture_log([level: :warning], fn ->
          assert I18n.t("test.greeting", %{"name" => "Grace"}, locale: "xx-Test") ==
                   "Hello, Grace!"
        end)

      assert log =~ "i18n fallback" or log =~ "i18n_fallback"
    end
  end

  describe "locale lifecycle" do
    test "rejects locales that are not loaded from app/locales" do
      assert {:error, %ArgumentError{} = error} = I18n.put_default_locale("fr-FR")
      assert Exception.message(error) =~ "is not loaded"
    end

    test "default translations follow tenant context without changing the shared site default" do
      {:ok, "zh-Hans-CN"} = I18n.put_default_locale("zh-Hans-CN")

      other =
        create_tenant(%{
          slug: "locale-#{Ecto.UUID.generate()}",
          display_name: "Other locale"
        })

      assert I18n.t("test.greeting", %{"name" => "Carol"}) == "你好，Carol！"

      Repo.with_tenant(other.id, fn ->
        assert I18n.t("test.greeting", %{"name" => "Carol"}) == "Hello, Carol!"
      end)

      assert I18n.t("test.greeting", %{"name" => "Carol"}) == "你好，Carol！"

      assert Ankole.I18n.Resolver.exact_loaded_locale(
               I18n.default_locale(),
               Ankole.I18n.Resolver.loaded()
             ) == "en-US"
    end

    test "put_default_locale/1 persists per Pod and rejects site-level reads and writes",
         %{tenant: tenant} do
      definition = Config.default_locale_definition()
      assert definition.scope == :pod

      assert {:ok, "zh-Hans-CN"} = I18n.put_default_locale("zh-Hans-CN")
      assert I18n.configured_default_locale() == {:ok, "zh-Hans-CN"}

      assert %AppConfig{value: %{"type" => "plaintext", "value" => "zh-Hans-CN"}} =
               Repo.one!(
                 from row in AppConfig,
                   where: row.tenant_id == ^tenant.id and row.key == "i18n.default_locale"
               )

      assert {:error, {:pod_scope_only, "i18n.default_locale"}} =
               AppConfigure.put_global(definition, "en-US")

      assert {:error, {:pod_scope_only, "i18n.default_locale"}} =
               AppConfigure.put_global_by_key("i18n.default_locale", "en-US")

      assert {:error, {:pod_scope_only, "i18n.default_locale"}} =
               AppConfigure.delete_global(definition)

      assert {:error, {:pod_scope_only, "i18n.default_locale"}} =
               AppConfigure.get(definition, scope: :global)

      assert I18n.configured_default_locale() == {:ok, "zh-Hans-CN"}
    end

    test "put_default_locale_in_tx/1 validates and commits inside the caller's transaction" do
      assert {:error, :unavailable_locale} = I18n.put_default_locale_in_tx("fr-FR")

      assert {:ok, write} =
               Repo.transact_top_level(fn ->
                 I18n.put_default_locale_in_tx("ja-JP")
               end)

      assert {:ok, "ja-JP"} = AppConfigure.cache_committed_write(write)
      assert I18n.configured_default_locale() == {:ok, "ja-JP"}
    end

    test "direct AppConfigure tenant writes reject unavailable locales before persistence" do
      assert {:error, :unavailable_locale} =
               AppConfigure.put_tenant_by_key("i18n.default_locale", "fr-FR")

      assert :ok = Ankole.I18n.Catalog.reload()
    end

    test "ScopeDefaultLocaleToPod migration copies legacy site locale only to Pods without overrides",
         %{tenant: first} do
      second =
        create_tenant(%{
          slug: "locale-migrated-#{Ecto.UUID.generate()}",
          display_name: "Migrated Pod"
        })

      {:ok, "ja-JP"} = I18n.put_default_locale("ja-JP")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {1, _} =
        Repo.insert_all(Ankole.AppConfigure.SiteConfig, [
          %{
            scope: "global",
            key: "i18n.default_locale",
            value: %{"type" => "plaintext", "value" => "zh-Hans-CN"},
            inserted_at: now,
            updated_at: now
          }
        ])

      {1, _} =
        Repo.with_tenant(second.id, fn ->
          Repo.insert_all(AppConfig, [
            %{
              tenant_id: second.id,
              scope: "agent:legacy-agent",
              key: "i18n.default_locale",
              value: %{"type" => "plaintext", "value" => "ko-KR"},
              inserted_at: now,
              updated_at: now
            }
          ])
        end)

      unless Code.ensure_loaded?(Ankole.Repo.Migrations.ScopeDefaultLocaleToPod) do
        Code.require_file(
          Path.expand(
            "../../priv/repo/migrations/20261028020000_scope_default_locale_to_pod.exs",
            __DIR__
          )
        )
      end

      Repo.without_tenant(fn ->
        Ecto.Migration.Runner.run(
          Repo,
          Repo.config(),
          20_261_028_020_000,
          Ankole.Repo.Migrations.ScopeDefaultLocaleToPod,
          :forward,
          :up,
          :up,
          log: false
        )
      end)

      Cache.clear_for_test()

      refute Repo.get_by(Ankole.AppConfigure.SiteConfig,
               scope: "global",
               key: "i18n.default_locale"
             )

      Repo.with_tenant(second.id, fn ->
        refute Repo.get_by(AppConfig, scope: "agent:legacy-agent", key: "i18n.default_locale")
      end)

      Repo.with_tenant(first.id, fn ->
        assert I18n.configured_default_locale() == {:ok, "ja-JP"}
      end)

      Repo.with_tenant(second.id, fn ->
        assert I18n.configured_default_locale() == {:ok, "zh-Hans-CN"}
      end)
    end
  end

  describe "available_locales/0" do
    test "lists locales found under app/locales" do
      assert "en-US" in I18n.available_locales()
      assert "zh-Hans-CN" in I18n.available_locales()
      assert "ja-JP" in I18n.available_locales()
      assert "ko-KR" in I18n.available_locales()
    end
  end

  defp put_test_catalogs do
    Resolver.put_catalog(
      "en-US",
      %{"test.greeting" => canonical_message!("Hello, {$name}!")},
      %{}
    )

    Resolver.put_catalog(
      "zh-Hans-CN",
      %{
        "test.greeting" => canonical_message!("你好，{$name}！")
      },
      %{fallback: "en-US"}
    )
  end

  defp canonical_message!(message) do
    case Localize.Message.canonical_message(message) do
      {:ok, canonical} -> canonical
      canonical when is_binary(canonical) -> canonical
    end
  end
end
