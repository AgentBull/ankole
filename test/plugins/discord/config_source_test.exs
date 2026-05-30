defmodule Discord.ConfigSourceTest do
  use ExUnit.Case, async: true

  alias Discord.Config.IMGatewaySources
  alias Discord.Source

  defmodule API do
    def request(_source, :get_current_bot, _params), do: {:ok, %{"id" => "bot_1"}}
    def request(source, :get_application, _params), do: {:ok, %{"id" => source.application_id}}
  end

  test "im_gateway source cast normalizes operator config" do
    assert {:ok, [source]} =
             IMGatewaySources.cast([
               %{
                 id: "main",
                 application_id: "app_1",
                 bot_token: "token",
                 client_secret: "secret",
                 stream_update_interval_ms: 1_000,
                 stream_chunk_soft_limit: 1_850,
                 oauth2: %{enabled: true, redirect_uri: "https://bullx.example/callback"}
               }
             ])

    assert source["id"] == "main"
    assert source["enabled"] == true
    assert source["application_id"] == "app_1"
    assert source["bot_token"] == "token"
    assert source["client_secret"] == "secret"
    refute Map.has_key?(source, "stream_update_interval_ms")
    refute Map.has_key?(source, "stream_chunk_soft_limit")

    assert source["oauth2"] == %{
             "enabled" => true,
             "redirect_uri" => "https://bullx.example/callback"
           }
  end

  test "source normalization redacts secrets and checks connectivity" do
    assert {:ok, source} =
             Source.normalize(%{
               id: "main",
               application_id: "app_1",
               bot_token: "token",
               client_secret: "secret",
               oauth2: %{enabled: true, redirect_uri: "https://bullx.example/callback"},
               api_module: API,
               start_transport: false
             })

    refute inspect(source) =~ "token"
    refute inspect(source) =~ "secret"
    refute Map.has_key?(Source.public_config(source), "bot_token")

    public_config =
      Source.public_config(%{
        "id" => "main",
        "stream_update_interval_ms" => 1_000,
        "stream_chunk_soft_limit" => 1_850
      })

    assert public_config["id"] == "main"
    refute Map.has_key?(public_config, "stream_update_interval_ms")
    refute Map.has_key?(public_config, "stream_chunk_soft_limit")

    assert {:ok, %{details: %{"bot_user_id" => "bot_1"}}} = Source.connectivity_check(source)
  end
end
