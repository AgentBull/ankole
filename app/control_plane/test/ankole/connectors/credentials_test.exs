defmodule Ankole.Connectors.CredentialsTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  require Ash.Query

  alias Ankole.Connectors.{
    Accounts,
    AuthConfig,
    ConnectedAccount,
    Credentials,
    LegacyConfig,
    Store,
    TokenRefresher
  }

  defmodule RefreshAdapter do
    def refresh_token(_config, _secret, %{"refresh_token" => "invalid"}),
      do: {:error, :invalid_grant}

    def refresh_token(_config, _secret, %{"refresh_token" => "temporary"}),
      do: {:error, :unavailable}

    def refresh_token(_config, _secret, _tokens),
      do: {:ok, %{"access_token" => "refreshed", "refresh_token" => "next", "expires_in" => 3600}}
  end

  setup do
    %{principal: principal} = human_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(principal.uid) end)
    {:ok, principal: principal}
  end

  test "selecting a new default atomically replaces the previous platform default", %{
    principal: actor
  } do
    assert {:ok, first} =
             Store.create_auth_config(actor, Map.put(attrs("first"), "is_default", true))

    assert {:ok, second} =
             Store.create_auth_config(actor, Map.put(attrs("second"), "is_default", true))

    assert {:ok, %{id: second_id}} = Store.get_auth_config(nil, "lark")
    assert second_id == second.id
    assert {:ok, %{is_default: false}} = Store.get_auth_config(first.id)

    assert {:ok, _} = Store.update_auth_config(actor, first.id, %{"is_default" => true})
    assert {:ok, %{id: first_id}} = Store.get_auth_config(nil, "lark")
    assert first_id == first.id
    assert {:ok, %{is_default: false}} = Store.get_auth_config(second.id)

    assert {:error, _} =
             Store.create_auth_config(actor, Map.put(attrs("second"), "is_default", true))

    assert {:ok, %{id: ^first_id}} = Store.get_auth_config(nil, "lark")
  end

  test "connection selectors resolve text slugs around 16 bytes, UUIDs, and platform defaults", %{
    principal: actor
  } do
    for slug <- ["team-connection", "github-downloads", "github-downloadsx"] do
      assert {:ok, config} =
               Store.create_auth_config(actor, Map.put(attrs(slug), "is_default", true))

      id = config.id
      assert {:ok, %{id: ^id}} = Store.get_auth_config(slug, "lark")
      assert {:ok, %{id: ^id}} = Store.get_auth_config(id, "lark")
      assert {:ok, %{id: ^id}} = Store.get_auth_config(nil, "lark")
    end
  end

  test "credential aliases retain the owning platform's field names", %{principal: actor} do
    for {plugin, snake_key, native_key, id, module} <- [
          {"dingtalk", "client_id", "clientId", "ding-client",
           Ankole.Plugins.DingTalkAdapter.Config},
          {"whatsapp", "app_id", "appId", "100001", Ankole.Plugins.WhatsAppAdapter.Config}
        ] do
      assert {:ok, config} =
               Store.create_auth_config(actor, %{
                 "plugin_id" => plugin,
                 "slug" => plugin <> "-alias",
                 "auth_scheme" => "platform_app",
                 "public_metadata" => %{"phoneNumberId" => "200001"},
                 "secret" => %{
                   snake_key => id,
                   "app_secret" => "app-secret",
                   "client_secret" => "client-secret",
                   "verifyToken" => "verify",
                   "accessToken" => "access"
                 }
               })

      assert {:ok, hydrated} = LegacyConfig.hydrate(%{"authConfigId" => config.id})
      assert hydrated[native_key] == id
      assert {:ok, _} = module.validate_binding_config(hydrated)
    end
  end

  test "the email connection form exposes reusable transport settings without hiding normal fields",
       %{principal: actor} do
    email = Enum.find(Ankole.Connectors.Catalog.list(), &(&1.plugin_id == "email"))
    public_keys = Enum.map(email.public_fields, & &1.key)

    assert Enum.all?(
             ~w(address imapHost imapPort smtpHost smtpPort smtpSecurity),
             &(&1 in public_keys)
           )

    refute "senderAuthentication" in public_keys
    assert Enum.all?(email.public_fields, &(not &1.secret))
    assert Enum.find(email.credential_fields, &(&1.key == "password")).secret
    refute Enum.find(email.credential_fields, &(&1.key == "username")).secret

    assert {:ok, root} =
             Store.create_auth_config(actor, %{
               "plugin_id" => "email",
               "slug" => "mailbox",
               "auth_scheme" => "imap_smtp",
               "public_metadata" => %{
                 "address" => "bot@example.com",
                 "imapHost" => "imap.example.com",
                 "imapPort" => 993,
                 "smtpHost" => "smtp.example.com",
                 "smtpPort" => 465,
                 "smtpSecurity" => "tls"
               },
               "secret" => %{"username" => "bot", "password" => "mail-secret"}
             })

    assert {:ok, reused} = LegacyConfig.hydrate(%{"authConfigId" => root.id})
    assert {:ok, validated} = Ankole.Plugins.EmailAdapter.Config.validate_binding_config(reused)
    assert validated["smtpPort"] == 465
    assert validated["smtpSecurity"] == "tls"
  end

  test "administrators can inspect and cancel application event bindings while a connection is disabled",
       %{principal: admin} do
    assert {:ok, config} = Store.create_auth_config(admin, attrs("application-events"))
    actor = Ankole.AuthZ.Actor.new(admin)
    job = Ankole.WorkFixtures.applet_job(admin.uid)
    reference = "connector://#{config.id}/lark"
    binding_attrs = %{"config_ref" => reference, "automation_job_id" => job.id}

    assert {:ok, binding} = Ankole.Signals.put_event_binding(actor, binding_attrs)
    binding_id = binding.id

    assert {:ok, _} = Store.update_auth_config(admin, config.id, %{"status" => "disabled"})
    assert {:error, :connection_disabled} = Credentials.resolve_credentials(config.id)

    assert {:error, :connection_disabled} =
             Ankole.Connectors.Ingress.receive_event(:auth, config.id, "{}", [])

    assert {:ok, [%{id: ^binding_id, enabled: true}]} =
             Ankole.Signals.list_event_bindings(actor, reference)

    cancellation = Map.merge(binding_attrs, %{"id" => binding_id, "enabled" => false})
    %{principal: member} = human_fixture()
    member_actor = Ankole.AuthZ.Actor.new(member)

    assert {:error, :forbidden} = Ankole.Signals.list_event_bindings(member_actor, reference)
    assert {:error, :forbidden} = Ankole.Signals.put_event_binding(member_actor, cancellation)

    assert {:ok, %{id: ^binding_id, enabled: false}} =
             Ankole.Signals.put_event_binding(actor, cancellation)

    assert {:ok, _} = Store.update_auth_config(admin, config.id, %{"status" => "active"})

    assert {:ok, [%{id: ^binding_id, enabled: false}]} =
             Ankole.Signals.list_event_bindings(actor, reference)
  end

  test "tenant credentials are row-bound, hidden in API projections, and rotate immediately", %{
    principal: actor
  } do
    assert {:ok, config} = Store.create_auth_config(actor, attrs("primary"))
    assert {:ok, %{"appSecret" => "root-secret"}} = Credentials.secret(config)
    refute Map.has_key?(Store.public(config), :sealed_secret)
    assert Store.public(config).public_metadata["appID"] == "app-primary"
    refute Map.has_key?(Store.public(config).public_metadata, "appSecret")

    assert Store.public(config).platform_name == %{
             "default" => "Feishu",
             "zh-Hans-CN" => "飞书"
           }

    {:ok, global} =
      Store.create_auth_config(
        actor,
        Map.put(attrs("global"), "public_metadata", %{"domain" => "lark"})
      )

    assert Store.public(global).platform_name == %{"default" => "Lark"}
    {:ok, other} = Store.create_auth_config(actor, attrs("other"))

    refute match?(
             {:ok, _},
             Ankole.SecretKeyBase.unseal(config.sealed_secret, "connector_auth_config", [
               Repo.tenant_id!(),
               other.id
             ])
           )

    assert {:ok, changed} =
             Store.update_auth_config(actor, config.id, %{
               "secret" => %{"appSecret" => "new-secret"}
             })

    assert changed.secret_version == 2
    assert {:ok, %{"appSecret" => "new-secret"}} = Credentials.resolve_credentials(config.id)

    assert {:ok, changed} =
             Store.update_auth_config(actor, config.id, %{
               "public_metadata" => %{"oauth_issuer" => "https://identity.example"}
             })

    assert changed.secret_version == 3
    assert {:ok, disabled} = Store.update_auth_config(actor, config.id, %{"status" => "disabled"})
    assert disabled.secret_version == 4
    assert {:error, :connection_disabled} = Credentials.resolve_credentials(config.id)
  end

  test "Microsoft credential rotation updates equal legacy aliases and preserves distinct secrets",
       %{principal: actor} do
    app_id = Ankole.Kernel.gen_uuid_v7()

    assert {:ok, config} =
             Store.create_auth_config(actor, %{
               "plugin_id" => "microsoft365",
               "slug" => "shared-entra",
               "auth_scheme" => "identity_app",
               "secret" => %{
                 "clientID" => app_id,
                 "appID" => app_id,
                 "clientSecret" => "same",
                 "appPassword" => "same"
               }
             })

    assert {:ok, rotated} =
             Store.update_auth_config(actor, config.id, %{
               "secret" => %{"clientSecret" => "rotated"}
             })

    assert {:ok, %{"clientSecret" => "rotated", "appPassword" => "rotated"}} =
             Credentials.secret(rotated)

    assert {:ok, distinct} =
             Store.create_auth_config(actor, %{
               "plugin_id" => "microsoft365",
               "slug" => "separate-entra-secrets",
               "auth_scheme" => "identity_app",
               "secret" => %{
                 "clientID" => Ankole.Kernel.gen_uuid_v7(),
                 "clientSecret" => "identity-secret",
                 "appPassword" => "bot-secret"
               }
             })

    assert {:ok, distinct} =
             Store.update_auth_config(actor, distinct.id, %{
               "secret" => %{"clientSecret" => "new-identity-secret"}
             })

    assert {:ok, %{"clientSecret" => "new-identity-secret", "appPassword" => "bot-secret"}} =
             Credentials.secret(distinct)

    assert {:error, :connection_application_change_requires_new_connection} =
             Store.update_auth_config(actor, config.id, %{
               "secret" => %{"clientID" => Ankole.Kernel.gen_uuid_v7()}
             })
  end

  test "an application cannot be rebound across tenants", %{principal: actor} do
    assert {:ok, config} = Store.create_auth_config(actor, attrs("primary"))
    second = create_tenant()

    Repo.with_tenant(second.id, fn ->
      assert {:error, :connection_required} = Store.get_auth_config(config.id)

      assert {:error, _} =
               Repo.transact_top_level(fn ->
                 Store.create_in_tx(
                   "system",
                   Map.put(
                     attrs("duplicate"),
                     "platform_application",
                     config.platform_application
                   )
                 )
               end)
    end)
  end

  test "root rotation cannot replace the application behind existing accounts", %{
    principal: actor
  } do
    {:ok, config} = Store.create_auth_config(actor, attrs("primary"))

    {:ok, account} =
      Accounts.put_human_tokens(config.id, actor.uid, %{
        "access_token" => "original-personal-token",
        "expires_in" => 3600
      })

    assert {:error, :connection_application_change_requires_new_connection} =
             Store.update_auth_config(actor, config.id, %{
               "secret" => %{"appID" => "another-application", "appSecret" => "another-secret"}
             })

    assert {:ok, unchanged} = Store.get_auth_config(config.id)
    assert unchanged.platform_application == config.platform_application
    assert unchanged.secret_version == config.secret_version
    assert {:ok, %{"appSecret" => "root-secret"}} = Credentials.secret(unchanged)
    assert {:ok, unchanged_account} = Accounts.get_by_id(account.id)
    assert unchanged_account.status == "active"
    assert unchanged_account.credentials_version == account.credentials_version

    assert {:ok, %{"access_token" => "original-personal-token"}} =
             Credentials.account_credentials(unchanged_account)

    assert {:ok, rotated} =
             Store.update_auth_config(actor, config.id, %{"secret" => %{"appSecret" => "rotated"}})

    assert rotated.platform_application == config.platform_application
    assert rotated.secret_version == config.secret_version + 1
  end

  test "legacy sharing merges complementary fields and refuses conflicting roots", %{
    principal: actor
  } do
    first = %{"appID" => "same-app", "appSecret" => "first", "userName" => "Bot"}

    assert {:ok, {config, id}} =
             Repo.transact_top_level(fn ->
               with {:ok, config, id} <-
                      LegacyConfig.ensure_in_tx("lark", first, "lark:shared", actor.uid),
                    do: {:ok, {config, id}}
             end)

    assert config["authConfigId"] == id
    {:ok, original} = Store.get_auth_config(id)

    {:ok, account} =
      Accounts.put_human_tokens(id, actor.uid, %{
        "access_token" => "personal-token",
        "expires_in" => 3600
      })

    assert {:ok, _} =
             Repo.transact_top_level(fn ->
               with {:ok, config, _} <-
                      LegacyConfig.ensure_in_tx(
                        "lark",
                        Map.put(first, "verificationToken", "verify"),
                        "lark:shared",
                        actor.uid
                      ),
                    do: {:ok, config}
             end)

    assert {:ok, secret} = Credentials.resolve_credentials(id)
    assert secret["verificationToken"] == "verify"
    {:ok, merged} = Store.get_auth_config(id)
    {:ok, refreshed_account} = Accounts.get_by_id(account.id)
    assert merged.secret_version == original.secret_version + 1
    assert refreshed_account.credentials_version == account.credentials_version + 1

    assert {:ok, _} =
             Repo.transact_top_level(fn ->
               with {:ok, config, _} <-
                      LegacyConfig.ensure_in_tx(
                        "lark",
                        Map.put(first, "verificationToken", "verify"),
                        "lark:shared",
                        actor.uid
                      ),
                    do: {:ok, config}
             end)

    {:ok, unchanged} = Store.get_auth_config(id)
    {:ok, unchanged_account} = Accounts.get_by_id(account.id)
    assert unchanged.secret_version == merged.secret_version
    assert unchanged_account.credentials_version == refreshed_account.credentials_version

    assert {:error, {:credential_conflict, ["appSecret"]}} =
             Repo.transact_top_level(fn ->
               LegacyConfig.ensure_in_tx(
                 "lark",
                 %{first | "appSecret" => "different"},
                 "lark:shared",
                 actor.uid
               )
             end)

    assert Ankole.Ash.count!(AuthConfig) == 1
  end

  test "OAuth refresh commits new credentials and transient cooldowns", %{principal: actor} do
    {:ok, config} = Store.create_auth_config(actor, attrs("primary"))

    {:ok, account} =
      Accounts.put_human_tokens(
        config.id,
        actor.uid,
        %{"access_token" => "expired", "refresh_token" => "valid", "expires_in" => -10},
        %{external_subject_id: "external-user"}
      )

    assert {:ok, "refreshed"} = TokenRefresher.access_token(config, account, RefreshAdapter)
    {:ok, refreshed} = Accounts.get_account(config.id, "human", actor.uid)
    assert refreshed.credentials_version == 2
    assert is_nil(refreshed.refresh_lease_id)

    {:ok, account} =
      Accounts.put_human_tokens(config.id, actor.uid, %{
        "access_token" => "expired",
        "refresh_token" => "temporary",
        "expires_in" => -10
      })

    assert {:error, :oauth_refresh_failed} =
             TokenRefresher.access_token(config, account, RefreshAdapter)

    {:ok, account} = Accounts.get_account(config.id, "human", actor.uid)
    assert account.status == "active"
    assert account.last_refresh_failure_at

    assert {:error, :oauth_refresh_cooling_down} =
             TokenRefresher.access_token(config, account, RefreshAdapter)
  end

  test "revoked humans cannot use or refresh their connection", %{principal: actor} do
    {:ok, config} = Store.create_auth_config(actor, attrs("primary"))

    {:ok, account} =
      Accounts.put_human_tokens(config.id, actor.uid, %{
        "access_token" => "token",
        "refresh_token" => "valid",
        "expires_in" => 3600
      })

    assert :ok =
             Repo.transact_top_level(fn ->
               Accounts.revoke_human_accounts_in_tx(actor.uid, actor.access_version + 1)
             end)

    revoked = ConnectedAccount |> Ash.Query.filter(id == ^account.id) |> Ankole.Ash.read_one!()
    assert revoked.status == "revoked"
    assert revoked.credentials_version == account.credentials_version + 1

    assert {:error, :oauth_reauthorization_required} =
             TokenRefresher.access_token(config, revoked, RefreshAdapter)
  end

  test "Principal rename follows personal connection ownership and pending OAuth without changing workspace keys",
       %{principal: actor} do
    {:ok, config} = Store.create_auth_config(actor, attrs("primary"))

    {:ok, _} =
      Accounts.put_human_tokens(config.id, actor.uid, %{"access_token" => "personal-token"})

    {:ok, workspace} =
      Repo.transact_top_level(fn ->
        Accounts.put_tokens_in_tx(
          config,
          "app",
          actor.uid,
          %{"access_token" => "workspace-token"},
          %{}
        )
      end)

    {:ok, _} = Ankole.Connectors.OAuth.begin(actor, %{"connection" => config.slug})

    assert {:ok, %{principal: renamed}} =
             Ankole.Principals.rename(actor.uid, "renamed-connector-owner")

    assert {:ok, %{created_by_uid: uid}} = Store.get_auth_config(config.id)
    assert uid == renamed.uid
    assert {:ok, personal} = Accounts.get_account(config.id, "human", renamed.uid)
    assert personal.owner_principal_uid == renamed.uid

    assert {:ok, %{"access_token" => "personal-token"}} =
             Credentials.account_credentials(personal)

    assert {:ok, %{account_key: original}} = Accounts.get_by_id(workspace.id)
    assert original == actor.uid
    assert Ankole.Ash.read_one!(Ankole.Connectors.OAuthSession).actor_uid == renamed.uid
  end

  defp attrs(slug),
    do: %{
      "plugin_id" => "lark",
      "slug" => slug,
      "auth_scheme" => "lark_app",
      "secret" => %{"appID" => "app-" <> slug, "appSecret" => "root-secret"}
    }
end
