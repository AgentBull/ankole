defmodule BullxTelegram.ConfigSourceTest do
  use ExUnit.Case, async: true

  alias BullxTelegram.Config.EventBusSources
  alias BullxTelegram.Source

  defmodule API do
    def request(_source, "getMe", _params),
      do: {:ok, %{"id" => 123_456, "username" => "bullx_bot"}}
  end

  test "eventbus source cast normalizes one channel instance with its bot token" do
    assert {:ok, [source]} =
             EventBusSources.cast([
               %{
                 id: "main",
                 bot_token: "123456:ABC",
                 bot_username: "bullx_bot",
                 attention: %{require_mention: false}
               }
             ])

    assert source["id"] == "main"
    assert source["bot_token"] == "123456:ABC"
    assert source["enabled"] == true
    assert source["attention"] == %{"require_mention" => false}
  end

  test "source normalization builds redacted public projection and connectivity metadata" do
    assert {:ok, source} =
             Source.normalize(%{
               id: "main",
               bot_token: "123456:ABC",
               bot_username: "bullx_bot",
               api_module: API,
               start_transport: false
             })

    assert source.bot_id == "123456"
    refute inspect(source) =~ "123456:ABC"

    public = Source.public_config(source)
    refute Map.has_key?(public, "bot_token")
    assert public["bot_id"] == "123456"

    assert {:ok, %{details: %{"bot_username" => "bullx_bot"}}} =
             Source.connectivity_check(source)
  end
end
