defmodule BullXGateway.AdapterConfigTest do
  use ExUnit.Case, async: true

  alias BullXGateway.AdapterConfig

  test "encodes JSON setup entries and casts them back to runtime adapter specs" do
    entry = feishu_entry()

    assert {:ok, encoded, [normalized]} = AdapterConfig.encode_for_storage([entry])

    assert {:ok, [{{:feishu, "ops-main"}, BullXFeishu.Adapter, config}]} =
             AdapterConfig.cast(encoded)

    assert normalized["credentials"]["app_secret"] == "secret_test"
    assert normalized["web_login_disabled"] == false
    assert normalized["authn"]["external_org_members"]["tenant_key"] == "tenant_test"
    assert config.app_id == "cli_test"
    assert config.app_secret == "secret_test"
    assert config.web_login_disabled == false
    refute Map.has_key?(config, :authn)
    assert config.domain == :feishu
    assert config.stream_update_interval_ms == 100
  end

  test "catalog exposes localized adapter setup documentation with en-US fallback" do
    catalog = AdapterConfig.catalog("zh-Hans-CN")

    assert %{
             "config_doc_url" =>
               "https://github.com/AgentBull/bullx/blob/main/docs/channels/feishu.zh-Hans-CN.md",
             "authn_policies" => [%{"type" => "external_org_members"}],
             "default_entry" => %{"channel_id" => ""}
           } = Enum.find(catalog, &(&1["adapter"] == "feishu"))

    assert %{
             "config_doc_url" =>
               "https://github.com/AgentBull/bullx/blob/main/docs/channels/discord.zh-Hans-CN.md",
             "authn_policies" => [],
             "default_entry" => %{"channel_id" => ""}
           } = Enum.find(catalog, &(&1["adapter"] == "discord"))

    assert %{
             "config_doc_url" =>
               "https://github.com/AgentBull/bullx/blob/main/docs/channels/telegram.zh-Hans-CN.md",
             "authn_policies" => [],
             "fields" => [
               %{
                 "path" => ["transport", "secret_token"],
                 "type" => :generated_secret,
                 "secret" => true
               }
             ],
             "default_entry" => %{"channel_id" => ""}
           } = Enum.find(catalog, &(&1["adapter"] == "telegram"))

    assert %{
             "config_doc_url" =>
               "https://github.com/AgentBull/bullx/blob/main/docs/channels/feishu.en-US.md"
           } = Enum.find(AdapterConfig.catalog("ja-JP"), &(&1["adapter"] == "feishu"))
  end

  test "encodes Discord setup entries and casts them back to runtime adapter specs" do
    entry = discord_entry()

    assert {:ok, _encoded, [normalized]} = AdapterConfig.encode_for_storage([entry])

    assert {:ok, [{{:discord, "community"}, BullXDiscord.Adapter, config}]} =
             AdapterConfig.runtime_specs([normalized])

    assert normalized["credentials"]["bot_token"] == "bot_token_test"
    assert normalized["credentials"]["client_secret"] == "client_secret_test"
    assert normalized["attention"]["require_mention"] == true
    assert config.application_id == "app_test"
    assert config.bot_token == "bot_token_test"
    assert config.client_secret == "client_secret_test"
    assert config.application_commands.sync_policy == "safe"
  end

  test "encodes Telegram setup entries and generates webhook secret before runtime specs" do
    entry = telegram_entry(%{"transport" => %{"mode" => "webhook", "set_webhook" => true}})

    assert {:ok, _encoded, [normalized]} = AdapterConfig.encode_for_storage([entry])

    assert {:ok, [{{:telegram, "alerts"}, BullXTelegram.Adapter, config}]} =
             AdapterConfig.runtime_specs([normalized])

    assert normalized["credentials"]["bot_token"] == "telegram_token_test"
    assert normalized["transport"]["mode"] == "webhook"
    assert normalized["transport"]["secret_token"] != ""
    assert config.bot_token == "telegram_token_test"
    assert config.transport.secret_token == normalized["transport"]["secret_token"]
    assert config.commands.sync_policy == "replace"
    assert config.flood_wait_max_ms == 5000
  end

  test "disabled drafts are persisted but omitted from runtime specs" do
    entry =
      feishu_entry(%{
        "enabled" => false,
        "credentials" => %{"app_id" => "", "app_secret" => ""}
      })

    assert {:ok, _encoded, [normalized]} = AdapterConfig.encode_for_storage([entry])
    assert normalized["enabled"] == false
    assert {:ok, []} = AdapterConfig.runtime_specs([normalized])
  end

  test "web_login_disabled is adapter-level config and reaches runtime config" do
    entry = feishu_entry(%{"web_login_disabled" => true})

    assert {:ok, _encoded, [normalized]} = AdapterConfig.encode_for_storage([entry])
    assert normalized["web_login_disabled"] == true
    refute Map.has_key?(normalized["authn"], "web_login")

    assert {:ok, [{{:feishu, "ops-main"}, BullXFeishu.Adapter, config}]} =
             AdapterConfig.runtime_specs([normalized])

    assert config.web_login_disabled == true
  end

  test "enabled adapter channels must be unique" do
    entries = [
      feishu_entry(%{"id" => "a"}),
      feishu_entry(%{"id" => "b"})
    ]

    assert {:error, [%{"kind" => "config"}]} = AdapterConfig.encode_for_storage(entries)
  end

  test "Feishu domain is limited to Feishu or Lark" do
    assert {:error, [%{"details" => %{"field" => "adapters[0].domain"}}]} =
             AdapterConfig.encode_for_storage([
               feishu_entry(%{"domain" => "https://example.test"})
             ])
  end

  test "public entries redact secrets and normalize_entry can preserve stored secret values" do
    assert {:ok, stored} = AdapterConfig.normalize_entry(feishu_entry())

    public = AdapterConfig.public_entry(stored)

    assert public["credentials"]["app_secret"] == ""
    assert public["secret_status"]["app_secret"] == "stored"
    refute Map.has_key?(public["credentials"], "verification_token")
    refute Map.has_key?(public["credentials"], "encrypt_key")
    refute Map.has_key?(public["secret_status"], "verification_token")
    refute Map.has_key?(public["secret_status"], "encrypt_key")

    assert {:ok, merged} =
             AdapterConfig.normalize_entry(public, existing_entries: [stored])

    assert merged["credentials"]["app_secret"] == "secret_test"
  end

  test "public Discord entries redact bot token and OAuth client secret" do
    assert {:ok, stored} = AdapterConfig.normalize_entry(discord_entry())

    public = AdapterConfig.public_entry(stored)

    assert public["credentials"]["bot_token"] == ""
    assert public["credentials"]["client_secret"] == ""
    assert public["secret_status"]["bot_token"] == "stored"
    assert public["secret_status"]["client_secret"] == "stored"

    assert {:ok, merged} = AdapterConfig.normalize_entry(public, existing_entries: [stored])

    assert merged["credentials"]["bot_token"] == "bot_token_test"
    assert merged["credentials"]["client_secret"] == "client_secret_test"
  end

  test "public Telegram entries redact bot token and generated webhook secret" do
    assert {:ok, stored} =
             AdapterConfig.normalize_entry(
               telegram_entry(%{"transport" => %{"mode" => "webhook", "set_webhook" => true}})
             )

    public = AdapterConfig.public_entry(stored)

    assert public["credentials"]["bot_token"] == ""
    assert public["transport"]["secret_token"] == ""
    assert public["secret_status"]["bot_token"] == "stored"
    assert public["secret_status"]["transport.secret_token"] == "stored"

    assert {:ok, merged} = AdapterConfig.normalize_entry(public, existing_entries: [stored])

    assert merged["credentials"]["bot_token"] == "telegram_token_test"
    assert merged["transport"]["secret_token"] == stored["transport"]["secret_token"]
  end

  test "public Telegram entries can reveal generated secrets before persistence" do
    assert {:ok, stored} =
             AdapterConfig.normalize_entry(
               telegram_entry(%{"transport" => %{"mode" => "webhook", "set_webhook" => true}})
             )

    public = AdapterConfig.public_entry(stored, reveal_generated_secrets?: true)

    assert public["credentials"]["bot_token"] == ""
    assert public["transport"]["secret_token"] == stored["transport"]["secret_token"]
    assert public["secret_status"]["transport.secret_token"] == "stored"
  end

  test "generated secret metadata is validated through the adapter catalog" do
    assert AdapterConfig.generated_secret_field?("telegram", ["transport", "secret_token"])
    refute AdapterConfig.generated_secret_field?("telegram", ["credentials", "bot_token"])
    refute AdapterConfig.generated_secret_field?("discord", ["transport", "secret_token"])
  end

  test "legacy Feishu webhook credentials are discarded for websocket-only adapters" do
    assert {:ok, normalized} =
             AdapterConfig.normalize_entry(
               feishu_entry(%{
                 "credentials" => %{
                   "app_id" => "cli_test",
                   "app_secret" => "secret_test",
                   "verification_token" => "legacy_vt",
                   "encrypt_key" => "legacy_ek"
                 }
               })
             )

    refute Map.has_key?(normalized["credentials"], "verification_token")
    refute Map.has_key?(normalized["credentials"], "encrypt_key")

    assert {:ok, [{{:feishu, "ops-main"}, BullXFeishu.Adapter, config}]} =
             AdapterConfig.runtime_specs([normalized])

    refute Map.has_key?(config, :verification_token)
    refute Map.has_key?(config, :encrypt_key)
  end

  defp feishu_entry(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "feishu:ops-main",
        "adapter" => "feishu",
        "channel_id" => "ops-main",
        "enabled" => true,
        "domain" => "feishu",
        "authn" => %{
          "external_org_members" => %{
            "enabled" => true,
            "tenant_key" => "tenant_test"
          }
        },
        "credentials" => %{
          "app_id" => "cli_test",
          "app_secret" => "secret_test"
        }
      },
      attrs
    )
  end

  defp discord_entry(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "discord:community",
        "adapter" => "discord",
        "channel_id" => "community",
        "enabled" => true,
        "web_login_disabled" => false,
        "credentials" => %{
          "application_id" => "app_test",
          "bot_token" => "bot_token_test",
          "client_secret" => "client_secret_test"
        }
      },
      attrs
    )
  end

  defp telegram_entry(attrs) do
    Map.merge(
      %{
        "id" => "telegram:alerts",
        "adapter" => "telegram",
        "channel_id" => "alerts",
        "enabled" => true,
        "web_login_disabled" => false,
        "credentials" => %{
          "bot_token" => "telegram_token_test",
          "bot_username" => "BullXBot"
        }
      },
      attrs
    )
  end
end
