defmodule Ankole.Upgrade202610Test do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AppConfigure.Crypto
  alias Ankole.Signals.Binding
  alias Ankole.Signals.Bindings
  alias Ankole.Upgrade202610
  alias Ankole.Plugins.SlackAdapter.Config, as: SlackConfig
  alias Ankole.Plugins.Microsoft365Adapter.Config, as: TeamsConfig

  setup do
    allow_cache_database_access()
    Req.Test.set_req_test_to_shared()
    previous = Application.fetch_env(:ankole, SlackConfig)

    Application.put_env(:ankole, SlackConfig,
      client_opts: [req_options: [plug: {Req.Test, __MODULE__}]]
    )

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:ankole, SlackConfig, config)
        :error -> Application.delete_env(:ankole, SlackConfig)
      end
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      refute Repo.in_transaction?(),
             "upgrade identity resolution cannot hold a database transaction"

      case conn.request_path do
        "/api/auth.test" ->
          Req.Test.json(conn, %{"ok" => true, "bot_id" => "BOLD", "user_id" => "UOLD"})

        "/api/bots.info" ->
          Req.Test.json(conn, %{"ok" => true, "bot" => %{"app_id" => "AOLD"}})
      end
    end)

    :ok
  end

  for {adapter, module} <- [{"slack", SlackConfig}, {"teams", TeamsConfig}] do
    @adapter adapter
    @config_module module
    test "#{adapter} shared keys split into independently encrypted Agent rows and repeat without changes" do
      %{principal: first} = agent_fixture()
      %{principal: second} = agent_fixture()
      key = @config_module.chat_config_key("shared")
      {:ok, config} = @config_module.validate_chat_config(config(@adapter))
      old_value = seed_config(key, config)

      for agent <- [first, second] do
        assert {:ok, _} =
                 Ankole.Signals.Bindings.upsert_binding(%{
                   agent_uid: agent.uid,
                   name: "shared",
                   adapter: @adapter,
                   config_ref: "app-config://#{key}"
                 })
      end

      assert :ok = Repo.without_tenant(&Upgrade202610.run/0)
      refute Repo.get_by(SiteConfig, scope: "global", key: key)

      rows =
        for agent <- [first, second] do
          binding = Repo.get_by!(Binding, agent_uid: agent.uid, name: "shared")
          new_key = @config_module.binding_config_key(agent.uid, "shared")
          assert binding.config_ref == "app-config://#{new_key}"
          row = Repo.get_by!(SiteConfig, scope: "global", key: new_key)
          assert row.value["type"] == old_value["type"]
          refute row.value["value"] == old_value["value"]
          assert {:ok, ^config} = Bindings.stored_binding_config(binding)
          assert is_binary(row.value["platform_application"])
          row
        end

      refute hd(rows).value["value"] == List.last(rows).value["value"]

      Req.Test.stub(__MODULE__, fn _ ->
        flunk("resolved rows must not request identity on repeat")
      end)

      assert :ok = Repo.without_tenant(&Upgrade202610.run/0)

      for row <- rows,
          do: assert(Repo.get_by!(SiteConfig, scope: row.scope, key: row.key).value == row.value)
    end
  end

  for {adapter, module} <- [
        {"line", Ankole.Plugins.LineAdapter.Config},
        {"lark", Ankole.Plugins.LarkAdapter.Config},
        {"email", Ankole.Plugins.EmailAdapter.Config},
        {"whatsapp", Ankole.Plugins.WhatsAppAdapter.Config}
      ] do
    @adapter adapter
    @config_module module
    test "#{adapter} existing binding configs gain an application identity without changing their values" do
      %{principal: agent} = agent_fixture()
      key = @config_module.binding_config_key(agent.uid, "existing")
      {:ok, config} = @config_module.validate_binding_config(config(@adapter))
      seed_config(key, config)

      assert {:ok, binding} =
               Ankole.Signals.Bindings.upsert_binding(%{
                 agent_uid: agent.uid,
                 name: "existing",
                 adapter: @adapter,
                 config_ref: "app-config://#{key}",
                 enabled: true
               })

      assert :ok = Repo.without_tenant(&Upgrade202610.run/0)
      assert {:ok, ^config} = Bindings.binding_config(binding, @config_module)
      assert {:ok, application} = @config_module.platform_application(config)
      row = Repo.get_by!(SiteConfig, scope: "global", key: key)
      assert row.value["platform_application"] == application

      assert :ok = Repo.without_tenant(&Upgrade202610.run/0)
      assert Repo.get_by!(SiteConfig, scope: "global", key: key).value == row.value
    end
  end

  test "a conflicting destination aborts the entire shared-key split without deleting old credentials" do
    %{principal: first} = agent_fixture()
    %{principal: second} = agent_fixture()
    key = TeamsConfig.chat_config_key("shared-conflict")
    {:ok, config} = TeamsConfig.validate_chat_config(config("teams"))
    seed_config(key, config)

    for agent <- [first, second],
        do:
          Ankole.Signals.Bindings.upsert_binding(%{
            agent_uid: agent.uid,
            name: "shared-conflict",
            adapter: "teams",
            config_ref: "app-config://#{key}"
          })

    destination = TeamsConfig.binding_config_key(second.uid, "shared-conflict")
    seed_config(destination, Map.put(config, "appPassword", "different"))

    assert_raise RuntimeError, ~r/binding_configuration_key_conflict/, fn ->
      Repo.without_tenant(&Upgrade202610.run/0)
    end

    assert Repo.get_by(SiteConfig, scope: "global", key: key)

    for agent <- [first, second],
        do:
          assert(
            Repo.get_by!(Binding,
              agent_uid: agent.uid,
              name: "shared-conflict"
            ).config_ref == "app-config://#{key}"
          )

    refute Repo.get_by(SiteConfig,
             scope: "global",
             key: TeamsConfig.binding_config_key(first.uid, "shared-conflict")
           )
  end

  test "identity ciphertext moves only to the original tenant and repeat tolerates its new name",
       %{
         tenant: other
       } do
    original = Repo.get_by!(Ankole.Tenants.Tenant, slug: "default")
    key = "principals.identity_providers.lark.migration-#{Ecto.UUID.generate()}"
    value = %{"appID" => "migration-fixture", "appSecret" => "migration-secret"}
    seed_config(key, value)

    assert :ok = Repo.without_tenant(&Upgrade202610.run/0)
    scope = "tenant:" <> original.id
    row = Repo.with_tenant(original.id, fn -> Repo.get_by!(AppConfig, scope: scope, key: key) end)
    assert row.tenant_id == original.id
    assert {:ok, ^value} = Crypto.unseal(row.value["value"], scope, key)
    assert {:error, _} = Crypto.unseal(row.value["value"], "global", key)
    refute Repo.get_by(SiteConfig, scope: "global", key: key)

    Repo.with_tenant(other.id, fn ->
      assert :error = Ankole.AppConfigure.get_by_key(key)
    end)

    original
    |> Ecto.Changeset.change(slug: "original-#{Ecto.UUID.generate()}")
    |> Repo.update!()

    assert :ok = Repo.without_tenant(&Upgrade202610.run/0)

    assert Repo.with_tenant(original.id, fn ->
             Repo.get_by!(AppConfig, scope: scope, key: key).value
           end) == row.value

    assert Repo.tenant_id!() == other.id
  end

  defp seed_config(key, config) do
    {:ok, ciphertext} = Crypto.seal(config, "global", key)
    value = %{"type" => "cipher", "value" => ciphertext}
    Repo.insert!(%SiteConfig{scope: "global", key: key, value: value})
    value
  end

  defp config("line"),
    do: %{
      "channelId" => "10001",
      "channelSecret" => "old-secret",
      "channelAccessToken" => "old-token"
    }

  defp config("lark"),
    do: %{"appID" => "cli_old_identity", "appSecret" => "old-secret", "domain" => "feishu"}

  defp config("email"),
    do: %{
      "address" => "agent@example.com",
      "imapHost" => "IMAP.example.com",
      "smtpHost" => "smtp.example.com",
      "username" => "Agent",
      "password" => "old-secret"
    }

  defp config("whatsapp"),
    do: %{
      "appId" => "10001",
      "appSecret" => "old-secret",
      "verifyToken" => "old-verify",
      "phoneNumberId" => "20001",
      "accessToken" => "old-token"
    }

  defp config("slack"), do: %{"botToken" => "xoxb-old", "appToken" => "xapp-old"}

  defp config("teams"),
    do: %{
      "appID" => "11111111-2222-3333-4444-555555555555",
      "appPassword" => "old-secret",
      "botTenancy" => "multi_tenant"
    }
end
