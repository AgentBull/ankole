defmodule BullXWeb.SetupControllerTest do
  use BullXWeb.ConnCase, async: true

  test "GET /setup renders the placeholder SPA", %{conn: conn} do
    conn = get(conn, ~p"/setup")

    assert html_response(conn, 200) =~ "setup/App"
  end

  test "GET /setup/activate-owner renders the placeholder SPA", %{conn: conn} do
    conn = get(conn, ~p"/setup/activate-owner")

    assert html_response(conn, 200) =~ "setup/App"
  end
end
