defmodule Ankole.Upgrade202610IntegrationTest do
  use Ankole.DataCase, async: false

  @moduletag sandbox: false
  @moduletag timeout: 120_000

  import Ankole.PrincipalsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AppConfigure.Crypto
  alias Ankole.AuthZ.Group
  alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig
  alias Ankole.Plugins.Microsoft365Adapter.Config, as: TeamsConfig
  alias Ankole.Principals.Principal
  alias Ankole.Signals.Binding
  alias Ankole.Signals.Bindings

  setup %{tenant: tenant} do
    original = Repo.get_by!(Ankole.Tenants.Tenant, slug: "default")
    scope = "tenant:" <> original.id
    active_key = "principals.identity_providers.active"

    previous_active =
      Repo.with_tenant(original.id, fn ->
        Repo.get_by(AppConfig, scope: scope, key: active_key)
      end)

    provider_id = "upgrade-#{Ecto.UUID.generate()}"
    idp_key = LarkConfig.identity_config_key(provider_id)
    name = "upgrade-#{Ecto.UUID.generate()}"
    binding_key = TeamsConfig.chat_config_key(name)
    agents = for _ <- 1..2, do: agent_fixture().principal
    agent_uids = Enum.map(agents, & &1.uid)
    binding_keys = Enum.map(agent_uids, &TeamsConfig.binding_config_key(&1, name))
    keys = [idp_key, binding_key | binding_keys]

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.with_tenant(tenant.id, fn ->
          Repo.delete_all(from binding in Binding, where: binding.agent_uid in ^agent_uids)
          Enum.each(agent_uids, &delete_agent_fixture_rows/1)
          Repo.delete_all(Group)
          Repo.delete_all(Principal)
          Repo.delete_all(from job in Oban.Job, where: job.args["tenant_id"] == ^tenant.id)
          Repo.delete!(tenant)
        end)

        Repo.delete_all(from config in SiteConfig, where: config.key in ^keys)

        Repo.with_tenant(original.id, fn ->
          Repo.delete_all(from config in AppConfig, where: config.key in ^[idp_key, active_key])
          if previous_active, do: Repo.insert!(Ecto.put_meta(previous_active, state: :built))
        end)
      end)
    end)

    {:ok, identity_config} =
      LarkConfig.validate_identity_config(%{
        "appID" => "cli_upgrade_#{Ecto.UUID.generate()}",
        "appSecret" => "old-secret",
        "sync" => %{"contacts" => true, "websocket" => false}
      })

    seed_config(idp_key, identity_config)

    Repo.with_tenant(original.id, fn ->
      {:ok, _} =
        AppConfigure.put_tenant_by_key(active_key, [
          %{
            "provider_id" => provider_id,
            "adapter_id" => "lark",
            "plugin_id" => "lark-adapter",
            "config_key" => idp_key,
            "enabled" => true
          }
        ])
    end)

    {:ok, binding_config} =
      TeamsConfig.validate_chat_config(%{
        "appID" => Ecto.UUID.generate(),
        "appPassword" => "old-secret",
        "botTenancy" => "multi_tenant"
      })

    seed_config(binding_key, binding_config)

    for uid <- agent_uids do
      %Binding{}
      |> Binding.changeset(%{
        agent_uid: uid,
        name: name,
        adapter: "teams",
        config_ref: "app-config://#{binding_key}"
      })
      |> Repo.insert!()
    end

    %{
      scope: scope,
      original_id: original.id,
      idp_key: idp_key,
      identity_config: identity_config,
      binding_key: binding_key,
      binding_keys: binding_keys,
      binding_config: binding_config,
      agent_uids: agent_uids,
      name: name
    }
  end

  for {entry, args} <- [
        {"ecto.migrate", ["ecto.migrate", "--quiet", "--no-compile", "--no-deps-check"]},
        {"ecto.setup", ["ecto.setup"]},
        {"Upgrade202610.run",
         [
           "run",
           "--no-start",
           "--no-compile",
           "--no-deps-check",
           "-e",
           "Ankole.Upgrade202610.run()"
         ]},
        {"Release.migrate",
         [
           "run",
           "--no-start",
           "--no-compile",
           "--no-deps-check",
           "-e",
           "Ankole.Release.migrate(); " <>
             "Enum.each([Ankole.Repo, Ankole.AppConfigure.Registry, Ankole.AppConfigure.Cache, Ankole.PubSub], fn name -> nil = Process.whereis(name) end)"
         ]}
      ] do
    @args args

    test "#{entry} completes the persisted data upgrade when no schema migrations remain",
         context do
      run_command(@args)

      row =
        Repo.with_tenant(context.original_id, fn ->
          Repo.get_by!(AppConfig, scope: context.scope, key: context.idp_key)
        end)

      assert {:ok, value} = Crypto.unseal(row.value["value"], context.scope, context.idp_key)
      assert value == context.identity_config
      assert is_binary(row.value["platform_application"])
      refute Repo.get_by(SiteConfig, scope: "global", key: context.idp_key)
      assert :error = AppConfigure.get_by_key(context.idp_key)
      refute Repo.get_by(SiteConfig, scope: "global", key: context.binding_key)

      for uid <- context.agent_uids do
        binding = Repo.get_by!(Binding, agent_uid: uid, name: context.name)
        key = TeamsConfig.binding_config_key(uid, context.name)
        assert binding.config_ref == "app-config://#{key}"
        assert {:ok, config} = Bindings.stored_binding_config(binding)
        assert config == context.binding_config

        assert is_binary(
                 Repo.get_by!(SiteConfig, scope: "global", key: key).value["platform_application"]
               )
      end

      keys = [context.idp_key | context.binding_keys]

      before_repeat = configuration_rows(context.original_id, keys)
      run_command(@args)
      assert configuration_rows(context.original_id, keys) == before_repeat
    end
  end

  defp seed_config(key, config) do
    {:ok, ciphertext} = Crypto.seal(config, "global", key)

    Repo.insert!(%SiteConfig{
      scope: "global",
      key: key,
      value: %{"type" => "cipher", "value" => ciphertext}
    })
  end

  defp configuration_rows(original_id, keys) do
    site = Repo.all(from config in SiteConfig, where: config.key in ^keys, order_by: config.key)

    tenant =
      Repo.with_tenant(original_id, fn ->
        Repo.all(from config in AppConfig, where: config.key in ^keys, order_by: config.key)
      end)

    {site, tenant}
  end

  defp run_command(args) do
    {output, status} =
      System.cmd("mix", args,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, "#{Enum.join(["mix" | args], " ")} failed:\n#{output}"
  end
end
