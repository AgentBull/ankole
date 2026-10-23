defmodule AnkoleWeb.JSONAPI.IdentityTest do
  @moduledoc """
  Checks the v2 JSON:API routes of Principals, principal groups, permission
  grants, and identity mapping requests.
  """
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Principals
  alias Ankole.Principals.MappingRequests
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup %{conn: conn} do
    Registry.clear_for_test()
    Cache.clear_for_test()
    {:ok, true} = Ankole.AppConfigure.put_global(SetupConfig.completed_definition(), true)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    %{conn: console_conn(conn)}
  end

  defp request(conn, method, path, body \\ nil) do
    response =
      conn
      |> recycle_api()
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> dispatch(@endpoint, method, path, body && Jason.encode!(body))

    {response.status, Jason.decode!(response.resp_body)}
  end

  defp resource(type, attributes), do: %{data: %{type: type, attributes: attributes}}

  defp error_code({_status, %{"errors" => [%{"code" => code} | _]}}), do: code

  defp enable_local_provider do
    {:ok, _provider} = Ankole.IdentityProviders.save_provider("local-main", "local", %{}, true)
    :ok
  end

  describe "authorization" do
    test "a request without a session gets the session failure" do
      response = build_conn() |> get("/api/v2/principals")
      assert %{"error" => %{"code" => "unauthorized"}} = json_response(response, 401)
    end

    test "a session without grants is refused before the action runs", %{conn: conn} do
      %{principal: human} = human_fixture()
      Repo.delete_all(from grant in AuthZ.Grant, where: grant.resource_pattern == "**")

      assert {403, %{"errors" => [%{"code" => "forbidden"}]}} =
               request(conn, :get, "/api/v2/principals")

      assert {403, _} =
               request(
                 conn,
                 :post,
                 "/api/v2/principal-groups",
                 resource("principal_group", %{name: "refused", display_name: "Refused"})
               )

      assert {:error, :not_found} = AuthZ.get_principal_group("refused")

      assert {403, _} =
               request(conn, :patch, "/api/v2/principals/#{human.uid}", %{
                 data: %{type: "principal", attributes: %{display_name: "Refused"}}
               })
    end
  end

  describe "missing targets" do
    test "a missing target answers 404 not_found", %{conn: conn} do
      enable_local_provider()
      %{principal: human} = human_fixture()
      principal_patch = %{data: %{type: "principal", attributes: %{display_name: "Missing"}}}

      for {method, path, body} <- [
            {:patch, "/api/v2/principals/missing-principal", principal_patch},
            {:get, "/api/v2/principal-groups/missing-group", nil},
            {:delete, "/api/v2/principal-groups/missing-group", nil},
            {:get, "/api/v2/principal-groups/missing-group/members", nil},
            {:put, "/api/v2/principal-groups/missing-group/members/#{human.uid}", nil},
            {:delete, "/api/v2/principal-groups/missing-group/members/#{human.uid}", nil},
            {:get, "/api/v2/permission-grants/#{Ecto.UUID.generate()}", nil},
            {:patch, "/api/v2/permission-grants/#{Ecto.UUID.generate()}",
             %{data: %{type: "permission_grant", attributes: %{description: "x"}}}},
            {:delete, "/api/v2/permission-grants/#{Ecto.UUID.generate()}", nil},
            {:get, "/api/v2/permission-grants/not-a-uuid", nil},
            {:delete, "/api/v2/permission-grants/not-a-uuid", nil},
            {:delete, "/api/v2/identity-mapping-requests/not-a-uuid", nil},
            {:post, "/api/v2/identity-mapping-requests/not-a-uuid/bind",
             %{data: %{principal_uid: human.uid}}},
            {:post, "/api/v2/permission-grants",
             resource("permission_grant", %{
               group_name: "missing-group",
               resource_pattern: "**",
               action: "read"
             })},
            {:delete, "/api/v2/identity-mapping-requests/#{Ecto.UUID.generate()}", nil},
            {:post, "/api/v2/identity-mapping-requests/#{Ecto.UUID.generate()}/bind",
             %{data: %{principal_uid: human.uid}}},
            {:post, "/api/v2/identity-mappings",
             %{data: %{provider: "lark-main", external_id: "ou_x", principal_uid: "missing"}}}
          ] do
        response = request(conn, method, path, body)
        assert {404, _} = response, "#{method} #{path}: #{inspect(response)}"
        assert error_code(response) == "not_found"
      end
    end
  end

  describe "principals" do
    test "lists active Principals in UID order and includes disabled ones on request", %{
      conn: conn
    } do
      human = human_fixture(%{uid: unique_uid("v2-human"), display_name: "V2 Human"})
      agent = agent_fixture(%{uid: unique_uid("v2-agent"), display_name: "V2 Agent"})
      disabled = human_fixture(%{uid: unique_uid("v2-disabled")})
      assert {:ok, _} = disable_principal_fixture(disabled.principal.uid)

      assert {200, %{"data" => listed}} = request(conn, :get, "/api/v2/principals")
      ids = Enum.map(listed, & &1["id"])
      assert ids == Enum.sort(ids)
      refute disabled.principal.uid in ids

      human_row = Enum.find(listed, &(&1["id"] == human.principal.uid))
      assert human_row["type"] == "principal"

      assert %{
               "type" => "human",
               "status" => "active",
               "display_name" => "V2 Human",
               "email" => email,
               "has_external_identity" => false,
               "local_credential_status" => nil
             } = human_row["attributes"]

      assert email == human.human_user.email

      agent_row = Enum.find(listed, &(&1["id"] == agent.principal.uid))
      assert agent_row["attributes"]["handle"] == agent.agent.handle

      assert {200, %{"data" => all}} =
               request(conn, :get, "/api/v2/principals?include_disabled=true")

      assert %{"attributes" => %{"status" => "disabled"}} =
               Enum.find(all, &(&1["id"] == disabled.principal.uid))
    end

    test "reads one Principal with its static groups and direct grants", %{conn: conn} do
      %{principal: human} = human_fixture(%{display_name: "Detail Human"})
      name = "detail_group_#{System.unique_integer([:positive])}"
      assert {:ok, group} = AuthZ.create_principal_group(%{name: name, display_name: "Detail"})
      assert {:ok, _membership} = AuthZ.add_principal_to_group(human.uid, group.id)

      assert {:ok, grant} =
               AuthZ.create_permission_grant(%{
                 principal_uid: human.uid,
                 resource_pattern: "workspace:**",
                 action: "read"
               })

      assert {200,
              %{"data" => %{"id" => uid, "attributes" => %{"display_name" => "Detail Human"}}}} =
               request(conn, :get, "/api/v2/principals/#{human.uid}")

      assert uid == human.uid

      assert {200, %{"data" => [%{"id" => group_id, "attributes" => group_attributes}]}} =
               request(conn, :get, "/api/v2/principals/#{human.uid}/groups")

      assert group_id == group.id
      assert %{"name" => ^name, "member_count" => 1, "grant_count" => 0} = group_attributes

      assert {200, %{"data" => [%{"id" => grant_id, "attributes" => grant_attributes}]}} =
               request(conn, :get, "/api/v2/principals/#{human.uid}/grants")

      assert grant_id == grant.id
      assert grant_attributes["principal_uid"] == human.uid
      refute Map.has_key?(grant_attributes, "metadata")

      assert {404, _} = request(conn, :get, "/api/v2/principals/missing-principal")
    end

    test "a local-account write needs an enabled local identity provider", %{conn: conn} do
      %{principal: human} = human_fixture()

      response =
        request(
          conn,
          :post,
          "/api/v2/principals",
          resource("principal", %{email: "someone@example.com"})
        )

      assert {409, _} = response
      assert error_code(response) == "local_identity_provider_disabled"

      response =
        request(conn, :patch, "/api/v2/principals/#{human.uid}", %{
          data: %{type: "principal", attributes: %{display_name: "Renamed"}}
        })

      assert {409, _} = response
      assert error_code(response) == "local_identity_provider_disabled"
    end

    test "creates a local user and gives its one-time password once", %{conn: conn} do
      enable_local_provider()

      assert {201, %{"data" => created, "meta" => %{"initial_password" => password}}} =
               request(
                 conn,
                 :post,
                 "/api/v2/principals",
                 resource("principal", %{
                   email: "New.User@Example.com",
                   display_name: "New User",
                   must_change_password: true
                 })
               )

      assert {:ok, _} = Ecto.UUID.cast(created["id"])
      assert String.length(password) == 16

      assert %{
               "email" => "new.user@example.com",
               "display_name" => "New User",
               "local_credential_status" => "must_change"
             } = created["attributes"]

      assert {:ok, %{must_change_password: true}} =
               Ankole.IdentityProviders.LocalPassword.authenticate(
                 "new.user@example.com",
                 password
               )

      assert {400, %{"errors" => [%{"source" => %{"pointer" => "/data/attributes/email"}} | _]}} =
               request(
                 conn,
                 :post,
                 "/api/v2/principals",
                 resource("principal", %{email: "new.user@example.com"})
               )

      assert {400, %{"errors" => [%{"source" => %{"pointer" => "/data/attributes/email"}} | _]}} =
               request(conn, :post, "/api/v2/principals", resource("principal", %{}))
    end

    test "updates the display name and the email of a Human", %{conn: conn} do
      enable_local_provider()
      %{principal: human} = human_fixture()

      assert {200, %{"data" => %{"attributes" => attributes}}} =
               request(conn, :patch, "/api/v2/principals/#{human.uid}", %{
                 data: %{
                   type: "principal",
                   attributes: %{display_name: "Renamed User", email: "Renamed@Example.com"}
                 }
               })

      assert attributes["display_name"] == "Renamed User"
      assert attributes["email"] == "renamed@example.com"

      assert {400, %{"errors" => [%{"source" => %{"pointer" => "/data/attributes/email"}} | _]}} =
               request(conn, :patch, "/api/v2/principals/#{human.uid}", %{
                 data: %{type: "principal", attributes: %{email: ""}}
               })

      %{principal: agent} = agent_fixture()

      response =
        request(conn, :patch, "/api/v2/principals/#{agent.uid}", %{
          data: %{type: "principal", attributes: %{display_name: "Agent"}}
        })

      assert {422, _} = response
      assert error_code(response) == "not_human"
    end
  end

  describe "principal groups" do
    test "group lifecycle in the tenant of the session", %{conn: conn} do
      name = "workspace_admins_#{System.unique_integer([:positive])}"
      other = Ankole.DataCase.create_tenant()

      {:ok, _hidden} =
        Repo.with_tenant(other.id, fn ->
          AuthZ.create_principal_group(%{name: "#{name}_other", display_name: "Other"})
        end)

      assert {201, %{"data" => %{"id" => id, "attributes" => created}}} =
               request(
                 conn,
                 :post,
                 "/api/v2/principal-groups",
                 resource("principal_group", %{
                   name: String.upcase(name),
                   display_name: "Workspace Admins"
                 })
               )

      assert %{"name" => ^name, "kind" => "static", "domain" => "operator", "built_in" => false} =
               created

      assert {200, %{"data" => listed}} = request(conn, :get, "/api/v2/principal-groups")
      names = Enum.map(listed, & &1["attributes"]["name"])
      assert name in names
      refute "#{name}_other" in names
      assert names == Enum.sort(names)

      assert {200, %{"data" => %{"id" => ^id}}} =
               request(conn, :get, "/api/v2/principal-groups/#{name}")

      assert {200, %{"data" => %{"attributes" => %{"display_name" => "Renamed"}}}} =
               request(conn, :patch, "/api/v2/principal-groups/#{name}", %{
                 data: %{type: "principal_group", id: id, attributes: %{display_name: "Renamed"}}
               })

      assert {200, %{"data" => %{"id" => ^id}}} =
               request(conn, :delete, "/api/v2/principal-groups/#{name}")

      assert {:error, :not_found} = AuthZ.get_principal_group(name)
      assert {404, _} = request(conn, :get, "/api/v2/principal-groups/#{name}")
    end

    test "create validates the kind shape", %{conn: conn} do
      response =
        request(
          conn,
          :post,
          "/api/v2/principal-groups",
          resource("principal_group", %{
            name: "computed_#{System.unique_integer([:positive])}",
            display_name: "Computed",
            kind: "computed"
          })
        )

      assert {400, %{"errors" => [%{"source" => %{"pointer" => pointer}}]}} = response
      assert pointer == "/data/attributes/computed_condition"
    end

    test "built-in groups keep their condition and cannot be deleted", %{conn: conn} do
      assert {400, _} =
               request(conn, :patch, "/api/v2/principal-groups/siteadmin", %{
                 data: %{type: "principal_group", attributes: %{computed_condition: "true"}}
               })

      response = request(conn, :delete, "/api/v2/principal-groups/siteadmin")
      assert {409, _} = response
      assert error_code(response) == "built_in_group"
      assert {:ok, _group} = AuthZ.get_principal_group("siteadmin")
    end

    test "static membership roundtrip and refused manual edits", %{conn: conn} do
      name = "readers_#{System.unique_integer([:positive])}"
      assert {:ok, _group} = AuthZ.create_principal_group(%{name: name, display_name: "Readers"})
      %{principal: member} = human_fixture(%{display_name: "Member Human"})

      assert {200, %{"principal_uid" => uid}} =
               request(conn, :put, "/api/v2/principal-groups/#{name}/members/#{member.uid}")

      assert uid == member.uid

      assert {200, [%{"uid" => ^uid, "type" => "human", "member_since" => since}]} =
               request(conn, :get, "/api/v2/principal-groups/#{name}/members")

      assert is_binary(since)

      assert {200, "deleted"} =
               request(conn, :delete, "/api/v2/principal-groups/#{name}/members/#{member.uid}")

      assert {200, []} = request(conn, :get, "/api/v2/principal-groups/#{name}/members")

      assert {:ok, directory} =
               AuthZ.create_principal_group(%{
                 name: "directory_#{System.unique_integer([:positive])}",
                 display_name: "Directory",
                 domain: :directory
               })

      response =
        request(conn, :put, "/api/v2/principal-groups/#{directory.name}/members/#{member.uid}")

      assert {409, _} = response
      assert error_code(response) == "group_domain_mismatch"

      [admin_uid] =
        AuthZ.list_group_members("siteadmin") |> elem(1) |> Enum.map(& &1.principal.uid)

      response = request(conn, :delete, "/api/v2/principal-groups/siteadmin/members/#{admin_uid}")
      assert {409, _} = response
      assert error_code(response) == "last_admin_member"
    end

    test "computed members are evaluated and the preview validates the condition", %{conn: conn} do
      %{principal: human} = human_fixture(%{display_name: "Computed Member"})

      assert {:ok, computed} =
               AuthZ.create_principal_group(%{
                 name: "all_humans_#{System.unique_integer([:positive])}",
                 display_name: "All Humans Copy",
                 kind: :computed,
                 computed_condition: ~s(principal.type == "human")
               })

      assert {200, members} =
               request(conn, :get, "/api/v2/principal-groups/#{computed.name}/members")

      assert Enum.any?(members, &(&1["uid"] == human.uid))
      assert Enum.all?(members, &is_nil(&1["member_since"]))

      assert {201, [%{"uid" => uid}]} =
               request(conn, :post, "/api/v2/principal-groups/computed-member-previews", %{
                 data: %{condition: ~s(principal.uid == "#{human.uid}")}
               })

      assert uid == human.uid

      assert {400, %{"errors" => [%{"detail" => detail} | _]}} =
               request(conn, :post, "/api/v2/principal-groups/computed-member-previews", %{
                 data: %{condition: "principal."}
               })

      assert is_binary(detail)
    end

    test "lists the grants of a group", %{conn: conn} do
      name = "grantees_#{System.unique_integer([:positive])}"
      assert {:ok, group} = AuthZ.create_principal_group(%{name: name, display_name: "Grantees"})

      assert {:ok, grant} =
               AuthZ.create_permission_grant(%{
                 group_name: name,
                 resource_pattern: "workspace:**",
                 action: "read"
               })

      assert {200, %{"data" => [%{"id" => id, "attributes" => attributes}]}} =
               request(conn, :get, "/api/v2/principal-groups/#{name}/grants")

      assert id == grant.id
      assert attributes["group_id"] == group.id
    end
  end

  describe "permission grants" do
    test "grant lifecycle for a Principal owner and a group owner", %{conn: conn} do
      %{principal: owner} = human_fixture()
      name = "grant_group_#{System.unique_integer([:positive])}"
      assert {:ok, group} = AuthZ.create_principal_group(%{name: name, display_name: "Group"})

      assert {201, %{"data" => %{"id" => id, "attributes" => created}}} =
               request(
                 conn,
                 :post,
                 "/api/v2/permission-grants",
                 resource("permission_grant", %{
                   principal_uid: owner.uid,
                   resource_pattern: "workspace:**",
                   action: "read"
                 })
               )

      assert %{"principal_uid" => uid, "condition" => "true"} = created
      assert uid == owner.uid

      assert {201, %{"data" => %{"attributes" => %{"group_id" => group_id}}}} =
               request(
                 conn,
                 :post,
                 "/api/v2/permission-grants",
                 resource("permission_grant", %{
                   group_name: name,
                   resource_pattern: "workspace:**",
                   action: "update"
                 })
               )

      assert group_id == group.id

      assert {200, %{"data" => %{"id" => ^id}}} =
               request(conn, :get, "/api/v2/permission-grants/#{id}")

      assert {200,
              %{"data" => %{"attributes" => %{"resource_pattern" => "**", "action" => "read"}}}} =
               request(conn, :patch, "/api/v2/permission-grants/#{id}", %{
                 data: %{type: "permission_grant", id: id, attributes: %{resource_pattern: "**"}}
               })

      assert {200, %{"data" => %{"id" => ^id}}} =
               request(conn, :delete, "/api/v2/permission-grants/#{id}")

      assert {:error, :not_found} = AuthZ.get_permission_grant(id)
      assert {404, _} = request(conn, :delete, "/api/v2/permission-grants/#{id}")
    end

    test "the Console cannot write or delete a Pod page grant", %{conn: conn} do
      %{principal: owner} = human_fixture()

      for action <- Ankole.Pod.Access.page_actions() do
        assert {400, %{"errors" => [%{"source" => %{"pointer" => "/data/attributes/action"}}]}} =
                 request(
                   conn,
                   :post,
                   "/api/v2/permission-grants",
                   resource("permission_grant", %{
                     principal_uid: owner.uid,
                     resource_pattern: "pod:space:**",
                     action: action
                   })
                 )
      end

      assert {:ok, grant} =
               AuthZ.create_permission_grant(%{
                 principal_uid: owner.uid,
                 resource_pattern: "space:engineering/**",
                 action: "page_view",
                 description: "shared space"
               })

      for attributes <- [
            %{resource_pattern: "**"},
            %{condition: "false"},
            %{action: "read", resource_pattern: "**"}
          ] do
        assert {400, %{"errors" => [_ | _]}} =
                 request(conn, :patch, "/api/v2/permission-grants/#{grant.id}", %{
                   data: %{type: "permission_grant", attributes: attributes}
                 })
      end

      assert {200, %{"data" => %{"attributes" => kept}}} =
               request(conn, :patch, "/api/v2/permission-grants/#{grant.id}", %{
                 data: %{type: "permission_grant", attributes: %{description: "team share"}}
               })

      assert %{"action" => "page_view", "description" => "team share"} = kept

      response = request(conn, :delete, "/api/v2/permission-grants/#{grant.id}")
      assert {422, _} = response
      assert error_code(response) == "page_grant"
      assert {:ok, _stored} = AuthZ.get_permission_grant(grant.id)
    end
  end

  describe "identity mapping requests" do
    test "lists, binds, and dismisses pending requests", %{conn: conn} do
      %{principal: target} = human_fixture()

      assert {:ok, bindable} =
               MappingRequests.record_observation(%{
                 provider: "lark-main",
                 external_id: "ou_v2_bind",
                 display_name: "Bindable"
               })

      assert {:ok, dismissable} =
               MappingRequests.record_observation(%{
                 provider: "lark-main",
                 external_id: "ou_v2_dismiss"
               })

      assert {200, %{"data" => listed}} =
               request(conn, :get, "/api/v2/identity-mapping-requests")

      assert Enum.sort(Enum.map(listed, & &1["id"])) == Enum.sort([bindable.id, dismissable.id])

      assert {201, %{"principal_uid" => uid, "external_id" => "ou_v2_bind"} = bound} =
               request(conn, :post, "/api/v2/identity-mapping-requests/#{bindable.id}/bind", %{
                 data: %{principal_uid: target.uid}
               })

      assert uid == target.uid
      refute Map.has_key?(bound, "metadata")
      assert {:ok, resolved} = Principals.resolve_platform_subject("lark-main", "ou_v2_bind")
      assert resolved.uid == target.uid

      assert {200, %{"data" => %{"id" => dismissed}}} =
               request(conn, :delete, "/api/v2/identity-mapping-requests/#{dismissable.id}")

      assert dismissed == dismissable.id
      assert MappingRequests.list_requests() == []
    end

    test "a bind to an agent is refused", %{conn: conn} do
      %{principal: agent} = agent_fixture()

      assert {:ok, request} =
               MappingRequests.record_observation(%{
                 provider: "lark-main",
                 external_id: "ou_v2_refused"
               })

      response =
        request(conn, :post, "/api/v2/identity-mapping-requests/#{request.id}/bind", %{
          data: %{principal_uid: agent.uid}
        })

      assert {422, _} = response
      assert error_code(response) == "not_human"
      assert [_still_pending] = MappingRequests.list_requests()
    end

    test "maps a provider subject proactively and refuses a reassignment", %{conn: conn} do
      %{principal: first} = human_fixture()
      %{principal: second} = human_fixture()
      subject = %{provider: "lark-main", external_id: "ou_v2_proactive"}

      assert {201, %{"principal_uid" => uid}} =
               request(conn, :post, "/api/v2/identity-mappings", %{
                 data: Map.put(subject, :principal_uid, first.uid)
               })

      assert uid == first.uid

      response =
        request(conn, :post, "/api/v2/identity-mappings", %{
          data: Map.put(subject, :principal_uid, second.uid)
        })

      assert {409, _} = response
      assert error_code(response) == "platform_subject_already_bound"
    end
  end
end
