defmodule AnkoleWeb.PodPageControllerTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod
  import OpenApiSpex.TestAssertions
  alias Ankole.Pod.Pages
  alias Ankole.Repo

  setup do
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  test "page lists carry the same current role as individual reads for inherited and restricted pages",
       %{conn: conn, tenant: tenant} do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    other = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, space} = Pages.create(uid, %{title: "Admin space"})
    {:ok, own_private} = Pages.create(uid, %{title: "Own Private", private_owner_uid: uid})

    {:ok, private} =
      Pages.create(other.uid, %{title: "Shared Private", private_owner_uid: other.uid})

    {:ok, child} = Pages.create(other.uid, %{title: "Inherited editor", parent_id: private.id})
    {:ok, restricted} = Pages.create(other.uid, %{title: "Direct viewer", parent_id: private.id})

    {:ok, hidden} =
      Pages.create(other.uid, %{title: "Hidden Private", private_owner_uid: other.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(other.uid, private.id, %{
        grants: [%{principal_uid: uid, role: "edit"}]
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(other.uid, restricted.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: uid, role: "view"}]
      })

    {:ok, _} = Pages.state(uid, child.id, %{favorite: true, visited: true})
    {:ok, _} = Pages.set_space(uid, "view")

    expected = %{
      space.id => "manage",
      own_private.id => "manage",
      private.id => "edit",
      child.id => "edit",
      restricted.id => "view"
    }

    for scope <- ~w(all space private shared recent favorites) do
      response = conn |> recycle_api() |> get("/.internal-apis/pod/pages", %{scope: scope})
      assert %{"pages" => pages} = json_response(response, 200)
      refute Enum.any?(pages, &(&1["id"] == hidden.id))

      for page <- pages do
        assert_schema(page, "PodPage", AnkoleWeb.InternalAPISpec.spec())
        assert page["role"] == Map.fetch!(expected, page["id"])
        assert {:ok, %{role: role}} = Pages.get(uid, page["id"])
        assert page["role"] == role
      end
    end

    {:ok, _} = Pages.delete(uid, space.id)
    response = conn |> recycle_api() |> get("/.internal-apis/pod/pages", %{scope: "trash"})
    assert %{"pages" => [%{"id" => id, "role" => "manage"}]} = json_response(response, 200)
    assert id == space.id
  end

  test "browser writes retain the newer document when a stale save conflicts", %{conn: conn} do
    {conn, _uid} = console_conn_with_principal(conn)
    created = post(conn, "/.internal-apis/pod/pages", %{})

    assert %{
             "page" => %{
               "id" => id,
               "type" => "doc",
               "title" => "",
               "revision" => 0,
               "created_at" => timestamp
             }
           } =
             json_response(created, 200)

    assert {:ok, _, _} = DateTime.from_iso8601(timestamp)

    saved =
      created
      |> recycle_api()
      |> put("/.internal-apis/pod/pages/#{id}/content", %{
        base_revision: 0,
        xml: "<page><p>new</p></page>"
      })

    assert %{"page" => %{"revision" => 1}} = json_response(saved, 200)

    stale =
      saved
      |> recycle_api()
      |> put("/.internal-apis/pod/pages/#{id}/content", %{base_revision: 0, xml: "<page />"})

    assert %{"error" => %{"code" => "revision_conflict"}, "revision" => 1} =
             json_response(stale, 409)

    read = stale |> recycle_api() |> get("/.internal-apis/pod/pages/#{id}")
    assert %{"content" => %{"xml" => "<page><p>new</p></page>"}} = json_response(read, 200)
  end

  test "deleting database references returns no target metadata for visible, hidden or missing targets",
       %{conn: conn, tenant: tenant} do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    other = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, parent} = Pages.create(uid, %{})
    {:ok, target} = Pages.create(other.uid, %{type: "database", private_owner_uid: other.uid})

    hidden = post(conn, "/.internal-apis/pod/pages/#{parent.id}/embeds/#{target.id}/delete", %{})
    assert %{} == json_response(hidden, 200)

    missing =
      hidden
      |> recycle_api()
      |> post("/.internal-apis/pod/pages/#{parent.id}/embeds/#{Ecto.UUID.generate()}/delete", %{})

    assert %{} == json_response(missing, 200)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(other.uid, target.id, %{
        grants: [%{principal_uid: uid, role: "view"}]
      })

    assert {:error, :forbidden} = Pages.authorize(uid, target.id, "page_manage")

    removed =
      missing
      |> recycle_api()
      |> post("/.internal-apis/pod/pages/#{parent.id}/embeds/#{target.id}/delete", %{})

    assert %{} == json_response(removed, 200)
    assert {:ok, %{page: %{deleted_at: nil}}} = Pages.get(other.uid, target.id)
  end

  test "personal state, sharing candidates and Space agents use browser JSON values", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    {:ok, page} = Pages.create(uid, %{})
    agent = Ankole.PrincipalsFixtures.agent_fixture(%{owner_principal_uid: uid}).principal
    {:ok, _} = Pages.space_agent(uid, agent.uid, "edit")

    state =
      put(conn, "/.internal-apis/pod/pages/#{page.id}/user-state", %{
        favorite: true,
        visited: true
      })

    assert %{"user_state" => %{"favorited_at" => favorite, "visited_at" => visited}} =
             json_response(state, 200)

    assert {:ok, _, _} = DateTime.from_iso8601(favorite)
    assert {:ok, _, _} = DateTime.from_iso8601(visited)

    subjects = state |> recycle_api() |> get("/.internal-apis/pod/subjects")
    assert %{"subjects" => candidates} = json_response(subjects, 200)
    assert Enum.any?(candidates, &(&1["principal_uid"] == agent.uid and &1["kind"] == "agent"))

    sharing = subjects |> recycle_api() |> get("/.internal-apis/pod/pages/#{page.id}/sharing")
    assert %{"subjects" => subjects} = json_response(sharing, 200)
    assert Enum.any?(subjects, &(&1["principal_uid"] == agent.uid and &1["kind"] == "agent"))

    space = sharing |> recycle_api() |> get("/.internal-apis/pod/space")

    assert %{"agents" => [%{"principal_uid" => agent_uid, "kind" => "agent", "role" => "edit"}]} =
             json_response(space, 200)

    assert agent_uid == agent.uid
  end

  test "version reconciliation excludes hidden pages and the socket token identifies its Principal",
       %{conn: conn, tenant: tenant} do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    {:ok, visible} = Pages.create(uid, %{})
    other = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, hidden} = Pages.create(other.uid, %{private_owner_uid: other.uid})

    versions =
      post(conn, "/.internal-apis/pod/versions", %{pages: [visible.id, hidden.id], tables: []})

    assert %{"pages" => [%{"id" => id, "revision" => 0}], "tables" => []} =
             json_response(versions, 200)

    assert id == visible.id
    token = versions |> recycle_api() |> get("/.internal-apis/pod/realtime-token")
    assert %{"principal" => %{"uid" => ^uid}, "token" => signed} = json_response(token, 200)
    assert is_binary(signed)
    denied = token |> recycle_api() |> get("/.internal-apis/pod/pages/#{hidden.id}")
    assert %{"error" => %{"code" => "forbidden"}} = json_response(denied, 403)
  end

  test "deleting a completed conversation through the browser keeps its saved Page", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    agent = Ankole.PrincipalsFixtures.agent_fixture(%{owner_principal_uid: uid}).principal
    id = Ankole.Kernel.gen_uuid_v7()
    message = Ankole.Kernel.gen_uuid_v7()

    created =
      post(conn, "/.internal-apis/pod/conversations", %{
        conversationID: id,
        messageID: message,
        agentUID: agent.uid,
        text: "Save this research"
      })

    assert json_response(created, 200)

    saved =
      created
      |> recycle_api()
      |> post("/.internal-apis/pod/pages", %{saved_from_message_id: message})

    assert %{"page" => %{"id" => page_id}} = json_response(saved, 200)
    busy = saved |> recycle_api() |> delete("/.internal-apis/pod/conversations/#{id}")
    assert %{"error" => %{"code" => "conversation_busy"}} = json_response(busy, 409)

    Repo.with_tenant(tenant.id, fn ->
      import Ecto.Query
      event = Repo.one!(from event in Ankole.Signals.Signal, where: event.conversation_id == ^id)

      {:ok, _} =
        Repo.transact(fn repo ->
          Ankole.Sessions.Queue.mark_event_completed_in_tx(
            repo,
            event,
            DateTime.utc_now(:microsecond)
          )
        end)
    end)

    removed = busy |> recycle_api() |> delete("/.internal-apis/pod/conversations/#{id}")
    assert response(removed, 204) == ""
    retained = removed |> recycle_api() |> get("/.internal-apis/pod/pages/#{page_id}")
    assert %{"source_conversation" => %{"deleted" => true}} = json_response(retained, 200)
  end
end
