defmodule Ankole.Signals.ApplicationBindingsTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AppConfigure.Crypto
  alias Ankole.Signals.Binding
  alias Ankole.Signals.Bindings

  setup do
    allow_cache_database_access()
    :ok
  end

  for {adapter, module, unavailable} <- [
        {"line", Ankole.Plugins.LineAdapter.Config, :line_binding_config_unavailable},
        {"lark", Ankole.Plugins.LarkAdapter.Config, :lark_binding_config_unavailable},
        {"email", Ankole.Plugins.EmailAdapter.Config, :email_binding_config_unavailable},
        {"whatsapp", Ankole.Plugins.WhatsAppAdapter.Config, :whatsapp_binding_config_unavailable}
      ] do
    @adapter adapter
    @config_module module
    @unavailable unavailable

    test "#{adapter} refuses a new application while an enabled owner's configuration is unavailable" do
      %{principal: owner} = agent_fixture()
      %{principal: claimant} = agent_fixture()
      owner_uid = owner.uid
      key = @config_module.binding_config_key(owner.uid, "owner")

      assert {:ok, %Binding{}} =
               Bindings.upsert_binding(%{
                 agent_uid: owner.uid,
                 name: "owner",
                 adapter: @adapter,
                 config_ref: "app-config://#{key}",
                 enabled: true
               })

      missing_error =
        case @adapter do
          "lark" -> {@unavailable, owner.uid, "owner", :missing}
          _ -> {@unavailable, owner.uid, "owner"}
        end

      assert {:error, ^missing_error} =
               Bindings.put_binding(claimant.uid, @adapter, "claimant", %{
                 "config" => config(@adapter),
                 "group_message_mode" => "addressed_only"
               })

      # The public application metadata is complete and different. An unreadable
      # enabled configuration must still stop assignment, as before this change.
      row =
        Repo.insert!(%SiteConfig{
          scope: "global",
          key: key,
          value: %{
            "type" => "cipher",
            "value" => "invalid-cipher-fixture",
            "platform_application" => "#{@adapter}:other-owner"
          }
        })

      assert {:error,
              {@unavailable, ^owner_uid, "owner", {:storage_error, "global", ^key, _reason}}} =
               Bindings.put_binding(claimant.uid, @adapter, "claimant", %{
                 "config" => config(@adapter),
                 "group_message_mode" => "addressed_only"
               })

      {:ok, ciphertext} = Crypto.seal(%{}, "global", key)

      assert {1, _} =
               Repo.update_all(
                 from(config in SiteConfig,
                   where: config.scope == "global" and config.key == ^key
                 ),
                 set: [value: Map.put(row.value, "value", ciphertext)]
               )

      assert {:error,
              {@unavailable, ^owner_uid, "owner", {:storage_error, "global", ^key, _reason}}} =
               Bindings.put_binding(claimant.uid, @adapter, "claimant", %{
                 "config" => config(@adapter),
                 "group_message_mode" => "addressed_only"
               })

      refute Repo.get_by(Binding, agent_uid: claimant.uid, name: "claimant")
    end
  end

  for later_failure <- [:duplicate, :invalid_cipher] do
    @later_failure later_failure
    test "WhatsApp reports the first peer's credential conflict before a later #{@later_failure}" do
      %{principal: owner} = agent_fixture()
      %{principal: claimant} = agent_fixture()

      first_config =
        config("whatsapp")
        |> Map.put("phoneNumberId", "30001")
        |> Map.put("appSecret", "other-fixture-secret")

      first = seed_whatsapp_binding(owner.uid, "credentials-first", first_config)
      later_config = Map.put(config("whatsapp"), "appId", "90001")
      later = seed_whatsapp_binding(owner.uid, "duplicate-later", later_config)

      if @later_failure == :invalid_cipher do
        key = Ankole.Plugins.WhatsAppAdapter.Config.binding_config_key(owner.uid, later.name)
        row = Repo.get_by!(SiteConfig, scope: "global", key: key)

        assert {1, _} =
                 Repo.update_all(
                   from(config in SiteConfig,
                     where: config.scope == "global" and config.key == ^key
                   ),
                   set: [value: Map.put(row.value, "value", "invalid-cipher-fixture")]
                 )
      end

      # Neither implementation declares a cross-row order. This fixture checks
      # the actual database traversal, without an ORDER BY or adapter fake.
      assert Repo.all(
               from(binding in Binding,
                 where: binding.adapter == "whatsapp" and binding.enabled == true,
                 select: {binding.agent_uid, binding.name}
               )
             ) == [{first.agent_uid, first.name}, {later.agent_uid, later.name}]

      owner_uid = owner.uid

      assert {:error, {:whatsapp_app_credentials_mismatch, ^owner_uid, "credentials-first"}} =
               Bindings.put_binding(claimant.uid, "whatsapp", "claimant", %{
                 "config" => config("whatsapp"),
                 "group_message_mode" => "addressed_only"
               })

      refute Repo.get_by(Binding, agent_uid: claimant.uid, name: "claimant")
    end
  end

  defp seed_whatsapp_binding(agent_uid, name, config) do
    module = Ankole.Plugins.WhatsAppAdapter.Config
    key = module.binding_config_key(agent_uid, name)
    {:ok, ciphertext} = Crypto.seal(config, "global", key)
    {:ok, application} = module.platform_application(config)

    Repo.insert!(%SiteConfig{
      scope: "global",
      key: key,
      value: %{"type" => "cipher", "value" => ciphertext, "platform_application" => application}
    })

    {:ok, binding} =
      Bindings.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: "whatsapp",
        config_ref: "app-config://#{key}",
        enabled: true
      })

    binding
  end

  defp config("line"),
    do: %{
      "channelId" => "10001",
      "channelSecret" => "fixture-secret",
      "channelAccessToken" => "fixture-token"
    }

  defp config("lark"),
    do: %{
      "appID" => "cli_application_fixture",
      "appSecret" => "fixture-secret",
      "domain" => "feishu"
    }

  defp config("email"),
    do: %{
      "address" => "agent@example.com",
      "imapHost" => "imap.example.com",
      "smtpHost" => "smtp.example.com",
      "username" => "agent",
      "password" => "fixture-secret"
    }

  defp config("whatsapp"),
    do: %{
      "appId" => "10001",
      "appSecret" => "fixture-secret",
      "verifyToken" => "fixture-verify",
      "phoneNumberId" => "20001",
      "accessToken" => "fixture-token"
    }
end
