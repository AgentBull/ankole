defmodule AnkoleWeb.SiteAdminConsoleTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest
  alias AnkoleWeb.SiteAdminConsole
  @endpoint AnkoleWeb.Endpoint

  setup do
    previous = Application.fetch_env(:ankole, :site_admin_console_path)
    Application.put_env(:ankole, :site_admin_console_path, "/operator/secret-entry")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ankole, :site_admin_console_path, value)
        :error -> Application.delete_env(:ankole, :site_admin_console_path)
      end
    end)

    :ok
  end

  test "a runtime mount keeps the browser path and rewrites only router path segments" do
    conn = build_conn(:get, "/operator/secret-entry/agents?sort=name")
    rewritten = SiteAdminConsole.call(conn, [])
    assert rewritten.path_info == ["site-admin-console", "agents"]
    assert rewritten.request_path == "/operator/secret-entry/agents"
    assert rewritten.query_string == "sort=name"
    assert :ok = SiteAdminConsole.validate!()
  end

  test "old and fixed mounts have the same HTTP 404 response as an unknown path" do
    for accept <- ["text/html", "application/json"] do
      responses =
        for path <- [
              "/console",
              "/console/settings",
              "/site-admin-console",
              "/site-admin-console/agents",
              "/site-admin-consol%65",
              "/site-admin-consol%65/agents",
              "/operator/secret-entry-extra",
              "/no-such-route"
            ] do
          conn = AnkoleWeb.ConnCase.build_conn() |> put_req_header("accept", accept) |> get(path)
          body = response(conn, 404)
          headers = Enum.reject(conn.resp_headers, fn {key, _} -> key == "x-request-id" end)
          {headers, body}
        end

      assert length(Enum.uniq(responses)) == 1
    end
  end

  test "console is available as a configured mount" do
    Application.put_env(:ankole, :site_admin_console_path, "/console")
    assert :ok = SiteAdminConsole.validate!()

    assert SiteAdminConsole.call(build_conn(:get, "/console/agents"), []).path_info == [
             "site-admin-console",
             "agents"
           ]
  end

  test "invalid mounts and routes owned by another subsystem fail before startup" do
    for path <- [
          "",
          "/",
          "relative",
          "/bad/",
          "/a//b",
          "/a/../b",
          "/api/private",
          "/oauth",
          "/assets/admin",
          "/bad?query",
          "/a%2Fb"
        ] do
      Application.put_env(:ankole, :site_admin_console_path, path)
      assert_raise ArgumentError, fn -> SiteAdminConsole.validate!() end
    end
  end
end
