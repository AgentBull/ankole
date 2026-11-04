defmodule Ankole.Connectors.LegacyUpgradeTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Connectors.{AuthConfig, Credentials, LegacyConfig, LegacyUpgrade, Store}
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Crypto

  defmodule PlatformHTTP do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      send(owner, {:platform_identity, conn.request_path})

      body =
        case conn.request_path do
          "/auth.test" ->
            %{"ok" => true, "user_id" => "U1", "bot_id" => "B1", "team_id" => "T1"}

          "/bots.info" ->
            %{"ok" => true, "bot" => %{"app_id" => "A1"}}

          "/applications/@me" ->
            %{"id" => "100001"}

          "/bot10001:secret/getMe" ->
            %{"ok" => true, "result" => %{"id" => 10001, "is_bot" => true}}
        end

      status = if get_req_header(conn, "authorization") == ["Bot expired"], do: 401, else: 200
      conn |> put_resp_content_type("application/json") |> send_resp(status, Torque.encode!(body))
    end
  end

  setup do
    server =
      start_supervised!({Bandit, plug: {PlatformHTTP, self()}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    for config <- [
          Ankole.Plugins.SlackAdapter.Config,
          Ankole.Plugins.DiscordAdapter.Config,
          Ankole.Plugins.TelegramAdapter.Config
        ] do
      previous = Application.get_env(:ankole, config)
      Application.put_env(:ankole, config, client_opts: [base_url: "http://127.0.0.1:#{port}"])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ankole, config, previous),
          else: Application.delete_env(:ankole, config)
      end)
    end

    %{principal: admin} = human_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)
    %{principal: agent} = agent_fixture()
    %{admin: admin, agent: agent}
  end

  test "startup imports Lark and all ten legacy platforms through their real schemas and identity protocols",
       %{agent: agent} do
    bindings =
      for {adapter, config} <- binding_configs() do
        id = Ankole.Kernel.gen_uuid_v7()
        key = "signals." <> adapter <> ".bindings." <> id
        assert {:ok, _} = AppConfigure.put_global_by_key(key, config)

        assert {:ok, binding} =
                 Ankole.SignalsFixtures.raw_binding_fixture(%{
                   id: id,
                   agent_uid: agent.uid,
                   adapter: adapter,
                   name: adapter,
                   config_ref: "app-config://" <> key
                 })

        {binding, key, config}
      end

    google_key = "principals.identity_providers.google-workspace.migration"

    google = %{
      "clientID" => "google-client",
      "clientSecret" => "google-secret",
      "oidc" => %{"allowedDomains" => ["example.com"]},
      "sync" => %{"contacts" => false}
    }

    assert {:ok, _} = AppConfigure.put_tenant_by_key(google_key, google)

    assert {:ok, _} =
             AppConfigure.put_tenant_by_key("principals.identity_providers.active", [
               %{
                 "provider_id" => "google-migration",
                 "plugin_id" => "google-workspace-adapter",
                 "adapter_id" => "google-workspace",
                 "config_key" => google_key,
                 "enabled" => false
               }
             ])

    assert :ok = LegacyUpgrade.run()
    assert Ankole.Ash.count!(AuthConfig) == 11
    assert_receive {:platform_identity, "/auth.test"}
    assert_receive {:platform_identity, "/bots.info"}
    assert_receive {:platform_identity, "/applications/@me"}
    assert_receive {:platform_identity, "/bot10001:secret/getMe"}

    for {binding, key, original} <- bindings do
      migrated = Ankole.Signals.get_binding!(binding.id)
      assert is_binary(migrated.auth_config_id)
      assert {:ok, runtime} = AppConfigure.get_by_key(key)
      assert runtime["authConfigId"] == migrated.auth_config_id
      assert {:ok, root} = Store.get_auth_config(migrated.auth_config_id)

      for {field, value} <- LegacyConfig.public_metadata(original),
          do: assert(root.public_metadata[field] == value)

      for {field, value} <- original,
          LegacyConfig.credential_field?(field),
          do: assert(runtime[field] == value)

      assert {:ok, row} = AppConfigure.get_site_config("global", key)
      assert {:ok, stored} = Crypto.unseal(row.value["value"], "global", key)
      assert stored["authConfigId"] == migrated.auth_config_id
      refute Enum.any?(Map.keys(stored), &LegacyConfig.credential_field?/1)
    end

    scope = "tenant:" <> Repo.tenant_id!()
    assert {:ok, row} = AppConfigure.get_app_config(scope, google_key)
    assert {:ok, stored} = Crypto.unseal(row.value["value"], scope, google_key)
    refute Map.has_key?(stored, "clientSecret")

    assert {:error, {:storage_error, _, _, :connection_disabled}} =
             AppConfigure.get_by_key(google_key)

    assert {:ok, runtime} = AppConfigure.read_configuration(google_key)
    assert runtime["clientSecret"] == "google-secret"
    assert :ok = LegacyUpgrade.run()
    assert Ankole.Ash.count!(AuthConfig) == 11
    refute_receive {:platform_identity, _}
  end

  test "complementary identity and bot roots share one connection, conflicts retain both source values",
       %{admin: admin} do
    for {plugin, credentials} <-
          Enum.map(binding_configs(), fn {plugin, fields} -> {plugin, fields} end) ++
            [{"google-workspace", %{"clientID" => "google-client", "clientSecret" => "secret"}}] do
      application = "migration:" <> plugin
      assert {:ok, {_, id}} = ensure(plugin, credentials, application, admin.uid)

      assert {:ok, {_, ^id}} =
               ensure(
                 plugin,
                 Map.put(credentials, "verificationToken", "verification"),
                 application,
                 admin.uid
               )

      assert {:ok, root} = Credentials.resolve_credentials(id)
      assert root["verificationToken"] == "verification"
      secret_key = credentials |> Map.keys() |> Enum.find(&LegacyConfig.credential_field?/1)
      conflicting = Map.put(credentials, secret_key, "conflicting-value")

      assert {:error, {:credential_conflict, [^secret_key]}} =
               ensure(plugin, conflicting, application, admin.uid)

      assert {:ok, still_original} = Credentials.resolve_credentials(id)
      assert still_original[secret_key] == credentials[secret_key]

      assert {:ok, {_, different_id}} =
               ensure(plugin, credentials, application <> ":other-app", admin.uid)

      refute different_id == id
    end
  end

  test "migrated disabled identity credentials do not prevent restart", %{admin: admin} do
    key = "principals.identity_providers.google-workspace.disabled"

    config = %{
      "clientID" => "disabled-google",
      "clientSecret" => "secret",
      "oidc" => %{"allowedDomains" => ["example.com"]},
      "sync" => %{"contacts" => false}
    }

    assert {:ok, _} = AppConfigure.put_tenant_by_key(key, config)

    assert {:ok, _} =
             AppConfigure.put_tenant_by_key("principals.identity_providers.active", [
               %{
                 "provider_id" => "google-disabled",
                 "plugin_id" => "google-workspace-adapter",
                 "adapter_id" => "google-workspace",
                 "config_key" => key,
                 "enabled" => false
               }
             ])

    assert :ok = LegacyUpgrade.run()
    assert {:ok, [root]} = Store.list_auth_configs(admin)
    assert {:ok, _} = Store.update_auth_config(admin, root.id, %{"status" => "disabled"})
    assert :ok = LegacyUpgrade.run()
    assert {:error, :connection_disabled} = Credentials.resolve_credentials(root.id)
  end

  test "failed imports keep startup and unrelated connections available", %{
    admin: admin,
    agent: agent
  } do
    assert {:ok, _} =
             Store.create_auth_config(admin, %{
               "plugin_id" => "lark",
               "slug" => "conflicting",
               "auth_scheme" => "lark_app",
               "secret" => %{"appID" => "lark-conflict", "appSecret" => "current-secret"}
             })

    configs = [
      {"lark", %{"appID" => "lark-conflict", "appSecret" => "old-secret"}},
      {"discord", %{"botToken" => "expired"}},
      {"line",
       %{"channelId" => "200002", "channelSecret" => "secret", "channelAccessToken" => "access"}}
    ]

    sources =
      for {adapter, config} <- configs do
        id = Ankole.Kernel.gen_uuid_v7()
        key = "signals.#{adapter}.bindings.#{id}"
        assert {:ok, _} = AppConfigure.put_global_by_key(key, config)
        assert {:ok, original} = AppConfigure.get_site_config("global", key)

        assert {:ok, binding} =
                 Ankole.SignalsFixtures.raw_binding_fixture(%{
                   id: id,
                   agent_uid: agent.uid,
                   adapter: adapter,
                   name: adapter,
                   config_ref: "app-config://" <> key
                 })

        {binding, key, original.value}
      end

    assert :ignore = LegacyUpgrade.start_link([])

    for {binding, key, original} <- sources do
      migrated = Ankole.Signals.get_binding!(binding.id)
      assert {:ok, row} = AppConfigure.get_site_config("global", key)

      if binding.adapter == "line" do
        assert is_binary(migrated.auth_config_id)
        refute row.value == original
      else
        assert is_nil(migrated.auth_config_id)
        assert row.value == original
      end
    end
  end

  test "disabled historical bindings do not claim another tenant's active application", ctx do
    app = %{"appID" => "transferred-app", "appSecret" => "secret"}

    assert {:ok, active} =
             Store.create_auth_config(ctx.admin, %{
               "plugin_id" => "lark",
               "slug" => "transferred",
               "auth_scheme" => "lark_app",
               "secret" => app
             })

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      %{principal: agent} = agent_fixture()
      id = Ankole.Kernel.gen_uuid_v7()
      key = "signals.lark.bindings.#{id}"
      assert {:ok, _} = AppConfigure.put_global_by_key(key, app)

      assert {:ok, binding} =
               Ankole.SignalsFixtures.raw_binding_fixture(%{
                 id: id,
                 agent_uid: agent.uid,
                 adapter: "lark",
                 name: "disabled",
                 enabled: false,
                 config_ref: "app-config://" <> key
               })

      assert :ok = LegacyUpgrade.run()
      migrated = Ankole.Signals.get_binding!(binding.id)
      assert {:ok, root} = Store.get_auth_config_for_configuration(migrated.auth_config_id)
      assert root.status == "disabled"
      refute root.id == active.id
      assert root.platform_application == active.platform_application
    end)
  end

  test "startup reuses the historical verified identity without contacting the external platform",
       %{agent: agent} do
    id = Ankole.Kernel.gen_uuid_v7()
    key = "signals.discord.bindings.#{id}"
    assert {:ok, _} = AppConfigure.put_global_by_key(key, %{"botToken" => "expired"})
    assert {:ok, row} = AppConfigure.get_site_config("global", key)

    assert {:ok, _} =
             AppConfigure.record_platform_application_site_config(row, %{
               application: "discord:100001"
             })

    assert {:ok, _} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               id: id,
               agent_uid: agent.uid,
               adapter: "discord",
               name: "known",
               config_ref: "app-config://" <> key
             })

    assert :ok = LegacyUpgrade.run()
    refute_received {:platform_identity, _}
  end

  defp ensure(plugin, config, application, uid) do
    Repo.transact_top_level(fn ->
      with {:ok, config, id} <- LegacyConfig.ensure_in_tx(plugin, config, application, uid),
           do: {:ok, {config, id}}
    end)
  end

  defp binding_configs do
    [
      {"lark", %{"appID" => "lark-migration", "appSecret" => "lark-secret"}},
      {"slack", %{"botToken" => "xoxb-secret", "appToken" => "xapp-secret"}},
      {"dingtalk", %{"clientId" => "dingtalk-migration", "clientSecret" => "dingtalk-secret"}},
      {"wecom", %{"botId" => "wecom-migration", "secret" => "wecom-secret"}},
      {"teams",
       %{
         "appID" => "11111111-2222-3333-4444-555555555555",
         "appPassword" => "microsoft-secret",
         "tenantID" => "99999999-8888-7777-6666-555555555555"
       }},
      {"discord", %{"botToken" => "discord-secret"}},
      {"telegram", %{"botToken" => "10001:secret"}},
      {"whatsapp",
       %{
         "appId" => "1000001",
         "phoneNumberId" => "2000001",
         "appSecret" => "whatsapp-secret",
         "verifyToken" => "verify",
         "accessToken" => "access"
       }},
      {"line",
       %{
         "channelId" => "100001",
         "channelSecret" => "line-secret",
         "channelAccessToken" => "line-token"
       }},
      {"email",
       %{
         "address" => "bot@example.com",
         "imapHost" => "imap.example.com",
         "smtpHost" => "smtp.example.com",
         "username" => "bot",
         "password" => "mail-secret"
       }}
    ]
  end
end
