defmodule Discord.OAuth2ProviderTest do
  use BullX.DataCase, async: false

  alias BullX.Gateway.SourceConfig
  alias Discord.OAuth2Provider

  setup %{sandbox_owner: owner} do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, owner, cache_pid)

    payload =
      Jason.encode!(%{
        "default" => %{
          "application_id" => "app_1",
          "bot_token" => "tok",
          "client_secret" => "secret"
        }
      })

    BullX.Config.put("bullx.plugins.discord.credentials", payload)
    on_exit(fn -> BullX.Config.delete("bullx.plugins.discord.credentials") end)
    :ok
  end

  defp source_config(opts \\ []) do
    config =
      %{
        "oauth2" => %{
          "enabled" => Keyword.get(opts, :enabled, true),
          "redirect_uri" => Keyword.get(opts, :redirect_uri, "https://example.com/cb")
        }
      }

    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "main",
        "enabled" => true,
        "config" => config
      })

    source_config
  end

  describe "authorization_url/2" do
    test "builds authorization URL with state, scopes, redirect" do
      assert {:ok, %{url: url, state: state}} =
               OAuth2Provider.authorization_url(source_config(), %{"return_to" => "/dashboard"})

      assert url =~ "https://discord.com/oauth2/authorize"
      assert url =~ "client_id=app_1"
      assert url =~ "response_type=code"
      assert url =~ "scope=identify+email"
      assert state["provider"] == "main"
      assert state["adapter"] == "discord"
      assert state["return_to"] == "/dashboard"
      assert is_binary(state["nonce"])
    end

    test "rejects when OAuth2 is disabled" do
      assert {:error, %{"kind" => "config"}} =
               OAuth2Provider.authorization_url(source_config(enabled: false), %{})
    end

    test "drops non-local return_to" do
      assert {:ok, %{state: state}} =
               OAuth2Provider.authorization_url(source_config(), %{
                 "return_to" => "https://evil.example/"
               })

      assert state["return_to"] == "/"
    end
  end

  describe "callback/3 — state validation" do
    test "rejects unknown adapter in state" do
      state = %{
        "provider" => "main",
        "adapter" => "facebook",
        "channel_id" => "main",
        "return_to" => "/",
        "issued_at" => System.system_time(:second),
        "nonce" => "x"
      }

      assert {:error, %{"kind" => "payload"}} =
               OAuth2Provider.callback(source_config(), %{"code" => "abc"}, state)
    end

    test "rejects mismatched channel_id" do
      state = %{
        "provider" => "other",
        "adapter" => "discord",
        "channel_id" => "other",
        "return_to" => "/",
        "issued_at" => System.system_time(:second),
        "nonce" => "x"
      }

      assert {:error, %{"kind" => "payload"}} =
               OAuth2Provider.callback(source_config(), %{"code" => "abc"}, state)
    end

    test "rejects expired state" do
      state = %{
        "provider" => "main",
        "adapter" => "discord",
        "channel_id" => "main",
        "return_to" => "/",
        "issued_at" => System.system_time(:second) - 999_999,
        "nonce" => "x"
      }

      assert {:error, %{"kind" => "payload"}} =
               OAuth2Provider.callback(source_config(), %{"code" => "abc"}, state)
    end
  end
end
