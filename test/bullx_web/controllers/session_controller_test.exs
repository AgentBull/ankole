defmodule BullXWeb.SessionControllerTest do
  use BullXWeb.ConnCase, async: true

  test "GET /sessions/new keeps local return_to paths", %{conn: conn} do
    conn = get(conn, ~p"/sessions/new?return_to=/console")

    assert html_response(conn, 200) =~ ~s(name="return_to" type="hidden" value="/console")
  end

  test "GET /sessions/new rejects protocol-relative return_to values", %{conn: conn} do
    conn = get(conn, ~p"/sessions/new?return_to=//evil.example/console")

    assert html_response(conn, 200) =~ ~s(name="return_to" type="hidden" value="/")
  end
end
