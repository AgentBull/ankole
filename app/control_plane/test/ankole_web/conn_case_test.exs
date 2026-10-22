defmodule AnkoleWeb.ConnCaseTest do
  use AnkoleWeb.ConnCase, async: true

  alias AnkoleWeb.Plugs.RequestHost

  test "recycle/1 keeps the canonical origin and browser state", %{conn: conn} do
    recycled =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer fixture")
      |> put_req_header("x-custom", "not retained")
      |> put_resp_cookie("browser", "retained")
      |> send_resp(200, "")
      |> recycle()
      |> fetch_cookies()

    assert RequestHost.origin(recycled) == AnkoleWeb.PodURL.site_origin(conn)
    assert recycled.state == :unset
    assert recycled.req_cookies["browser"] == "retained"
    assert get_req_header(recycled, "accept") == ["application/json"]
    assert get_req_header(recycled, "authorization") == ["Bearer fixture"]
    assert get_req_header(recycled, "x-custom") == []
  end

  test "recycle/2 keeps the origin and only the selected headers", %{conn: conn} do
    recycled =
      conn
      |> put_req_header("authorization", "Bearer fixture")
      |> put_req_header("x-custom", "retained")
      |> recycle(["x-custom"])

    assert RequestHost.origin(recycled) == RequestHost.origin(conn)
    assert get_req_header(recycled, "x-custom") == ["retained"]
    assert get_req_header(recycled, "authorization") == []
  end

  test "both recycle forms preserve a noncanonical origin", %{conn: conn} do
    conn = %{conn | scheme: :https, host: "untrusted.example", port: 9443}

    for recycled <- [recycle(conn), recycle(conn, [])] do
      assert RequestHost.origin(recycled) == "https://untrusted.example:9443"
    end
  end
end
