defmodule AnkoleWeb.PodRequestContextTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  alias Ankole.Pod.{Files, Pages}
  alias Ankole.Files, as: Drive
  @moduletag host: :pod

  setup %{conn: conn} do
    Ankole.AppConfigure.Cache.clear_for_test()
    {conn, reader} = console_conn_with_principal(conn)
    owner = Ankole.PrincipalsFixtures.human_fixture().principal.uid
    %{conn: conn, reader: reader, owner: owner}
  end

  test "HTTP files and JSON:API use the trusted connection IP for conditional grants", ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        type: "file",
        private_owner_uid: ctx.owner
      })

    {:ok, _} =
      Files.upload(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        page.id,
        "file",
        0,
        "report.txt",
        "restricted bytes",
        "text/plain"
      )

    grant(ctx.reader, page.id)
    path = "/api/v2/pod/pages/#{page.id}/files/content?path=report.txt"

    allowed = ctx.conn |> at_ip({10, 0, 0, 1}) |> get(path)
    assert response(allowed, 200) == "restricted bytes"

    json = ctx.conn |> at_ip({10, 0, 0, 1}) |> api_get("/api/v2/pod/pages/#{page.id}")
    assert api_response(json, 200)["page"]["id"] == page.id

    denied =
      ctx.conn
      |> at_ip({10, 0, 0, 2})
      |> put_req_header("x-ankole-ip", "10.0.0.1")
      |> get(path)

    assert json_response(denied, 403)["error"]["code"] == "forbidden"

    forwarded =
      ctx.conn
      |> at_ip({10, 0, 0, 2})
      |> put_req_header("x-forwarded-for", "10.0.0.1")
      |> get(path)

    if Application.fetch_env!(:ankole, :edition) == :saas do
      assert response(forwarded, 200) == "restricted bytes"
    else
      assert json_response(forwarded, 403)["error"]["code"] == "forbidden"
    end
  end

  test "Applet HTTP and its capability tasks share the trusted request context", ctx do
    {:ok, file} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        type: "file",
        private_owner_uid: ctx.owner
      })

    {:ok, _} =
      Files.upload(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        file.id,
        "file",
        0,
        "report.txt",
        "restricted bytes",
        "text/plain"
      )

    {:ok, applet} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        type: "applet",
        private_owner_uid: ctx.owner
      })

    source = "export default {'GET /files':()=>AnkoleRuntime.file.list('#{file.id}')}"
    publish(ctx.owner, applet.id, source)
    {:ok, applet_grant} = grant(ctx.reader, applet.id)
    grant(ctx.reader, file.id)
    path = "/api/v2/pod/pages/#{applet.id}/routes/files"

    allowed =
      ctx.conn
      |> at_ip({10, 0, 0, 1})
      |> put_req_header("x-ankole-applet-revision", "1")
      |> get(path)

    assert %{"files" => [%{"path" => file_path}]} = json_response(allowed, 200)
    assert file_path == "pages/#{file.id}/report.txt"

    denied =
      ctx.conn
      |> at_ip({10, 0, 0, 2})
      |> put_req_header("x-ankole-applet-revision", "1")
      |> get(path)

    assert json_response(denied, 403)["error"]["code"] == "forbidden"

    {:ok, _} = Ankole.AuthZ.update_permission_grant(applet_grant.id, %{condition: "true"})

    capability_denied =
      ctx.conn
      |> at_ip({10, 0, 0, 2})
      |> put_req_header("x-ankole-applet-revision", "1")
      |> get(path)

    assert json_response(capability_denied, 403)["error"]["code"] == "forbidden"
  end

  defp at_ip(conn, ip), do: conn |> recycle_api() |> Map.put(:remote_ip, ip)

  defp grant(uid, page_id) do
    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: uid,
        resource_pattern: "pod:**:#{page_id}:page",
        action: "page_view",
        condition:
          ~s(context.request.ip == "10.0.0.1" && context.request.surface == "pod_browser")
      })
  end

  defp publish(uid, page_id, source) do
    manifest =
      Enum.map(
        [{"src/main.tsx", "source"}, {"dist/index.html", "frontend"}, {"server/main.js", source}],
        fn {path, bytes} ->
          {:ok, blob} = Drive.store(bytes)

          {:ok, _} =
            Drive.commit(uid, [
              %{path: "publish/#{page_id}/#{path}", sha256: blob.sha256, source: "pod"}
            ])

          %{path: path, sha256: blob.sha256}
        end
      )

    {:ok, _} = Files.publish(Ankole.PrincipalsFixtures.actor_fixture(uid), page_id, 0, manifest)
  end
end
