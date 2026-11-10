defmodule AnkoleWeb.PodAppletControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod
  alias Ankole.Pod.{Applets, Files, Pages, PagesFixtures}
  alias Ankole.AutomationJobs
  alias Ankole.Files, as: Drive
  alias Ankole.PrincipalsFixtures
  alias AnkoleWeb.Session, as: WebSession

  setup do
    :ok
  end

  test "browser routes require a pinned revision and preserve flat query and arbitrary JSON", %{
    conn: conn
  } do
    {conn, uid} = console_conn_with_principal(conn)
    page = publish(uid)
    url = "/api/v2/pod/pages/#{page.id}/routes/echo?tag=one&tag=two&a%5Bb%5D=flat"
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
      |> get("/api/v2/pod/pages/#{page.id}/routes/params/#{encoded}")

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
    url = "/api/v2/pod/pages/#{page.id}/routes/crash"

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
      |> post("/api/v2/pod/pages/#{page.id}/routes/echo", "{}")
    end
  end

  test "JSON:API validates required sharing input while Applet malformed JSON uses its own protocol",
       %{
         conn: conn
       } do
    {conn, uid} = console_conn_with_principal(conn)

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{private_owner_uid: uid})

    response = conn |> recycle_api() |> api_put("/api/v2/pod/pages/#{page.id}/sharing", %{})
    assert %{"errors" => [%{"code" => "required"}]} = json_response(response, 400)
  end

  test "published Applet approvals require the assigned Human's browser session", %{conn: conn} do
    {owner_conn, owner_uid} = console_conn_with_principal(conn)
    owner = PrincipalsFixtures.actor_fixture(owner_uid)
    reviewer = PrincipalsFixtures.human_fixture().principal
    reviewer_actor = PrincipalsFixtures.actor_fixture(reviewer)
    reviewer_conn = reviewer_connection(conn, reviewer)

    {:ok, page} = Pages.create(owner, %{type: :applet, private_owner_uid: owner_uid})

    {:ok, _} =
      PagesFixtures.set_sharing(owner_uid, page.id, %{
        grants: [%{principal_uid: reviewer.uid, role: "view"}]
      })

    Ankole.FilesFixtures.publish_applet_fixture(%{actor: owner, page: page}, """
    export default {
      routes: {
        'POST /approvals': r => AnkoleRuntime.approvals.request(r.body),
        'GET /approvals': () => AnkoleRuntime.approvals.list(),
        'GET /approvals/:id': r => AnkoleRuntime.approvals.get(r.params.id),
        'POST /decision': r => AnkoleRuntime.approvals.decide(r.body),
        'GET /admin-can-decide': () => ({available: typeof AnkoleRuntime.admin.approvals.decide === 'function'}),
        'POST /background-review': r => AnkoleRuntime.signals.emit({
          targetJobId: r.body.jobId, type: 'review.requested', data: r.body.request
        })
      },
      actions: {
        review: {idempotent: true, handler: ctx => AnkoleRuntime.admin.approvals.request(ctx.signal.data)}
      }
    }
    """)

    url = "/api/v2/pod/pages/#{page.id}/routes"

    request = %{
      "requestKey" => "source-2",
      "reviewerUid" => reviewer.uid,
      "summary" => "Review source"
    }

    assert %{"id" => id, "status" => "pending", "requesterUid" => ^owner_uid} =
             owner_conn
             |> applet_route_conn()
             |> post(url <> "/approvals", Torque.encode!(request))
             |> json_response(200)

    assert %{"approvals" => [%{"id" => ^id, "status" => "pending"}]} =
             reviewer_conn
             |> applet_route_conn()
             |> get(url <> "/approvals")
             |> json_response(200)

    assert %{"available" => false} =
             reviewer_conn
             |> applet_route_conn()
             |> get(url <> "/admin-can-decide")
             |> json_response(200)

    decision = %{"id" => id, "decision" => "approved"}

    assert {:ok, %{"status" => 403, "body" => %{"error" => %{"code" => "forbidden"}}}} =
             Applets.call(reviewer_actor, page.id, %{
               "method" => "POST",
               "path" => "/decision",
               "query" => %{},
               "body" => decision
             })

    assert {:error, %{status: 403, code: "forbidden"}} =
             Applets.Capabilities.call(
               %{
                 "applet" => %{"pageId" => page.id},
                 "method" => "POST",
                 "authentication_ref" => "test"
               },
               reviewer_actor,
               "admin.approvals.decide",
               [decision]
             )

    assert %{"error" => %{"code" => "forbidden"}} =
             owner_conn
             |> applet_route_conn()
             |> post(url <> "/decision", Torque.encode!(decision))
             |> json_response(403)

    assert %{"id" => ^id, "status" => "approved"} =
             reviewer_conn
             |> applet_route_conn()
             |> post(url <> "/decision", Torque.encode!(decision))
             |> json_response(200)

    assert %{"id" => ^id, "status" => "approved"} =
             owner_conn
             |> applet_route_conn()
             |> get(url <> "/approvals/#{id}")
             |> json_response(200)

    {:ok, job} =
      AutomationJobs.create_applet_job(owner, page.id, "review", %{authorization_kind: "service"})

    background = %{"jobId" => job.id, "request" => %{request | "requestKey" => "source-3"}}

    assert %{"runId" => run_id} =
             owner_conn
             |> applet_route_conn()
             |> post(url <> "/background-review", Torque.encode!(background))
             |> json_response(200)

    assert :ok =
             AutomationJobs.Jobs.ExecuteRun.run(%Oban.Job{
               args: %{"automation_job_run_id" => run_id, "expected_slice_count" => 0}
             })

    assert %{status: :succeeded, result: %{"id" => background_id, "requesterUid" => ^owner_uid}} =
             AutomationJobs.get_run_record(run_id)

    assert %{"approvals" => [%{"id" => ^background_id, "status" => "pending"}, %{"id" => ^id}]} =
             reviewer_conn
             |> applet_route_conn()
             |> get(url <> "/approvals")
             |> json_response(200)
  end

  test "route invocation and publish return 503 when all Applet runtime slots are saturated", %{
    conn: conn
  } do
    {conn, uid} = console_conn_with_principal(conn)
    page = publish(uid)

    active = Ankole.FunctionRuntimeHelpers.saturate()

    try do
      route_response =
        conn
        |> recycle_api()
        |> put_req_header("x-ankole-applet-revision", "1")
        |> get("/api/v2/pod/pages/#{page.id}/routes/params/test")

      assert %{"error" => %{"code" => "applet_busy"}} =
               json_response(route_response, 503)

      {:ok, draft_page} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{
          type: "applet",
          private_owner_uid: uid
        })

      manifest = stage_manifest(uid, draft_page.id)

      assert {:error, :applet_busy} =
               Files.publish(
                 Ankole.PrincipalsFixtures.actor_fixture(uid),
                 draft_page.id,
                 0,
                 manifest
               )
    after
      Ankole.FunctionRuntimeHelpers.release(active)
    end
  end

  defp publish(uid) do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{
        type: "applet",
        private_owner_uid: uid
      })

    manifest = stage_manifest(uid, page.id)
    {:ok, _} = Files.publish(Ankole.PrincipalsFixtures.actor_fixture(uid), page.id, 0, manifest)
    page
  end

  defp applet_route_conn(conn),
    do: conn |> recycle_api() |> put_req_header("x-ankole-applet-revision", "1")

  defp reviewer_connection(conn, reviewer) do
    conn = conn |> Plug.Test.init_test_session(%{}) |> WebSession.ensure_browser()

    {:ok, %{browser: browser, authentication: auth}} =
      Ankole.BrowserSessions.authenticate(WebSession.browser_reference(conn), %{
        "principal_uid" => reviewer.uid,
        "access_version" => reviewer.access_version,
        "provider_id" => "local",
        "external_id" => reviewer.uid
      })

    conn
    |> WebSession.put_authentication(browser, auth)
    |> with_console_csrf()
    |> get("/api/v2/browser/session")
  end

  defp stage_manifest(uid, page_id) do
    source =
      "export default {'GET /params/:id':r=>r.params.id,'POST /echo':r=>({body:r.body,query:r.query}),'GET /crash':()=>{console.log('private-console');throw new Error('private-debug')}}"

    Enum.map(
      [{"src/main.tsx", "source"}, {"dist/index.html", "frontend"}, {"server/main.js", source}],
      fn {path, bytes} ->
        {:ok, blob} = Drive.store(bytes)

        {:ok, _} =
          Drive.commit(uid, [
            Map.merge(blob, %{path: "publish/#{page_id}/#{path}", source: "pod"})
          ])

        %{path: path, object_id: blob.object_id, source_path: "publish/#{page_id}/#{path}"}
      end
    )
  end
end
