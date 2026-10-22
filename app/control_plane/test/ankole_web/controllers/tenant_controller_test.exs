defmodule AnkoleWeb.TenantControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Repo
  alias Ankole.AppConfigure.Cache

  setup do
    Cache.clear_for_test()
    :ok
  end

  test "a site admin creates two same-named Agents and each data context sees only its own", %{
    conn: conn,
    tenant: first
  } do
    {auth, admin_uid} = console_conn_with_principal(conn)
    provider = worker_provider_fixture()

    response =
      auth
      |> recycle_api()
      |> post("/api/v1/site/tenants", %{
        "slug" => "second",
        "display_name" => "Second",
        "brain_packs" => []
      })

    assert %{"tenant" => %{"id" => second_id}} = json_response(response, 201)

    first_owner =
      Repo.with_tenant(first.id, fn -> human_fixture(%{email: "owner@example.test"}).principal end)

    second_owner =
      Repo.with_tenant(second_id, fn ->
        human_fixture(%{email: "owner@example.test"}).principal
      end)

    create = fn tenant_id, owner ->
      auth
      |> recycle_api()
      |> put_req_header("x-ankole-tenant", tenant_id)
      |> post("/api/v1/agents", %{
        "handle" => "operator",
        "display_name" => "Operator",
        "role" => "Research",
        "owner_principal_uid" => owner.uid,
        "worker_provider_id" => provider.provider_id
      })
      |> json_response(200)
      |> Map.fetch!("agent")
    end

    left = create.(first.id, first_owner)
    right = create.(second_id, second_owner)
    assert left["handle"] == right["handle"]
    assert left["uid"] != right["uid"]
    assert {:ok, _} = Ecto.UUID.cast(left["uid"])

    assert %{"tenant_id" => first_id, "uid" => ^admin_uid} = right["created_by"]

    assert first_id == first.id

    response =
      auth
      |> recycle_api()
      |> put_req_header("x-ankole-tenant", second_id)
      |> get("/api/v1/agents")

    assert %{"agents" => [%{"uid" => right_uid}]} = json_response(response, 200)
    assert right_uid == right["uid"]

    response =
      auth
      |> recycle_api()
      |> put_req_header("x-ankole-tenant", second_id)
      |> get("/api/v1/agents/" <> left["uid"])

    assert json_response(response, 404)["error"]["code"] == "not_found"

    # Simulate reuse of the HTTP process after a request for the other tenant.
    Repo.put_tenant_id(second_id)
    response = auth |> recycle_api() |> get("/api/v1/agents")
    assert %{"agents" => [%{"uid" => left_uid}]} = json_response(response, 200)
    assert left_uid == left["uid"]

    response =
      auth
      |> recycle_api()
      |> put_req_header("x-ankole-tenant", second_id)
      |> patch("/api/v1/agents/" <> right_uid, %{"handle" => "renamed"})

    assert %{"agent" => %{"uid" => ^right_uid, "handle" => "renamed"}} =
             json_response(response, 200)
  end

  test "an invalid data context is rejected while site resources ignore that header", %{
    conn: conn
  } do
    auth = console_conn(conn)

    response =
      auth
      |> recycle_api()
      |> put_req_header("x-ankole-tenant", "not-a-uuid")
      |> get("/api/v1/agents")

    assert %{"error" => %{"code" => "data_tenant_unavailable"}} = json_response(response, 404)

    response =
      auth
      |> recycle_api()
      |> put_req_header("x-ankole-tenant", "not-a-uuid")
      |> get("/api/v1/site/tenants")

    assert %{"tenants" => [_ | _]} = json_response(response, 200)
  end
end
