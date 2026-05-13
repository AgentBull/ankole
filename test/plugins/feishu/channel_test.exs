defmodule Feishu.ChannelTest do
  use ExUnit.Case, async: false

  alias BullX.Gateway.SourceConfig

  setup do
    previous_plugins = Application.get_env(:bullx, :plugins)

    Application.put_env(:bullx, :plugins, %{
      feishu: %{
        credentials: %{
          "default" => %{"app_id" => "cli_test", "app_secret" => "secret_test"}
        }
      }
    })

    on_exit(fn -> restore_env(:plugins, previous_plugins) end)

    :ok
  end

  test "card action callback entry handles Feishu challenge payloads" do
    source = %SourceConfig{
      adapter: "feishu",
      channel_id: "main",
      enabled?: true,
      config: %{"credential_id" => "default"}
    }

    assert {:challenge, "echo"} =
             Feishu.Channel.handle_card_action_callback(
               %{"type" => "url_verification", "challenge" => "echo"},
               source
             )
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
