defmodule AnkoleWeb.JSONAPI.PodDocumentHistoryTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

  test "history lists checkpoint summaries, reads XML, and restores with metadata-aware concurrency",
       %{conn: conn} do
    {conn, uid} = console_conn_with_principal(conn)
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)

    {:ok, page} =
      Ankole.Pod.Pages.create(actor, %{
        title: "Original",
        private_owner_uid: uid,
        xml: "<page><p>Initial content</p></page>"
      })

    path = "/api/v2/pod/pages/#{page.id}/history"

    assert %{
             "snapshots" => [%{"id" => snapshot_id, "reason" => "created"} = summary],
             "current_revision" => 0,
             "current_updated_at" => updated_at,
             "next_cursor" => nil
           } =
             conn |> json_conn() |> get(path) |> json_response(200)

    refute Map.has_key?(summary, "content")
    assert updated_at == DateTime.to_iso8601(page.updated_at)

    assert %{"snapshot" => %{"content" => "<page><p>Initial content</p></page>"}} =
             conn |> json_conn() |> get(path <> "/#{snapshot_id}") |> json_response(200)

    {:ok, %{page: changed}} =
      Ankole.Pod.Documents.write(actor, page.id, 0, "<page><p>New content</p></page>")

    stale =
      conn
      |> json_conn()
      |> post(path <> "/#{snapshot_id}/restore", %{
        data: %{
          base_revision: 0,
          updated_at: updated_at
        }
      })

    assert %{"errors" => [%{"code" => "document_conflict"}]} = json_response(stale, 409)

    restored =
      conn
      |> json_conn()
      |> post(path <> "/#{snapshot_id}/restore", %{
        data: %{
          base_revision: changed.revision,
          updated_at: DateTime.to_iso8601(changed.updated_at)
        }
      })

    assert %{
             "page" => %{"revision" => 2, "title" => "Original"},
             "content" => %{"content" => "<page><p>Initial content</p></page>"}
           } = json_response(restored, 201)
  end

  defp json_conn(conn) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
  end
end
