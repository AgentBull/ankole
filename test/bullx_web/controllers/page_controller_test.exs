defmodule BullXWeb.PageControllerTest do
  use BullXWeb.ConnCase, async: true

  test "GET / renders the placeholder SPA", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~ "setup/App"
  end
end
