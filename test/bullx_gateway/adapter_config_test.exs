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
    assert [
             %{
               "config_doc_url" =>
                 "https://github.com/AgentBull/bullx/blob/main/docs/channels/feishu.zh-Hans-CN.md",
               "authn_policies" => [%{"type" => "external_org_members"}],
               "default_entry" => %{"channel_id" => ""}
             }
           ] = AdapterConfig.catalog("zh-Hans-CN")

    assert [
             %{
               "config_doc_url" =>
                 "https://github.com/AgentBull/bullx/blob/main/docs/channels/feishu.en-US.md"
             }
           ] = AdapterConfig.catalog("ja-JP")
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
end
