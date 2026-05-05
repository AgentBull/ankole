defmodule BullXWeb.I18n.HTMLTest do
  use ExUnit.Case, async: false

  alias BullXWeb.I18n.HTML

  setup do
    previous = BullX.I18n.default_locale()

    on_exit(fn ->
      {:ok, _} = BullX.I18n.put_default_locale(previous)
    end)

    :ok
  end

  test "lang/0 returns the configured BCP 47 locale" do
    {:ok, _} = BullX.I18n.put_default_locale(:"zh-Hans-CN")

    assert HTML.lang() == "zh-Hans-CN"
  end
end
