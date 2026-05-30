defmodule BullxTelegram.ConfigSourceTest do
  use ExUnit.Case, async: true

  alias BullxTelegram.Config.IMGatewaySources
  alias BullxTelegram.Source

  defmodule API do
    def request(_source, "getMe", _params),
      do: {:ok, %{"id" => 123_456, "username" => "bullx_bot"}}
  end

  test "im_gateway source cast normalizes one channel instance with its bot token" do
    assert {:ok, [source]} =
             IMGatewaySources.cast([
               %{
                 id: "main",
                 bot_token: "123456:ABC",
                 bot_username: "bullx_bot",
                 stream_update_interval_ms: 1_000,
                 stream_chunk_soft_limit: 3_900,
                 attention: %{require_mention: false}
               }
             ])

    assert source["id"] == "main"
    assert source["bot_token"] == "123456:ABC"
    assert source["enabled"] == true
    refute Map.has_key?(source, "stream_update_interval_ms")
    refute Map.has_key?(source, "stream_chunk_soft_limit")
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

    stale_public =
      Source.public_config(%{
        "id" => "main",
        "stream_update_interval_ms" => 1_000,
        "stream_chunk_soft_limit" => 3_900
      })

    assert stale_public["id"] == "main"
    refute Map.has_key?(stale_public, "stream_update_interval_ms")
    refute Map.has_key?(stale_public, "stream_chunk_soft_limit")

    assert {:ok, %{details: %{"bot_username" => "bullx_bot"}}} =
             Source.connectivity_check(source)
  end
end
