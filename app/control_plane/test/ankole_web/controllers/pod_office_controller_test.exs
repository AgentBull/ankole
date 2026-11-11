defmodule AnkoleWeb.PodOfficeControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod
  alias Ankole.Pod.OfficeFiles

  test "browsers create, bootstrap, download, list versions of, and restore office files, and convert word pages to documents",
       %{
         conn: conn,
         tenant: tenant
       } do
    {conn, uid} = console_conn_with_principal(conn)

    created =
      api_post(conn, "/api/v2/pod/office-pages", %{format: "spreadsheet", title: "Budget"})

    assert %{"page" => %{"id" => id, "type" => "file", "title" => "Budget.xlsx", "revision" => 1}} =
             api_response(created, 200)

    bootstrap = created |> recycle_api() |> api_get("/api/v2/pod/pages/#{id}/office")

    assert %{
             "page_id" => ^id,
             "revision" => 1,
             "format" => "spreadsheet",
             "file" => %{"path" => "Budget.xlsx", "sha256" => created_sha},
             "ops" => [],
             "metadata" => %{"sheets" => [%{"name" => "Sheet1"}]}
           } = api_response(bootstrap, 200)

    actor =
      Ankole.Repo.with_tenant(tenant.id, fn -> Ankole.PrincipalsFixtures.actor_fixture(uid) end)

    {:ok, %{revision: 2}} =
      Ankole.Repo.with_tenant(tenant.id, fn ->
        OfficeFiles.apply_op(actor, id, %{
          base_revision: 1,
          client_id: "tab",
          client_seq: 1,
          op: %{"type" => "cell.set", "sheet_id" => 1, "cell" => "A1", "input" => "downloaded"}
        })
      end)

    bootstrap = bootstrap |> recycle_api() |> api_get("/api/v2/pod/pages/#{id}/office")

    assert %{"revision" => 2, "ops" => [%{"revision" => 2, "client_id" => "tab", "op" => op}]} =
             api_response(bootstrap, 200)

    assert op["cell"] == "A1"

    pinned =
      bootstrap
      |> recycle_api()
      |> get("/api/v2/pod/pages/#{id}/files/content", %{path: "Budget.xlsx", sha256: created_sha})

    assert {:ok, %{plain_text: "[Sheet: Sheet1]\n"}} =
             Ankole.Kernel.office_open(:spreadsheet, response(pinned, 200), [])

    download =
      pinned
      |> recycle_api()
      |> get("/api/v2/pod/pages/#{id}/files/content", %{path: "Budget.xlsx"})

    assert {:ok, %{plain_text: text}} =
             Ankole.Kernel.office_open(:spreadsheet, response(download, 200), [])

    assert text =~ "downloaded"

    # The download wrote the edit into a new object, so the bootstrap pin is stale.
    stale =
      download
      |> recycle_api()
      |> get("/api/v2/pod/pages/#{id}/files/content", %{path: "Budget.xlsx", sha256: created_sha})

    assert %{"error" => %{"code" => "manifest_changed"}} = json_response(stale, 409)

    versions =
      stale |> recycle_api() |> api_get("/api/v2/pod/pages/#{id}/office/versions")

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
      |> api_post("/api/v2/pod/pages/#{id}/office/versions/#{version_id}/restore", %{})

    assert %{
             "page_id" => ^id,
             "revision" => 3,
             "format" => "spreadsheet",
             "file" => %{"sha256" => ^created_sha}
           } = api_response(restored, 200)

    # Create a Word page, bootstrap it, and convert it to a Document page.
    word_created =
      restored
      |> recycle_api()
      |> api_post("/api/v2/pod/office-pages", %{format: "word", title: "Architecture Plan"})

    assert %{"page" => %{"id" => word_id, "type" => "file", "title" => "Architecture Plan.docx"}} =
             api_response(word_created, 200)

    word_bootstrap =
      word_created |> recycle_api() |> api_get("/api/v2/pod/pages/#{word_id}/office")

    assert %{"format" => "word", "revision" => 1} = api_response(word_bootstrap, 200)

    converted =
      word_bootstrap
      |> recycle_api()
      |> api_post("/api/v2/pod/pages/#{word_id}/convert-to-document", %{})

    assert %{
             "page" => %{"id" => doc_id, "type" => "doc", "title" => "Architecture Plan"},
             "omitted" => omitted,
             "downgraded" => downgraded
           } = api_response(converted, 200)

    assert is_binary(doc_id)
    assert is_map(omitted)
    assert is_map(downgraded)

    # Create a Presentation page and bootstrap it.
    pres_created =
      converted
      |> recycle_api()
      |> api_post("/api/v2/pod/office-pages", %{format: "presentation", title: "Q4 Review"})

    assert %{"page" => %{"id" => pres_id, "type" => "file", "title" => "Q4 Review.pptx"}} =
             api_response(pres_created, 200)

    pres_bootstrap =
      pres_created |> recycle_api() |> api_get("/api/v2/pod/pages/#{pres_id}/office")

    assert %{"format" => "presentation", "revision" => 1} = api_response(pres_bootstrap, 200)

    missing =
      pres_bootstrap
      |> recycle_api()
      |> api_get("/api/v2/pod/pages/#{Ecto.UUID.generate()}/office")

    assert %{"code" => "not_found"} = api_error(missing, 404)

    font_manifest =
      missing
      |> recycle_api()
      |> get("/fonts/office/manifest.json")

    assert %{"fonts" => fonts} = json_response(font_manifest, 200)
    assert is_list(fonts)
  end
end
