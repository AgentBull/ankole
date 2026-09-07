defmodule AnkoleWeb.PrincipalControllerTest do
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

  test "admin lists active human and agent principals", %{conn: conn} do
    human = human_fixture(%{uid: unique_uid("console-human"), display_name: "Console Human"})
    agent = agent_fixture(%{uid: unique_uid("console-agent"), display_name: "Console Agent"})
    disabled = human_fixture(%{uid: unique_uid("console-disabled")})

    assert {:ok, _principal} = Ankole.Principals.disable_principal(disabled.principal.uid)

    conn = conn |> bearer_conn() |> get(~p"/api/v1/principals")
    assert %{"principals" => principals} = json_response(conn, 200)

    assert %{
             "uid" => human_uid,
             "type" => "human",
             "status" => "active",
             "display_name" => "Console Human"
           } = Enum.find(principals, &(&1["uid"] == human.principal.uid))

    assert human_uid == human.principal.uid

    assert %{
             "uid" => agent_uid,
             "type" => "agent",
             "status" => "active",
             "display_name" => "Console Agent"
           } = Enum.find(principals, &(&1["uid"] == agent.principal.uid))

    assert agent_uid == agent.principal.uid
    refute Enum.any?(principals, &(&1["uid"] == disabled.principal.uid))
    assert Enum.map(principals, & &1["uid"]) == Enum.sort(Enum.map(principals, & &1["uid"]))
  end

  test "admin can include disabled principals for audits", %{conn: conn} do
    disabled = agent_fixture(%{uid: unique_uid("audit-disabled")})
    assert {:ok, _} = Ankole.Principals.disable_principal(disabled.principal.uid)
    conn = bearer_conn(conn)

    for {include_disabled, expected} <- [{true, true}, {false, false}] do
      response =
        conn
        |> recycle_api()
        |> get(~p"/api/v1/principals?#{%{include_disabled: include_disabled}}")
        |> json_response(200)

      found = Enum.find(response["principals"], &(&1["uid"] == disabled.principal.uid))
      assert found != nil == expected
      if found, do: assert(found["status"] == "disabled")
    end
  end

  test "admin reads one principal with its groups and direct grants", %{conn: conn} do
    conn = bearer_conn(conn)

    %{principal: human} =
      human_fixture(%{uid: unique_uid("principal-detail"), display_name: "Detail Human"})

    assert {:ok, group} =
             AuthZ.create_principal_group(%{
               name: "detail_group_#{System.unique_integer([:positive])}",
               display_name: "Detail Group"
             })

    assert {:ok, _membership} = AuthZ.add_principal_to_group(human.uid, group.id)

    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: human.uid,
               resource_pattern: "workspace:**",
               action: "read"
             })

    conn = conn |> recycle_api() |> get(~p"/api/v1/principals/#{human.uid}")
    assert %{"principal" => fetched} = json_response(conn, 200)
    assert fetched["uid"] == human.uid
    assert fetched["display_name"] == "Detail Human"

    conn = conn |> recycle_api() |> get(~p"/api/v1/principals/#{human.uid}/groups")
    assert %{"principal_groups" => groups} = json_response(conn, 200)
    assert Enum.map(groups, & &1["name"]) == [group.name]

    conn = conn |> recycle_api() |> get(~p"/api/v1/principals/#{human.uid}/grants")
    assert %{"permission_grants" => [listed]} = json_response(conn, 200)
    assert listed["id"] == grant.id
    assert listed["principal_uid"] == human.uid

    conn = conn |> recycle_api() |> get(~p"/api/v1/principals/missing-principal")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  describe "local user management" do
    test "every local-account write requires an enabled local provider", %{conn: conn} do
      conn = bearer_conn(conn)
      %{principal: human} = human_fixture()

      create_conn =
        conn
        |> recycle_api()
        |> post(~p"/api/v1/principals", %{"email" => "someone@example.com"})

      assert %{"error" => %{"code" => "local_identity_provider_disabled"}} =
               json_response(create_conn, 409)

      reset_conn =
        conn
        |> recycle_api()
        |> post(~p"/api/v1/principals/#{human.uid}/local-password-resets", %{})

      assert %{"error" => %{"code" => "local_identity_provider_disabled"}} =
               json_response(reset_conn, 409)

      update_conn =
        conn
        |> recycle_api()
        |> patch(~p"/api/v1/principals/#{human.uid}", %{"display_name" => "Renamed"})

      assert %{"error" => %{"code" => "local_identity_provider_disabled"}} =
               json_response(update_conn, 409)
    end

    test "creates a local user with a one-time initial password", %{conn: conn} do
      conn = bearer_conn(conn)
      enable_local_provider()

      conn =
        conn
        |> recycle_api()
        |> post(~p"/api/v1/principals", %{
          "email" => "New.User@Example.com",
          "display_name" => "New User",
          "must_change_password" => true
        })

      assert %{"principal" => principal, "initial_password" => initial_password} =
               json_response(conn, 200)

      assert principal["uid"] == "new.user@example.com"
      assert principal["email"] == "new.user@example.com"
      assert principal["display_name"] == "New User"
      assert principal["has_external_identity"] == false
      assert principal["local_credential"] == %{"status" => "must_change"}
      assert String.length(initial_password) == 16

      duplicate_conn =
        conn
        |> recycle_api()
        |> post(~p"/api/v1/principals", %{"email" => "new.user@example.com"})

      assert %{"error" => %{"code" => "email_taken"}} = json_response(duplicate_conn, 422)
    end

    test "resets a local password for a human with an email", %{conn: conn} do
      conn = bearer_conn(conn)
      enable_local_provider()
      %{principal: human, human_user: human_user} = human_fixture()

      conn =
        conn
        |> recycle_api()
        |> post(~p"/api/v1/principals/#{human.uid}/local-password-resets", %{
          "must_change_password" => false
        })

      assert %{"initial_password" => initial_password} = json_response(conn, 200)

      assert {:ok, %{must_change_password: false}} =
               Ankole.IdentityProviders.LocalPassword.authenticate(
                 human_user.email,
                 initial_password
               )

      %{principal: agent} = agent_fixture()

      agent_conn =
        conn
        |> recycle_api()
        |> post(~p"/api/v1/principals/#{agent.uid}/local-password-resets", %{})

      assert %{"error" => %{"code" => "not_human"}} = json_response(agent_conn, 422)
    end

    test "resetting a password for an unknown principal returns 404", %{conn: conn} do
      conn = bearer_conn(conn)
      enable_local_provider()

      conn =
        conn
        |> recycle_api()
        |> post(~p"/api/v1/principals/no-such-user/local-password-resets", %{})

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "edits the display name and email of a locally managed user", %{conn: conn} do
      conn = bearer_conn(conn)
      enable_local_provider()
      %{principal: human} = human_fixture()

      conn =
        conn
        |> recycle_api()
        |> patch(~p"/api/v1/principals/#{human.uid}", %{
          "display_name" => "Renamed User",
          "email" => "Renamed@Example.com"
        })

      assert %{"principal" => principal} = json_response(conn, 200)
      assert principal["display_name"] == "Renamed User"
      assert principal["email"] == "renamed@example.com"
    end

    test "allows an email change even when an external identity is attached", %{conn: conn} do
      conn = bearer_conn(conn)
      enable_local_provider()
      %{principal: human} = human_fixture()

      {:ok, _identity} =
        Ankole.Principals.create_external_identity(%{
          principal_uid: human.uid,
          provider: "lark",
          external_id: "ou-#{System.unique_integer([:positive])}"
        })

      conn =
        conn
        |> recycle_api()
        |> patch(~p"/api/v1/principals/#{human.uid}", %{"email" => "updated@example.com"})

      assert %{"principal" => principal} = json_response(conn, 200)
      assert principal["email"] == "updated@example.com"
    end
  end

  defp enable_local_provider do
    {:ok, _provider} =
      Ankole.IdentityProviders.save_provider("local-main", "local", %{}, true)

    :ok
  end
end
