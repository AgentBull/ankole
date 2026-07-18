defmodule Ankole.ApplicationTest do
  use ExUnit.Case, async: true

  alias Ankole.I18n

  test "loads CardKit translations before SignalsGateway can recover durable replies" do
    reverse_start_order =
      Ankole.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    signals_gateway_index =
      Enum.find_index(reverse_start_order, &(&1 == Ankole.SignalsGateway.Supervisor))

    i18n_catalog_index =
      Enum.find_index(reverse_start_order, &(&1 == Ankole.I18n.Catalog))

    assert signals_gateway_index < i18n_catalog_index

    assert {:ok, "Refining the answer…"} =
             I18n.translate("signals_gateway.cardkit.refining", %{}, locale: "en-US")

    assert {:ok, "正在完善回答…"} =
             I18n.translate("signals_gateway.cardkit.refining", %{}, locale: "zh-Hans-CN")
  end
end
