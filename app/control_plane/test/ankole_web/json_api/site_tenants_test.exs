defmodule AnkoleWeb.JSONAPI.SiteTenantsTest do
  @moduledoc "Checks the tenant routes of the site JSON:API."
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.Repo
  alias Ankole.Tenants.Tenant

  @media_type "application/vnd.api+json"

  setup do
    Cache.clear_for_test()
    :ok
  end

  defp v2(conn) do
    conn
    |> recycle_api()
    |> put_req_header("accept", @media_type)
    |> put_req_header("content-type", @media_type)
  end

  defp send_v2(conn, method, path, body \\ nil),
    do: dispatch(v2(conn), @endpoint, method, path, body && Jason.encode!(body))

  defp attributes(%{"data" => %{"attributes" => attributes, "id" => id}}),
    do: Map.put(attributes, "id", id)

  test "a site admin manages the tenant lifecycle", %{conn: conn, tenant: privileged} do
    conn = console_conn(conn)

    packs =
      conn |> send_v2(:get, "/api/v2/site/tenants/brain-packs") |> json_response(200)

    assert packs == Ankole.Brain.SchemaPacks.industry_packs()

    created =
      conn
      |> send_v2(:post, "/api/v2/site/tenants", %{
        data: %{
          type: "tenant",
          attributes: %{slug: "second", display_name: "Second", brain_packs: ["legal"]}
        }
      })
      |> json_response(201)

    assert %{"data" => %{"type" => "tenant"}} = created
    assert %{"id" => id, "slug" => "second", "suspended_at" => nil} = attributes(created)

    listed = conn |> send_v2(:get, "/api/v2/site/tenants") |> json_response(200)
    assert Enum.map(listed["data"], & &1["id"]) == Enum.map(Ankole.Tenants.list(), & &1.id)
    assert id in Enum.map(listed["data"], & &1["id"])

    updated =
      conn
      |> send_v2(:patch, "/api/v2/site/tenants/#{id}", %{
        data: %{type: "tenant", id: id, attributes: %{display_name: "Renamed"}}
      })
      |> json_response(200)

    assert %{"display_name" => "Renamed", "slug" => "second"} = attributes(updated)

    suspended =
      conn |> send_v2(:post, "/api/v2/site/tenants/#{id}/suspension") |> json_response(201)

    assert %{"suspended_at" => suspended_at} = attributes(suspended)
    refute is_nil(suspended_at)

    resumed =
      conn |> send_v2(:delete, "/api/v2/site/tenants/#{id}/suspension") |> json_response(200)

    assert %{"suspended_at" => nil} = attributes(resumed)

    privileged_id = privileged.id

    assert %{"id" => ^privileged_id} =
             conn
             |> send_v2(:get, "/api/v2/site/privileged-tenant")
             |> json_response(200)
             |> attributes()

    response =
      conn
      |> send_v2(:post, "/api/v2/site/tenants/#{privileged_id}/suspension")
      |> json_response(409)

    assert %{"errors" => [%{"code" => "privileged_tenant_protected"}]} = response

    deleting = conn |> send_v2(:delete, "/api/v2/site/tenants/#{id}") |> json_response(200)
    assert %{"deleting_at" => deleting_at} = attributes(deleting)
    refute is_nil(deleting_at)
    assert Repo.get!(Tenant, id).deleting_at

    response =
      conn
      |> send_v2(:patch, "/api/v2/site/tenants/#{id}", %{
        data: %{type: "tenant", id: id, attributes: %{display_name: "Too late"}}
      })
      |> json_response(409)

    assert %{"errors" => [%{"code" => "tenant_deleting"}]} = response

    missing = Ecto.UUID.generate()

    response =
      conn |> send_v2(:post, "/api/v2/site/tenants/#{missing}/suspension") |> json_response(404)

    assert %{"errors" => [%{"code" => "not_found"}]} = response
  end

  test "a rejected tenant field names its attribute", %{conn: conn} do
    conn = console_conn(conn)

    response =
      conn
      |> send_v2(:post, "/api/v2/site/tenants", %{
        data: %{type: "tenant", attributes: %{slug: "Not A Slug", display_name: "Bad"}}
      })

    assert response.status in [400, 422]

    assert %{"errors" => [%{"source" => %{"pointer" => "/data/attributes/slug"}} | _]} =
             Jason.decode!(response.resp_body)

    refute Repo.get_by(Tenant, display_name: "Bad")
  end

  test "a site admin transfers site administration to a tenant", %{conn: conn} do
    conn = console_conn(conn)
    {:ok, target} = Ankole.Tenants.create(%{slug: "target", display_name: "Target"})
    admin = Repo.with_tenant(target.id, fn -> human_fixture().principal end)

    response =
      conn
      |> send_v2(:patch, "/api/v2/site/privileged-tenant", %{
        data: %{
          type: "tenant",
          attributes: %{tenant_id: target.id, site_admin_uid: admin.uid}
        }
      })
      |> json_response(200)

    target_id = target.id
    assert %{"id" => ^target_id} = attributes(response)
    assert {:ok, %Tenant{id: ^target_id}} = Ankole.Tenants.privileged()
  end

  test "a site admin creates two same-named Agents and each data context sees only its own", %{
    conn: conn,
    tenant: first
  } do
    {auth, admin_uid} = console_conn_with_principal(conn)
    provider = worker_provider_fixture()

    second_id =
      auth
      |> send_v2(:post, "/api/v2/site/tenants", %{
        data: %{type: "tenant", attributes: %{slug: "second", display_name: "Second"}}
      })
      |> json_response(201)
      |> get_in(["data", "id"])

    first_owner =
      Repo.with_tenant(first.id, fn -> human_fixture(%{email: "owner@example.test"}).principal end)

    second_owner =
      Repo.with_tenant(second_id, fn ->
        human_fixture(%{email: "owner@example.test"}).principal
      end)

    create = fn tenant_id, owner ->
      auth
      |> v2()
      |> put_req_header("x-ankole-tenant", tenant_id)
      |> post(
        "/api/v2/agents",
        Jason.encode!(%{
          data: %{
            "handle" => "operator",
            "display_name" => "Operator",
            "role" => "Research",
            "owner_principal_uid" => owner.uid,
            "worker_provider_id" => provider.provider_id
          }
        })
      )
      |> json_response(201)
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
      |> v2()
      |> put_req_header("x-ankole-tenant", second_id)
      |> get("/api/v2/agents")

    assert %{"data" => [%{"id" => right_uid}]} = json_response(response, 200)
    assert right_uid == right["uid"]

    response =
      auth
      |> v2()
      |> put_req_header("x-ankole-tenant", second_id)
      |> get("/api/v2/agents/" <> left["uid"])

    assert [%{"code" => "not_found"}] = json_response(response, 404)["errors"]

    # Simulate reuse of the HTTP process after a request for the other tenant.
    Repo.put_tenant_id(second_id)
    response = auth |> v2() |> get("/api/v2/agents")
    assert %{"data" => [%{"id" => left_uid}]} = json_response(response, 200)
    assert left_uid == left["uid"]
  end

  test "an invalid data context is rejected while site resources ignore that header", %{
    conn: conn
  } do
    auth = console_conn(conn)

    response =
      auth
      |> recycle_api()
      |> put_req_header("x-ankole-tenant", "not-a-uuid")
      |> get("/api/v2/console-readiness")

    assert %{"error" => %{"code" => "data_tenant_unavailable"}} = json_response(response, 404)

    response =
      auth
      |> v2()
      |> put_req_header("x-ankole-tenant", "not-a-uuid")
      |> get("/api/v2/site/tenants")

    assert %{"data" => [_ | _]} = json_response(response, 200)
  end
end
