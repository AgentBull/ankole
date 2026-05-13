defmodule BullX.I18nTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BullX.I18n
  alias BullX.I18n.Resolver

  setup do
    previous = Process.get(:localize_locale)
    install_test_catalog()

    on_exit(fn ->
      :ok = BullX.I18n.Catalog.reload_locales!()

      case previous do
        nil -> Process.delete(:localize_locale)
        tag -> Process.put(:localize_locale, tag)
      end
    end)

    :ok
  end

  describe "t/3 — happy path" do
    test "returns the default-locale message" do
      {:ok, _} = I18n.put_locale(:"en-US")
      assert I18n.t("examples.greeting", %{name: "Alice"}) == "Hello, Alice!"
    end

    test "explicit :locale option overrides process locale" do
      {:ok, _} = I18n.put_locale(:"en-US")

      assert I18n.t("examples.greeting", %{name: "Alice"}, locale: :"zh-Hans-CN") ==
               "你好，Alice！"
    end

    test "scope option prepends to the key" do
      {:ok, _} = I18n.put_locale(:"en-US")
      assert I18n.t("greeting", %{name: "Bob"}, scope: "examples") == "Hello, Bob!"
    end

    test "Rails-style leading dot prepends scope" do
      {:ok, _} = I18n.put_locale(:"en-US")
      assert I18n.t(".greeting", %{name: "Eve"}, scope: "examples") == "Hello, Eve!"
    end

    test "with_locale/2 applies for one block" do
      {:ok, _} = I18n.put_locale(:"en-US")

      result =
        I18n.with_locale(:"zh-Hans-CN", fn ->
          I18n.t("examples.greeting", %{name: "Carol"})
        end)

      assert result == "你好，Carol！"
      assert I18n.t("examples.greeting", %{name: "Carol"}) == "Hello, Carol!"
    end

    test "plural via MF2 .match dispatches on count" do
      {:ok, _} = I18n.put_locale(:"en-US")

      assert I18n.t("errors.validation.length.string.min", %{count: 1}) ==
               "should be at least 1 character"

      assert I18n.t("errors.validation.length.string.min", %{count: 7}) ==
               "should be at least 7 characters"
    end
  end

  describe "t/3 — degradation" do
    test "missing key returns the key literal and logs :i18n_missing" do
      {:ok, _} = I18n.put_locale(:"en-US")

      log =
        capture_log([level: :error], fn ->
          assert I18n.t("does.not.exist") == "does.not.exist"
        end)

      assert log =~ "i18n missing" or log =~ "i18n_missing"
    end

    test "missing MF2 binding returns raw source and logs :i18n_format_error" do
      {:ok, _} = I18n.put_locale(:"en-US")

      log =
        capture_log([level: :error], fn ->
          out = I18n.t("examples.greeting", %{})
          # Raw MF2 source is returned
          assert out =~ "$name"
        end)

      assert log =~ "i18n format error" or log =~ "i18n_format_error"
    end
  end

  describe "translate/3" do
    test "returns {:ok, string} for a valid key" do
      assert {:ok, "Hello, Dave!"} =
               I18n.translate("examples.greeting", %{name: "Dave"}, locale: :"en-US")
    end

    test "returns {:error, _} for a missing key without logging" do
      assert {:error, %KeyError{}} = I18n.translate("nope.nope", %{})
    end

    test "returns {:error, _} on a missing MF2 binding" do
      assert {:error, _} = I18n.translate("examples.greeting", %{}, locale: :"en-US")
    end
  end

  describe "fallback chain" do
    test "zh-Hans-CN resolves directly when the key exists in both locales" do
      {:ok, _} = I18n.put_locale(:"zh-Hans-CN")
      assert "你好，Frank！" = I18n.t("examples.greeting", %{name: "Frank"})
    end

    test "falls back through meta.fallback when the requested locale misses the key" do
      # Inject a synthetic locale with a missing key to exercise the fallback
      # path without shipping test fixtures in priv/locales.
      alias BullX.I18n.Resolver
      Resolver.put_catalog(:"xx-Test", %{}, %{fallback: "en-US"})
      original = Resolver.loaded()
      Resolver.put_loaded(Enum.uniq([:"xx-Test" | Map.keys(original)]))

      on_exit(fn -> BullX.I18n.Catalog.reload_locales!() end)

      log =
        capture_log([level: :warning], fn ->
          assert I18n.t("examples.greeting", %{name: "Grace"}, locale: :"xx-Test") ==
                   "Hello, Grace!"
        end)

      assert log =~ "i18n fallback" or log =~ "i18n_fallback"
    end
  end

  describe "locale lifecycle" do
    test "put_locale/1 rejects locales that are not loaded from priv/locales" do
      assert {:error, %ArgumentError{} = error} = I18n.put_locale("ja-JP")
      assert Exception.message(error) =~ "is not loaded"
    end

    test "with_locale/2 rejects unloaded locales without changing the process locale" do
      {:ok, _} = I18n.put_locale(:"en-US")

      assert {:error, %ArgumentError{}} =
               I18n.with_locale("ja-JP", fn ->
                 flunk("should not execute for unloaded locales")
               end)

      assert I18n.t("examples.greeting", %{name: "Ivy"}) == "Hello, Ivy!"
    end
  end

  describe "available_locales/0" do
    test "lists locales found under priv/locales" do
      locales = I18n.available_locales()
      assert :"en-US" in locales
      assert :"zh-Hans-CN" in locales
    end
  end

  defp install_test_catalog do
    Resolver.put_catalog(
      :"en-US",
      %{
        "examples.greeting" => "Hello, {$name}!",
        "errors.validation.length.string.min" => """
        .input {$count :integer}
        .match $count
          1 {{should be at least 1 character}}
          * {{should be at least {$count} characters}}
        """
      },
      %{}
    )

    Resolver.put_catalog(
      :"zh-Hans-CN",
      %{
        "examples.greeting" => "你好，{$name}！"
      },
      %{fallback: "en-US"}
    )

    Resolver.put_loaded([:"en-US", :"zh-Hans-CN"])
  end
end
