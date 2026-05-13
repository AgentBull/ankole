defmodule Discord.SourceTest do
  use BullX.DataCase, async: false

  alias BullX.Gateway.SourceConfig
  alias Discord.Source

  setup %{sandbox_owner: owner} do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, owner, cache_pid)

    payload =
      Jason.encode!(%{
        "default" => %{
          "application_id" => "123456789012345678",
          "bot_token" => "discord_token",
          "client_secret" => "discord_client_secret"
        },
        "no_oauth" => %{
          "application_id" => "999999999999999999",
          "bot_token" => "other_token"
        }
      })

    BullX.Config.put("bullx.plugins.discord.credentials", payload)
    on_exit(fn -> BullX.Config.delete("bullx.plugins.discord.credentials") end)
    :ok
  end

  test "normalize/1 loads bot credentials from plugin config" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "main",
        "enabled" => true,
        "config" => %{}
      })

    assert {:ok, source} = Source.normalize(source_config)
    assert source.adapter == "discord"
    assert source.channel_id == "main"
    assert source.application_id == "123456789012345678"
    assert source.bot_token == "discord_token"
    assert source.client_secret == "discord_client_secret"
    assert source.bot_name == :"discord:main"
  end

  test "normalize/1 picks an alternate credential profile" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "second",
        "config" => %{"credential_id" => "no_oauth"}
      })

    assert {:ok, source} = Source.normalize(source_config)
    assert source.credential_id == "no_oauth"
    assert source.application_id == "999999999999999999"
    assert source.bot_token == "other_token"
    assert is_nil(source.client_secret)
  end

  test "Inspect strips secrets" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "main",
        "config" => %{}
      })

    {:ok, source} = Source.normalize(source_config)
    representation = inspect(source)
    refute representation =~ "discord_token"
    refute representation =~ "discord_client_secret"
  end

  test "normalize/1 rejects unknown credential_id" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "main",
        "config" => %{"credential_id" => "missing"}
      })

    assert {:error, %{"kind" => "config"}} = Source.normalize(source_config)
  end

  test "normalize/1 rejects OAuth2 enabled without client_secret on credential" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "main",
        "config" => %{
          "credential_id" => "no_oauth",
          "oauth2" => %{
            "enabled" => true,
            "redirect_uri" => "https://example.com/cb"
          }
        }
      })

    assert {:error, %{"kind" => "config", "details" => %{"field" => "credentials.client_secret"}}} =
             Source.normalize(source_config)
  end

  test "normalize/1 rejects OAuth2 enabled without redirect_uri" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "main",
        "config" => %{
          "oauth2" => %{"enabled" => true}
        }
      })

    assert {:error, %{"kind" => "config", "details" => %{"field" => "oauth2.redirect_uri"}}} =
             Source.normalize(source_config)
  end

  test "normalize/1 normalizes attention defaults and free_response opt-in" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "main",
        "config" => %{
          "attention" => %{
            "allowed_channel_ids" => [123],
            "free_response_channel_ids" => [456, 789],
            "require_mention" => false
          }
        }
      })

    {:ok, source} = Source.normalize(source_config)
    assert source.attention["allowed_channel_ids"] == ["123"]
    assert source.attention["free_response_channel_ids"] == ["456", "789"]
    assert source.attention["require_mention"] == false
  end

  test "normalize/1 rejects invalid application_commands.sync_policy" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "main",
        "config" => %{"application_commands" => %{"sync_policy" => "force"}}
      })

    assert {:error, %{"kind" => "config"}} = Source.normalize(source_config)
  end

  test "oauth2_enabled?/1 requires both flag and client_secret" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "main",
        "config" => %{
          "oauth2" => %{
            "enabled" => true,
            "redirect_uri" => "https://example.com/cb"
          }
        }
      })

    {:ok, source} = Source.normalize(source_config)
    assert Source.oauth2_enabled?(source)

    no_secret = %{source | client_secret: nil}
    refute Source.oauth2_enabled?(no_secret)
  end

  test "stream_chunk_soft_limit caps at 2000" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "main",
        "config" => %{"stream_chunk_soft_limit" => 9_999}
      })

    {:ok, source} = Source.normalize(source_config)
    assert source.stream_chunk_soft_limit == 2_000
  end

  test "public_config/1 redacts credentials and injectable modules" do
    config = %{
      "credential_id" => "default",
      "bot_token" => "should-not-be-here",
      "client_secret" => "neither-should-this",
      "self_api" => :some_mock,
      "stream_chunk_soft_limit" => 1500
    }

    public = Source.public_config(config)
    refute Map.has_key?(public, "bot_token")
    refute Map.has_key?(public, "client_secret")
    refute Map.has_key?(public, "self_api")
    assert public["credential_id"] == "default"
    assert public["stream_chunk_soft_limit"] == 1500
  end
end
