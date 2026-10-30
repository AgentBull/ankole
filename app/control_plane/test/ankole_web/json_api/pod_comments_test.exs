defmodule AnkoleWeb.JSONAPI.PodCommentsTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

  test "browser comments serialize authors, conflict on stale edits, resolve and delete", %{
    conn: conn
  } do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{private_owner_uid: uid})
    Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-page:" <> page.id)
    page_id = page.id
    url = "/api/v2/pod/pages/#{page.id}/comments"

    created =
      owner
      |> recycle_json()
      |> post(url, %{data: %{body: "A **review** question"}})
      |> json_response(201)

    comment = created["comment"]
    assert_receive {:comments_committed, ^page_id}
    assert comment["author"]["principal_uid"] == uid
    assert comment["root_id"] == nil
    assert comment["anchor_present"] == false
    assert created["revision"] == 0
    comment_url = url <> "/" <> comment["id"]

    updated =
      owner
      |> recycle_json()
      |> patch(comment_url, %{data: %{body: "Clarified", version: comment["version"]}})
      |> json_response(200)

    assert updated["comment"]["body"] == "Clarified"
    assert_receive {:comments_committed, ^page_id}

    assert %{"errors" => [%{"code" => "comment_conflict"}]} =
             owner
             |> recycle_json()
             |> patch(comment_url, %{data: %{body: "Stale", version: comment["version"]}})
             |> json_response(409)

    resolved =
      owner
      |> recycle_json()
      |> put(comment_url <> "/resolution", %{
        data: %{version: updated["comment"]["version"], resolved: true}
      })
      |> json_response(200)

    assert resolved["comment"]["resolved_by"]["uid"] == uid
    assert_receive {:comments_committed, ^page_id}
    assert %{"threads" => []} = owner |> recycle_json() |> get(url) |> json_response(200)

    assert %{"threads" => [_]} =
             owner |> recycle_json() |> get(url, %{status: "resolved"}) |> json_response(200)

    deleted =
      owner
      |> recycle_json()
      |> delete(comment_url <> "?version=#{resolved["comment"]["version"]}")
      |> json_response(200)

    assert deleted["comment"]["body"] == nil
    assert_receive {:comments_committed, ^page_id}

    assert %{"threads" => []} =
             owner |> recycle_json() |> get(url, %{status: "all"}) |> json_response(200)
  end

  test "the browser summarizes activity and acknowledges exactly the supplied watermark", %{
    conn: conn
  } do
    {owner, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)

    other =
      Ankole.PrincipalsFixtures.human_fixture().principal
      |> Ankole.PrincipalsFixtures.actor_fixture()

    {:ok, page} = Ankole.Pod.Pages.create(actor, %{private_owner_uid: uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(uid, page.id, %{
        grants: [%{principal_uid: other.principal.uid, role: "contribute"}]
      })

    {:ok, %{comment: comment}} =
      Ankole.Pod.Comments.create(other, page.id, %{body: "Please review"})

    url = "/api/v2/pod/pages/#{page.id}/comments"
    summary = owner |> recycle_json() |> get(url <> "/summary") |> json_response(200)
    assert summary["unread_count"] == 1
    assert summary["resolved_ids"] == []
    assert summary["open_count"] == 1

    assert %{"thread" => %{"id" => thread_id, "unread" => true}} =
             owner |> recycle_json() |> get(url <> "/#{comment.id}") |> json_response(200)

    assert thread_id == comment.id

    assert %{"threads" => [_]} =
             owner |> recycle_json() |> get(url, %{status: "unread"}) |> json_response(200)

    acknowledged =
      owner
      |> recycle_json()
      |> put(url <> "/read", %{data: %{through: summary["activity_at"]}})
      |> json_response(200)

    assert acknowledged["unread_count"] == 0

    assert %{"threads" => []} =
             owner |> recycle_json() |> get(url, %{status: "unread"}) |> json_response(200)

    assert %{"unread_count" => 0} =
             owner |> recycle_json() |> get(url <> "/summary") |> json_response(200)
  end

  defp recycle_json(conn) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
  end
end
