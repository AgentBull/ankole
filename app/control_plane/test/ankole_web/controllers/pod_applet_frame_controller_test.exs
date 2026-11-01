defmodule AnkoleWeb.PodAppletFrameControllerTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod
  alias Ankole.Files, as: Drive
  alias Ankole.Pod.{Files, Pages}

  test "frame modules revalidate privately and reject a stale publication", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, page} = Pages.create(actor, %{type: "applet", private_owner_uid: uid})

    manifest =
      Enum.map(
        %{
          "src/main.tsx" => "source",
          "dist/index.html" => "<head></head>",
          "dist/main.js" => "export {}"
        },
        fn {path, bytes} ->
          {:ok, stored} = Drive.store(bytes)

          {:ok, _} =
            Drive.commit(uid, [
              Map.merge(stored, %{path: "project/" <> path, source: "agent"})
            ])

          %{path: path, object_id: stored.object_id, source_path: "project/" <> path}
        end
      )

    assert {:ok, %{revision: 1}} = Files.publish(actor, page.id, 0, manifest)

    reference =
      conn
      |> get("/api/v2/browser/session")
      |> AnkoleWeb.Session.authentication_reference()
      |> Ankole.BrowserSessions.encode_reference()

    url = "/pod/applet-frame/#{reference}/#{page.id}/1/main.js"
    response = conn |> recycle_api() |> get(url)
    assert response(response, 200) == "export {}"
    ranged = conn |> recycle_api() |> put_req_header("range", "bytes=0-5") |> get(url)
    assert response(ranged, 206) == "export"
    assert get_resp_header(ranged, "content-range") == ["bytes 0-5/9"]
    assert get_resp_header(response, "content-type") == ["text/javascript; charset=utf-8"]
    assert get_resp_header(response, "cache-control") == ["private, no-cache"]
    assert get_resp_header(response, "x-frame-options") == ["SAMEORIGIN"]
    assert get_resp_header(response, "content-security-policy") == []
    assert get_resp_header(response, "content-disposition") == []

    index =
      conn
      |> recycle_api()
      |> get("/pod/applet-frame/#{reference}/#{page.id}/1/index.html")

    assert html_response(index, 200) =~ "parent.__ANKOLE_APPLET_HOST__.prepare(window)"

    anonymous = build_conn() |> pod_conn(tenant) |> get(url)
    assert response(anonymous, 401)

    current = conn |> recycle_api() |> get("/pod/applet-frame/current/#{page.id}/1/main.js")
    assert response(current, 200) == "export {}"

    [etag] = get_resp_header(response, "etag")
    cached = conn |> recycle_api() |> put_req_header("if-none-match", etag) |> get(url)
    assert response(cached, 304) == ""
    assert {:ok, %{revision: 2}} = Files.publish(actor, page.id, 1, manifest)
    stale = conn |> recycle_api() |> get(url)
    assert response(stale, 409) =~ "changed(window)"

    rev2_url = "/pod/applet-frame/#{reference}/#{page.id}/2/main.js"
    assert response(conn |> recycle_api() |> get(rev2_url), 200) == "export {}"

    assert {:ok, _} = Pages.delete(actor, page.id)

    assert %{"error" => %{"code" => "not_found"}} =
             conn |> recycle_api() |> get(rev2_url) |> json_response(404)

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> recycle_api()
             |> get("/pod/applet-frame/current/#{page.id}/2/index.html")
             |> json_response(404)
  end
end
