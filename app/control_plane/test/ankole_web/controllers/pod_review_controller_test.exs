defmodule AnkoleWeb.PodReviewControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod
  alias Ankole.Pod.{Files, Pages}
  alias Ankole.Repo

  setup do
    :ok
  end

  test "untrusted active files are attachments in a sandbox, while passive previews remain inline",
       %{conn: conn, tenant: tenant} do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)

    for {name, type, disposition} <- [
          {"page.html", "text/html", "attachment"},
          {"image.svg", "image/svg+xml", "attachment"},
          {"report.pdf", "application/pdf", "inline"}
        ] do
      {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{type: "file"})

      {:ok, uploaded} =
        Files.upload(
          Ankole.PrincipalsFixtures.actor_fixture(uid),
          page.id,
          "file",
          nil,
          name,
          "<script>parent.alert(1)</script>",
          type
        )

      response =
        conn
        |> recycle_api()
        |> get("/api/v2/pod/pages/#{page.id}/files/content", %{
          path: name,
          sha256: uploaded.file.sha256
        })

      assert response.status == 200

      assert ["sandbox; default-src 'none'"] ==
               get_resp_header(response, "content-security-policy")

      assert ["nosniff"] == get_resp_header(response, "x-content-type-options")
      assert [header] = get_resp_header(response, "content-disposition")
      assert String.starts_with?(header, disposition)
      assert ["private, no-cache"] == get_resp_header(response, "cache-control")
    end
  end

  test "a known digest still requires live page authorization after a grant is revoked", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, reader} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    owner = Ankole.PrincipalsFixtures.human_fixture().principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        type: "file",
        private_owner_uid: owner.uid
      })

    {:ok, uploaded} =
      Files.upload(
        Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
        page.id,
        "file",
        nil,
        "report.txt",
        "private",
        "text/plain"
      )

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [%{principal_uid: reader, role: "view"}]
      })

    params = %{path: "report.txt", sha256: uploaded.file.sha256}
    allowed = get(conn, "/api/v2/pod/pages/#{page.id}/files/content", params)
    assert response(allowed, 200) == "private"
    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{grants: []})

    denied =
      allowed
      |> recycle_api()
      |> get("/api/v2/pod/pages/#{page.id}/files/content", params)

    assert %{"error" => %{"code" => "forbidden"}} = json_response(denied, 403)
  end

  test "stale sharing snapshots cannot erase another manager's grants", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    other = Ankole.PrincipalsFixtures.human_fixture().principal
    agent = Ankole.PrincipalsFixtures.agent_fixture().principal
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{})
    first = api_get(conn, "/api/v2/pod/pages/#{page.id}/sharing")
    baseline = json_response(first, 200)["sharing_version"]

    saved =
      first
      |> recycle_api()
      |> api_put("/api/v2/pod/pages/#{page.id}/sharing", %{
        sharing_version: baseline,
        grants: [%{principal_uid: agent.uid, role: "edit"}]
      })

    assert json_response(saved, 200)

    stale =
      saved
      |> recycle_api()
      |> api_put("/api/v2/pod/pages/#{page.id}/sharing", %{
        sharing_version: baseline,
        grants: [%{principal_uid: other.uid, role: "view"}]
      })

    assert %{"errors" => [%{"code" => "sharing_conflict"}]} = json_response(stale, 409)
    {:ok, current} = Pages.sharing(Ankole.PrincipalsFixtures.actor_fixture(uid), page.id)
    assert Enum.any?(current.grants, &(&1.principal_uid == agent.uid))
    refute Enum.any?(current.grants, &(&1.principal_uid == other.uid))

    missing =
      stale |> recycle_api() |> api_put("/api/v2/pod/pages/#{page.id}/sharing", %{grants: []})

    assert json_response(missing, 400)

    malformed =
      missing
      |> recycle_api()
      |> api_put("/api/v2/pod/pages/#{page.id}/sharing", %{
        sharing_version: current.sharing_version,
        grants: [nil]
      })

    assert json_response(malformed, 400)
  end

  test "attachment-only native replies retain the string text HTTP contract", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    agent = Ankole.PrincipalsFixtures.agent_fixture(%{owner_principal_uid: uid}).principal
    Ankole.ConversationsFixtures.grant_chat(uid, agent.uid)
    id = Ecto.UUID.generate()

    {:ok, _} =
      Ankole.ConversationsFixtures.create(uid, %{
        conversation_id: id,
        agent_uid: agent.uid,
        message_id: Ecto.UUID.generate(),
        text: "Create a report"
      })

    event = Repo.get_by!(Ankole.Signals.Signal, conversation_id: id)

    attachment =
      Ankole.FilesFixtures.sent_attachment_fixture(
        agent.uid,
        "report.pdf",
        "result",
        "application/pdf"
      )

    {:ok, target} = Ankole.Conversations.Target.for_reply(event)

    assert {:ok, _} =
             Repo.transact(fn ->
               Ankole.Conversations.post_in_tx(target, %Ankole.Conversations.Statement{
                 signal: event,
                 completion: %{final_text: nil, clarify_prompt: nil, attachments: [attachment]}
               })
             end)

    response = api_get(conn, "/api/v2/pod/conversations/#{id}")
    assert %{"messages" => messages} = json_response(response, 200)
    assert %{"text" => "", "attachments" => [%{"name" => "report.pdf"}]} = List.last(messages)
  end

  test "malformed version collections fail as requests and duplicates have one result", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{})
    malformed = api_post(conn, "/api/v2/pod/versions", %{pages: [], tables: %{}})

    assert json_response(malformed, 400)

    duplicate =
      malformed
      |> recycle_api()
      |> api_post("/api/v2/pod/versions", %{pages: [page.id, page.id], tables: []})

    assert %{"pages" => [%{"id" => id}], "tables" => []} = json_response(duplicate, 201)
    assert id == page.id
  end
end
