defmodule AnkoleWeb.JSONAPI.PodDocumentInsightsTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

  test "document insights expose source timestamps and attributed contributors", %{conn: conn} do
    {conn, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{private_owner_uid: uid})

    response =
      conn
      |> recycle_api()
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> get("/api/v2/pod/pages/#{page.id}/insights")
      |> json_response(200)

    assert %{
             "created_at" => created,
             "updated_at" => updated,
             "contributors" => [
               %{"principal_uid" => ^uid, "kind" => "human", "role" => "creator", "name" => name}
             ]
           } = response

    assert is_binary(name)
    assert created == DateTime.to_iso8601(page.created_at)
    assert updated == DateTime.to_iso8601(page.updated_at)
  end

  test "browser visits and privacy expose typed insights and paginated readers", %{conn: conn} do
    {conn, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{private_owner_uid: uid})

    conn =
      recycle_api(conn)
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")

    assert %{"user_state" => %{"visited_at" => visited}} =
             conn
             |> put("/api/v2/pod/pages/#{page.id}/user-state", %{data: %{visited: true}})
             |> json_response(200)

    assert is_binary(visited)

    assert %{
             "total" => 1,
             "viewers" => [%{"person" => %{"principal_uid" => ^uid}, "visited_at" => ^visited}]
           } = conn |> get("/api/v2/pod/pages/#{page.id}/viewers") |> json_response(200)

    assert %{"daily" => [%{"views" => 1}], "can_view_readers" => true} =
             conn |> get("/api/v2/pod/pages/#{page.id}/insights") |> json_response(200)

    assert %{"user_state" => %{"hide_visits" => true}} =
             conn
             |> put("/api/v2/pod/pages/#{page.id}/user-state", %{data: %{hide_visits: true}})
             |> json_response(200)

    assert %{"total" => 0, "viewers" => []} =
             conn |> get("/api/v2/pod/pages/#{page.id}/viewers") |> json_response(200)
  end
end
