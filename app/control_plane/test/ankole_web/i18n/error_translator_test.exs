defmodule AnkoleWeb.I18n.ErrorTranslatorTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.I18n.Config
  alias AnkoleWeb.I18n.ErrorTranslator

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()
    :ok = Config.ensure_registered()
    :ok = Ankole.I18n.Catalog.reload_locales!()
    :ok
  end

  test "maps length validation metadata to stable translation keys" do
    assert ErrorTranslator.translate_error(
             {"should be at least %{count} character(s)",
              validation: :length, kind: :min, count: 2, type: :string}
           ) == "should be at least 2 characters"
  end

  test "falls back to normalized Ecto message keys" do
    assert ErrorTranslator.translate_error({"can't be blank", validation: :required}) ==
             "can't be blank"
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
