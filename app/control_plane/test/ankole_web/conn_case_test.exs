defmodule AnkoleWeb.ConnCaseTest do
  use AnkoleWeb.ConnCase, async: true

  alias AnkoleWeb.Plugs.RequestHost

  test "both recycle forms preserve a noncanonical origin", %{conn: conn} do
    conn = %{conn | scheme: :https, host: "untrusted.example", port: 9443}

    for recycled <- [recycle(conn), recycle(conn, [])] do
      assert RequestHost.origin(recycled) == "https://untrusted.example:9443"
    end
  end
end
