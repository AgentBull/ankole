defmodule Ankole.Connectors.OAuthProtocolTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.Connectors.{
    Accounts,
    ConnectedAccount,
    Credentials,
    OAuth,
    OAuthSession,
    Store,
    TokenRefresher
  }

  alias Ankole.Plugins.GitHubAdapter.Connector

  defmodule GitHub do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      case {conn.method, conn.request_path} do
        {"POST", "/login/oauth/access_token"} ->
          {:ok, body, conn} = read_body(conn)
          params = Torque.decode!(body)
          send(owner, {:token_request, self(), params})

          receive do
            {:token_response, status, payload} -> json(conn, status, payload)
          after
            5_000 -> send_resp(conn, 500, "test response missing")
          end

        {"GET", "/user"} ->
          send(owner, {:user_request, get_req_header(conn, "authorization")})
          json(conn, 200, %{"id" => 42})

        {method, path}
        when path in ["/repos/example/project/hooks", "/repos/example/project/hooks/99"] ->
          {:ok, body, conn} = read_body(conn)
          send(owner, {:hook_request, self(), method, path, body})

          receive do
            {:hook_response, 204, _} -> send_resp(conn, 204, "")
            {:hook_response, status, payload} -> json(conn, status, payload)
          after
            5_000 -> send_resp(conn, 500, "test response missing")
          end

        {"POST", "/open-apis/auth/v3/tenant_access_token/internal"} ->
          {:ok, body, conn} = read_body(conn)
          send(owner, {:app_token_request, self(), Torque.decode!(body)})

          receive do
            {:token_response, status, payload} -> json(conn, status, payload)
          after
            5_000 -> send_resp(conn, 500, "test response missing")
          end

        {"POST", "/app/installations/123/access_tokens"} ->
          send(owner, {:installation_request, self(), get_req_header(conn, "authorization")})

          receive do
            {:token_response, status, payload} -> json(conn, status, payload)
          after
            5_000 -> send_resp(conn, 500, "test response missing")
          end
      end
    end

    defp json(conn, status, body),
      do:
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Torque.encode!(body))
  end

  setup do
    server = start_supervised!({Bandit, plug: {GitHub, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{principal: admin} = human_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)
    %{principal: human} = human_fixture()

    {:ok, config} =
      Store.create_auth_config(admin, %{
        "plugin_id" => "github",
        "slug" => "engineering",
        "auth_scheme" => "oauth2",
        "secret" => %{"client_id" => "client-#{admin.uid}", "client_secret" => "client-secret"},
        "public_metadata" => %{
          "base_url" => "http://127.0.0.1:#{port}",
          "web_url" => "http://127.0.0.1:#{port}"
        }
      })

    %{config: config, admin: admin, human: human}
  end

  test "cancelled consent returns to its tenant and consumes the pending state", ctx do
    assert {:ok, %{authorization_url: url}} =
             OAuth.begin(ctx.human, %{
               "connection" => ctx.config.slug,
               "return_to" => "/connectors?connection=engineering"
             })

    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
    params = %{"state" => state, "error" => "access_denied"}

    assert {:ok,
            %{
              error: "oauth_authorization_cancelled",
              return_to: "/connectors?connection=engineering",
              tenant_id: tenant
            }} = OAuth.callback(params)

    assert tenant == Repo.tenant_id!()
    assert {:error, :invalid_oauth_state} = OAuth.callback(params)
    refute_receive {:token_request, _, _}
  end

  test "consent return destinations remain local to the tenant Pod", ctx do
    for return_to <- ["//outside.example/connectors", "/\\outside.example/connectors", nil] do
      assert {:ok, %{authorization_url: url}} =
               OAuth.begin(ctx.human, %{
                 "connection" => ctx.config.slug,
                 "return_to" => return_to
               })

      state =
        url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

      assert {:ok, %{return_to: nil, tenant_id: tenant}} =
               OAuth.callback(%{"state" => state, "error" => "access_denied"})

      assert tenant == Repo.tenant_id!()
    end
  end

  test "tenant teardown retries outages and finishes when a revoked provider refuses unsubscribe",
       ctx do
    {:ok, account} = expired_account(ctx, "unsubscribe-refresh")

    assert {:ok, trigger} =
             Ankole.Connectors.Triggers.create(ctx.human, %{
               "auth_config_id" => ctx.config.id,
               "connected_account_id" => account.id,
               "trigger_type" => "github_repository",
               "scope_key" => "example/project"
             })

    assert {:ok, _} =
             Ankole.Principals.HumanAccess.disable(
               ctx.human.uid,
               "departed",
               Ankole.ActorRef.from_principal(ctx.admin),
               Ankole.Kernel.gen_uuid_v7(),
               :offboarded
             )

    cleanup = async_tenant(fn -> Ankole.Connectors.teardown_tenant() end)
    assert_receive {:hook_request, request, "GET", "/repos/example/project/hooks", _}, 2_000
    send(request, {:hook_response, 503, %{"message" => "Temporary outage"}})
    assert {:error, :connector_subscription_cleanup_failed} = Task.await(cleanup)
    assert {:ok, %{status: "degraded"}} = Ankole.Connectors.Triggers.get(trigger.id)

    cleanup = async_tenant(fn -> Ankole.Connectors.teardown_tenant() end)
    assert_receive {:hook_request, request, "GET", "/repos/example/project/hooks", _}, 2_000
    send(request, {:hook_response, 401, %{"message" => "Bad credentials"}})
    assert {:snooze, 1} = Task.await(cleanup)
    assert {:error, :not_found} = Ankole.Connectors.Triggers.get(trigger.id)
    assert :ok = Ankole.Connectors.teardown_tenant()
    refute_received {:token_request, _, _}
  end

  test "OAuth-only tools give members a consent link and require a workspace account for services",
       ctx do
    spec = Enum.find(Connector.tools(), &(&1.upstream_auth == :adaptive_token))
    assert spec

    assert {:error, %{code: "oauth_consent_required", authorization_url: url}} =
             Ankole.Connectors.resolve_call(spec, ctx.human, ctx.config.slug, nil)

    assert String.starts_with?(url, AnkoleWeb.PodURL.tenant_origin(ctx.tenant) <> "/connectors?")

    %{principal: service} = agent_fixture()

    assert {:error, :connection_account_required} =
             Ankole.Connectors.resolve_call(spec, service, ctx.config.slug, nil)

    refute_receive {:token_request, _, _}
  end

  test "a workspace OAuth subscription uses its connected account and rejects missing grants",
       ctx do
    attrs = %{
      "auth_config_id" => ctx.config.id,
      "trigger_type" => "github_repository",
      "scope_key" => "example/project"
    }

    assert {:error, :connection_account_required} =
             Ankole.Connectors.Triggers.create(ctx.admin, attrs)

    assert {:ok, account} =
             Repo.transact_top_level(fn ->
               Accounts.put_tokens_in_tx(
                 ctx.config,
                 "app",
                 "workspace",
                 %{"access_token" => "workspace-token"},
                 %{}
               )
             end)

    assert {:ok, trigger} = Ankole.Connectors.Triggers.create(ctx.admin, attrs)
    assert trigger.connected_account_id == account.id
    assert {:error, %Ash.Error.Invalid{}} = Ankole.Connectors.Triggers.create(ctx.admin, attrs)
    refute_receive {:token_request, _, _}
  end

  test "the first permanently failed personal refresh returns a usable reconnect link", ctx do
    spec = Enum.find(Connector.tools(), &(&1.upstream_auth == :adaptive_token))

    {:ok, account} =
      Accounts.put_human_tokens(
        ctx.config.id,
        ctx.human.uid,
        %{"access_token" => "expired", "refresh_token" => "revoked", "expires_in" => -10},
        %{granted_scopes: spec.scopes}
      )

    call =
      async_tenant(fn ->
        Ankole.Connectors.resolve_call(spec, ctx.human, ctx.config.slug, nil)
      end)

    assert_receive {:token_request, request, %{"refresh_token" => "revoked"}}, 2_000
    send(request, {:token_response, 400, %{"error" => "invalid_grant"}})

    assert {:error, %{code: "oauth_consent_required", authorization_url: url}} = Task.await(call)
    assert String.contains?(url, "connection=engineering")
    assert URI.decode_query(URI.parse(url).query)["scopes"] == Enum.join(spec.scopes, " ")
    assert {:ok, %{status: "expired"}} = Accounts.get_by_id(account.id)
  end

  test "explicit workspace selection wins and revoked personal grants never fall through to a workspace",
       ctx do
    spec = Enum.find(Connector.tools(), &(&1.upstream_auth == :adaptive_token))

    {:ok, personal} =
      Accounts.put_human_tokens(
        ctx.config.id,
        ctx.human.uid,
        %{"access_token" => "personal-token", "expires_in" => 3600},
        %{granted_scopes: spec.scopes || []}
      )

    {:ok, workspace} =
      Repo.transact_top_level(fn ->
        Accounts.put_tokens_in_tx(
          ctx.config,
          "app",
          "workspace",
          %{"access_token" => "workspace-token", "expires_in" => 3600},
          %{}
        )
      end)

    assert {:ok, %{account: selected, access_token: "workspace-token"}} =
             Ankole.Connectors.resolve_call(spec, ctx.human, ctx.config.slug, "workspace")

    assert selected.id == workspace.id

    assert {:ok, %{account: selected, access_token: "personal-token"}} =
             Ankole.Connectors.resolve_call(spec, ctx.human, ctx.config.slug, nil)

    assert selected.id == personal.id
    assert {:ok, _} = Accounts.disconnect_account(ctx.human, personal.id)

    assert {:error, %{code: "oauth_consent_required", authorization_url: url}} =
             Ankole.Connectors.resolve_call(spec, ctx.human, ctx.config.slug, nil)

    assert String.contains?(url, "connection=engineering")

    assert {:ok, %{access_token: "workspace-token"}} =
             Ankole.Connectors.resolve_call(spec, ctx.human, ctx.config.slug, "workspace")

    assert {:error, :connection_account_not_found} =
             Ankole.Connectors.resolve_call(spec, ctx.human, ctx.config.slug, "unknown")
  end

  test "application token misses collapse per application without blocking another tenant", ctx do
    previous = Application.fetch_env(:ankole, Ankole.Plugins.LarkAdapter.Config)

    Application.put_env(:ankole, Ankole.Plugins.LarkAdapter.Config,
      client_opts: [base_url: ctx.config.public_metadata["base_url"], req_options: [retry: false]]
    )

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ankole, Ankole.Plugins.LarkAdapter.Config, value)
        :error -> Application.delete_env(:ankole, Ankole.Plugins.LarkAdapter.Config)
      end
    end)

    create = fn actor, slug ->
      Store.create_auth_config(actor, %{
        "plugin_id" => "lark",
        "slug" => slug,
        "auth_scheme" => "lark_app",
        "secret" => %{"appID" => slug, "appSecret" => "app-secret"},
        "public_metadata" => %{"base_url" => ctx.config.public_metadata["base_url"]}
      })
    end

    {:ok, first} = create.(ctx.admin, "first-application")
    second_tenant = create_tenant()

    second =
      Repo.with_tenant(second_tenant.id, fn ->
        %{principal: admin} = human_fixture()
        {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)
        {:ok, config} = create.(admin, "second-application")
        config
      end)

    adapter = Ankole.Plugins.LarkAdapter.Connector
    first_call = async_tenant(fn -> Credentials.access_token(first, nil, adapter) end)
    assert_receive {:app_token_request, first_request, %{"app_id" => "first-application"}}, 2_000
    same_call = async_tenant(fn -> Credentials.access_token(first, nil, adapter) end)

    second_call =
      async_tenant(fn ->
        Repo.with_tenant(second.tenant_id, fn ->
          Credentials.access_token(second, nil, adapter)
        end)
      end)

    assert_receive {:app_token_request, second_request, %{"app_id" => "second-application"}},
                   2_000

    send(
      second_request,
      {:token_response, 200,
       %{"code" => 0, "tenant_access_token" => "second-token", "expire" => 7200}}
    )

    assert {:ok, "second-token"} = Task.await(second_call)
    refute_receive {:app_token_request, _, %{"app_id" => "first-application"}}, 100

    send(
      first_request,
      {:token_response, 200,
       %{"code" => 0, "tenant_access_token" => "first-token", "expire" => 7200}}
    )

    assert {:ok, "first-token"} = Task.await(first_call)
    assert {:ok, "first-token"} = Task.await(same_call)
    refute_receive {:app_token_request, _, _}, 100
  end

  test "deleting a trigger during upstream subscribe preserves its identity until unsubscribe",
       ctx do
    {:ok, _} =
      Repo.transact_top_level(fn ->
        Accounts.put_tokens_in_tx(
          ctx.config,
          "app",
          "workspace",
          %{"access_token" => "workspace-token"},
          %{}
        )
      end)

    {:ok, trigger} =
      Ankole.Connectors.Triggers.create(ctx.admin, %{
        "auth_config_id" => ctx.config.id,
        "trigger_type" => "github_repository",
        "scope_key" => "example/project"
      })

    %{principal: agent} = agent_fixture()
    Ankole.ConversationsFixtures.grant_chat(ctx.admin.uid, agent.uid)
    actor = Ankole.AuthZ.Actor.new(ctx.admin)

    attrs = %{
      "config_ref" => "connector-trigger://" <> trigger.id,
      "agent_uid" => agent.uid,
      "target" => %{"conversation_id" => Ankole.Kernel.gen_uuid_v7()}
    }

    {:ok, binding} = Ankole.Signals.EventBindings.put(actor, attrs)
    subscribing = async_tenant(fn -> Ankole.Connectors.Triggers.reconcile(trigger.id) end)
    assert_receive {:hook_request, lookup, "GET", "/repos/example/project/hooks", _}, 2_000
    send(lookup, {:hook_response, 200, []})
    assert_receive {:hook_request, create, "POST", "/repos/example/project/hooks", payload}, 2_000
    callback = Torque.decode!(payload)["config"]["url"]

    {:ok, _} =
      Ankole.Signals.EventBindings.put(
        actor,
        Map.merge(attrs, %{"id" => binding.id, "enabled" => false})
      )

    assert {:ok, %{status: "deleting"}} = Ankole.Connectors.Triggers.delete(ctx.admin, trigger.id)
    send(create, {:hook_response, 201, %{"id" => 99}})
    assert {:ok, %{status: "deleting", external_subscription_id: "99"}} = Task.await(subscribing)

    deleting = async_tenant(fn -> Ankole.Connectors.Triggers.reconcile(trigger.id) end)
    assert_receive {:hook_request, lookup, "GET", "/repos/example/project/hooks", _}, 2_000
    send(lookup, {:hook_response, 200, [%{"id" => 99, "config" => %{"url" => callback}}]})
    assert_receive {:hook_request, remove, "DELETE", "/repos/example/project/hooks/99", _}, 2_000
    send(remove, {:hook_response, 204, nil})
    assert {:ok, %{__meta__: %{state: :deleted}}} = Task.await(deleting)
    assert {:error, :not_found} = Ankole.Connectors.Triggers.get(trigger.id)
  end

  test "retry preserves an in-flight subscription and its pending deletion", ctx do
    {:ok, _} =
      Repo.transact_top_level(fn ->
        Accounts.put_tokens_in_tx(
          ctx.config,
          "app",
          "workspace",
          %{"access_token" => "workspace-token"},
          %{}
        )
      end)

    {:ok, trigger} =
      Ankole.Connectors.Triggers.create(ctx.admin, %{
        "auth_config_id" => ctx.config.id,
        "trigger_type" => "github_repository",
        "scope_key" => "example/project"
      })

    %{principal: agent} = agent_fixture()
    Ankole.ConversationsFixtures.grant_chat(ctx.admin.uid, agent.uid)
    actor = Ankole.AuthZ.Actor.new(ctx.admin)

    attrs = %{
      "config_ref" => "connector-trigger://" <> trigger.id,
      "agent_uid" => agent.uid,
      "target" => %{"conversation_id" => Ankole.Kernel.gen_uuid_v7()}
    }

    {:ok, binding} = Ankole.Signals.EventBindings.put(actor, attrs)
    subscribing = async_tenant(fn -> Ankole.Connectors.Triggers.reconcile(trigger.id) end)
    assert_receive {:hook_request, lookup, "GET", "/repos/example/project/hooks", _}, 2_000
    send(lookup, {:hook_response, 200, []})
    assert_receive {:hook_request, create, "POST", "/repos/example/project/hooks", payload}, 2_000
    callback = Torque.decode!(payload)["config"]["url"]
    {:ok, leased} = Ankole.Connectors.Triggers.get(trigger.id)

    subscribing_retry = Ankole.Connectors.Triggers.retry(ctx.admin, trigger.id)

    {:ok, _} =
      Ankole.Signals.EventBindings.put(
        actor,
        Map.merge(attrs, %{"id" => binding.id, "enabled" => false})
      )

    assert {:ok, %{status: "deleting"}} = Ankole.Connectors.Triggers.delete(ctx.admin, trigger.id)
    deleting_retry = Ankole.Connectors.Triggers.retry(ctx.admin, trigger.id)
    {:ok, pending} = Ankole.Connectors.Triggers.get(trigger.id)
    send(create, {:hook_response, 201, %{"id" => 99}})
    subscribed = Task.await(subscribing)

    assert subscribing_retry == {:error, :connector_trigger_busy}
    assert deleting_retry == {:error, :connector_trigger_busy}
    assert pending.status == "deleting"
    assert pending.lease_expires_at == leased.lease_expires_at
    assert {:ok, %{status: "deleting", external_subscription_id: "99"}} = subscribed

    deleting = async_tenant(fn -> Ankole.Connectors.Triggers.reconcile(trigger.id) end)
    assert_receive {:hook_request, lookup, "GET", "/repos/example/project/hooks", _}, 2_000
    send(lookup, {:hook_response, 200, [%{"id" => 99, "config" => %{"url" => callback}}]})
    assert_receive {:hook_request, remove, "DELETE", "/repos/example/project/hooks/99", _}, 2_000
    send(remove, {:hook_response, 204, nil})
    assert {:ok, %{__meta__: %{state: :deleted}}} = Task.await(deleting)
    assert {:error, :not_found} = Ankole.Connectors.Triggers.get(trigger.id)
    refute_receive {:hook_request, _, "POST", _, _}
  end

  test "PKCE callback exchanges over HTTP without cookies and only its initiating member can claim once",
       ctx do
    {:ok, previous} =
      Accounts.put_human_tokens(
        ctx.config.id,
        ctx.human.uid,
        %{"access_token" => "existing-access", "expires_in" => 3600},
        %{granted_scopes: ["read:user"]}
      )

    {:ok, begun} =
      OAuth.begin(ctx.human, %{
        "connection" => ctx.config.slug,
        "scopes" => ["repo"],
        "return_to" => "/connectors"
      })

    authorize = begun.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert authorize["code_challenge_method"] == "S256"
    assert authorize["client_id"] == "client-#{ctx.admin.uid}"
    assert authorize["scope"] == "read:user repo"

    callback =
      async_tenant(fn ->
        OAuth.callback(%{"state" => authorize["state"], "code" => "authorization-code"})
      end)

    assert_receive {:token_request, request, params}, 2_000
    assert params["code"] == "authorization-code"
    assert params["client_secret"] == "client-secret"

    assert authorize["code_challenge"] ==
             Base.url_encode64(:crypto.hash(:sha256, params["code_verifier"]), padding: false)

    assert params["redirect_uri"] == OAuth.callback_url()

    send(
      request,
      {:token_response, 200,
       %{
         "access_token" => "new-access",
         "refresh_token" => "new-refresh",
         "expires_in" => 3600,
         "scope" => "repo read:user"
       }}
    )

    assert_receive {:user_request, ["Bearer new-access"]}

    assert {:ok, %{completion_code: code, tenant_id: tenant, return_to: "/connectors"}} =
             Task.await(callback)

    assert tenant == Repo.tenant_id!()

    assert {:ok, %{credentials_version: version}} =
             Accounts.get_account(ctx.config.id, "human", ctx.human.uid)

    assert version == previous.credentials_version
    assert {:ok, "existing-access"} = Credentials.access_token(ctx.config, previous, Connector)

    assert {:error, :invalid_oauth_state} =
             OAuth.callback(%{"state" => authorize["state"], "code" => "replay"})

    assert {:error, :invalid_oauth_completion} = OAuth.claim(ctx.admin, code)
    assert {:ok, public} = OAuth.claim(ctx.human, code)
    assert public.external_subject_id == "42"
    assert public.granted_scopes == ["repo", "read:user"]
    refute Map.has_key?(public, :sealed_credentials)
    assert {:ok, account} = Accounts.get_account(ctx.config.id, "human", ctx.human.uid)
    assert {:ok, %{"access_token" => "new-access"}} = Credentials.account_credentials(account)
    assert {:error, :invalid_oauth_completion} = OAuth.claim(ctx.human, code)
    session = Ankole.Ash.read_one!(OAuthSession)
    assert session.status == "completed"
    assert is_nil(session.sealed_pending_tokens)
    assert is_nil(session.sealed_pkce_verifier)
  end

  test "personal consent started before a Principal rename can be claimed by the renamed member",
       ctx do
    {:ok, begun} =
      OAuth.begin(ctx.human, %{"connection" => ctx.config.slug, "scopes" => ["repo"]})

    state = begun.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    callback =
      async_tenant(fn ->
        OAuth.callback(%{"state" => state["state"], "code" => "consent-code"})
      end)

    assert_receive {:token_request, request, _}, 2_000

    assert {:ok, %{principal: renamed}} =
             Ankole.Principals.rename(ctx.human.uid, "renamed-consent-owner")

    send(
      request,
      {:token_response, 200,
       %{
         "access_token" => "renamed-access",
         "refresh_token" => "renamed-refresh",
         "scope" => "repo"
       }}
    )

    assert {:ok, %{completion_code: code}} = Task.await(callback)
    assert {:ok, %{owner_principal_uid: uid}} = OAuth.claim(renamed, code)
    assert uid == renamed.uid
    assert {:ok, nil} = Accounts.get_account(ctx.config.id, "human", ctx.human.uid)
    assert {:ok, account} = Accounts.get_account(ctx.config.id, "human", renamed.uid)
    assert {:ok, "renamed-access"} = Credentials.access_token(ctx.config, account, Connector)
  end

  test "tenant deletion preserves credentials until its upstream subscription is removed", ctx do
    {:ok, _} =
      Repo.transact_top_level(fn ->
        Accounts.put_tokens_in_tx(
          ctx.config,
          "app",
          "workspace",
          %{"access_token" => "workspace-token"},
          %{}
        )
      end)

    {:ok, trigger} =
      Ankole.Connectors.Triggers.create(ctx.admin, %{
        "auth_config_id" => ctx.config.id,
        "trigger_type" => "github_repository",
        "scope_key" => "example/project"
      })

    callback =
      AnkoleWeb.Endpoint.url() <>
        "/webhooks/connectors/#{ctx.tenant.id}/triggers/#{trigger.id}"

    assert {:ok, _} = Ankole.Tenants.delete(ctx.tenant)
    first = async_tenant(fn -> drain_tenant_delete(ctx.tenant.id) end)
    assert_receive {:hook_request, lookup, "GET", "/repos/example/project/hooks", _}, 2_000
    send(lookup, {:hook_response, 200, [%{"id" => 99, "config" => %{"url" => callback}}]})
    assert_receive {:hook_request, remove, "DELETE", "/repos/example/project/hooks/99", _}, 2_000
    send(remove, {:hook_response, 503, %{"message" => "temporarily unavailable"}})
    assert {:error, :connector_subscription_cleanup_failed} = Task.await(first)
    assert {:ok, %{deleting_at: deleting_at}} = Ankole.Tenants.get(ctx.tenant.id)
    assert deleting_at
    assert {:ok, %{status: "degraded"}} = Ankole.Connectors.Triggers.get(trigger.id)

    assert {:ok, %{"clientSecret" => "client-secret"}} =
             Credentials.resolve_credentials(ctx.config.id)

    retry = async_tenant(fn -> drain_tenant_delete(ctx.tenant.id) end)
    assert_receive {:hook_request, lookup, "GET", "/repos/example/project/hooks", _}, 2_000
    send(lookup, {:hook_response, 200, [%{"id" => 99, "config" => %{"url" => callback}}]})
    assert_receive {:hook_request, remove, "DELETE", "/repos/example/project/hooks/99", _}, 2_000
    send(remove, {:hook_response, 204, nil})
    assert :ok = Task.await(retry)
    assert {:error, :not_found} = Ankole.Tenants.get(ctx.tenant.id)
    assert {:error, :not_found} = Ankole.Connectors.Triggers.get(trigger.id)
    assert {:error, :connection_required} = Credentials.resolve_credentials(ctx.config.id)
    assert :ok = Ankole.Tenants.Jobs.Delete.run(%Oban.Job{args: %{"tenant_id" => ctx.tenant.id}})
  end

  test "an OAuth callback cannot change issuer or tenant and expiration consumes no account",
       ctx do
    {:ok, _} =
      Store.update_auth_config(ctx.admin, ctx.config.id, %{
        "public_metadata" =>
          Map.put(ctx.config.public_metadata, "oauth_issuer", "https://github.example")
      })

    {:ok, begun} = OAuth.begin(ctx.human, %{"connection" => ctx.config.slug})
    params = begun.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert {:error, :oauth_issuer_mismatch} =
             OAuth.callback(%{
               "state" => params["state"],
               "code" => "code",
               "iss" => "https://other.example"
             })

    refute_receive {:token_request, _, _}

    assert {:error, :invalid_oauth_state} =
             OAuth.callback(%{
               "state" => params["state"],
               "code" => "code",
               "iss" => "https://github.example"
             })

    second = create_tenant()
    forged = second.id <> "." <> List.last(String.split(params["state"], "."))
    assert {:error, :invalid_oauth_state} = OAuth.callback(%{"state" => forged, "code" => "code"})
    assert Ankole.Ash.count!(ConnectedAccount) == 0
  end

  test "saving connection presentation preserves an in-flight rotating refresh token", ctx do
    {:ok, account} = expired_account(ctx, "old-refresh")
    refresh = async_tenant(fn -> TokenRefresher.access_token(ctx.config, account, Connector) end)
    assert_receive {:token_request, request, params}, 2_000
    assert params["refresh_token"] == "old-refresh"

    assert {:ok, _} =
             Store.update_auth_config(ctx.admin, ctx.config.id, %{
               "display_name" => "Engineering GitHub"
             })

    assert {:ok, saved} =
             Store.update_auth_config(ctx.admin, ctx.config.id, %{
               "display_name" => "Engineering GitHub",
               "slug" => "engineering-team",
               "is_default" => true,
               "secret" => %{},
               "public_metadata" => ctx.config.public_metadata
             })

    send(
      request,
      {:token_response, 200,
       %{
         "access_token" => "refreshed-access",
         "refresh_token" => "rotated-refresh",
         "expires_in" => 3600
       }}
    )

    assert {:ok, "refreshed-access"} = Task.await(refresh)
    assert saved.secret_version == ctx.config.secret_version
    {:ok, current} = Accounts.get_account(ctx.config.id, "human", ctx.human.uid)

    assert {:ok, %{"refresh_token" => "rotated-refresh"}} =
             Credentials.account_credentials(current)

    {:ok, expired} =
      Ankole.Ash.update(current, :update, %{expires_at: DateTime.add(DateTime.utc_now(), -10)})

    next_refresh = async_tenant(fn -> TokenRefresher.access_token(saved, expired, Connector) end)
    assert_receive {:token_request, next_request, next_params}, 2_000
    assert next_params["refresh_token"] == "rotated-refresh"

    send(
      next_request,
      {:token_response, 200,
       %{
         "access_token" => "next-access",
         "refresh_token" => "next-refresh",
         "expires_in" => 3600
       }}
    )

    assert {:ok, "next-access"} = Task.await(next_refresh)
  end

  test "a Principal rename preserves an in-flight rotating grant for the same member", ctx do
    {:ok, account} = expired_account(ctx, "before-rename-refresh")
    refresh = async_tenant(fn -> TokenRefresher.access_token(ctx.config, account, Connector) end)
    assert_receive {:token_request, request, %{"refresh_token" => "before-rename-refresh"}}, 2_000

    assert {:ok, %{principal: renamed}} =
             Ankole.Principals.rename(ctx.human.uid, "renamed-refresh-owner")

    send(
      request,
      {:token_response, 200,
       %{
         "access_token" => "after-rename-access",
         "refresh_token" => "after-rename-refresh",
         "expires_in" => 3600
       }}
    )

    assert {:ok, "after-rename-access"} = Task.await(refresh)
    {:ok, current} = Accounts.get_account(ctx.config.id, "human", renamed.uid)
    assert current.id == account.id

    assert {:ok, %{"refresh_token" => "after-rename-refresh"}} =
             Credentials.account_credentials(current)

    {:ok, expired} =
      Ankole.Ash.update(current, :update, %{expires_at: DateTime.add(DateTime.utc_now(), -10)})

    next = async_tenant(fn -> TokenRefresher.access_token(ctx.config, expired, Connector) end)

    assert_receive {:token_request, next_request, %{"refresh_token" => "after-rename-refresh"}},
                   2_000

    send(
      next_request,
      {:token_response, 200,
       %{"access_token" => "next-access", "refresh_token" => "next-refresh", "expires_in" => 3600}}
    )

    assert {:ok, "next-access"} = Task.await(next)
  end

  test "refresh grants one lease and credential rotation fences the in-flight HTTP result", ctx do
    {:ok, account} = expired_account(ctx, "old-refresh")
    refresh = async_tenant(fn -> TokenRefresher.access_token(ctx.config, account, Connector) end)
    assert_receive {:token_request, request, params}, 2_000
    assert params["refresh_token"] == "old-refresh"

    assert {:ok, rotated} =
             Store.update_auth_config(ctx.admin, ctx.config.id, %{
               "secret" => %{"client_secret" => "rotated-secret"}
             })

    send(
      request,
      {:token_response, 200,
       %{
         "access_token" => "stale-response",
         "refresh_token" => "stale-rotation",
         "expires_in" => 3600
       }}
    )

    assert {:error, :oauth_refresh_superseded} = Task.await(refresh)
    {:ok, current} = Accounts.get_account(ctx.config.id, "human", ctx.human.uid)
    assert is_nil(current.refresh_lease_id)

    assert {:ok, %{"access_token" => "expired", "refresh_token" => "old-refresh"}} =
             Credentials.account_credentials(current)

    retry = async_tenant(fn -> TokenRefresher.access_token(rotated, current, Connector) end)
    assert_receive {:token_request, retry_request, retry_params}, 2_000
    assert retry_params["client_secret"] == "rotated-secret"

    send(
      retry_request,
      {:token_response, 200,
       %{
         "access_token" => "current-response",
         "refresh_token" => "current-refresh",
         "expires_in" => 3600
       }}
    )

    assert {:ok, "current-response"} = Task.await(retry)
  end

  test "late failures cannot overwrite a reconnected grant and upstream failures persist cooldown",
       ctx do
    {:ok, account} = expired_account(ctx, "old-refresh")
    refresh = async_tenant(fn -> TokenRefresher.access_token(ctx.config, account, Connector) end)
    assert_receive {:token_request, request, _}, 2_000

    {:ok, reconnected} =
      Accounts.put_human_tokens(ctx.config.id, ctx.human.uid, %{
        "access_token" => "reconnected",
        "refresh_token" => "new-refresh",
        "expires_in" => 3600
      })

    send(request, {:token_response, 400, %{"error" => "invalid_grant"}})
    assert {:error, :oauth_refresh_superseded} = Task.await(refresh)
    {:ok, current} = Accounts.get_account(ctx.config.id, "human", ctx.human.uid)
    assert current.credentials_version == reconnected.credentials_version
    assert current.status == "active" and is_nil(current.last_error)
    assert {:ok, %{"access_token" => "reconnected"}} = Credentials.account_credentials(current)

    {:ok, account} = expired_account(ctx, "temporary-refresh")
    refresh = async_tenant(fn -> TokenRefresher.access_token(ctx.config, account, Connector) end)
    assert_receive {:token_request, request, _}, 2_000
    send(request, {:token_response, 503, %{"error" => "temporarily_unavailable"}})
    assert {:error, :oauth_refresh_failed} = Task.await(refresh)
    {:ok, current} = Accounts.get_account(ctx.config.id, "human", ctx.human.uid)
    assert current.last_refresh_failure_at && current.first_refresh_failure_at

    assert {:error, :oauth_refresh_cooling_down} =
             TokenRefresher.access_token(ctx.config, current, Connector)

    refute_receive {:token_request, _, _}
  end

  test "concurrent callers share refreshed credentials and retain access during the refresh window",
       ctx do
    for expires_in <- [-10, 45] do
      assert {:ok, account} =
               Accounts.put_human_tokens(ctx.config.id, ctx.human.uid, %{
                 "access_token" => "current-access",
                 "refresh_token" => "rotating-refresh",
                 "expires_in" => expires_in,
                 "refresh_expires_in" => 3600
               })

      refresh =
        async_tenant(fn -> TokenRefresher.access_token(ctx.config, account, Connector) end)

      assert_receive {:token_request, request, %{"refresh_token" => "rotating-refresh"}}, 2_000

      follower =
        async_tenant(fn -> TokenRefresher.access_token(ctx.config, account, Connector) end)

      if expires_in > 0 do
        assert {:ok, "current-access"} = Task.await(follower)
      else
        assert Task.yield(follower, 200) == nil
      end

      refute_received {:token_request, _, _}

      send(
        request,
        {:token_response, 200,
         %{
           "access_token" => "next-access",
           "refresh_token" => "next-refresh",
           "expires_in" => 3600
         }}
      )

      assert {:ok, "next-access"} = Task.await(refresh)
      if expires_in < 0, do: assert({:ok, "next-access"} = Task.await(follower))
      refute_received {:token_request, _, _}
    end
  end

  test "upstream rejection refreshes only the rejected token and preserves a newer token", ctx do
    assert {:ok, account} =
             Accounts.put_human_tokens(ctx.config.id, ctx.human.uid, %{
               "access_token" => "rejected-access",
               "refresh_token" => "refresh",
               "expires_in" => 3600
             })

    assert {:ok, "rejected-access"} = Credentials.access_token(ctx.config, account, Connector)

    assert {:ok, :ok} =
             Credentials.invalidate_access_token(ctx.config, account, "rejected-access")

    refresh = async_tenant(fn -> Credentials.access_token(ctx.config, account, Connector) end)
    assert_receive {:token_request, request, %{"refresh_token" => "refresh"}}, 2_000

    send(
      request,
      {:token_response, 200,
       %{
         "access_token" => "replacement-access",
         "refresh_token" => "replacement-refresh",
         "expires_in" => 3600
       }}
    )

    assert {:ok, "replacement-access"} = Task.await(refresh)

    assert {:ok, :ok} =
             Credentials.invalidate_access_token(ctx.config, account, "rejected-access")

    assert {:ok, "replacement-access"} = Credentials.access_token(ctx.config, account, Connector)
    refute_received {:token_request, _, _}
  end

  test "offboarding revokes an expired account and retains its credentials only for unsubscribe",
       ctx do
    {:ok, account} = expired_account(ctx, "unsubscribe-refresh")
    assert {:ok, expired} = Ankole.Ash.update(account, :update, %{status: "expired"})

    assert {:ok, _} =
             Ankole.Principals.HumanAccess.disable(
               ctx.human.uid,
               "departed",
               Ankole.ActorRef.from_principal(ctx.admin),
               Ankole.Kernel.gen_uuid_v7(),
               :offboarded
             )

    assert {:ok, %{status: "revoked"} = revoked} = Accounts.get_by_id(expired.id)
    assert revoked.credentials_version == expired.credentials_version + 1

    assert {:error, :oauth_reauthorization_required} =
             Credentials.access_token(ctx.config, revoked, Connector)

    assert {:ok, "expired"} =
             Credentials.subscription_token(ctx.config, revoked, Connector, false)

    refute_received {:token_request, _, _}
  end

  test "offboarding rejects late refreshes and restored members reconnect with fresh consent",
       ctx do
    {:ok, account} = expired_account(ctx, "old-refresh")
    refresh = async_tenant(fn -> TokenRefresher.access_token(ctx.config, account, Connector) end)
    assert_receive {:token_request, request, _}, 2_000

    assert {:ok, _} =
             Ankole.Principals.HumanAccess.disable(
               ctx.human.uid,
               "departed",
               Ankole.ActorRef.from_principal(ctx.admin),
               Ankole.Kernel.gen_uuid_v7(),
               :offboarded
             )

    send(
      request,
      {:token_response, 200,
       %{
         "access_token" => "late-response",
         "refresh_token" => "late-refresh",
         "expires_in" => 3600
       }}
    )

    assert {:error, :human_access_revoked} = Task.await(refresh)
    {:ok, revoked} = Accounts.get_account(ctx.config.id, "human", ctx.human.uid)
    assert revoked.status == "revoked"
    assert is_nil(revoked.refresh_lease_id)

    assert {:error, :oauth_reauthorization_required} =
             Credentials.access_token(ctx.config, account, Connector)

    assert {:ok, %{"access_token" => "expired"}} = Credentials.account_credentials(revoked)

    assert {:ok, restored} =
             Ankole.Principals.HumanAccess.restore(
               ctx.human.uid,
               Ankole.ActorRef.from_principal(ctx.admin),
               "returned",
               Ankole.Kernel.gen_uuid_v7()
             )

    assert restored.access_version > account.owner_access_version

    assert {:error, :oauth_reauthorization_required} =
             Credentials.access_token(ctx.config, revoked, Connector)

    refute_receive {:token_request, _, _}

    assert {:ok, begun} =
             OAuth.begin(restored, %{"connection" => ctx.config.slug, "scopes" => ["repo"]})

    state = begun.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    callback =
      async_tenant(fn ->
        OAuth.callback(%{"state" => state["state"], "code" => "renewed-consent"})
      end)

    assert_receive {:token_request, request, %{"code" => "renewed-consent"}}, 2_000

    send(
      request,
      {:token_response, 200,
       %{
         "access_token" => "restored-access",
         "refresh_token" => "restored-refresh",
         "expires_in" => 3600,
         "scope" => "repo"
       }}
    )

    assert {:ok, %{completion_code: code}} = Task.await(callback)
    assert {:ok, _} = OAuth.claim(restored, code)
    assert {:ok, fresh} = Accounts.get_account(ctx.config.id, "human", restored.uid)
    assert fresh.id == account.id
    assert fresh.owner_access_version == restored.access_version
    assert {:ok, "restored-access"} = Credentials.access_token(ctx.config, fresh, Connector)
  end

  test "GitHub installation metadata derives cached app tokens and rotation takes effect immediately",
       ctx do
    key = :public_key.generate_key({:rsa, 2048, 65537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    {:ok, config} =
      Store.create_auth_config(ctx.admin, %{
        "plugin_id" => "github",
        "slug" => "installed",
        "auth_scheme" => "github_app",
        "secret" => %{"app_id" => "12345", "private_key" => pem},
        "public_metadata" => Map.put(ctx.config.public_metadata, "installation_id", "123")
      })

    {:ok, account} = Accounts.get_account(config.id, "app", "123")
    assert account.external_subject_id == "123" and is_nil(account.sealed_credentials)
    fetched = async_tenant(fn -> Credentials.access_token(config, account, Connector) end)
    assert_receive {:installation_request, request, ["Bearer " <> jwt]}, 2_000
    [header, claims, signature] = String.split(jwt, ".")
    assert Torque.decode!(Base.url_decode64!(claims, padding: false))["iss"] == "12345"

    assert :public_key.verify(
             header <> "." <> claims,
             :sha256,
             Base.url_decode64!(signature, padding: false),
             {:RSAPublicKey, elem(key, 2), elem(key, 3)}
           )

    send(
      request,
      {:token_response, 201,
       %{
         "token" => "installation-one",
         "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
       }}
    )

    assert {:ok, "installation-one"} = Task.await(fetched)
    assert {:ok, "installation-one"} = Credentials.access_token(config, account, Connector)
    refute_receive {:installation_request, _, _}

    {:ok, _} =
      Store.update_auth_config(ctx.admin, config.id, %{"secret" => %{"private_key" => pem}})

    assert {:ok, "installation-one"} = Credentials.access_token(config, account, Connector)
    refute_receive {:installation_request, _, _}

    rotated_key = :public_key.generate_key({:rsa, 2048, 65537})

    rotated_pem =
      :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rotated_key)])

    {:ok, _} =
      Store.update_auth_config(ctx.admin, config.id, %{
        "secret" => %{"private_key" => rotated_pem}
      })

    fetched = async_tenant(fn -> Credentials.access_token(config, account, Connector) end)
    assert_receive {:installation_request, request, ["Bearer " <> rotated_jwt]}, 2_000
    [header, claims, signature] = String.split(rotated_jwt, ".")

    assert :public_key.verify(
             header <> "." <> claims,
             :sha256,
             Base.url_decode64!(signature, padding: false),
             {:RSAPublicKey, elem(rotated_key, 2), elem(rotated_key, 3)}
           )

    send(
      request,
      {:token_response, 201,
       %{
         "token" => "installation-two",
         "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
       }}
    )

    assert {:ok, "installation-two"} = Task.await(fetched)
    {:ok, latest} = Accounts.get_account(config.id, "app", "123")
    assert is_nil(latest.sealed_credentials)
    assert {:ok, _} = Accounts.disconnect_account(ctx.admin, account.id)

    assert {:error, :oauth_reauthorization_required} =
             Credentials.access_token(config, account, Connector)
  end

  test "hourly maintenance removes expired OAuth sessions without disrupting pending consent",
       ctx do
    now = DateTime.utc_now()

    sessions =
      for status <- ["pending", "failed", "callback_received", "completed"] do
        {:ok, _} = OAuth.begin(ctx.human, %{"connection" => ctx.config.slug})
        session = OAuthSession |> Ash.Query.sort(inserted_at: :desc) |> Ankole.Ash.read!() |> hd()

        {:ok, expired} =
          Ankole.Ash.update(session, :update, %{
            status: status,
            expires_at: DateTime.add(now, -1)
          })

        expired
      end

    {:ok, %{authorization_url: url}} = OAuth.begin(ctx.human, %{"connection" => ctx.config.slug})

    assert :ok =
             Repo.without_tenant(fn ->
               Ankole.Connectors.Jobs.RefreshAccounts.run(%Oban.Job{})
             end)

    assert [pending] = Ankole.Ash.read!(OAuthSession)
    refute pending.id in Enum.map(sessions, & &1.id)
    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    assert {:ok, %{error: "oauth_authorization_cancelled"}} =
             OAuth.callback(%{"state" => state, "error" => "access_denied"})
  end

  defp drain_tenant_delete(id) do
    Enum.reduce_while(1..20, {:error, :tenant_cleanup_incomplete}, fn _, _ ->
      case Ankole.Tenants.Jobs.Delete.run(%Oban.Job{args: %{"tenant_id" => id}}) do
        {:snooze, _} -> {:cont, {:error, :tenant_cleanup_incomplete}}
        result -> {:halt, result}
      end
    end)
  end

  defp expired_account(ctx, token),
    do:
      Accounts.put_human_tokens(ctx.config.id, ctx.human.uid, %{
        "access_token" => "expired",
        "refresh_token" => token,
        "expires_in" => -10
      })

  defp async_tenant(fun) do
    tenant = Repo.tenant_id!()
    Task.async(fn -> Repo.with_tenant(tenant, fun) end)
  end
end
