defmodule AnkoleWeb.PermissionGrantControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "requests without a bearer token are rejected", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/permission-grants", %{})

    assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401)
  end

  test "grant lifecycle for a principal owner and a group owner", %{conn: conn} do
    conn = bearer_conn(conn)
    %{principal: owner} = human_fixture(%{uid: unique_uid("grant-owner")})

    assert {:ok, group} =
             AuthZ.create_principal_group(%{
               name: "grant_group_#{System.unique_integer([:positive])}",
               display_name: "Grant Group"
             })

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/permission-grants", %{
        "principal_uid" => owner.uid,
        "resource_pattern" => "workspace:**",
        "action" => "read",
        "description" => "direct read"
      })

    assert %{"permission_grant" => direct} = json_response(conn, 200)
    assert direct["principal_uid"] == owner.uid
    assert direct["group_id"] == nil
    assert direct["condition"] == "true"

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/permission-grants", %{
        "group_name" => group.name,
        "resource_pattern" => "chat:channel:*",
        "action" => "update",
        "condition" => ~s(context.request.surface == "console_rest")
      })

    assert %{"permission_grant" => grouped} = json_response(conn, 200)
    assert grouped["group_id"] == group.id
    assert grouped["principal_uid"] == nil

    conn = conn |> recycle_api() |> get(~p"/api/v1/permission-grants/#{direct["id"]}")
    assert %{"permission_grant" => fetched} = json_response(conn, 200)
    assert fetched["description"] == "direct read"

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/permission-grants/#{direct["id"]}", %{
        "action" => "update",
        "condition" => "false"
      })

    assert %{"permission_grant" => updated} = json_response(conn, 200)
    assert updated["action"] == "update"
    assert updated["condition"] == "false"
    assert updated["principal_uid"] == owner.uid
    assert updated["group_id"] == nil

    conn = conn |> recycle_api() |> delete(~p"/api/v1/permission-grants/#{direct["id"]}")
    assert %{"permission_grant" => %{"id" => deleted_id}} = json_response(conn, 200)
    assert deleted_id == direct["id"]

    conn = conn |> recycle_api() |> get(~p"/api/v1/permission-grants/#{direct["id"]}")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "create validates owner shape, rule syntax, and owner existence", %{conn: conn} do
    conn = bearer_conn(conn)
    %{principal: owner} = human_fixture(%{uid: unique_uid("shape-owner")})

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/permission-grants", %{
        "resource_pattern" => "workspace:**",
        "action" => "read"
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/permission-grants", %{
        "principal_uid" => owner.uid,
        "group_name" => "admin",
        "resource_pattern" => "workspace:**",
        "action" => "read"
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/permission-grants", %{
        "principal_uid" => owner.uid,
        "resource_pattern" => "workspace:[",
        "action" => "read"
      })

    assert %{"error" => %{"code" => "validation_failed", "details" => details}} =
             json_response(conn, 422)

    assert Enum.any?(details, &(&1["path"] == "resource_pattern"))

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/permission-grants", %{
        "principal_uid" => owner.uid,
        "resource_pattern" => "workspace:**",
        "action" => "read:write"
      })

    assert %{"error" => %{"code" => "validation_failed", "details" => details}} =
             json_response(conn, 422)

    assert Enum.any?(details, &(&1["path"] == "action"))

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/permission-grants", %{
        "group_name" => "missing_group",
        "resource_pattern" => "workspace:**",
        "action" => "read"
      })

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "deleting a malformed grant id answers not found in the console envelope", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> recycle_api()
      |> delete(~p"/api/v1/permission-grants/not-a-uuid")

    assert %{"error" => %{"code" => "not_found", "message" => message}} = json_response(conn, 404)
    assert is_binary(message)
  end
end
