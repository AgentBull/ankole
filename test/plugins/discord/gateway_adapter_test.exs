defmodule Discord.GatewayAdapterTest do
  use BullX.DataCase, async: false

  alias BullX.Gateway.SourceConfig
  alias Discord.GatewayAdapter

  defmodule FakeSelfApi do
    def get, do: {:ok, %{id: 1_234_567_890_123_456_789, username: "bullx"}}
  end

  defmodule FailingSelfApi do
    def get,
      do:
        {:error,
         %{
           __exception__: true,
           __struct__: Nostrum.Error.ApiError,
           status_code: 401,
           response: %{}
         }}
  end

  setup %{sandbox_owner: owner} do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, owner, cache_pid)

    payload =
      Jason.encode!(%{
        "default" => %{
          "application_id" => "111",
          "bot_token" => "tok",
          "client_secret" => "sec"
        }
      })

    BullX.Config.put("bullx.plugins.discord.credentials", payload)
    on_exit(fn -> BullX.Config.delete("bullx.plugins.discord.credentials") end)
    :ok
  end

  test "capabilities/0 declares the v1 surface" do
    caps = GatewayAdapter.capabilities()

    assert :gateway_ws in caps.inbound_modes
    assert :interaction in caps.inbound_modes
    assert :send in caps.outbound_ops
    assert :edit in caps.outbound_ops
    assert :stream in caps.outbound_ops
    assert :threads in caps.features
    assert :application_commands in caps.features
    assert :ephemeral_replies in caps.features
    assert :text in caps.content_kinds
  end

  defp build_source_config(api_module) do
    %SourceConfig{
      adapter: "discord",
      channel_id: "main",
      enabled?: true,
      config: %{"self_api" => api_module, "start_transport" => false}
    }
  end

  test "connectivity_check/1 verifies bot user and returns redacted metadata" do
    assert {:ok, result} = GatewayAdapter.connectivity_check(build_source_config(FakeSelfApi))

    assert result.status == :ok
    assert result.adapter == "discord"
    assert result.details["bot_user_id"] == "1234567890123456789"
    assert result.details["message_content_intent_required"] == true
    refute Map.has_key?(result.details, "bot_token")
  end

  test "connectivity_check/1 surfaces auth failure" do
    assert {:error, %{"kind" => "auth"}} =
             GatewayAdapter.connectivity_check(build_source_config(FailingSelfApi))
  end

  test "source_child_spec/1 returns :ignore for disabled sources" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "discord",
        "channel_id" => "main",
        "enabled" => false,
        "config" => %{}
      })

    assert :ignore = GatewayAdapter.source_child_spec(source_config)
  end
end
