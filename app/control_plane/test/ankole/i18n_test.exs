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
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()
    :ok = Ankole.I18n.Catalog.reload_locales!()
    put_test_catalogs()

    on_exit(fn ->
      :ok = Ankole.I18n.Catalog.reload_locales!()
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

  describe "translate/3" do
    test "returns {:ok, string} for a valid key" do
      assert {:ok, "Hello, Dave!"} =
               I18n.translate("test.greeting", %{"name" => "Dave"}, locale: "en-US")
    end

    test "returns {:error, _} for a missing key without logging" do
      assert {:error, %KeyError{}} = I18n.translate("nope.nope", %{})
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
        %Ankole.Tenants.Tenant{}
        |> Ankole.Tenants.Tenant.changeset(%{
          slug: "locale-#{Ecto.UUID.generate()}",
          display_name: "Other locale"
        })
        |> Repo.insert!()

      assert I18n.t("test.greeting", %{"name" => "Carol"}) == "你好，Carol！"

      Repo.with_tenant(other.id, fn ->
        assert I18n.t("test.greeting", %{"name" => "Carol"}) == "Hello, Carol!"
      end)

      assert I18n.t("test.greeting", %{"name" => "Carol"}) == "你好，Carol！"
      assert Resolver.language_tag_to_locale(I18n.default_locale()) == "en-US"
    end

    test "put_default_locale/1 persists in the current tenant without replacing the site value",
         %{tenant: tenant} do
      assert {:ok, "zh-Hans-CN"} = I18n.put_default_locale("zh-Hans-CN")
      assert I18n.configured_default_locale() == {:ok, "zh-Hans-CN"}

      assert %AppConfig{value: %{"type" => "plaintext", "value" => "zh-Hans-CN"}} =
               Repo.one!(
                 from row in AppConfig,
                   where: row.tenant_id == ^tenant.id and row.key == "i18n.default_locale"
               )

      assert {:ok, "en-US"} = AppConfigure.put_global(Config.default_locale_definition(), "en-US")
      assert I18n.configured_default_locale() == {:ok, "zh-Hans-CN"}
    end

    test "a stored unavailable global default does not prevent catalog boot or reload" do
      definition = Config.default_locale_definition()
      assert {:ok, "en-US"} = AppConfigure.put_global(definition, "en-US")
      schema = AppConfig.for_scope("global")

      Repo.update_all(
        from(row in schema, where: row.scope == "global" and row.key == ^definition.key),
        set: [value: %{"type" => "plaintext", "value" => "fr-FR"}]
      )

      Cache.clear_for_test()

      log =
        capture_log([format: "$metadata $message\n", metadata: [:event]], fn ->
          assert :ok = I18n.reload()
          # init loads the release catalog before reading the same persisted row.
          assert {:ok, _state} = Ankole.I18n.Catalog.init([])
        end)

      assert log =~ "i18n.catalog.default_unavailable"
      assert Resolver.language_tag_to_locale(I18n.default_locale()) == "en-US"
      assert Repo.get_by!(schema, scope: "global", key: definition.key).value["value"] == "fr-FR"
      assert {:ok, "en-US"} = AppConfigure.put_global(definition, "en-US")
    end

    test "direct AppConfigure writes reject unavailable active defaults before persistence" do
      restore_default_locale = fn ->
        {:ok, "en-US"} = AppConfigure.put_global(Config.default_locale_definition(), "en-US")
        :ok = I18n.reload()
      end

      on_exit(restore_default_locale)

      assert {:error, :unavailable_locale} =
               AppConfigure.put_global(Config.default_locale_definition(), "fr-FR")

      assert {:error, :unavailable_locale} =
               AppConfigure.put_global_by_key("i18n.default_locale", "fr-FR")

      assert {:error, :unavailable_locale} =
               AppConfigure.put_tenant_by_key("i18n.default_locale", "fr-FR")

      assert :ok = I18n.reload()

      restore_default_locale.()
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
