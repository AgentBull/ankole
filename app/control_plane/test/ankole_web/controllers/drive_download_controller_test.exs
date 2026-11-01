defmodule AnkoleWeb.DriveDownloadControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures

  test "a site operator downloads a selected tenant object by range while its Worker is offline",
       %{conn: conn, tenant: tenant} do
    conn = console_conn(conn)
    %{principal: agent} = agent_fixture()
    file = drive_file_fixture(agent.uid, "offline/report.txt", "frozen report bytes")
    url = "/api/v2/drive/#{tenant.id}/nodes/#{file.id}/content"
    downloaded = conn |> recycle_api() |> put_req_header("range", "bytes=7-12") |> get(url)
    assert response(downloaded, 206) == "report"
    assert get_resp_header(downloaded, "content-range") == ["bytes 7-12/19"]

    assert get_resp_header(downloaded, "content-disposition") == [
             "attachment; filename*=UTF-8''report.txt"
           ]

    denied = build_conn() |> get(url)
    assert denied.status in [401, 403]
  end

  test "empty Drive files download without manufacturing a stored object", %{
    conn: conn,
    tenant: tenant
  } do
    conn = console_conn(conn)
    %{principal: agent} = agent_fixture()
    {:ok, root} = Ankole.Files.private_root(agent.uid)

    {:ok, node} =
      Ankole.Files.create_node(actor_fixture(agent.uid), %{
        parent_id: root.id,
        kind: :file,
        name: "empty.txt"
      })

    url = "/api/v2/drive/#{tenant.id}/nodes/#{node.id}/content"
    assert response(conn |> recycle_api() |> get(url), 200) == ""
    ranged = conn |> recycle_api() |> put_req_header("range", "bytes=0-1") |> get(url)
    assert response(ranged, 416) == ""
    assert get_resp_header(ranged, "content-range") == ["bytes */0"]
  end

  test "legacy Bidi filenames are stripped in Content-Disposition while remaining downloadable",
       %{
         conn: conn,
         tenant: tenant
       } do
    conn = console_conn(conn)
    %{principal: agent} = agent_fixture()
    file = drive_file_fixture(agent.uid, "offline/safe.sh", "echo ok")

    Ankole.Repo.query!(
      "UPDATE drive_nodes SET name = $1 WHERE tenant_id = $2::text::uuid AND id = $3::text::uuid",
      ["invoice_\u202Efdp.sh", tenant.id, file.id]
    )

    url = "/api/v2/drive/#{tenant.id}/nodes/#{file.id}/content"
    downloaded = conn |> recycle_api() |> get(url)
    assert response(downloaded, 200) == "echo ok"

    assert get_resp_header(downloaded, "content-disposition") == [
             "attachment; filename*=UTF-8''invoice_fdp.sh"
           ]
  end
end
