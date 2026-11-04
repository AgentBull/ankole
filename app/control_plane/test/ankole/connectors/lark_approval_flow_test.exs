defmodule Ankole.Connectors.LarkApprovalFlowTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures, only: [publish_applet_fixture: 2]
  require Ash.Query
  alias Ankole.{AutomationJobs, Signals}
  alias Ankole.AutomationJobs.Jobs.ExecuteRun
  alias Ankole.AutomationJobs.Schemas.Run
  alias Ankole.Connectors.Store
  alias Ankole.Plugins.LarkAdapter.Config

  defmodule Gateway do
    use Plug.Builder

    plug Plug.Parsers,
      parsers: [:json],
      json_decoder: Torque,
      body_reader: {AnkoleWeb.Plugs.ProviderWebhookBodyReader, :read_body, []}

    plug AnkoleWeb.Router
  end

  defmodule Lark do
    import Plug.Conn
    def init(options), do: options

    def call(conn, {owner, responses}) do
      {:ok, body, conn} = read_body(conn)
      body = if body == "", do: nil, else: Torque.decode!(body)
      conn = fetch_query_params(conn)

      send(
        owner,
        {:lark, conn.method, conn.request_path, conn.query_params, body,
         get_req_header(conn, "authorization")}
      )

      data =
        case {conn.method, conn.request_path} do
          {"POST", "/open-apis/auth/v3/tenant_access_token/internal"} ->
            token =
              if body["app_secret"] == "rotated-secret",
                do: "rotated-application-token",
                else: "application-token"

            %{"code" => 0, "tenant_access_token" => token, "expire" => 7200}

          {"POST", "/open-apis/authen/v2/oauth/token"} ->
            %{
              "code" => 0,
              "access_token" => "personal-token",
              "refresh_token" => "personal-refresh",
              "expires_in" => 7200,
              "refresh_expires_in" => 86400,
              "scope" => "task:task:write offline_access"
            }

          {"GET", "/open-apis/authen/v1/user_info"} ->
            %{
              "code" => 0,
              "data" => %{
                "user_id" => "employee-1",
                "name" => "Employee",
                "email" => "employee@example.test"
              }
            }

          {"GET", "/open-apis/contact/v3/users/employee-1"} ->
            %{
              "code" => 0,
              "data" => %{
                "user" => %{
                  "user_id" => "employee-1",
                  "name" => "Employee",
                  "email" => "employee@example.test",
                  "status" => %{"is_activated" => true}
                }
              }
            }

          {"GET", "/open-apis/approval/v4/tasks/query"} ->
            %{
              "code" => 0,
              "data" => %{
                "tasks" => [
                  %{
                    "task_id" => "task-1",
                    "definition_code" => "approval-1",
                    "process_code" => "instance-1",
                    "title" => "Purchase laptop",
                    "status" => "PENDING"
                  }
                ],
                "has_more" => false
              }
            }

          {"POST", "/open-apis/im/v1/messages"} ->
            %{"code" => 0, "data" => %{"message_id" => "message-1"}}

          {"POST", "/open-apis/approval/v4/tasks/approve"} ->
            %{"code" => 0, "data" => %{}}

          {"PATCH", "/open-apis/im/v1/messages/message-1"} ->
            %{"code" => 0, "data" => %{}}

          _ ->
            %{"code" => 9999}
        end

      status =
        if conn.request_path == "/open-apis/approval/v4/tasks/approve" do
          Agent.get_and_update(responses, fn
            [status | rest] -> {status, rest}
            [] -> {200, []}
          end)
        else
          200
        end

      conn |> put_resp_content_type("application/json") |> send_resp(status, Torque.encode!(data))
    end
  end

  setup do
    principal = human_fixture().principal
    actor = actor_fixture(principal.uid)
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(principal.uid) end)

    responses = start_supervised!({Agent, fn -> [] end})

    server =
      start_supervised!({Bandit, plug: {Lark, {self(), responses}}, ip: {127, 0, 0, 1}, port: 0},
        id: :lark
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    gateway = start_supervised!({Bandit, plug: Gateway, ip: {0, 0, 0, 0}, port: 0}, id: :gateway)
    {:ok, {_, gateway_port}} = ThousandIsland.listener_info(gateway)
    original = Application.get_env(:ankole, Config)
    origin = Application.get_env(:ankole, :runtime_fabric_internal_origin)
    Application.put_env(:ankole, Config, client_opts: [base_url: "http://127.0.0.1:#{port}"])

    Application.put_env(
      :ankole,
      :runtime_fabric_internal_origin,
      "http://host.docker.internal:#{gateway_port}"
    )

    on_exit(fn ->
      Application.put_env(:ankole, Config, original || [])
      Application.put_env(:ankole, :runtime_fabric_internal_origin, origin)
    end)

    {:ok, config} =
      Store.create_auth_config(principal, %{
        "plugin_id" => "lark",
        "slug" => "approval-inbox",
        "auth_scheme" => "lark_app",
        "secret" => %{
          "appID" => "approval-app",
          "appSecret" => "secret",
          "verificationToken" => "verify",
          "encryptKey" => "signature-key"
        }
      })

    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "approval-people",
        "lark",
        %{
          "appID" => "approval-app",
          "appSecret" => "secret",
          "authConfigId" => config.id,
          "sync" => %{"websocket" => false}
        },
        true
      )

    identity =
      external_identity_fixture(%{
        human: %{principal: principal},
        provider: "approval-people",
        external_id: "employee-1",
        metadata: %{"user_id" => "employee-1"}
      })

    {:ok, page} = Ankole.Pod.Pages.create(actor, %{type: "applet"})

    %{
      actor: actor,
      page: page,
      config: config,
      identity: identity,
      responses: responses,
      gateway_url: "http://127.0.0.1:#{gateway_port}"
    }
  end

  test "personal Job sends pending card, rejects another operator, approves once and writes back through real gateway",
       ctx do
    source =
      File.read!(
        Path.expand(
          "../library/agent-plugins/lark/skills/lark-approvals/examples/approval-inbox/server/main.js",
          File.cwd!()
        )
      )

    publish_applet_fixture(ctx, source)

    {:ok, job} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "inbox", %{
        authorization_kind: "human",
        config: %{connection: ctx.config.slug}
      })

    reference = "connector://#{ctx.config.id}/lark"

    {:ok, _} =
      Signals.put_event_binding(ctx.actor, %{config_ref: reference, automation_job_id: job.id})

    {:ok, %{receipts: [receipt]}} =
      Signals.emit(reference, %{id: "pending", type: "approval_task", data: %{}})

    assert :ok = execute(receipt.automation_job_run_id)

    assert %{status: :succeeded, result: %{"refreshed" => true}} =
             AutomationJobs.get_run_record(receipt.automation_job_run_id)

    assert_receive {:lark, "GET", "/open-apis/approval/v4/tasks/query",
                    %{"user_id" => "employee-1", "topic" => "1"}, nil,
                    ["Bearer application-token"]}

    assert_receive {:lark, "POST", "/open-apis/im/v1/messages", %{"receive_id_type" => "user_id"},
                    sent, ["Bearer application-token"]}

    assert sent["receive_id"] == "employee-1"
    assert is_binary(sent["uuid"])
    assert %{"elements" => [_, %{"actions" => [approve | _]}]} = Torque.decode!(sent["content"])

    assert {:ok, %{status: 200}} = click(ctx, "outsider", approve["value"], "employee-other")
    run = latest_run(job.id)
    assert :ok = execute(run.id)

    assert %{status: :succeeded, result: %{"ignored" => "another_operator"}} =
             AutomationJobs.get_run_record(run.id)

    refute_receive {:lark, "POST", "/open-apis/approval/v4/tasks/approve", _, _, _}

    Agent.update(ctx.responses, fn _ -> [429] end)
    assert {:ok, %{status: 200}} = click(ctx, "rate-limited", approve["value"], "employee-1")
    run = latest_run(job.id)
    assert :ok = execute(run.id)

    assert %{status: :failed, error: "upstream_rate_limited"} =
             AutomationJobs.get_run_record(run.id)

    assert_receive {:lark, "POST", "/open-apis/approval/v4/tasks/approve", _, _, _}
    assert_receive {:lark, "PATCH", "/open-apis/im/v1/messages/message-1", _, retry_card, _}

    assert %{"elements" => [%{"text" => %{"content" => notice}}, %{"actions" => [_, _]}]} =
             Torque.decode!(retry_card["content"])

    assert notice =~ "not submitted"

    assert {:ok, %{status: 200}} = click(ctx, "approved", approve["value"], "employee-1")
    run = latest_run(job.id)
    assert :ok = execute(run.id)

    assert %{status: :succeeded, result: %{"outcome" => "Approved"}} =
             AutomationJobs.get_run_record(run.id)

    assert_receive {:lark, "POST", "/open-apis/approval/v4/tasks/approve",
                    %{"user_id_type" => "user_id"},
                    %{
                      "user_id" => "employee-1",
                      "approval_code" => "approval-1",
                      "instance_code" => "instance-1",
                      "task_id" => "task-1"
                    }, ["Bearer application-token"]}

    assert_receive {:lark, "PATCH", "/open-apis/im/v1/messages/message-1", _, updated, _}

    assert %{"elements" => [%{"text" => %{"content" => "Approved"}}]} =
             Torque.decode!(updated["content"])

    assert {:ok, %{status: 200}} = click(ctx, "duplicate-click", approve["value"], "employee-1")
    assert :ok = execute(latest_run(job.id).id)
    assert_receive {:lark, "PATCH", "/open-apis/im/v1/messages/message-1", _, _, _}
    refute_receive {:lark, "POST", "/open-apis/approval/v4/tasks/approve", _, _, _}
  end

  test "optional sign-in consent persists personal tokens in the shared connection", ctx do
    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "approval-people",
        "lark",
        %{
          "appID" => "approval-app",
          "appSecret" => "secret",
          "authConfigId" => ctx.config.id,
          "sync" => %{"websocket" => false},
          "oidc" => %{
            "requestPersonalConnectorScopes" => true,
            "personalConnectorScopes" => ["task:task:write"]
          }
        },
        true
      )

    assert {:ok, url} =
             Ankole.IdentityProviders.Login.authorization_url("approval-people",
               redirect_uri: "https://ankole.example/callback",
               state: "state"
             )

    scopes =
      url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("scope")
      |> String.split(" ")

    assert "offline_access" in scopes
    assert "task:task:write" in scopes
    assert URI.parse(url).host == "accounts.feishu.cn"

    assert {:ok, %{principal_uid: uid}} =
             Ankole.IdentityProviders.Login.complete_oidc_login(
               "approval-people",
               "consent-code",
               redirect_uri: "https://ankole.example/callback"
             )

    assert_receive {:lark, "POST", "/open-apis/authen/v2/oauth/token", _,
                    %{
                      "client_id" => "approval-app",
                      "client_secret" => "secret",
                      "grant_type" => "authorization_code",
                      "redirect_uri" => "https://ankole.example/callback"
                    }, _}

    refute_receive {:lark, "POST", "/open-apis/authen/v1/oidc/access_token", _, _, _}

    assert uid == ctx.actor.principal.uid
    assert {:ok, account} = Ankole.Connectors.Accounts.get_account(ctx.config.id, "human", uid)
    assert account.external_subject_id == "employee-1"
    assert account.granted_scopes == ["task:task:write", "offline_access"]

    assert {:ok, %{"access_token" => "personal-token", "refresh_token" => "personal-refresh"}} =
             Ankole.Connectors.Credentials.account_credentials(account)
  end

  test "an uncertain approval removes card actions and never submits a duplicate decision", ctx do
    source =
      File.read!(
        Path.expand(
          "../library/agent-plugins/lark/skills/lark-approvals/examples/approval-inbox/server/main.js"
        )
      )

    publish_applet_fixture(ctx, source)

    {:ok, job} =
      AutomationJobs.create_applet_job(ctx.actor, ctx.page.id, "inbox", %{
        authorization_kind: "human",
        config: %{connection: ctx.config.slug}
      })

    reference = "connector://#{ctx.config.id}/lark"

    {:ok, _} =
      Signals.put_event_binding(ctx.actor, %{config_ref: reference, automation_job_id: job.id})

    {:ok, %{receipts: [receipt]}} =
      Signals.emit(reference, %{id: "pending", type: "approval_task", data: %{}})

    assert :ok = execute(receipt.automation_job_run_id)
    assert_receive {:lark, "POST", "/open-apis/im/v1/messages", _, sent, _}
    %{"elements" => [_, %{"actions" => [approve | _]}]} = Torque.decode!(sent["content"])

    Agent.update(ctx.responses, fn _ -> [500] end)
    assert {:ok, %{status: 200}} = click(ctx, "uncertain", approve["value"], "employee-1")
    run = latest_run(job.id)
    assert :ok = execute(run.id)

    assert %{status: :failed, error: "upstream_outcome_unknown"} =
             AutomationJobs.get_run_record(run.id)

    assert_receive {:lark, "POST", "/open-apis/approval/v4/tasks/approve", _, _, _}
    assert_receive {:lark, "PATCH", "/open-apis/im/v1/messages/message-1", _, updated, _}

    assert %{"elements" => [%{"text" => %{"content" => notice}}]} =
             Torque.decode!(updated["content"])

    assert notice =~ "uncertain"

    assert {:ok, %{status: 200}} = click(ctx, "repeat-uncertain", approve["value"], "employee-1")
    assert :ok = execute(latest_run(job.id).id)
    refute_receive {:lark, "POST", "/open-apis/approval/v4/tasks/approve", _, _, _}
  end

  test "one root rotation reaches cached OIDC and IM configuration, and disablement gates both",
       ctx do
    alias Ankole.IdentityProviders.Login
    alias Ankole.Plugins.LarkAdapter.Delivery

    {:ok, _} =
      Ankole.IdentityProviders.save_provider("approval-people", "lark", %{
        "authConfigId" => ctx.config.id,
        "sync" => %{"contacts" => false, "websocket" => false},
        "oidc" => %{
          "requestPersonalConnectorScopes" => true,
          "personalConnectorScopes" => ["task:task:write"]
        }
      })

    %{principal: agent} = agent_fixture()

    {:ok, %{binding: binding}} =
      Signals.Bindings.put_binding(agent.uid, "lark", "shared-root", %{
        "config" => %{
          "authConfigId" => ctx.config.id,
          "identityProvider" => "approval-people",
          "userName" => "Shared application bot"
        }
      })

    conversation =
      Ankole.ExternalConversationsFixtures.external_conversation_fixture("lark:shared-chat")

    intent = %Ankole.Conversations.Delivery.Intent{
      agent_uid: agent.uid,
      binding_id: binding.id,
      binding_name: binding.name,
      outbound_key: "shared-root-delivery",
      operation: :post,
      conversation_id: conversation.id,
      fallback_visible_text: "Shared application message",
      payload: %{},
      idempotency_key: "shared-root-delivery"
    }

    for {secret, token} <- [
          {"secret", "application-token"},
          {"rotated-secret", "rotated-application-token"}
        ] do
      assert {:ok, _} =
               Store.update_auth_config(ctx.actor.principal, ctx.config.id, %{
                 "secret" => %{"appSecret" => secret}
               })

      assert {:ok, %{principal_uid: uid}} =
               Login.complete_oidc_login("approval-people", "shared-root-code", [])

      assert uid == ctx.actor.principal.uid

      assert_receive {:lark, "POST", "/open-apis/authen/v2/oauth/token", _,
                      %{"client_id" => "approval-app", "client_secret" => ^secret}, _}

      assert {:ok, %{created_provider_message_id: "message-1"}} = Delivery.deliver(intent)
      authorization = "Bearer " <> token

      assert_receive {:lark, "POST", "/open-apis/im/v1/messages", _, _, [^authorization]}

      assert {:ok, %{"authConfigId" => id, "userName" => "Shared application bot"}} =
               Signals.Bindings.binding_config(binding, Config)

      assert id == ctx.config.id
    end

    assert {:ok, _} =
             Store.update_auth_config(ctx.actor.principal, ctx.config.id, %{
               "status" => "disabled"
             })

    assert {:error, _} = Login.complete_oidc_login("approval-people", "disabled-code", [])
    assert {:error, _} = Delivery.deliver(intent)
    refute_receive {:lark, "POST", "/open-apis/authen/v2/oauth/token", _, _, _}
    refute_receive {:lark, "POST", "/open-apis/im/v1/messages", _, _, _}

    assert {:ok, _} =
             Store.update_auth_config(ctx.actor.principal, ctx.config.id, %{"status" => "active"})

    assert {:ok, _} = Login.complete_oidc_login("approval-people", "restored-code", [])
    assert {:ok, _} = Delivery.deliver(intent)

    assert_receive {:lark, "POST", "/open-apis/im/v1/messages", _, _,
                    ["Bearer rotated-application-token"]}
  end

  test "first enterprise sign-in can create the human and its personal connection atomically",
       ctx do
    {:ok, _} = Repo.transact_top_level(fn -> Ankole.Ash.destroy(ctx.identity, :unbind_in_tx) end)

    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "approval-people",
        "lark",
        %{
          "appID" => "approval-app",
          "appSecret" => "secret",
          "authConfigId" => ctx.config.id,
          "sync" => %{"websocket" => false},
          "oidc" => %{
            "requestPersonalConnectorScopes" => true,
            "personalConnectorScopes" => ["task:task:write"]
          }
        },
        true
      )

    assert {:ok, %{principal_uid: uid}} =
             Ankole.IdentityProviders.Login.complete_oidc_login(
               "approval-people",
               "consent-code",
               []
             )

    assert uid != ctx.actor.principal.uid

    assert {:ok, %{external_subject_id: "employee-1"}} =
             Ankole.Connectors.Accounts.get_account(ctx.config.id, "human", uid)
  end

  defp click(ctx, id, value, employee) do
    body =
      Torque.encode!(%{
        "schema" => "2.0",
        "header" => %{
          "event_id" => id,
          "event_type" => "card.action.trigger",
          "token" => "verify",
          "app_id" => "approval-app"
        },
        "event" => %{
          "operator" => %{"user_id" => employee},
          "context" => %{"open_message_id" => "message-1"},
          "action" => %{"value" => value}
        }
      })

    timestamp = Integer.to_string(System.system_time(:second))

    signature =
      :crypto.hash(:sha256, timestamp <> "nonce" <> "signature-key" <> body)
      |> Base.encode16(case: :lower)

    Ankole.Files.HTTP.request(
      "POST",
      ctx.gateway_url <> "/webhooks/connectors/#{Repo.tenant_id!()}/auth/#{ctx.config.id}",
      [
        {"content-type", "application/json"},
        {"x-lark-request-timestamp", timestamp},
        {"x-lark-request-nonce", "nonce"},
        {"x-lark-signature", signature}
      ],
      body
    )
  end

  defp latest_run(id),
    do:
      Run
      |> Ash.Query.filter(automation_job_id == ^id)
      |> Ash.Query.sort(id: :desc)
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()

  defp execute(id),
    do:
      ExecuteRun.run(%Oban.Job{
        args: %{"automation_job_run_id" => id, "expected_slice_count" => 0},
        attempt: 1,
        max_attempts: 5
      })
end
