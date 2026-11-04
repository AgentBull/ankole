defmodule Ankole.Connectors.CredentialReuseProtocolTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.Connectors.{Credentials, LegacyConfig, Store}
  alias Ankole.Plugins.SlackAdapter.Config

  defmodule Slack do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      ["Bearer " <> token] = get_req_header(conn, "authorization")
      send(owner, {:slack_request, conn.request_path, token})

      body =
        case conn.request_path do
          "/api/auth.test" ->
            app = if String.starts_with?(token, "xoxb-first"), do: "FIRST", else: "SECOND"
            %{"ok" => true, "user_id" => "U" <> app, "bot_id" => "B" <> app}

          "/api/bots.info" ->
            conn = fetch_query_params(conn)

            %{
              "ok" => true,
              "bot" => %{"app_id" => String.replace_prefix(conn.params["bot"], "B", "A")}
            }

          "/api/apps.connections.open" ->
            %{"ok" => false, "error" => "not_allowed_token_type"}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Torque.encode!(body))
    end
  end

  setup do
    server = start_supervised!({Bandit, plug: {Slack, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    previous = Application.fetch_env(:ankole, Config)
    Application.put_env(:ankole, Config, client_opts: [base_url: "http://127.0.0.1:#{port}/api"])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ankole, Config, value)
        :error -> Application.delete_env(:ankole, Config)
      end
    end)

    %{actor: admin()}
  end

  test "a bot connection adds OIDC credentials without copying tokens or changing its application",
       %{actor: actor} do
    {:ok, root} = Store.create_auth_config(actor, attrs("bot", bot_credentials()))
    assert root.platform_application == "slack:AFIRST"

    assert {:ok, root} =
             Store.update_auth_config(actor, root.id, %{"secret" => identity_credentials()})

    assert root.platform_application == "slack:AFIRST"
    assert root.platform_client_id == "shared-client"
    assert_shared_identity_and_messaging(root)
    assert_received {:slack_request, "/api/auth.test", "xoxb-first"}
    assert_received {:slack_request, "/api/bots.info", "xoxb-first"}
  end

  test "bot-only connections with blank OAuth client fields do not share an application identity",
       %{actor: actor} do
    first_secret = Map.merge(bot_credentials(), %{"clientID" => "", "clientSecret" => ""})
    second_secret = Map.put(first_secret, "botToken", "xoxb-second")

    assert {:ok, first} = Store.create_auth_config(actor, attrs("first-bot", first_secret))
    assert {:ok, second} = Store.create_auth_config(actor, attrs("second-bot", second_secret))
    assert is_nil(first.platform_client_id)
    assert is_nil(second.platform_client_id)
    refute first.platform_application == second.platform_application

    assert {:ok, configured} =
             Store.update_auth_config(actor, first.id, %{"secret" => identity_credentials()})

    assert configured.platform_client_id == "shared-client"
  end

  test "the identity-provider form completes a selected bot connection in place", %{actor: actor} do
    initial = Map.merge(bot_credentials(), %{"clientID" => "", "clientSecret" => ""})
    {:ok, original} = Store.create_auth_config(actor, attrs("inline-identity", initial))
    assert Store.public(original).configured_credential_fields == ["appToken", "botToken"]

    assert {:ok, _} =
             Ankole.IdentityProviders.save_provider(
               "inline-identity",
               "slack",
               Map.merge(identity_credentials(), %{
                 "authConfigId" => original.id,
                 "sync" => %{"contacts" => false, "websocket" => false}
               })
             )

    assert {:ok, root} = Store.get_auth_config(original.id)
    assert root.platform_application == original.platform_application
    assert root.platform_client_id == "shared-client"

    assert Store.public(root).configured_credential_fields ==
             ["appToken", "botToken", "clientID", "clientSecret"]

    assert_shared_identity_and_messaging(root)

    key = "principals.identity_providers.slack.inline-identity"
    scope = "tenant:" <> Repo.tenant_id!()
    row = Repo.get_by!(Ankole.AppConfigure.AppConfig, scope: scope, key: key)
    assert {:ok, stored} = Ankole.AppConfigure.Crypto.unseal(row.value["value"], scope, key)
    assert stored["authConfigId"] == root.id
    refute Map.has_key?(stored, "clientSecret")
    refute Map.has_key?(stored, "botToken")

    assert {:error, {:credential_conflict, ["clientSecret"]}} =
             Ankole.IdentityProviders.save_provider("inline-identity", "slack", %{
               "authConfigId" => root.id,
               "clientSecret" => "unexpected-rotation"
             })

    {:ok, other} =
      Store.create_auth_config(
        actor,
        attrs("other-identity", %{
          "clientID" => "other-client",
          "clientSecret" => "other-secret",
          "botToken" => "xoxb-second",
          "appToken" => "xapp-second"
        })
      )

    assert {:ok, _} =
             Ankole.IdentityProviders.save_provider("inline-identity", "slack", %{
               "authConfigId" => other.id,
               "sync" => %{"contacts" => false, "websocket" => false}
             })

    assert {:ok, %{"clientID" => "other-client", "clientSecret" => "other-secret"}} =
             Ankole.AppConfigure.get_by_key(key)
  end

  test "the channel form completes a selected identity connection and can switch roots", %{
    actor: actor
  } do
    {:ok, original} =
      Store.create_auth_config(actor, attrs("inline-channel", identity_credentials()))

    %{principal: agent} = agent_fixture()

    assert {:ok, %{binding: binding}} =
             Ankole.Signals.Bindings.put_binding(agent.uid, "slack", "inline", %{
               "config" => Map.put(bot_credentials(), "authConfigId", original.id)
             })

    assert binding.auth_config_id == original.id
    assert {:ok, root} = Store.get_auth_config(original.id)
    assert root.platform_application == "slack:AFIRST"
    assert root.platform_client_id == original.platform_client_id
    assert_shared_identity_and_messaging(root)

    other_secret = %{"botToken" => "xoxb-second", "appToken" => "xapp-second"}
    {:ok, other} = Store.create_auth_config(actor, attrs("other-channel", other_secret))

    assert {:ok, %{binding: switched}} =
             Ankole.Signals.Bindings.update_binding(binding.id, %{
               "config" => %{"authConfigId" => other.id}
             })

    assert switched.auth_config_id == other.id

    assert {:ok, %{"botToken" => "xoxb-second", "appToken" => "xapp-second"}} =
             Ankole.Signals.Bindings.binding_config(switched, Config)

    assert {:ok, _} = Ankole.Signals.Bindings.disable_binding(switched.id)

    assert {:ok, root} = Store.get_auth_config(root.id)

    assert {:ok, %{"botToken" => "xoxb-first", "clientSecret" => "client-secret"}} =
             Credentials.secret(root)
  end

  test "an OIDC connection gains a verified bot identity, preserves both exclusions, and rotates both secrets",
       %{actor: actor} do
    {:ok, original} = Store.create_auth_config(actor, attrs("identity", identity_credentials()))
    assert original.platform_application == "slack-client:shared-client"

    assert {:ok, root} =
             Store.update_auth_config(actor, original.id, %{"secret" => bot_credentials()})

    assert root.id == original.id
    assert root.platform_application == "slack:AFIRST"
    assert root.platform_client_id == "shared-client"
    assert_shared_identity_and_messaging(root)

    assert {:ok, rotated} =
             Store.update_auth_config(actor, root.id, %{
               "secret" => %{
                 "botToken" => "xoxb-first-rotated",
                 "clientSecret" => "rotated-client-secret"
               }
             })

    assert rotated.platform_application == root.platform_application
    assert rotated.platform_client_id == root.platform_client_id

    assert {:ok, %{"clientSecret" => "rotated-client-secret", "botToken" => "xoxb-first-rotated"}} =
             Credentials.secret(rotated)

    assert_received {:slack_request, "/api/auth.test", "xoxb-first-rotated"}

    assert {:error, :connection_application_change_requires_new_connection} =
             Store.update_auth_config(actor, root.id, %{
               "secret" => %{"clientID" => "different-client"}
             })

    assert {:error, :connection_application_change_requires_new_connection} =
             Store.update_auth_config(actor, root.id, %{
               "secret" => %{"botToken" => "xoxb-second"}
             })

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      other_actor = admin()

      for {name, credentials} <- [
            {"same-client", identity_credentials()},
            {"same-bot", bot_credentials()}
          ] do
        assert {:error, :platform_app_bound_to_another_tenant} =
                 Store.create_auth_config(other_actor, attrs(name, credentials))
      end
    end)
  end

  test "bot identity already owned by another tenant rejects OIDC completion without changing the root",
       %{actor: actor} do
    {:ok, original} = Store.create_auth_config(actor, attrs("identity", identity_credentials()))
    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert {:ok, _} = Store.create_auth_config(admin(), attrs("owned-bot", bot_credentials()))
    end)

    assert {:error, :platform_app_bound_to_another_tenant} =
             Store.update_auth_config(actor, original.id, %{"secret" => bot_credentials()})

    assert {:ok, unchanged} = Store.get_auth_config(original.id)
    assert unchanged.platform_application == original.platform_application
    assert unchanged.secret_version == original.secret_version
    assert {:ok, credentials} = Credentials.secret(unchanged)
    refute Map.has_key?(credentials, "botToken")
  end

  test "legacy forms complement the same OIDC connection and keep the client exclusion", %{
    actor: actor
  } do
    {:ok, original} = Store.create_auth_config(actor, attrs("identity", identity_credentials()))
    combined = Map.merge(identity_credentials(), bot_credentials())
    assert {:ok, application} = Config.platform_application(combined)

    assert {:ok, reused_id} =
             Repo.transact_top_level(fn ->
               with {:ok, _config, id} <-
                      LegacyConfig.ensure_in_tx("slack", combined, application, actor.uid),
                    do: {:ok, id}
             end)

    assert reused_id == original.id
    assert {:ok, root} = Store.get_auth_config(reused_id)
    assert root.platform_application == "slack:AFIRST"
    assert root.platform_client_id == "shared-client"
    assert_shared_identity_and_messaging(root)

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert {:error, :platform_app_bound_to_another_tenant} =
               Store.create_auth_config(admin(), attrs("same-client", identity_credentials()))
    end)
  end

  defp assert_shared_identity_and_messaging(root) do
    assert {:ok, _} =
             Ankole.IdentityProviders.save_provider("shared-slack", "slack", %{
               "authConfigId" => root.id,
               "sync" => %{"contacts" => false, "websocket" => false}
             })

    %{principal: agent} = agent_fixture()

    assert {:ok, %{binding: binding}} =
             Ankole.Signals.Bindings.put_binding(agent.uid, "slack", "shared", %{
               "config" => %{"authConfigId" => root.id, "identityProvider" => "shared-slack"}
             })

    assert {:ok, _} = Ankole.Signals.Bindings.disable_binding(binding.id)

    assert binding.auth_config_id == root.id

    assert {:ok, %{"clientSecret" => "client-secret", "botToken" => "xoxb-first"}} =
             Ankole.AppConfigure.get_by_key("principals.identity_providers.slack.shared-slack")

    assert {:ok, %{"botToken" => "xoxb-first", "appToken" => "xapp-first"}} =
             Ankole.Signals.Bindings.binding_config(binding, Config)
  end

  defp admin do
    %{principal: actor} = human_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(actor.uid) end)
    actor
  end

  defp identity_credentials,
    do: %{"clientID" => "shared-client", "clientSecret" => "client-secret"}

  defp bot_credentials, do: %{"botToken" => "xoxb-first", "appToken" => "xapp-first"}

  defp attrs(slug, secret),
    do: %{
      "plugin_id" => "slack",
      "slug" => slug,
      "auth_scheme" => "platform_app",
      "secret" => secret
    }
end
