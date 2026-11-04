defmodule Ankole.Connectors.AdapterContractProtocolTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Connectors.{Accounts, Resolver, Store, ToolSpec}
  alias Ankole.Plugins.GitHubAdapter.Connector, as: GitHub
  alias Ankole.Plugins.LarkAdapter.{Connector, Config, IdentityProvider, Inbound}

  defmodule Provider do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, raw, conn} = read_body(conn)
      conn = fetch_query_params(conn)
      body = if raw == "", do: nil, else: Torque.decode!(raw)

      send(
        owner,
        {:provider, conn.method, conn.request_path, conn.query_params, body, conn.req_headers}
      )

      result =
        case conn.request_path do
          "/open-apis/auth/v3/tenant_access_token/internal" ->
            %{"code" => 0, "tenant_access_token" => "application-token", "expire" => 7200}

          "/open-apis/authen/v2/oauth/token" ->
            %{"code" => 0, "access_token" => "personal-token", "expires_in" => 7200}

          "/open-apis/authen/v1/user_info" ->
            %{"code" => 0, "data" => %{"open_id" => "ou-app-specific", "name" => "Employee"}}

          "/open-apis/approval/v4/approvals/expired-token" ->
            %{"code" => 99_991_663}

          "/repos/owner/repo/issues/42/labels" ->
            []

          "/open-apis/approval/v4/tasks/query" ->
            %{"code" => 0, "data" => %{"tasks" => [], "has_more" => false}}

          "/open-apis/approval/v4/instances" ->
            %{"code" => 0, "data" => %{"instance_code_list" => []}}

          _ ->
            %{"code" => 0, "data" => %{}}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Torque.encode!(result))
    end
  end

  setup do
    server = start_supervised!({Bandit, plug: {Provider, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}"
    previous = Application.get_env(:ankole, Config)
    Application.put_env(:ankole, Config, client_opts: [base_url: url])
    on_exit(fn -> Application.put_env(:ankole, Config, previous || []) end)
    human = human_fixture()
    actor = actor_fixture(human.principal.uid)
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(human.principal.uid) end)

    {:ok, config} =
      Store.create_auth_config(human.principal, %{
        "plugin_id" => "lark",
        "slug" => "protocol-lark",
        "auth_scheme" => "lark_app",
        "secret" => %{"appID" => "adapter-contract-app", "appSecret" => "secret"}
      })

    context = %{
      actor: actor,
      auth_config: config,
      account: nil,
      external_user_id: "employee",
      access_token: "personal-token"
    }

    %{url: url, human: human, actor: actor, config: config, context: context}
  end

  test "setting issue labels sends the explicit list and clearing requires an explicit empty list",
       ctx do
    tool = Enum.find(GitHub.tools(), &(&1.name == "issues_manage_labels"))
    args = %{"owner" => "owner", "repo" => "repo", "issue_number" => 42}
    assert {:error, _} = ToolSpec.validate_input(tool, args)

    context = %{
      ctx.context
      | auth_config: %{ctx.config | public_metadata: %{"base_url" => ctx.url}}
    }

    for labels <- [["bug", "priority"], []] do
      input = Map.put(args, "labels", labels)
      assert {:ok, _} = ToolSpec.validate_input(tool, input)
      assert {:ok, %{"result" => []}} = GitHub.call(tool, input, context)

      assert_receive {:provider, "PUT", "/repos/owner/repo/issues/42/labels", %{},
                      %{"labels" => ^labels}, _}
    end
  end

  test "GitHub content paths preserve nested directories and the root directory", ctx do
    config = %{ctx.config | public_metadata: %{"base_url" => ctx.url}}

    for {name, method, path} <- [
          {"repos_get_content", "GET", "dir/a file.txt"},
          {"repos_put_content", "PUT", "dir/a file.txt"},
          {"repos_get_content", "GET", ""}
        ] do
      tool = Enum.find(GitHub.tools(), &(&1.name == name))

      args = %{
        "owner" => "owner",
        "repo" => "repo",
        "path" => path,
        "message" => "update",
        "content" => "eA=="
      }

      assert {:ok, _} = GitHub.call(tool, args, %{ctx.context | auth_config: config})
      expected = "/repos/owner/repo/contents/" <> if(path == "", do: "", else: "dir/a%20file.txt")
      assert_receive {:provider, ^method, ^expected, _, _, _}
    end
  end

  test "GitHub enterprise OAuth stays on its host and App user tokens request no OAuth scopes",
       ctx do
    config = %{
      ctx.config
      | public_metadata: %{"base_url" => "https://ghe.example/api/v3", "web_url" => ""}
    }

    config = Map.put(config, :auth_scheme, "github_app")

    assert {:ok, url} =
             GitHub.oauth_authorize_url(config, %{"clientID" => "client"}, %{
               :subject_kind => "human",
               "scope" => "repo"
             })

    uri = URI.parse(url)
    assert uri.host == "ghe.example"
    assert uri.path == "/login/oauth/authorize"
    refute Map.has_key?(URI.decode_query(uri.query), "scope")

    assert GitHub.web_url(%{config | public_metadata: %{"base_url" => nil, "web_url" => nil}}) ==
             "https://github.com"

    assert {:ok, oauth} =
             GitHub.oauth_authorize_url(
               %{config | auth_scheme: "oauth2"},
               %{"clientID" => "client"},
               %{:subject_kind => "human", "scope" => "repo"}
             )

    assert URI.decode_query(URI.parse(oauth).query)["scope"] == "repo"
  end

  test "Lark add-sign and rollback use their documented user-token task endpoints without invented user_id",
       ctx do
    for {name, args} <- [
          {"approvals_add_sign",
           %{
             "instance_code" => "instance",
             "task_id" => "task",
             "add_sign_user_ids" => ["employee-2"],
             "add_sign_type" => 1
           }},
          {"approvals_rollback",
           %{"instance_code" => "instance", "task_id" => "task", "node_ids" => ["node"]}}
        ] do
      tool = Connector.find_tool(name)
      assert tool.upstream_auth == :human_oauth_token
      assert {:ok, _} = ToolSpec.validate_input(tool, args)
      assert {:ok, %{}} = Connector.call(tool, args, ctx.context)
      path = tool.operation["path"]
      assert_receive {:provider, "POST", ^path, _, body, headers}
      refute Map.has_key?(body, "user_id")
      assert {"authorization", "Bearer personal-token"} in headers
    end

    for name <- ["approvals_get_definition", "approvals_list_instances", "approvals_get_instance"],
        do: assert(Connector.find_tool(name).upstream_auth == :app_token)
  end

  test "approval lists use verified employee identity even when unrelated personal consent is insufficient",
       ctx do
    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "adapter-people",
        "lark",
        %{
          "authConfigId" => ctx.config.id,
          "appID" => "adapter-contract-app",
          "appSecret" => "secret",
          "sync" => %{"websocket" => false}
        },
        true
      )

    external_identity_fixture(%{
      human: ctx.human,
      provider: "adapter-people",
      external_id: "employee",
      metadata: %{"user_id" => "employee"}
    })

    {:ok, personal} =
      Accounts.put_human_tokens(
        ctx.config.id,
        ctx.human.principal.uid,
        %{"access_token" => "calendar-token", "expires_in" => 3600},
        %{external_subject_id: "employee", granted_scopes: ["calendar:calendar"]}
      )

    tool = Connector.find_tool("approvals_list_tasks")
    assert {:error, _} = ToolSpec.validate_input(tool, %{})

    for status <- ["active", "expired", "revoked"] do
      {:ok, _} = Ankole.Ash.update(personal, :update, %{status: status})

      assert {:ok, resolved} =
               Resolver.resolve_call(tool, ctx.actor.principal, ctx.config.id, nil, %{
                 "topic" => "1"
               })

      assert resolved.account == nil
      assert resolved.external_user_id == "employee"
      assert {:ok, _} = Connector.call(tool, %{"topic" => "1"}, resolved)

      assert_receive {:provider, "GET", "/open-apis/approval/v4/tasks/query",
                      %{"topic" => "1", "user_id" => "employee"}, _, headers}

      assert {"authorization", "Bearer application-token"} in headers
    end

    assert {:error, %{code: "oauth_consent_required"}} =
             Resolver.resolve_call(
               Connector.find_tool("calendar_list_events"),
               ctx.actor.principal,
               ctx.config.id,
               nil,
               %{"calendar_id" => "cal"}
             )
  end

  test "OIDC can keep a personal OAuth identity without relabeling app-specific open_id as employee ID",
       ctx do
    login = %{
      token: %{access_token: "oauth", scope: "task:task:write"},
      user: %{"open_id" => "ou-app-specific", "name" => "Employee"}
    }

    assert {:ok, :ok} =
             Repo.transact(fn ->
               with :ok <-
                      IdentityProvider.complete_connector_login_in_tx(
                        %{
                          "authConfigId" => ctx.config.id,
                          "oidc" => %{"requestPersonalConnectorScopes" => true}
                        },
                        login,
                        ctx.human.principal
                      ),
                    do: {:ok, :ok}
             end)

    assert {:ok, account} = Accounts.get_account(ctx.config.id, "human", ctx.human.principal.uid)
    assert account.external_subject_id == "ou-app-specific"
    assert account.public_metadata["subject_id_type"] == "open_id"

    assert {:error, :oauth_consent_required} =
             Connector.bound_user_id(ctx.config, ctx.human.principal.uid)

    assert {:ok, tokens} =
             Connector.oauth_exchange(ctx.config, %{"appID" => "app", "appSecret" => "secret"}, %{
               "code" => "code"
             })

    assert tokens["external_subject_id"] == "ou-app-specific"
    assert tokens["public_metadata"]["name"] == "Employee"
  end

  test "RFC3339 timestamps reach approval milliseconds and calendar anchor seconds", ctx do
    assert {:ok, _} =
             Connector.call(
               Connector.find_tool("approvals_list_instances"),
               %{
                 "approval_code" => "approval",
                 "start_time" => "2026-11-04T12:00:00Z",
                 "end_time" => "2026-11-04T13:00:00Z"
               },
               ctx.context
             )

    assert_receive {:provider, "GET", "/open-apis/approval/v4/instances",
                    %{"start_time" => "1793793600000", "end_time" => "1793797200000"}, _, _}

    assert {:ok, _} =
             Connector.call(
               Connector.find_tool("calendar_list_events"),
               %{"calendar_id" => "cal", "anchor_time" => "2026-11-04T12:00:00Z"},
               ctx.context
             )

    assert_receive {:provider, "GET", "/open-apis/calendar/v4/calendars/cal/events",
                    %{"anchor_time" => "1793793600"}, _, _}
  end

  test "image upload declares image_key and event patches cannot silently ignore attendee edits" do
    upload = Connector.find_tool("im_upload_file")
    assert upload.output_schema["properties"]["image_key"] == %{"type" => "string"}
    assert {:ok, _} = ToolSpec.validate_output(upload, %{"image_key" => "img-1"})
    patch = Connector.find_tool("calendar_patch_event")

    assert {:error, _} =
             ToolSpec.validate_input(patch, %{
               "calendar_id" => "cal",
               "event_id" => "event",
               "attendees" => [%{"user_id" => "employee"}]
             })

    assert {:ok, _} =
             ToolSpec.validate_input(Connector.find_tool("calendar_manage_attendees"), %{
               "calendar_id" => "cal",
               "event_id" => "event",
               "operation" => "add",
               "attendees" => [%{"type" => "user", "user_id" => "employee"}]
             })
  end

  test "signed legacy direct-message cards normalize to durable business events without requiring a chat id",
       ctx do
    payload = %{
      "open_message_id" => "message",
      "user_id" => "employee",
      "token" => "callback-1",
      "action" => %{"tag" => "button", "value" => %{"decision" => "approve"}}
    }

    body = Torque.encode!(payload)

    headers = [
      {"x-lark-request-timestamp", "1711111"},
      {"x-lark-request-nonce", "nonce"},
      {"x-lark-signature",
       FeishuOpenAPI.Crypto.card_signature("1711111", "nonce", "verify", body)}
    ]

    assert {:ok, signal} =
             Connector.webhook(ctx.config, %{"verificationToken" => "verify"}, body, headers)

    assert signal["type"] == "card.action.trigger"
    assert signal["id"] != nil
    assert signal["data"]["action"] == payload["action"]
    assert signal["data"]["context"]["open_message_id"] == "message"

    assert {:ok, repeated} =
             Connector.webhook(ctx.config, %{"verificationToken" => "verify"}, body, headers)

    assert Map.take(repeated, ["source", "id", "data"]) ==
             Map.take(signal, ["source", "id", "data"])

    assert Connector.webhook_response(signal) == %{}

    assert {:ok, []} =
             Inbound.handle_card_action(
               "card.action.trigger",
               %FeishuOpenAPI.Event{raw: payload},
               [%{kind: :chat}]
             )

    refute match?(
             {:ok, _},
             Connector.webhook(ctx.config, %{"verificationToken" => "wrong"}, body, headers)
           )
  end

  test "an upstream-invalid cached application token is refreshed on the next call, without replaying the failed operation",
       ctx do
    assert {:ok, token} = Ankole.Connectors.Credentials.access_token(ctx.config, nil, Connector)
    assert_receive {:provider, "POST", "/open-apis/auth/v3/tenant_access_token/internal", _, _, _}
    context = %{ctx.context | access_token: token}

    assert {:error, %{upstream_code: 99_991_663, retryable: true}} =
             Connector.call(
               Connector.find_tool("approvals_get_definition"),
               %{"approval_code" => "expired-token"},
               context
             )

    assert_receive {:provider, "GET", "/open-apis/approval/v4/approvals/expired-token", _, _, _}
    refute_receive {:provider, "GET", "/open-apis/approval/v4/approvals/expired-token", _, _, _}
    assert {:ok, _} = Ankole.Connectors.Credentials.access_token(ctx.config, nil, Connector)
    assert_receive {:provider, "POST", "/open-apis/auth/v3/tenant_access_token/internal", _, _, _}
  end

  test "a second bot can explicitly reuse the verified employee directory", ctx do
    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "shared-people",
        "lark",
        %{
          "authConfigId" => ctx.config.id,
          "appID" => "adapter-contract-app",
          "appSecret" => "secret",
          "sync" => %{"websocket" => false}
        },
        true
      )

    external_identity_fixture(%{
      human: ctx.human,
      provider: "shared-people",
      external_id: "employee",
      metadata: %{"user_id" => "employee"}
    })

    {:ok, second} =
      Store.create_auth_config(ctx.human.principal, %{
        "plugin_id" => "lark",
        "slug" => "second-bot",
        "auth_scheme" => "lark_app",
        "secret" => %{"appID" => "second-bot-app", "appSecret" => "secret"},
        "public_metadata" => %{"identityProvider" => "shared-people"}
      })

    assert {:ok, "employee"} = Connector.bound_user_id(second, ctx.human.principal.uid)
    catalog = Ankole.Connectors.Registry.catalog()

    assert Enum.any?(
             Enum.find(catalog, &(&1.id == "lark")).public_fields,
             &(&1.key == "identityProvider")
           )

    github = Enum.find(catalog, &(&1.id == "github"))

    for key <- ["clientID", "clientSecret"],
        do: assert("github_app" in Enum.find(github.credential_fields, &(&1.key == key)).schemes)
  end
end
