defmodule AnkoleWeb.JSONAPI.UnreadScansTest do
  # Console shows these counts before an administrator accepts the OCR charges
  # for the scanned PDFs uploaded earlier.
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PdfFixture
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.Pod.{Files, Pages}

  setup do
    Ankole.AppConfigure.Registry.clear_for_test()
    :ok
  end

  test "the Pod count covers its unread scans, and the Site count covers the Pods that follow the Site setting",
       %{conn: conn} do
    conn = console_conn(conn)
    upload_scan()
    count = fn path -> conn |> api_get(path) |> json_response(200) end

    assert count.("/api/v2/unread-scans") == %{"files" => 1, "pages" => 3, "counting" => false}

    assert count.("/api/v2/site/unread-scans") == %{
             "files" => 1,
             "pages" => 3,
             "counting" => false
           }

    # A Pod that gave its own answer keeps it, so a Site-level consent would not read its scans.
    assert {:ok, false} = AppConfigure.put_tenant_by_key("pod.ocr_existing_scans", false)

    assert count.("/api/v2/site/unread-scans") == %{
             "files" => 0,
             "pages" => 0,
             "counting" => false
           }

    assert count.("/api/v2/unread-scans") == %{"files" => 1, "pages" => 3, "counting" => false}
  end

  test "the counts need the permission to read the consent setting", %{conn: conn} do
    conn = console_conn(conn)

    for grant <- Ankole.AuthZ.list_grants!(),
        do: {:ok, _} = Ankole.AuthZ.delete_permission_grant(grant.id)

    conn |> api_get("/api/v2/unread-scans") |> json_response(403)
    conn |> api_get("/api/v2/site/unread-scans") |> json_response(403)
  end

  # A PDF whose three pages are scans, extracted without an OCR model.
  defp upload_scan do
    actor = actor_fixture(human_fixture().principal)
    {:ok, folder} = Pages.create(actor, %{type: :doc, title: "Scans"})

    {:ok, _page} =
      Files.create_from_upload(
        actor,
        %{parent_id: folder.id},
        "scan.pdf",
        pdf(["", "", ""]),
        "application/pdf"
      )

    assert %{failure: 0} = Oban.drain_queue(queue: :default)
  end

  defp api_get(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> get(path)
  end
end
