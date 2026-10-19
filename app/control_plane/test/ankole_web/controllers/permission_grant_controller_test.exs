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

  test "requests without a browser session are rejected", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/permission-grants", %{})

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  test "grant lifecycle for a principal owner and a group owner", %{conn: conn} do
    conn = console_conn(conn)
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
    conn = console_conn(conn)
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
        "group_name" => "siteadmin",
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

  test "create rejects the reserved page actions for principal and group owners", %{conn: conn} do
    conn = console_conn(conn)
    %{principal: owner} = human_fixture(%{uid: unique_uid("page-action-owner")})

    assert {:ok, group} =
             AuthZ.create_principal_group(%{
               name: "page_action_group_#{System.unique_integer([:positive])}",
               display_name: "Page Action Group"
             })

    for action <- ["page_view", "page_edit", "page_manage"],
        owner_attrs <- [%{"principal_uid" => owner.uid}, %{"group_name" => group.name}] do
      conn =
        conn
        |> recycle_api()
        |> post(
          ~p"/api/v1/permission-grants",
          Map.merge(owner_attrs, %{
            "resource_pattern" => "space:engineering",
            "action" => action
          })
        )

      assert %{"error" => %{"code" => "validation_failed", "details" => details}} =
               json_response(conn, 422)

      assert Enum.any?(details, &(&1["path"] == "action"))
    end

    assert {:ok, []} = AuthZ.list_principal_grants(owner.uid)
    assert {:ok, []} = AuthZ.list_group_grants(group.id)
  end

  test "a page grant keeps its resource pattern and condition when updated", %{conn: conn} do
    conn = console_conn(conn)
    %{principal: owner} = human_fixture(%{uid: unique_uid("page-grant-owner")})

    # The Pod writes page grants through the AuthZ internal interface.
    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: owner.uid,
               resource_pattern: "space:engineering/**",
               action: "page_view",
               condition: "true",
               description: "shared space"
             })

    for attrs <- [
          %{"resource_pattern" => "**"},
          %{"condition" => "false"},
          %{"resource_pattern" => "space:engineering/**", "condition" => "true"},
          %{"resource_pattern" => "**", "description" => "kept description"}
        ] do
      conn = conn |> recycle_api() |> patch(~p"/api/v1/permission-grants/#{grant.id}", attrs)

      assert %{"error" => %{"code" => "validation_failed", "details" => details}} =
               json_response(conn, 422)

      assert details != []
    end

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/permission-grants/#{grant.id}", %{
        "description" => "shared with the team"
      })

    assert %{"permission_grant" => kept} = json_response(conn, 200)
    assert kept["action"] == "page_view"
    assert kept["resource_pattern"] == "space:engineering/**"
    assert kept["condition"] == "true"
    assert kept["description"] == "shared with the team"

    # Ordinary grants keep partial updates without an action.
    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/permission-grants", %{
        "principal_uid" => owner.uid,
        "resource_pattern" => "workspace:**",
        "action" => "read"
      })

    assert %{"permission_grant" => ordinary} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/permission-grants/#{ordinary["id"]}", %{"resource_pattern" => "**"})

    assert %{"permission_grant" => %{"resource_pattern" => "**", "action" => "read"}} =
             json_response(conn, 200)

    # A request cannot turn a page grant into an ordinary grant.
    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/permission-grants/#{grant.id}", %{
        "action" => "read",
        "resource_pattern" => "**"
      })

    assert %{"error" => %{"code" => "validation_failed", "details" => details}} =
             json_response(conn, 422)

    assert Enum.any?(details, &(&1["path"] == "action"))

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/permission-grants/#{ordinary["id"]}", %{"action" => "page_manage"})

    assert %{"error" => %{"code" => "validation_failed", "details" => details}} =
             json_response(conn, 422)

    assert Enum.any?(details, &(&1["path"] == "action"))
  end

  test "Console cannot delete grants owned by Pod sharing", %{conn: conn} do
    conn = console_conn(conn)
    %{principal: owner} = human_fixture()

    for action <- Ankole.Pod.Access.page_actions() do
      {:ok, grant} =
        AuthZ.create_permission_grant(%{
          principal_uid: owner.uid,
          resource_pattern: "pod:space:**",
          action: action
        })

      response = conn |> recycle_api() |> delete(~p"/api/v1/permission-grants/#{grant.id}")
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(response, 422)
      assert {:ok, ^grant} = AuthZ.get_permission_grant(grant.id)
    end
  end

  test "ordinary grants keep their update shape", %{conn: conn} do
    conn = console_conn(conn)
    %{principal: owner} = human_fixture(%{uid: unique_uid("ordinary-owner")})

    assert {:ok, group} =
             AuthZ.create_principal_group(%{
               name: "ordinary_group_#{System.unique_integer([:positive])}",
               display_name: "Ordinary Group"
             })

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/permission-grants", %{
        "group_name" => group.name,
        "resource_pattern" => "chat:channel:*",
        "action" => "update"
      })

    assert %{"permission_grant" => grant} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/permission-grants/#{grant["id"]}", %{
        "resource_pattern" => "chat:channel:announcements",
        "condition" => ~s(context.request.surface == "console_rest")
      })

    assert %{"permission_grant" => updated} = json_response(conn, 200)
    assert updated["action"] == "update"
    assert updated["resource_pattern"] == "chat:channel:announcements"
    assert updated["condition"] == ~s(context.request.surface == "console_rest")
    assert updated["group_id"] == group.id
    assert updated["description"] == grant["description"]
    assert updated["id"] != owner.uid
  end

  test "deleting a malformed grant id answers not found in the console envelope", %{conn: conn} do
    conn =
      conn
      |> console_conn()
      |> recycle_api()
      |> delete(~p"/api/v1/permission-grants/not-a-uuid")

    assert %{"error" => %{"code" => "not_found", "message" => message}} = json_response(conn, 404)
    assert is_binary(message)
  end
end
