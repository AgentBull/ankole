defmodule AnkoleWeb.PodSpreadsheetControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod
  alias Ankole.Pod.Spreadsheets

  test "browsers create, bootstrap, download, list versions of, and restore a spreadsheet", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    created = api_post(conn, "/api/v2/pod/spreadsheet-pages", %{title: "Budget"})

    assert %{"page" => %{"id" => id, "type" => "file", "title" => "Budget.xlsx", "revision" => 1}} =
             api_response(created, 200)

    bootstrap = created |> recycle_api() |> api_get("/api/v2/pod/pages/#{id}/spreadsheet")

    assert %{
             "page_id" => ^id,
             "revision" => 1,
             "file" => %{"path" => "Budget.xlsx", "sha256" => created_sha},
             "ops" => [],
             "metadata" => %{"sheets" => [%{"name" => "Sheet1"}]}
           } = api_response(bootstrap, 200)

    actor =
      Ankole.Repo.with_tenant(tenant.id, fn -> Ankole.PrincipalsFixtures.actor_fixture(uid) end)

    {:ok, %{revision: 2}} =
      Ankole.Repo.with_tenant(tenant.id, fn ->
        Spreadsheets.apply_op(actor, id, %{
          base_revision: 1,
          client_id: "tab",
          client_seq: 1,
          op: %{"type" => "cell.set", "sheet_id" => 1, "cell" => "A1", "input" => "downloaded"}
        })
      end)

    bootstrap = bootstrap |> recycle_api() |> api_get("/api/v2/pod/pages/#{id}/spreadsheet")

    assert %{"revision" => 2, "ops" => [%{"revision" => 2, "client_id" => "tab", "op" => op}]} =
             api_response(bootstrap, 200)

    assert op["cell"] == "A1"

    pinned =
      bootstrap
      |> recycle_api()
      |> get("/api/v2/pod/pages/#{id}/files/content", %{path: "Budget.xlsx", sha256: created_sha})

    assert {:ok, %{plain_text: "[Sheet: Sheet1]\n"}} =
             Ankole.Kernel.spreadsheet_open(response(pinned, 200), [])

    download =
      pinned
      |> recycle_api()
      |> get("/api/v2/pod/pages/#{id}/files/content", %{path: "Budget.xlsx"})

    assert {:ok, %{plain_text: text}} =
             Ankole.Kernel.spreadsheet_open(response(download, 200), [])

    assert text =~ "downloaded"

    # The download wrote the edit into a new object, so the bootstrap pin is stale.
    stale =
      download
      |> recycle_api()
      |> get("/api/v2/pod/pages/#{id}/files/content", %{path: "Budget.xlsx", sha256: created_sha})

    assert %{"error" => %{"code" => "manifest_changed"}} = json_response(stale, 409)

    versions =
      stale |> recycle_api() |> api_get("/api/v2/pod/pages/#{id}/spreadsheet/versions")

    assert %{
             "versions" => [
               %{
                 "id" => version_id,
                 "reason" => "created",
                 "revision" => 1,
                 "file_name" => "Budget.xlsx",
                 "sha256" => ^created_sha,
                 "author" => %{"principal_uid" => ^uid}
               }
             ]
           } = api_response(versions, 200)

    restored =
      versions
      |> recycle_api()
      |> api_post("/api/v2/pod/pages/#{id}/spreadsheet/versions/#{version_id}/restore", %{})

    assert %{"page_id" => ^id, "revision" => 3, "file" => %{"sha256" => ^created_sha}} =
             api_response(restored, 200)

    missing =
      restored
      |> recycle_api()
      |> api_get("/api/v2/pod/pages/#{Ecto.UUID.generate()}/spreadsheet")

    assert %{"code" => "not_found"} = api_error(missing, 404)
  end
end
