defmodule AnkoleWeb.PodFileControllerTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod

  test "replacement rejects a stale object after a Drive write and accepts the current object", %{
    conn: conn
  } do
    {conn, uid} = console_conn_with_principal(conn)
    local = Ankole.Files.temp_path()
    File.write!(local, "browser bytes")
    on_exit(fn -> File.rm(local) end)
    upload = %Plug.Upload{path: local, filename: "shared.txt", content_type: "text/plain"}
    created = post(conn, "/api/v2/pod/file-pages", %{file: upload, private_owner_uid: uid})
    assert %{"page" => %{"id" => id, "object_id" => original}} = json_response(created, 200)

    assert {:ok, written} =
             Ankole.Files.write_node(
               Ankole.PrincipalsFixtures.actor_fixture(uid),
               id,
               "runtime bytes"
             )

    stale =
      created
      |> recycle_api()
      |> post("/api/v2/pod/pages/#{id}/files", %{
        file: upload,
        role: "file",
        base_object_id: original
      })

    assert json_response(stale, 409)
    assert {:ok, "runtime bytes"} = Ankole.Files.read_object(written.object_id)
    assert {:ok, %{object_id: current}} = Ankole.Files.fetch_node(id)
    assert current == written.object_id

    fresh =
      stale
      |> recycle_api()
      |> post("/api/v2/pod/pages/#{id}/files", %{
        file: upload,
        role: "file",
        base_object_id: current
      })

    assert %{"file" => %{"object_id" => replaced}} = json_response(fresh, 200)
    refute replaced == current
    assert {:ok, "browser bytes"} = Ankole.Files.read_object(replaced)
  end

  test "an uploaded file page returns the requested object range and keeps the sandbox headers",
       %{conn: conn} do
    {conn, uid} = console_conn_with_principal(conn)
    local = Ankole.Files.temp_path()
    File.write!(local, "0123456789")
    on_exit(fn -> File.rm(local) end)
    upload = %Plug.Upload{path: local, filename: "range.txt", content_type: "text/plain"}
    created = post(conn, "/api/v2/pod/file-pages", %{file: upload, private_owner_uid: uid})
    assert %{"page" => %{"id" => id}} = json_response(created, 200)

    downloaded =
      created
      |> recycle_api()
      |> put_req_header("range", "bytes=-4")
      |> get("/api/v2/pod/pages/#{id}/files/content", %{path: "range.txt"})

    assert response(downloaded, 206) == "6789"
    assert get_resp_header(downloaded, "content-range") == ["bytes 6-9/10"]

    assert get_resp_header(downloaded, "content-security-policy") == [
             "sandbox; default-src 'none'"
           ]
  end
end
