defmodule AnkoleWeb.PodAppletControllerTest do
  use AnkoleWeb.ConnCase, async: false
  alias Ankole.Pod.{Files, Pages}
  alias Ankole.Files, as: Drive

  setup do
    allow_cache_database_access()
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  test "browser routes require a pinned revision and preserve flat query and arbitrary JSON", %{
    conn: conn
  } do
    {conn, uid} = console_conn_with_principal(conn)
    page = publish(uid)
    url = "/.internal-apis/pod/pages/#{page.id}/routes/echo?tag=one&tag=two&a%5Bb%5D=flat"
    response = post(conn, url, "[1,true]")
    assert %{"error" => %{"code" => "invalid_request"}} = json_response(response, 400)

    response =
      conn
      |> recycle_api()
      |> put_req_header("x-ankole-applet-revision", "0")
      |> post(url, "[1,true]")

    assert %{"error" => %{"code" => "applet_revision_changed", "details" => %{"revision" => 1}}} =
             json_response(response, 409)

    response =
      conn
      |> recycle_api()
      |> put_req_header("x-ankole-applet-revision", "1")
      |> post(url, "[1,true]")

    assert %{"body" => [1, true], "query" => %{"tag" => ["one", "two"], "a[b]" => "flat"}} =
             json_response(response, 200)

    encoded = URI.encode("a/b 中%", &URI.char_unreserved?/1)

    parameter_response =
      conn
      |> recycle_api()
      |> put_req_header("x-ankole-applet-revision", "1")
      |> get("/.internal-apis/pod/pages/#{page.id}/routes/params/#{encoded}")

    assert json_response(parameter_response, 200) == "a/b 中%"

    response =
      conn
      |> recycle_api()
      |> put_req_header("x-ankole-applet-revision", "1")
      |> post(url, "not-json")

    assert %{"error" => %{"code" => "invalid_request"}} = json_response(response, 400)

    response =
      conn
      |> recycle_api()
      |> put_req_header("x-ankole-applet-revision", "1")
      |> put_req_header("content-type", "text/plain")
      |> post(url, "hello")

    assert %{"error" => %{"code" => "invalid_request"}} = json_response(response, 400)
  end

  test "browser errors never disclose handler stack or console output and mutations retain CSRF protection",
       %{conn: conn} do
    {conn, uid} = console_conn_with_principal(conn)
    page = publish(uid)
    url = "/.internal-apis/pod/pages/#{page.id}/routes/crash"

    response =
      conn |> recycle_api() |> put_req_header("x-ankole-applet-revision", "1") |> get(url)

    assert %{"error" => %{"code" => "handler_error"}} = json_response(response, 500)
    refute response.resp_body =~ "private-debug"
    refute response.resp_body =~ "private-console"

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> recycle_api()
      |> delete_req_header("x-csrf-token")
      |> put_req_header("x-ankole-applet-revision", "1")
      |> post("/.internal-apis/pod/pages/#{page.id}/routes/echo", "{}")
    end
  end

  test "ordinary Pod validation keeps its 422 status while Applet malformed JSON uses 400", %{
    conn: conn
  } do
    {conn, uid} = console_conn_with_principal(conn)
    {:ok, page} = Pages.create(uid, %{private_owner_uid: uid})
    response = conn |> recycle_api() |> put("/.internal-apis/pod/pages/#{page.id}/sharing", %{})
    assert %{"error" => %{"code" => "invalid_request"}} = json_response(response, 422)
  end

  defp publish(uid) do
    {:ok, page} = Pages.create(uid, %{type: "applet", private_owner_uid: uid})

    source =
      "export default {'GET /params/:id':r=>r.params.id,'POST /echo':r=>({body:r.body,query:r.query}),'GET /crash':()=>{console.log('private-console');throw new Error('private-debug')}}"

    manifest =
      Enum.map(
        [{"src/main.tsx", "source"}, {"dist/index.html", "frontend"}, {"server/main.js", source}],
        fn {path, bytes} ->
          {:ok, blob} = Drive.store(bytes)

          {:ok, _} =
            Drive.commit(uid, [
              %{path: "publish/#{page.id}/#{path}", sha256: blob.sha256, source: "pod"}
            ])

          %{path: path, sha256: blob.sha256}
        end
      )

    {:ok, _} = Files.publish(uid, page.id, 0, manifest)
    page
  end
end
