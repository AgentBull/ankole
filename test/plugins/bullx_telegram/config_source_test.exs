defmodule BullxTelegram.ConfigSourceTest do
  use ExUnit.Case, async: true

  alias BullxTelegram.Config.{Credentials, EventBusSources}
  alias BullxTelegram.Source

  defmodule API do
    def request(_source, "getMe", _params),
      do: {:ok, %{"id" => 123_456, "username" => "bullx_bot"}}
  end

  test "credentials cast keeps bot tokens under credential profiles" do
    assert {:ok, %{"main" => %{"bot_token" => "123456:ABC", "bot_username" => "bullx_bot"}}} =
             Credentials.cast(%{main: %{bot_token: "123456:ABC", bot_username: "bullx_bot"}})
  end

  test "eventbus source cast normalizes operator config without tokens" do
    assert {:ok, [source]} =
             EventBusSources.cast([
               %{
                 id: "main",
                 credential_id: "default",
                 connected_realm_ref: "telegram:bot:123456",
                 bot_username: "bullx_bot",
                 attention: %{require_mention: false}
               }
             ])

    assert source["id"] == "main"
    assert source["enabled"] == true
    assert source["attention"] == %{"require_mention" => false}
  end

  test "source normalization builds redacted public projection and connectivity metadata" do
    assert {:ok, source} =
             Source.normalize(%{
               id: "main",
               bot_token: "123456:ABC",
               bot_username: "bullx_bot",
               connected_realm_ref: "telegram:bot:123456",
               api_module: API,
               start_transport: false
             })

    assert source.bot_id == "123456"
    refute inspect(source) =~ "123456:ABC"

    public = Source.public_config(source)
    refute Map.has_key?(public, "bot_token")
    assert public["connected_realm_ref"] == "telegram:bot:123456"

    assert {:ok, %{details: %{"bot_username" => "bullx_bot"}}} =
             Source.connectivity_check(source)
  end
end
