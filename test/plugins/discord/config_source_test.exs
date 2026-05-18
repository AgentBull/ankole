defmodule Discord.ConfigSourceTest do
  use ExUnit.Case, async: true

  alias Discord.Config.{Credentials, EventBusSources}
  alias Discord.Source

  defmodule API do
    def request(_source, :get_current_bot, _params), do: {:ok, %{"id" => "bot_1"}}
    def request(source, :get_application, _params), do: {:ok, %{"id" => source.application_id}}
  end

  test "credentials cast keeps bot tokens and client secrets under credential profiles" do
    assert {:ok,
            %{
              "main" => %{
                "application_id" => "app_1",
                "bot_token" => "token",
                "client_secret" => "secret"
              }
            }} =
             Credentials.cast(%{
               main: %{application_id: "app_1", bot_token: "token", client_secret: "secret"}
             })
  end

  test "eventbus source cast normalizes operator config" do
    assert {:ok, [source]} =
             EventBusSources.cast([
               %{
                 id: "main",
                 credential_id: "default",
                 connected_realm_ref: "discord:application:app_1",
                 oauth2: %{enabled: true, redirect_uri: "https://bullx.example/callback"}
               }
             ])

    assert source["id"] == "main"
    assert source["enabled"] == true

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

    assert {:ok, %{details: %{"bot_user_id" => "bot_1"}}} = Source.connectivity_check(source)
  end
end
