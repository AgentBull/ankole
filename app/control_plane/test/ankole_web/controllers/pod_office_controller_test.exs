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
    assert get_resp_header(font_manifest, "cache-control") == ["public, max-age=300"]

    tmp_fonts_dir =
      Path.join(System.tmp_dir!(), "ankole-office-fonts-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_fonts_dir)
    previous_fonts_dir = System.get_env("ANKOLE_OFFICE_FONTS_DIR")

    try do
      manifest_body =
        ~s({"version":"v2-test","fonts":[{"family":"IBM Plex Sans SC","file":"IBMPlexSansSC-Regular-034c70a1c7aa.ttf"}]})

      blob_body = "synthetic-ttf-bytes"
      blob_name = "IBMPlexSansSC-Regular-034c70a1c7aa.ttf"

      File.write!(Path.join(tmp_fonts_dir, "manifest.json"), manifest_body)
      File.write!(Path.join(tmp_fonts_dir, "manifest.json.gz"), :zlib.gzip(manifest_body))
      File.write!(Path.join(tmp_fonts_dir, blob_name), blob_body)
      File.write!(Path.join(tmp_fonts_dir, "#{blob_name}.gz"), :zlib.gzip(blob_body))
      System.put_env("ANKOLE_OFFICE_FONTS_DIR", tmp_fonts_dir)

      gz_manifest =
        font_manifest
        |> recycle_api()
        |> put_req_header("accept-encoding", "gzip")
        |> get("/fonts/office/manifest.json")

      assert gz_manifest.status == 200
      assert get_resp_header(gz_manifest, "cache-control") == ["public, max-age=300"]
      assert get_resp_header(gz_manifest, "content-encoding") == ["gzip"]

      gz_blob =
        gz_manifest
        |> recycle_api()
        |> put_req_header("accept-encoding", "gzip")
        |> get("/fonts/office/#{blob_name}")

      assert gz_blob.status == 200
      assert get_resp_header(gz_blob, "cache-control") == ["public, max-age=31536000, immutable"]
      assert get_resp_header(gz_blob, "content-encoding") == ["gzip"]
    after
      if previous_fonts_dir do
        System.put_env("ANKOLE_OFFICE_FONTS_DIR", previous_fonts_dir)
      else
        System.delete_env("ANKOLE_OFFICE_FONTS_DIR")
      end

      File.rm_rf(tmp_fonts_dir)
    end
  end
end
