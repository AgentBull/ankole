defmodule AnkoleWeb.PodMovePermissionsControllerTest do
  use AnkoleWeb.ConnCase, async: false
  alias Ankole.Pod.Pages

  setup do
    allow_cache_database_access()
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  test "an editor gets 403 for a changed audience and can move after policies agree", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = console_conn_with_principal(conn)
    Ankole.Repo.put_tenant_id(tenant.id)
    owner = Ankole.PrincipalsFixtures.human_fixture().principal
    viewer = Ankole.PrincipalsFixtures.human_fixture().principal
    {:ok, left} = Pages.create(owner.uid, %{private_owner_uid: owner.uid})
    {:ok, right} = Pages.create(owner.uid, %{private_owner_uid: owner.uid})
    grants = [%{principal_uid: uid, role: "edit"}]
    with_viewer = grants ++ [%{principal_uid: viewer.uid, role: "view"}]
    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(owner.uid, left.id, %{grants: with_viewer})
    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(owner.uid, right.id, %{grants: grants})
    {:ok, page} = Pages.create(owner.uid, %{parent_id: left.id})

    rejected = post(conn, "/.internal-apis/pod/pages/#{page.id}/move", %{parent_id: right.id})
    assert %{"error" => %{"code" => "move_requires_manage"}} = json_response(rejected, 403)
    assert {:ok, %{parent_id: original}} = Pages.fetch(page.id)
    assert original == left.id

    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(owner.uid, right.id, %{grants: with_viewer})

    moved =
      rejected
      |> recycle_api()
      |> post("/.internal-apis/pod/pages/#{page.id}/move", %{parent_id: right.id})

    assert %{"page" => %{"id" => id, "parent_id" => destination}} = json_response(moved, 200)
    assert id == page.id
    assert destination == right.id
    assert {:error, :forbidden} = Pages.authorize(uid, page.id, "page_manage")
  end
end
