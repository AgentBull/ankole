defmodule BullX.I18n.CatalogTest do
  use BullX.DataCase, async: false

  import ExUnit.CaptureLog

  alias BullX.I18n
  alias BullX.I18n.Resolver

  @config_key "bullx.i18n_default_locale"
  @config_env "BULLX_I18N_DEFAULT_LOCALE"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)

    original = BullX.Repo.get(BullX.Config.AppConfig, @config_key)
    original_env = System.get_env(@config_env)

    :ok = BullX.Config.delete(@config_key)
    System.delete_env(@config_env)

    :ok = BullX.Config.Cache.refresh_all()
    :ok = BullX.I18n.Catalog.reload_locales!()
    :ok = BullX.I18n.reload()

    on_exit(fn ->
      restore_default_locale(original)
      restore_env(original_env)
      :ok = BullX.I18n.Catalog.reload_locales!()
      :ok = BullX.I18n.reload()
    end)

    :ok
  end

  test "reload/0 refreshes the fallback chain when the configured default locale changes" do
    System.put_env(@config_env, "zh-Hans-CN")
    assert :ok = I18n.reload()

    assert :"zh-Hans-CN" =
             I18n.default_locale()
             |> Resolver.language_tag_to_locale()
  end

  test "reload_locales!/0 restores the on-disk catalog through the explicit API" do
    Resolver.put_catalog(:"en-US", %{"app.close" => "Broken"}, %{})

    assert I18n.t("app.close", %{}, locale: :"en-US") == "Broken"

    assert :ok = BullX.I18n.Catalog.reload_locales!()

    log =
      capture_log([level: :error], fn ->
        assert I18n.t("app.close", %{}, locale: :"en-US") == "app.close"
      end)

    assert log =~ "i18n missing" or log =~ "i18n_missing"
  end

  test "reload_locales!/0 drops stale locales from persistent_term" do
    Resolver.put_catalog(:"xx-Test", %{}, %{fallback: "en-US"})
    loaded = Resolver.loaded() |> Map.keys()
    Resolver.put_loaded([:"xx-Test" | loaded])

    assert %{fallback: "en-US"} = Resolver.meta(:"xx-Test")

    assert :ok = BullX.I18n.Catalog.reload_locales!()

    refute Map.has_key?(Resolver.loaded(), :"xx-Test")
    assert Resolver.meta(:"xx-Test") == %{}
  end

  test "catalog reload ignores client locale TOMLs" do
    log =
      capture_log([level: :error], fn ->
        assert I18n.t("web.setup.title", %{}, locale: :"en-US") == "web.setup.title"
      end)

    assert log =~ "i18n missing" or log =~ "i18n_missing"
  end

  defp restore_default_locale(nil), do: BullX.Config.delete(@config_key)

  defp restore_default_locale(%BullX.Config.AppConfig{value: value}),
    do: BullX.Config.put(@config_key, value)

  defp restore_env(nil), do: System.delete_env(@config_env)
  defp restore_env(value), do: System.put_env(@config_env, value)
end
