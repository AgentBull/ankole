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
    :ok = Config.ensure_registered()
    :ok = Ankole.I18n.Catalog.reload_locales!()

    on_exit(fn ->
      :ok = Ankole.I18n.Catalog.reload_locales!()
    end)

    :ok
  end

  describe "t/3" do
    test "returns the default-locale message" do
      {:ok, _tag} = I18n.put_locale("en-US")
      assert I18n.t("examples.greeting", %{"name" => "Alice"}) == "Hello, Alice!"
    end

    test "explicit locale option overrides the process locale" do
      {:ok, _tag} = I18n.put_locale("en-US")

      assert I18n.t("examples.greeting", %{"name" => "Alice"}, locale: "zh-Hans-CN") ==
               "你好，Alice！"
    end

    test "scope option prepends to the key" do
      {:ok, _tag} = I18n.put_locale("en-US")
      assert I18n.t("greeting", %{"name" => "Bob"}, scope: "examples") == "Hello, Bob!"
    end

    test "missing key returns the key literal and logs" do
      {:ok, _tag} = I18n.put_locale("en-US")

      log =
        capture_log([level: :error], fn ->
          assert I18n.t("does.not.exist") == "does.not.exist"
        end)

      assert log =~ "i18n missing" or log =~ "i18n_missing"
    end

    test "MF2 plural messages format through Localize" do
      {:ok, _tag} = I18n.put_locale("en-US")

      assert I18n.t("errors.validation.length.string.min", %{"count" => 1}) ==
               "should be at least 1 character"

      assert I18n.t("errors.validation.length.string.min", %{"count" => 7}) ==
               "should be at least 7 characters"
    end
  end

  describe "translate/3" do
    test "returns {:ok, string} for a valid key" do
      assert {:ok, "Hello, Dave!"} =
               I18n.translate("examples.greeting", %{"name" => "Dave"}, locale: "en-US")
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
          assert I18n.t("examples.greeting", %{"name" => "Grace"}, locale: "xx-Test") ==
                   "Hello, Grace!"
        end)

      assert log =~ "i18n fallback" or log =~ "i18n_fallback"
    end
  end

  describe "locale lifecycle" do
    test "rejects locales that are not loaded from priv/locales" do
      assert {:error, %ArgumentError{} = error} = I18n.put_locale("ja-JP")
      assert Exception.message(error) =~ "is not loaded"
    end

    test "with_locale/2 applies for one block" do
      {:ok, _tag} = I18n.put_locale("en-US")

      result =
        I18n.with_locale("zh-Hans-CN", fn ->
          I18n.t("examples.greeting", %{"name" => "Carol"})
        end)

      assert result == "你好，Carol！"
      assert I18n.t("examples.greeting", %{"name" => "Carol"}) == "Hello, Carol!"
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

      assert {:ok, "ja-JP"} = AppConfigure.put_global(Config.default_locale_definition(), "ja-JP")
      assert {:error, %ArgumentError{} = error} = I18n.reload()
      assert Exception.message(error) =~ "configured i18n.default_locale"
      assert Exception.message(error) =~ "ja-JP"

      restore_default_locale.()
    end
  end

  describe "available_locales/0" do
    test "lists locales found under priv/locales" do
      assert "en-US" in I18n.available_locales()
      assert "zh-Hans-CN" in I18n.available_locales()
    end
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
