defmodule AnkoleWeb.HumanAccessControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{AuthZ, Principals, Repo}
  alias Ankole.Principals.HumanAccess
  alias Ankole.Principals.WorkAccess

  setup do
    Ankole.AppConfigure.Registry.clear_for_test()
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  test "the Console requires identity and current permission review and never revives old credentials",
       %{conn: conn, tenant: tenant} do
    {conn, admin_uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    %{principal: person} = human_fixture()
    uid = person.uid
    body = %{reason: "Confirmed departure", operation_id: "console-disable"}

    disabled =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/principals/#{uid}/access-disables", body)
      |> json_response(200)

    assert disabled["status"] == "disabled"
    assert disabled["access_version"] == person.access_version + 1
    assert [%{"source" => "manual", "id" => restriction_id}] = disabled["restrictions"]
    assert [%{"state" => "available"}] = disabled["cleanup_jobs"]

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/principals/#{uid}/access-disables", body)
           |> json_response(200) == disabled

    restore = %{
      reason: "Verified return",
      operation_id: "console-restore",
      review_fingerprint: disabled["permission_review"]["fingerprint"],
      identity_verified: true
    }

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/principals/#{uid}/access-restorations", restore)
           |> json_response(409)
           |> get_in(["error", "code"]) == "active_restrictions"

    clear = %{reason: "Departure restriction no longer applies", operation_id: "clear"}

    assert conn
           |> recycle_api()
           |> post(
             ~p"/api/v1/principals/#{uid}/access-restrictions/#{restriction_id}/clear",
             clear
           )
           |> json_response(200)
           |> Map.fetch!("status") == "disabled"

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/principals/#{uid}/access-restorations", %{
             restore
             | identity_verified: false
           })
           |> json_response(409)
           |> get_in(["error", "code"]) == "identity_review_required"

    Repo.put_tenant_id(tenant.id)

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: uid,
        resource_pattern: "workspace:**",
        action: "read"
      })

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/principals/#{uid}/access-restorations", restore)
           |> json_response(409)
           |> get_in(["error", "code"]) == "permission_review_changed"

    state =
      conn |> recycle_api() |> get(~p"/api/v1/principals/#{uid}/access") |> json_response(200)

    assert state["permission_review"]["permissions"]["grants"] != []
    restore = %{restore | review_fingerprint: state["permission_review"]["fingerprint"]}

    restored =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/principals/#{uid}/access-restorations", restore)
      |> json_response(200)

    assert restored["status"] == "active"
    Repo.put_tenant_id(tenant.id)
    assert {:error, :human_access_revoked} = HumanAccess.check(uid, person.access_version)

    assert Enum.any?(
             restored["history"],
             &(&1["action"] == "restore" and
                 &1["actor"] == %{"tenant_id" => tenant.id, "uid" => admin_uid} and
                 &1["details"]["identity_verified"] == true)
           )

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/principals/#{uid}/access-restorations", restore)
           |> json_response(200) == restored
  end

  test "read and mutations require a live Console administrator", %{conn: conn, tenant: tenant} do
    %{principal: person} = human_fixture()
    assert conn |> get(~p"/api/v1/principals/#{person.uid}/access") |> json_response(401)
    {admin, admin_uid} = console_conn_with_principal(conn)

    assert admin
           |> recycle_api()
           |> post(~p"/api/v1/principals/#{admin_uid}/access-disables", %{
             reason: "self",
             operation_id: "self"
           })
           |> json_response(409)
           |> get_in(["error", "code"]) == "cannot_disable_self"

    Repo.put_tenant_id(tenant.id)

    assert {:ok, _} =
             HumanAccess.restrict_from_provider(admin_uid, "lark-main", "departure", "event")

    assert admin
           |> recycle_api()
           |> get(~p"/api/v1/principals/#{person.uid}/access")
           |> json_response(401)
  end

  test "unknown work needs explicit service approval and cannot be reclassified", %{
    conn: conn,
    tenant: tenant
  } do
    conn = console_conn(conn)
    Repo.put_tenant_id(tenant.id)
    %{principal: agent} = agent_fixture()

    {:ok, event} =
      Ankole.Signals.accept(%{
        source: "test://work-review",
        id: "review",
        target: %{agent_uid: agent.uid, session_id: "test"},
        type: "test.work",
        data: %{}
      })

    assert event.authorization_kind == "review_required"
    response = conn |> recycle_api() |> get(~p"/api/v1/work-access-reviews") |> json_response(200)
    assert [%{"id" => id, "kind" => "signal"}] = response["work"]

    body = %{
      kind: "signal",
      id: id,
      authorization_kind: "human",
      reason: "Known independent job"
    }

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/work-access-reviews", body)
           |> json_response(409)
           |> get_in(["error", "code"]) == "human_uid_required"

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/work-access-reviews", %{body | authorization_kind: "service"})
           |> json_response(200) == %{"work" => []}

    Repo.put_tenant_id(tenant.id)

    assert WorkAccess.fields(Repo.get!(Ankole.Signals.Signal, event.id)) ==
             WorkAccess.service()

    assert conn
           |> recycle_api()
           |> post(~p"/api/v1/work-access-reviews", %{body | authorization_kind: "service"})
           |> json_response(409)

    Repo.put_tenant_id(tenant.id)
    assert {:ok, %{status: :active}} = Principals.get_principal(agent.uid)
  end
end
