defmodule BullXDiscord.ConfigTest do
  use ExUnit.Case, async: true

  alias BullXDiscord.Config

  test "normalizes required Discord config and includes message content intent" do
    assert {:ok, config} =
             Config.normalize({:discord, "community"}, %{
               application_id: 123,
               bot_token: " bot-token ",
               client_secret: " client-secret ",
               auto_thread: %{
                 auto_archive_duration_minutes: "60",
                 no_thread_channel_ids: [123, "456"]
               },
               attention: %{
                 allowed_channel_ids: [" 111 "],
                 ignored_channel_ids: [222],
                 require_mention: true
               },
               application_commands: %{sync_policy: :off}
             })

    assert config.channel == {:discord, "community"}
    assert config.channel_id == "community"
    assert config.application_id == "123"
    assert config.bot_token == "bot-token"
    assert config.client_secret == "client-secret"
    assert config.auto_thread.auto_archive_duration_minutes == 60
    assert config.auto_thread.no_thread_channel_ids == ["123", "456"]
    assert config.attention.allowed_channel_ids == ["111"]
    assert config.attention.ignored_channel_ids == ["222"]
    assert config.application_commands.sync_policy == "off"
    assert :message_content in Config.intents()
  end

  test "requires OAuth client secret only when web login is enabled" do
    assert {:error, %{"details" => %{"field" => "client_secret"}}} =
             Config.normalize({:discord, "default"}, %{
               application_id: "app",
               bot_token: "bot"
             })

    assert {:ok, %Config{web_login_disabled: true}} =
             Config.normalize({:discord, "default"}, %{
               application_id: "app",
               bot_token: "bot",
               web_login_disabled: true
             })
  end

  test "rejects free-response attention until that behavior is approved" do
    assert {:error, %{"details" => %{"field" => "attention.require_mention"}}} =
             Config.normalize({:discord, "default"}, %{
               application_id: "app",
               bot_token: "bot",
               client_secret: "secret",
               attention: %{require_mention: false}
             })
  end

  test "inspect output redacts Discord secrets" do
    {:ok, config} =
      Config.normalize({:discord, "default"}, %{
        application_id: "app",
        bot_token: "bot-secret",
        client_secret: "client-secret"
      })

    inspected = inspect(config)

    refute inspected =~ "bot-secret"
    refute inspected =~ "client-secret"
  end
end
