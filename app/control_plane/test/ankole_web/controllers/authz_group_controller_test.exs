defmodule AnkoleWeb.AuthZGroupControllerTest do
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
      |> get(~p"/api/v1/principal-groups")

    assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401)
  end

  test "group lifecycle: create, list with counts, show, update, delete", %{conn: conn} do
    conn = bearer_conn(conn)
    name = "workspace_admins_#{System.unique_integer([:positive])}"

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/principal-groups", %{
        "name" => String.upcase(name),
        "display_name" => "Workspace Admins",
        "description" => "operators"
      })

    assert %{"principal_group" => created} = json_response(conn, 200)
    assert created["name"] == name
    assert created["kind"] == "static"
    assert created["domain"] == "operator"
    assert created["built_in"] == false

    %{principal: member} = human_fixture(%{uid: unique_uid("group-member")})
    assert {:ok, _membership} = AuthZ.add_principal_to_group(member.uid, name)

    assert {:ok, _grant} =
             AuthZ.create_permission_grant(%{
               group_name: name,
               resource_pattern: "workspace:**",
               action: "read"
             })

    conn = conn |> recycle_api() |> get(~p"/api/v1/principal-groups")
    assert %{"principal_groups" => groups} = json_response(conn, 200)
    listed = Enum.find(groups, &(&1["name"] == name))
    assert listed["member_count"] == 1
    assert listed["grant_count"] == 1
    assert Enum.any?(groups, &(&1["name"] == "admin" and &1["built_in"]))

    conn = conn |> recycle_api() |> get(~p"/api/v1/principal-groups/#{name}")
    assert %{"principal_group" => fetched} = json_response(conn, 200)
    assert fetched["display_name"] == "Workspace Admins"

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/principal-groups/#{name}", %{
        "display_name" => "Renamed Admins"
      })

    assert %{"principal_group" => updated} = json_response(conn, 200)
    assert updated["display_name"] == "Renamed Admins"
    assert updated["name"] == name
    assert updated["kind"] == "static"

    conn = conn |> recycle_api() |> delete(~p"/api/v1/principal-groups/#{name}")
    assert %{"error" => %{"code" => "group_has_grants"}} = json_response(conn, 409)

    assert {:ok, [grant]} = AuthZ.list_group_grants(name)
    assert {:ok, _deleted} = AuthZ.delete_permission_grant(grant.id)

    conn = conn |> recycle_api() |> delete(~p"/api/v1/principal-groups/#{name}")
    assert %{"principal_group" => %{"name" => ^name}} = json_response(conn, 200)

    conn = conn |> recycle_api() |> get(~p"/api/v1/principal-groups/#{name}")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "create validates kind shape and name uniqueness", %{conn: conn} do
    conn = bearer_conn(conn)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/principal-groups", %{
        "name" => "broken_computed_#{System.unique_integer([:positive])}",
        "display_name" => "Broken Computed",
        "kind" => "computed"
      })

    assert %{"error" => %{"code" => "validation_failed", "details" => details}} =
             json_response(conn, 422)

    assert Enum.any?(details, &(&1["path"] == "computed_condition"))

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/principal-groups", %{
        "name" => "bad_condition_#{System.unique_integer([:positive])}",
        "display_name" => "Bad Condition",
        "kind" => "computed",
        "computed_condition" => "principal."
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/principal-groups", %{
        "name" => "admin",
        "display_name" => "Duplicate Admin"
      })

    assert %{"error" => %{"code" => "validation_failed", "details" => details}} =
             json_response(conn, 422)

    assert Enum.any?(details, &(&1["path"] == "name"))
  end

  test "built-in groups reject delete and keep their computed condition", %{conn: conn} do
    conn = bearer_conn(conn)

    conn = conn |> recycle_api() |> delete(~p"/api/v1/principal-groups/admin")
    assert %{"error" => %{"code" => "built_in_group"}} = json_response(conn, 409)

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/principal-groups/all_humans", %{
        "computed_condition" => ~s(principal.type == "agent")
      })

    assert %{"principal_group" => updated} = json_response(conn, 200)

    assert updated["computed_condition"] ==
             ~s(principal.type == "human" && principal.status == "active")
  end

  test "static membership roundtrip and computed or directory groups reject manual edits", %{
    conn: conn
  } do
    conn = bearer_conn(conn)
    name = "readers_#{System.unique_integer([:positive])}"
    assert {:ok, _group} = AuthZ.create_principal_group(%{name: name, display_name: "Readers"})

    %{principal: member} =
      human_fixture(%{uid: unique_uid("membership-human"), display_name: "Member Human"})

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/principal-groups/#{name}/members/#{member.uid}")

    assert %{"principal_group_members" => [added]} = json_response(conn, 200)
    assert added["uid"] == member.uid
    assert added["member_since"]

    conn = conn |> recycle_api() |> get(~p"/api/v1/principal-groups/#{name}/members")
    assert %{"principal_group_members" => [listed]} = json_response(conn, 200)
    assert listed["uid"] == member.uid

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/principal-groups/#{name}/members/#{member.uid}")

    assert %{"principal_group_members" => []} = json_response(conn, 200)

    assert {:ok, computed} =
             AuthZ.create_principal_group(%{
               name: "computed_#{System.unique_integer([:positive])}",
               display_name: "Computed",
               kind: :computed,
               computed_condition: "true"
             })

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/principal-groups/#{computed.name}/members/#{member.uid}")

    assert %{"error" => %{"code" => "computed_group"}} = json_response(conn, 409)

    assert {:ok, directory} =
             AuthZ.create_principal_group(%{
               name: "directory_#{System.unique_integer([:positive])}",
               display_name: "Directory",
               domain: :directory
             })

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/principal-groups/#{directory.name}/members/#{member.uid}")

    assert %{"error" => %{"code" => "group_domain_mismatch"}} = json_response(conn, 409)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/principal-groups/#{name}/members/#{member.uid}")

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "removing the last active human admin is rejected", %{conn: conn} do
    conn = bearer_conn(conn)
    assert {:ok, [%{principal: admin}]} = AuthZ.list_group_members("admin")

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/principal-groups/admin/members/#{admin.uid}")

    assert %{"error" => %{"code" => "last_admin_member"}} = json_response(conn, 409)
  end

  test "computed group members are evaluated and preview validates conditions", %{conn: conn} do
    conn = bearer_conn(conn)

    %{principal: human} =
      human_fixture(%{uid: unique_uid("computed-member"), display_name: "Computed Member"})

    assert {:ok, computed} =
             AuthZ.create_principal_group(%{
               name: "all_humans_#{System.unique_integer([:positive])}",
               display_name: "All Humans Copy",
               kind: :computed,
               computed_condition: ~s(principal.type == "human")
             })

    conn = conn |> recycle_api() |> get(~p"/api/v1/principal-groups/#{computed.name}/members")

    assert %{"principal_group_members" => members} = json_response(conn, 200)
    assert Enum.any?(members, &(&1["uid"] == human.uid))
    assert Enum.all?(members, &(&1["member_since"] == nil))

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/principal-groups/computed-member-previews", %{
        "condition" => ~s(principal.uid == "#{human.uid}")
      })

    assert %{"principal_group_members" => [previewed]} = json_response(conn, 200)
    assert previewed["uid"] == human.uid

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/principal-groups/computed-member-previews", %{
        "condition" => "principal."
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
  end

  test "group grants are listed for the group detail page", %{conn: conn} do
    conn = bearer_conn(conn)
    name = "grantees_#{System.unique_integer([:positive])}"
    assert {:ok, _group} = AuthZ.create_principal_group(%{name: name, display_name: "Grantees"})

    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               group_name: name,
               resource_pattern: "workspace:**",
               action: "read",
               description: "read workspaces"
             })

    conn = conn |> recycle_api() |> get(~p"/api/v1/principal-groups/#{name}/grants")

    assert %{"permission_grants" => [listed]} = json_response(conn, 200)
    assert listed["id"] == grant.id
    assert listed["resource_pattern"] == "workspace:**"
    assert listed["action"] == "read"
  end
end
