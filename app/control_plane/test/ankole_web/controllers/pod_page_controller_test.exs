defmodule AnkoleWeb.PodPageControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod
  alias Ankole.Pod.Pages
  alias Ankole.Repo

  test "browser creation rejects Applet shells and creates a document with its body", %{
    conn: conn
  } do
    {conn, _uid} = console_conn_with_principal(conn)
    rejected = api_post(conn, "/api/v2/pod/pages", %{type: "applet"})
    assert rejected.status in [400, 422]

    created =
      conn
      |> recycle_api()
      |> api_post("/api/v2/pod/pages", %{
        type: "doc",
        title: "Saved",
        xml: "<page><p>Complete</p></page>"
      })

    assert %{"page" => %{"id" => id}} = api_response(created, 200)
    read = created |> recycle_api() |> api_get("/api/v2/pod/pages/#{id}")

    assert %{"content" => %{"content" => "<page><p>Complete</p></page>"}} =
             api_response(read, 200)
  end

  test "uploading a new file creates a named readable page in one request", %{conn: conn} do
    {conn, _uid} = console_conn_with_principal(conn)
    path = Path.join(System.tmp_dir!(), "pod-upload-#{Ecto.UUID.generate()}.txt")
    File.write!(path, "File page content")
    on_exit(fn -> File.rm(path) end)
    upload = %Plug.Upload{path: path, filename: "report.txt", content_type: "text/plain"}
    created = post(conn, "/api/v2/pod/file-pages", %{file: upload})

    assert %{"page" => %{"id" => id, "title" => "report.txt", "object_id" => object_id}} =
             json_response(created, 200)

    assert {:ok, _} = Ecto.UUID.cast(object_id)
    assert {:ok, %{object_id: ^object_id}} = Pages.fetch(id)

    response =
      created
      |> recycle_api()
      |> get("/api/v2/pod/pages/#{id}/files/content", %{path: "report.txt"})

    assert response(response, 200) == "File page content"
  end

  test "page lists carry the same current role as individual reads for inherited and restricted pages",
       %{conn: conn, tenant: tenant} do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    other = Ankole.PrincipalsFixtures.human_fixture().principal

    {:ok, space} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{title: "Admin space"})

    {:ok, own_private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{
        title: "Own Private",
        private_owner_uid: uid
      })

    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(other.uid), %{
        title: "Shared Private",
        private_owner_uid: other.uid
      })

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(other.uid), %{
        title: "Inherited editor",
        parent_id: private.id
      })

    {:ok, restricted} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(other.uid), %{
        title: "Direct viewer",
        parent_id: private.id
      })

    {:ok, hidden} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(other.uid), %{
        title: "Hidden Private",
        private_owner_uid: other.uid
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(other.uid, private.id, %{
        grants: [%{principal_uid: uid, role: "edit"}]
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(other.uid, restricted.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: uid, role: "view"}]
      })

    {:ok, _} =
      Pages.state(Ankole.PrincipalsFixtures.actor_fixture(uid), child.id, %{
        favorite: true,
        visited: true
      })

    {:ok, _} = Pages.set_space(Ankole.PrincipalsFixtures.actor_fixture(uid), "view")

    expected = %{
      space.id => "manage",
      own_private.id => "manage",
      private.id => "edit",
      child.id => "edit",
      restricted.id => "view"
    }

    for scope <- ~w(all space private shared recent favorites) do
      response = conn |> recycle_api() |> api_get("/api/v2/pod/pages", %{scope: scope})
      assert %{"pages" => pages} = api_response(response, 200)
      refute Enum.any?(pages, &(&1["id"] == hidden.id))

      for page <- pages do
        assert page["role"] == Map.fetch!(expected, page["id"])

        assert {:ok, %{role: role}} =
                 Pages.get(Ankole.PrincipalsFixtures.actor_fixture(uid), page["id"])

        assert page["role"] == role
      end
    end

    {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(uid), space.id)
    response = conn |> recycle_api() |> api_get("/api/v2/pod/pages", %{scope: "trash"})
    assert %{"pages" => [%{"id" => id, "role" => "manage"}]} = api_response(response, 200)
    assert id == space.id
  end

  test "browser writes retain the newer document when a stale save conflicts", %{conn: conn} do
    {conn, _uid} = console_conn_with_principal(conn)
    created = api_post(conn, "/api/v2/pod/pages", %{})

    assert %{
             "page" => %{
               "id" => id,
               "type" => "doc",
               "title" => "",
               "revision" => 0,
               "created_at" => timestamp
             }
           } =
             api_response(created, 200)

    assert {:ok, _, _} = DateTime.from_iso8601(timestamp)

    saved =
      created
      |> recycle_api()
      |> api_put("/api/v2/pod/pages/#{id}/content", %{
        base_revision: 0,
        xml: "<page><p>new</p></page>"
      })

    assert %{"page" => %{"revision" => 1}} = api_response(saved, 200)

    stale =
      saved
      |> recycle_api()
      |> api_put("/api/v2/pod/pages/#{id}/content", %{base_revision: 0, xml: "<page />"})

    assert %{
             "errors" => [
               %{"code" => "revision_conflict", "meta" => %{"details" => %{"revision" => 1}}}
             ]
           } =
             api_response(stale, 409)

    read = stale |> recycle_api() |> api_get("/api/v2/pod/pages/#{id}")
    assert %{"content" => %{"content" => "<page><p>new</p></page>"}} = api_response(read, 200)
  end

  test "deleting database references returns no target metadata for visible, hidden or missing targets",
       %{conn: conn, tenant: tenant} do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    other = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, parent} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{})

    {:ok, target} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(other.uid), %{
        type: "base",
        private_owner_uid: other.uid
      })

    hidden = api_post(conn, "/api/v2/pod/pages/#{parent.id}/embeds/delete", %{refs: [target.id]})
    assert true == api_response(hidden, 200)

    missing =
      hidden
      |> recycle_api()
      |> api_post("/api/v2/pod/pages/#{parent.id}/embeds/delete", %{refs: [Ecto.UUID.generate()]})

    assert true == api_response(missing, 200)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(other.uid, target.id, %{
        grants: [%{principal_uid: uid, role: "view"}]
      })

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(uid),
               target.id,
               "node_manage"
             )

    removed =
      missing
      |> recycle_api()
      |> api_post("/api/v2/pod/pages/#{parent.id}/embeds/delete", %{refs: [target.id]})

    assert true == api_response(removed, 200)

    assert {:ok, %{page: %{deleted_at: nil}}} =
             Pages.get(Ankole.PrincipalsFixtures.actor_fixture(other.uid), target.id)
  end

  test "personal state, sharing candidates and Space agents use browser JSON values", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{})
    agent = Ankole.PrincipalsFixtures.agent_fixture(%{owner_principal_uid: uid}).principal

    Ankole.ConversationsFixtures.grant_chat(uid, agent.uid)
    {:ok, _} = Pages.space_agent(Ankole.PrincipalsFixtures.actor_fixture(uid), agent.uid, "edit")

    state =
      api_put(conn, "/api/v2/pod/pages/#{page.id}/user-state", %{
        favorite: true,
        visited: true
      })

    assert %{"user_state" => %{"favorited_at" => favorite, "visited_at" => visited}} =
             api_response(state, 200)

    assert {:ok, _, _} = DateTime.from_iso8601(favorite)
    assert {:ok, _, _} = DateTime.from_iso8601(visited)

    subjects = state |> recycle_api() |> api_get("/api/v2/pod/subjects")
    assert %{"subjects" => candidates} = api_response(subjects, 200)
    assert Enum.any?(candidates, &(&1["principal_uid"] == agent.uid and &1["kind"] == "agent"))

    sharing = subjects |> recycle_api() |> api_get("/api/v2/pod/pages/#{page.id}/sharing")
    assert %{"subjects" => subjects} = api_response(sharing, 200)
    assert Enum.any?(subjects, &(&1["principal_uid"] == agent.uid and &1["kind"] == "agent"))

    space = sharing |> recycle_api() |> api_get("/api/v2/pod/space")

    assert %{"agents" => [%{"principal_uid" => agent_uid, "kind" => "agent", "role" => "edit"}]} =
             api_response(space, 200)

    assert agent_uid == agent.uid
  end

  test "version reconciliation excludes hidden pages and the socket token identifies its Principal",
       %{conn: conn, tenant: tenant} do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    {:ok, visible} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{})
    other = Ankole.PrincipalsFixtures.human_fixture().principal

    {:ok, hidden} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(other.uid), %{
        private_owner_uid: other.uid
      })

    versions =
      api_post(conn, "/api/v2/pod/versions", %{pages: [visible.id, hidden.id], tables: []})

    assert %{"pages" => [%{"id" => id, "revision" => 0}], "tables" => []} =
             api_response(versions, 200)

    assert id == visible.id
    token = versions |> recycle_api() |> api_get("/api/v2/pod/realtime-token")
    assert %{"principal" => %{"uid" => ^uid}, "token" => signed} = api_response(token, 200)
    assert is_binary(signed)
    denied = token |> recycle_api() |> api_get("/api/v2/pod/pages/#{hidden.id}")
    assert %{"errors" => [%{"code" => "forbidden"}]} = api_response(denied, 403)
  end

  test "deleting a completed conversation through the browser keeps its saved Page", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    agent = Ankole.PrincipalsFixtures.agent_fixture(%{owner_principal_uid: uid}).principal
    Ankole.ConversationsFixtures.grant_chat(uid, agent.uid)
    id = Ankole.Kernel.gen_uuid_v7()
    message = Ankole.Kernel.gen_uuid_v7()

    created =
      api_post(conn, "/api/v2/pod/conversations", %{
        conversationID: id,
        messageID: message,
        agentUID: agent.uid,
        text: "Save this research"
      })

    assert api_response(created, 200)

    saved =
      created
      |> recycle_api()
      |> api_post("/api/v2/pod/pages", %{saved_from_message_id: message})

    assert %{"page" => %{"id" => page_id}} = api_response(saved, 200)
    busy = saved |> recycle_api() |> api_delete("/api/v2/pod/conversations/#{id}")
    assert %{"errors" => [%{"code" => "conversation_busy"}]} = api_response(busy, 409)

    Repo.with_tenant(tenant.id, fn ->
      import Ecto.Query
      event = Repo.one!(from event in Ankole.Signals.Signal, where: event.conversation_id == ^id)

      {:ok, _} =
        Repo.transact(fn ->
          Ankole.Sessions.Queue.mark_event_completed_in_tx(
            event,
            DateTime.utc_now(:microsecond)
          )
        end)
    end)

    removed = busy |> recycle_api() |> api_delete("/api/v2/pod/conversations/#{id}")
    assert api_response(removed, 200) == true
    retained = removed |> recycle_api() |> api_get("/api/v2/pod/pages/#{page_id}")
    assert %{"source_conversation" => %{"deleted" => true}} = api_response(retained, 200)
  end
end
