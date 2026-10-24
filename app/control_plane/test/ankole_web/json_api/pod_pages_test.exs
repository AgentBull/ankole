defmodule AnkoleWeb.JSONAPI.PodPagesTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

  test "a human edits their private page while another human cannot read or move it", %{
    conn: conn
  } do
    {owner, uid} = console_conn_with_principal(conn)
    created = send_json(owner, :post, "/pages", %{title: "Private draft", private_owner_uid: uid})
    assert %{"page" => %{"id" => id, "revision" => 0}} = json_response(created, 201)

    saved =
      send_json(owner, :put, "/pages/#{id}/content", %{
        base_revision: 0,
        xml: "<page><p>Saved text</p></page>"
      })

    assert %{"page" => %{"revision" => 1}, "content" => %{"content" => xml}} =
             json_response(saved, 200)

    assert xml =~ "Saved text"

    stale =
      send_json(owner, :put, "/pages/#{id}/content", %{
        base_revision: 0,
        xml: "<page><p>Stale text</p></page>"
      })

    assert %{
             "errors" => [
               %{"code" => "revision_conflict", "meta" => %{"details" => %{"revision" => 1}}}
             ]
           } = json_response(stale, 409)

    assert %{"pages" => [%{"id" => ^id, "title" => "Private draft"}]} =
             owner
             |> recycle_json()
             |> get("/api/v2/pod/pages", %{scope: "private"})
             |> json_response(200)

    assert %{"pages" => [%{"id" => ^id}]} =
             owner |> recycle_json() |> get("/api/v2/pod/pages") |> json_response(200)

    read = owner |> recycle_json() |> get("/api/v2/pod/pages/#{id}")
    assert %{"content" => %{"content" => ^xml}, "role" => "manage"} = json_response(read, 200)

    human = Ankole.PrincipalsFixtures.human_fixture().principal

    {:ok, other, flow} =
      conn |> Plug.Test.init_test_session(%{}) |> AnkoleWeb.Session.begin_login(:pod, %{})

    {:ok, _} =
      Ankole.BrowserSessions.bind_provider(
        AnkoleWeb.Session.browser_reference(other),
        flow.id,
        "lark-main"
      )

    {:ok, other, _} =
      AnkoleWeb.Session.complete_login(other, flow.id, %{
        "principal_uid" => human.uid,
        "access_version" => human.access_version,
        "provider_id" => "lark-main",
        "external_id" => "other"
      })

    other = other |> with_console_csrf() |> get("/api/v2/browser/session")
    denied = other |> recycle_json() |> get("/api/v2/pod/pages/#{id}")
    assert %{"errors" => [%{"code" => "forbidden"}]} = json_response(denied, 403)

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             other
             |> send_json(:post, "/pages/#{id}/move", %{parent_id: nil})
             |> json_response(403)

    assert {:ok, %{page: %{private_owner_uid: ^uid}, content: %{content: ^xml}}} =
             Ankole.Pod.Pages.get(uid, id)
  end

  test "AshJsonApi derives concrete page identifiers and timestamps for all page results" do
    spec = AnkoleWeb.JSONAPI.PodRouter.spec() |> OpenApiSpex.OpenApi.to_map()
    page = spec["components"]["schemas"]["pod_page-type"]
    assert "id" in page["required"]
    assert page["properties"]["id"]["type"] == "string"
    assert page["properties"]["created_at"]["format"] == "date-time"

    scope =
      Enum.find(spec["paths"]["/api/v2/pod/pages"]["get"]["parameters"], &(&1["name"] == "scope"))

    refute scope["required"]
  end

  defp recycle_json(conn) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
  end

  defp send_json(conn, method, path, attrs) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> dispatch(@endpoint, method, "/api/v2/pod" <> path, Ankole.JSON.encode!(%{data: attrs}))
  end
end
