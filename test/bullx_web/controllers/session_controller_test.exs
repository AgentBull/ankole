defmodule BullXWeb.SessionControllerTest do
  use BullXWeb.ConnCase, async: true

  test "GET /sessions/new renders the placeholder SPA", %{conn: conn} do
    conn = get(conn, ~p"/sessions/new")

    assert html_response(conn, 200) =~ "setup/App"
  end
end
