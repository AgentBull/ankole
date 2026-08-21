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
      {:ok, _tag} = I18n.put_locale("en-US")
      assert I18n.t("test.greeting", %{"name" => "Alice"}) == "Hello, Alice!"
    end

    test "explicit locale option overrides the process locale" do
      {:ok, _tag} = I18n.put_locale("en-US")

      assert I18n.t("test.greeting", %{"name" => "Alice"}, locale: "zh-Hans-CN") ==
               "你好，Alice！"
    end

    test "scope option prepends to the key" do
      {:ok, _tag} = I18n.put_locale("en-US")
      assert I18n.t("greeting", %{"name" => "Bob"}, scope: "test") == "Hello, Bob!"
    end

    test "missing key returns the key literal and logs" do
      {:ok, _tag} = I18n.put_locale("en-US")

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
      assert {:error, %ArgumentError{} = error} = I18n.put_locale("fr-FR")
      assert Exception.message(error) =~ "is not loaded"
    end

    test "with_locale/2 applies for one block" do
      {:ok, _tag} = I18n.put_locale("en-US")

      result =
        I18n.with_locale("zh-Hans-CN", fn ->
          I18n.t("test.greeting", %{"name" => "Carol"})
        end)

      assert result == "你好，Carol！"
      assert I18n.t("test.greeting", %{"name" => "Carol"}) == "Hello, Carol!"
    end

    test "put_default_locale/1 persists through AppConfigure and reloads Localize" do
      assert {:ok, "zh-Hans-CN"} = I18n.put_default_locale("zh-Hans-CN")
      assert I18n.default_locale() |> Resolver.language_tag_to_locale() == "zh-Hans-CN"

      assert %AppConfig{value: %{"type" => "plaintext", "value" => "zh-Hans-CN"}} =
               Repo.one!(
                 from row in AppConfig,
                   where: row.scope == "global" and row.key == "i18n.default_locale"
               )

      assert {:ok, "en-US"} = AppConfigure.put_global(Config.default_locale_definition(), "en-US")
      assert :ok = I18n.reload()
    end

    test "direct AppConfigure writes are validated when the runtime default is applied" do
      restore_default_locale = fn ->
        {:ok, "en-US"} = AppConfigure.put_global(Config.default_locale_definition(), "en-US")
        :ok = I18n.reload()
      end

      on_exit(restore_default_locale)

      assert {:ok, "fr-FR"} = AppConfigure.put_global(Config.default_locale_definition(), "fr-FR")
      assert {:error, %ArgumentError{} = error} = I18n.reload()
      assert Exception.message(error) =~ "configured i18n.default_locale"
      assert Exception.message(error) =~ "fr-FR"

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
