defmodule AnkoleWeb.JSONAPI.ConnectorOperationsTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures
  import Ecto.Query, only: [from: 2]

  alias Ankole.Connectors
  alias Ankole.Repo

  setup do
    reconciler = Ankole.Plugins.LarkAdapter.ConnectionReconciler
    previous_connections = reconciler.registered_keys()
    Ankole.AppConfigure.Registry.clear_for_test()
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    :ok = Ankole.Setup.Config.delete_bootstrap_activation_code()

    on_exit(fn ->
      :sys.get_state(reconciler)
      Enum.each(reconciler.registered_keys() -- previous_connections, &reconciler.stop/1)
    end)

    :ok
  end

  test "MCP discovery succeeds before a service caller's business authorization fails", %{
    conn: conn
  } do
    actor = actor_fixture(human_fixture().principal.uid)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{type: "applet"})

    {:ok, headers} =
      Ankole.Connectors.Tokens.invocation(
        %{"applet" => %{"pageId" => page.id}},
        nil,
        Ash.UUIDv7.generate(),
        System.monotonic_time(:millisecond) + 30_000
      )

    token =
      Enum.find_value(headers, fn {key, value} ->
        if key == "x-ankole-caller-mcp-token", do: value
      end)

    request = fn method, params ->
      conn
      |> Map.put(:host, "127.0.0.1")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/internal/mcp/toolkits/github",
        Torque.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => method,
          "params" => params
        })
      )
      |> json_response(200)
    end

    assert %{"result" => %{"supportedVersions" => ["2026-07-28"]}} =
             request.("server/discover", %{})

    assert %{"result" => %{"isError" => true, "structuredContent" => %{"error" => error}}} =
             request.("tools/call", %{
               "name" => "repos_get",
               "arguments" => %{"owner" => "owner", "repo" => "repo"}
             })

    assert error["code"] == "user_authority_unavailable"
    assert error["request_sent"] == false

    assert %{"error" => %{"data" => %{"code" => "user_authority_unavailable"}}} =
             request.("tools/list", %{})

    notification =
      conn
      |> Map.put(:host, "127.0.0.1")
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/internal/mcp/toolkits/github",
        Torque.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/cancelled",
          "params" => %{"requestId" => 1}
        })
      )

    assert response(notification, 202) == ""

    admin_token =
      Enum.find_value(headers, fn {key, value} ->
        if key == "x-ankole-admin-mcp-token", do: value
      end)

    malformed =
      conn
      |> Map.put(:host, "127.0.0.1")
      |> put_req_header("authorization", "Bearer " <> admin_token)
      |> put_req_header("content-type", "application/json")
      |> post("/api/internal/mcp/toolkits/github", "{}")

    assert %{"id" => nil, "error" => %{"data" => %{"code" => "invalid_request"}}} =
             json_response(malformed, 200)

    unsigned_malformed =
      conn
      |> Map.put(:host, "127.0.0.1")
      |> put_req_header("content-type", "application/json")
      |> post("/api/internal/mcp/toolkits/github", "{}")

    assert json_response(unsigned_malformed, 401) == %{"error" => %{"code" => "unauthorized"}}

    invalid =
      conn
      |> Map.put(:host, "127.0.0.1")
      |> put_req_header("authorization", "Bearer invalid")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/api/internal/mcp/toolkits/github",
        Torque.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover"
        })
      )

    assert json_response(invalid, 401) == %{"error" => %{"code" => "unauthorized"}}
  end

  test "Console selects tenant connections without a Pod host or tenant impersonation", %{
    conn: conn
  } do
    {conn, operator_uid} = console_conn_with_principal(conn)
    home = create_connection("home")
    selected_tenant = Ankole.DataCase.create_tenant()

    selected =
      Repo.with_tenant(selected_tenant.id, fn ->
        assert {:ok, nil} = Ankole.Principals.get_principal_record(operator_uid)
        create_connection("selected")
      end)

    home_response = get_json_api(conn, "/api/v2/connector-auth-configs")
    assert %{"connections" => [%{"id" => home_id}]} = json_response(home_response, 200)
    assert home_id == home.id

    response =
      conn
      |> put_req_header("x-ankole-tenant", selected_tenant.id)
      |> get_json_api("/api/v2/connector-auth-configs")

    assert %{"connections" => [%{"id" => selected_id, "slug" => "selected"} = connection]} =
             json_response(response, 200)

    assert selected_id == selected.id
    assert response.host == conn.host
    assert get_resp_header(response, "location") == []
    assert connection["public_metadata"] == %{"domain" => "feishu", "appID" => "cli_selected"}
    assert Enum.sort(connection["configured_credential_fields"]) == ["appID", "appSecret"]
    refute response.resp_body =~ "private-secret"
    refute Map.has_key?(connection, "sealed_secret")
    refute Map.has_key?(connection, "secret")
    refute response.resp_body =~ home.id

    catalog_response =
      conn
      |> put_req_header("x-ankole-tenant", selected_tenant.id)
      |> get_json_api("/api/v2/connector-catalog")

    assert %{"connectors" => connectors} = json_response(catalog_response, 200)
    lark = Enum.find(connectors, &(&1["plugin_id"] == "lark"))
    assert "lark_app" in lark["auth_schemes"]
    assert Enum.any?(lark["credential_fields"], &(&1["key"] == "appSecret"))
    refute catalog_response.resp_body =~ "private-secret"
  end

  test "both Console projections require a browser session", %{conn: conn} do
    for path <- ["/api/v2/connector-catalog", "/api/v2/connector-auth-configs"] do
      assert %{"error" => %{"code" => "unauthorized"}} =
               conn |> get_json_api(path) |> json_response(401)
    end
  end

  test "Pod trigger consent errors preserve an actionable authorization URL", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, uid} = conn |> pod_conn(tenant) |> console_conn_with_principal()
    {:ok, actor} = Ankole.Principals.get_principal(uid)
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(uid) end)

    {:ok, connection} =
      Connectors.create_auth_config(actor, %{
        "plugin_id" => "lark",
        "slug" => "calendar",
        "auth_scheme" => "lark_app",
        "secret" => %{"appID" => "calendar-app", "appSecret" => "secret"}
      })

    response =
      conn
      |> post_json_api("/api/v2/pod/connectors/triggers", %{
        "auth_config_id" => connection.id,
        "trigger_type" => "lark_calendar",
        "scope_key" => "primary"
      })

    assert %{
             "errors" => [
               %{"code" => "oauth_consent_required", "meta" => %{"details" => details}}
             ]
           } = json_response(response, 422)

    assert details["owner_principal_uid"] == uid
    assert details["scopes"] == ["calendar:calendar.event:read"]
    assert details["authorization_url"] =~ "/connectors?"
    assert details["authorization_url"] =~ "connection=calendar"
  end

  test "disabled connections keep identity and messaging configuration readable and replaceable",
       %{
         conn: conn
       } do
    conn = console_conn(conn)
    original = create_connection("original")
    {:ok, owner} = Ankole.Principals.get_principal(original.created_by_uid)

    provider_config = %{
      "authConfigId" => original.id,
      "oidc" => %{"enabled" => true},
      "sync" => %{"contacts" => false, "websocket" => false}
    }

    provider = %{"adapter_id" => "lark", "enabled" => true, "config" => provider_config}

    assert %{"identity_provider" => %{}} =
             conn
             |> post_json_api("/api/v2/identity-providers/lark-recover", provider)
             |> json_response(201)

    assert %{"signal_binding" => %{"id" => binding_id}} =
             conn
             |> json_api()
             |> put("/api/v2/signal-bindings/lark/recover", %{
               data: %{
                 "routing_mode" => "sender_personal_assistant",
                 "config" => %{"authConfigId" => original.id, "userName" => "Recoverable Bot"}
               }
             })
             |> json_response(200)

    assert {:ok, _} = Connectors.update_auth_config(owner, original.id, %{"status" => "disabled"})
    assert {:error, :connection_disabled} = Connectors.get_auth_config(original.id)

    assert {:error, {:storage_error, _, _, :connection_disabled}} =
             Ankole.AppConfigure.get_by_key("principals.identity_providers.lark.lark-recover")

    assert {:error, {:storage_error, _, _, :connection_disabled}} =
             binding_id
             |> Ankole.Signals.get_binding!()
             |> Ankole.Signals.Bindings.stored_binding_config()

    identity_response = get_json_api(conn, "/api/v2/identity-providers")
    assert %{"identity_providers" => [identity]} = json_response(identity_response, 200)
    assert identity["config"]["authConfigId"] == original.id
    refute identity_response.resp_body =~ "private-secret"

    binding_response = get_json_api(conn, "/api/v2/signal-bindings/#{binding_id}")
    assert %{"config" => %{"authConfigId" => original_id}} = json_response(binding_response, 200)
    assert original_id == original.id
    refute binding_response.resp_body =~ "private-secret"

    assert %{"identity_provider" => %{}} =
             conn
             |> json_api()
             |> put("/api/v2/identity-providers/lark-recover", %{
               data: put_in(provider, ["config", "sync", "contacts"], true)
             })
             |> json_response(200)

    assert %{"signal_binding" => %{}} =
             conn
             |> json_api()
             |> patch("/api/v2/signal-bindings/#{binding_id}", %{
               data: %{config: %{userName: "Edited while disconnected"}}
             })
             |> json_response(200)

    assert {:ok, %{enqueued: [], skipped: ["lark-recover"]}} =
             Ankole.IdentityProviders.DirectorySync.enqueue_directory_syncs()

    assert {:error, {:storage_error, _, _, :connection_disabled}} =
             Ankole.AppConfigure.get_by_key("principals.identity_providers.lark.lark-recover")

    replacement = create_connection("replacement")
    provider = put_in(provider, ["config", "authConfigId"], replacement.id)

    assert %{"identity_provider" => %{"config" => %{"authConfigId" => replacement_id}}} =
             conn
             |> json_api()
             |> put("/api/v2/identity-providers/lark-recover", %{data: provider})
             |> json_response(200)

    assert replacement_id == replacement.id

    assert %{"signal_binding" => %{}} =
             conn
             |> json_api()
             |> patch("/api/v2/signal-bindings/#{binding_id}", %{
               data: %{config: %{authConfigId: replacement.id}}
             })
             |> json_response(200)

    assert {:ok, %{"appSecret" => "replacement-private-secret"}} =
             Ankole.AppConfigure.get_by_key("principals.identity_providers.lark.lark-recover")

    binding = Ankole.Signals.get_binding!(binding_id)
    assert binding.auth_config_id == replacement.id

    assert {:ok, %{"appSecret" => "replacement-private-secret"}} =
             Ankole.Signals.Bindings.binding_config(binding, Ankole.Plugins.LarkAdapter.Config)

    assert {:error, :connection_disabled} = Connectors.get_auth_config(original.id)
  end

  test "Console resource grants authorize both projections", %{conn: conn} do
    {conn, operator_uid} = console_conn_with_principal(conn)

    Repo.delete_all(
      from grant in Ankole.AuthZ.Grant,
        where: grant.resource_pattern in ["site_console:**", "tenant_console:**"]
    )

    for path <- ["/api/v2/connector-catalog", "/api/v2/connector-auth-configs"] do
      assert %{"errors" => [%{"code" => "forbidden"}]} =
               conn |> get_json_api(path) |> json_response(403)
    end

    assert {:ok, _} =
             Ankole.AuthZ.create_permission_grant(%{
               principal_uid: operator_uid,
               resource_pattern: "site_console:app_configurations",
               action: "read",
               condition: "true",
               metadata: %{}
             })

    assert %{"connections" => []} =
             conn |> get_json_api("/api/v2/connector-auth-configs") |> json_response(200)

    assert %{"connectors" => [_ | _]} =
             conn |> get_json_api("/api/v2/connector-catalog") |> json_response(200)
  end

  test "one Entra application credential serves both Pod identity and Teams configuration", %{
    conn: conn
  } do
    conn = console_conn(conn)
    %{principal: admin} = human_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)
    %{principal: agent} = agent_fixture()

    for {kind, id_key, secret_key} <- [
          {"identity", "clientID", "clientSecret"},
          {"messaging", "appID", "appPassword"}
        ] do
      application_id = Ankole.Kernel.gen_uuid_v7()
      tenant_id = Ankole.Kernel.gen_uuid_v7()

      assert {:ok, connection} =
               Connectors.create_auth_config(admin, %{
                 "plugin_id" => "microsoft365",
                 "slug" => kind,
                 "auth_scheme" =>
                   if(kind == "identity", do: "identity_app", else: "platform_app"),
                 "secret" => %{id_key => application_id, secret_key => "shared-entra-secret"},
                 "public_metadata" => %{"tenantID" => tenant_id}
               })

      provider_id = "entra-" <> kind

      assert %{"identity_provider" => %{"config" => %{"clientID" => ^application_id}}} =
               conn
               |> post_json_api("/api/v2/identity-providers/#{provider_id}", %{
                 "adapter_id" => "entra-id",
                 "config" => %{
                   "authConfigId" => connection.id,
                   "sync" => %{"contacts" => false, "realtime" => false}
                 }
               })
               |> json_response(201)

      assert %{"signal_binding" => %{"id" => binding_id}} =
               conn
               |> json_api()
               |> put("/api/v2/signal-bindings/teams/#{kind}", %{
                 data: %{
                   agent_uid: agent.uid,
                   config: %{"authConfigId" => connection.id, "identityProvider" => provider_id}
                 }
               })
               |> json_response(200)

      config_response = get_json_api(conn, "/api/v2/signal-bindings/#{binding_id}")
      assert %{"config" => %{"appID" => ^application_id}} = json_response(config_response, 200)
      refute config_response.resp_body =~ "shared-entra-secret"

      assert {:ok, _} =
               Connectors.update_auth_config(admin, connection.id, %{
                 "secret" => %{secret_key => "rotated-entra-secret"}
               })

      assert {:ok, %{"clientSecret" => "rotated-entra-secret"}} =
               Ankole.AppConfigure.get_by_key(
                 "principals.identity_providers.entra-id.#{provider_id}"
               )

      binding = Ankole.Signals.get_binding!(binding_id)
      assert binding.auth_config_id == connection.id

      assert {:ok, %{"appPassword" => "rotated-entra-secret"}} =
               Ankole.Signals.Bindings.binding_config(
                 binding,
                 Ankole.Plugins.Microsoft365Adapter.Config
               )
    end
  end

  defp create_connection(slug) do
    %{principal: actor} = human_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(actor.uid) end)

    {:ok, connection} =
      Connectors.create_auth_config(actor, %{
        "plugin_id" => "lark",
        "slug" => slug,
        "auth_scheme" => "lark_app",
        "public_metadata" => %{"domain" => "feishu"},
        "secret" => %{"appID" => "cli_" <> slug, "appSecret" => slug <> "-private-secret"}
      })

    connection
  end

  defp get_json_api(conn, path) do
    conn
    |> json_api()
    |> get(path)
  end

  defp post_json_api(conn, path, body), do: post(json_api(conn), path, %{data: body})

  defp json_api(conn) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
  end
end
