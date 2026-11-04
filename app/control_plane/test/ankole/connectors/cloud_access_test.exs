defmodule Ankole.Connectors.CloudAccessTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Connectors.{Accounts, Credentials, Store, Triggers}

  setup do
    %{principal: admin} = human_fixture()
    %{principal: member} = human_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)

    {:ok, config} =
      Store.create_auth_config(admin, %{
        "plugin_id" => "github",
        "slug" => "engineering",
        "auth_scheme" => "oauth2",
        "secret" => %{"client_id" => "client-#{admin.uid}", "client_secret" => "secret"}
      })

    %{admin: admin, member: member, config: config}
  end

  test "personal views remain private for members and administrators", ctx do
    {:ok, mine} =
      Accounts.put_human_tokens(ctx.config.id, ctx.admin.uid, %{"access_token" => "admin"})

    {:ok, theirs} =
      Accounts.put_human_tokens(ctx.config.id, ctx.member.uid, %{"access_token" => "member"})

    {:ok, team} =
      Repo.transact_top_level(fn ->
        Accounts.put_tokens_in_tx(
          ctx.config,
          "app",
          "workspace",
          %{"access_token" => "team"},
          %{}
        )
      end)

    assert {:ok, [own]} = Accounts.list_accounts(ctx.admin, "mine")
    assert own.id == mine.id
    assert {:ok, [own]} = Accounts.list_accounts(ctx.member, "mine")
    assert own.id == theirs.id
    assert {:ok, [shared]} = Accounts.list_accounts(ctx.member, "team")
    assert shared.id == team.id
    refute Map.has_key?(shared, :sealed_credentials)
  end

  test "an administrator cannot create a subscription using another member's account", ctx do
    {:ok, account} =
      Accounts.put_human_tokens(ctx.config.id, ctx.member.uid, %{"access_token" => "member"})

    assert {:error, :forbidden} =
             Triggers.create(ctx.admin, %{
               "auth_config_id" => ctx.config.id,
               "connected_account_id" => account.id,
               "trigger_type" => "github.repository",
               "scope_key" => "owner/repo"
             })

    assert {:ok, %{status: "revoked"}} = Accounts.disconnect_account(ctx.admin, account.id)
  end

  test "reauthorization keeps the local account and queues cloud handover after its write", ctx do
    {:ok, original} =
      Accounts.put_human_tokens(ctx.config.id, ctx.member.uid, %{
        "upstream_connection_id" => "cloud-old"
      })

    {:ok, replacement} =
      Accounts.put_human_tokens(ctx.config.id, ctx.member.uid, %{
        "upstream_connection_id" => "cloud-new"
      })

    assert original.id == replacement.id
    assert replacement.sealed_credentials == nil
    assert Accounts.cloud_account_referenced?("cloud-new")
    refute Accounts.cloud_account_referenced?("cloud-old")

    assert_enqueued(
      worker: Ankole.Connectors.Jobs.CloudAccount,
      args: %{
        operation: "claim",
        upstream_connection_id: "cloud-new",
        previous_upstream_connection_id: "cloud-old"
      }
    )

    assert {:ok, %{status: "revoked"}} = Accounts.disconnect_account(ctx.member, replacement.id)
    refute Accounts.cloud_account_referenced?("cloud-new")

    assert_enqueued(
      worker: Ankole.Connectors.Jobs.CloudAccount,
      args: %{operation: "revoke", upstream_connection_id: "cloud-new"}
    )
  end

  test "a single active local application resolves without an administrator selecting a default",
       ctx do
    assert {:ok, selected} = Store.get_auth_config(nil, "github")
    assert selected.id == ctx.config.id
    assert {:ok, secret} = Credentials.secret(selected)
    assert secret["clientSecret"] == "secret"
  end

  test "reconnecting a local account resumes failed subscriptions and preserves deletion intent",
       ctx do
    {:ok, account} =
      Accounts.put_human_tokens(ctx.config.id, ctx.member.uid, %{"access_token" => "old"})

    triggers =
      for {scope, error} <- [
            {"owner/resume", %{"code" => "invalid_grant"}},
            {"owner/remove", %{"operation" => "delete"}}
          ] do
        {:ok, trigger} =
          Triggers.create(ctx.member, %{
            "auth_config_id" => ctx.config.id,
            "connected_account_id" => account.id,
            "trigger_type" => "github_repository",
            "scope_key" => scope
          })

        {:ok, row} = Triggers.get(trigger.id)

        {:ok, _} =
          Ankole.Ash.update(row, :update, %{
            status: "degraded",
            last_error: error,
            external_subscription_id: scope
          })

        trigger
      end

    assert {:ok, reconnected} =
             Accounts.put_human_tokens(ctx.config.id, ctx.member.uid, %{"access_token" => "new"})

    assert reconnected.id == account.id

    for {trigger, expected} <- Enum.zip(triggers, ["provisioning", "deleting"]) do
      assert {:ok, row} = Triggers.get(trigger.id)
      assert row.status == expected
      assert row.last_error == nil
      assert row.external_subscription_id == trigger.scope_key

      assert_enqueued(
        worker: Ankole.Connectors.Jobs.ReconcileTrigger,
        args: %{"trigger_id" => trigger.id}
      )
    end
  end

  test "missing team credentials do not send members into a personal OAuth flow", ctx do
    for {plugin, scheme} <- [{"stripe", "api_token"}, {"figma", "personal_token"}] do
      {:ok, _} =
        Store.create_auth_config(ctx.admin, %{
          "plugin_id" => plugin,
          "slug" => plugin,
          "auth_scheme" => scheme,
          "secret" => %{}
        })
    end

    {:ok, _, [stripe | _]} = Ankole.Connectors.Registry.toolkit("stripe")

    assert {:error, :connection_account_required} =
             Ankole.Connectors.Resolver.resolve_call(stripe, ctx.member, "stripe", nil)

    {:ok, _, [figma | _]} = Ankole.Connectors.Registry.toolkit("figma")

    assert {:error, %{code: "oauth_consent_required", authorization_url: url}} =
             Ankole.Connectors.Resolver.resolve_call(figma, ctx.member, "figma", nil)

    assert URI.decode_query(URI.parse(url).query)["auth_mode"] == "personal_credentials"

    for plugin <- ["stripe", "figma"] do
      assert {:error, %{authorization_url: url}} =
               Ankole.Connectors.OAuth.consent_required(plugin, [], %{"subject_kind" => "app"})

      assert %{"auth_mode" => "team_credentials", "subject_kind" => "app"} =
               URI.decode_query(URI.parse(url).query)
    end
  end

  test "team OAuth subscriptions request missing permissions before creating an upstream hook",
       ctx do
    {:ok, config} =
      Store.create_auth_config(ctx.admin, %{
        "plugin_id" => "gitlab",
        "slug" => "gitlab",
        "auth_scheme" => "oauth2",
        "secret" => %{"client_id" => ctx.admin.uid, "client_secret" => "secret"}
      })

    {:ok, account} =
      Repo.transact_top_level(fn ->
        Accounts.put_tokens_in_tx(config, "app", "team", %{"access_token" => "token"}, %{
          granted_scopes: ["read_api"]
        })
      end)

    attrs = %{
      "auth_config_id" => config.id,
      "connected_account_id" => account.id,
      "trigger_type" => "gitlab.push",
      "scope_key" => "42"
    }

    assert {:error, %{code: "oauth_consent_required", scopes: scopes, authorization_url: url}} =
             Triggers.create(ctx.admin, attrs)

    assert Enum.sort(scopes) == ["api", "read_api"]
    assert URI.decode_query(URI.parse(url).query)["subject_kind"] == "app"

    {:ok, _} =
      Repo.transact_top_level(fn ->
        Accounts.put_tokens_in_tx(config, "app", "team", %{"access_token" => "expanded"}, %{
          granted_scopes: scopes
        })
      end)

    assert {:ok, trigger} = Triggers.create(ctx.admin, attrs)
    assert trigger.connected_account_id == account.id
  end

  test "adding a consumer to an application-token subscription requires its management authority",
       ctx do
    {:ok, config} =
      Store.create_auth_config(ctx.admin, %{
        "plugin_id" => "lark",
        "slug" => "approval-events",
        "auth_scheme" => "lark_app",
        "secret" => %{"appID" => "approval-#{ctx.admin.uid}", "appSecret" => "secret"}
      })

    {:ok, trigger} =
      Triggers.create(ctx.admin, %{
        "auth_config_id" => config.id,
        "trigger_type" => "lark_approval",
        "scope_key" => "approval-definition"
      })

    assert trigger.connected_account_id == nil
    %{principal: agent} = agent_fixture()
    Ankole.ConversationsFixtures.grant_chat(ctx.member.uid, agent.uid)

    assert {:error, :forbidden} =
             Ankole.Signals.EventBindings.put(Ankole.AuthZ.Actor.new(ctx.member), %{
               "config_ref" => "connector-trigger://" <> trigger.id,
               "agent_uid" => agent.uid,
               "target" => %{"conversation_id" => Ankole.Kernel.gen_uuid_v7()}
             })
  end
end
