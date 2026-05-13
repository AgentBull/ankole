defmodule BullxTelegram.SourceTest do
  use BullX.DataCase, async: false

  alias BullX.Gateway.SourceConfig
  alias BullxTelegram.Source

  setup %{sandbox_owner: owner} do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, owner, cache_pid)

    payload =
      Jason.encode!(%{
        "default" => %{"bot_token" => "test_token", "bot_username" => "test_bot"},
        "secondary" => %{"bot_token" => "other_token"}
      })

    BullX.Config.put("bullx.plugins.telegram.credentials", payload)

    on_exit(fn ->
      BullX.Config.delete("bullx.plugins.telegram.credentials")
    end)

    :ok
  end

  test "normalize/1 loads bot_token from credentials and source uses it" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "telegram",
        "channel_id" => "main",
        "enabled" => true,
        "config" => %{}
      })

    assert {:ok, source} = Source.normalize(source_config)
    assert source.adapter == "telegram"
    assert source.channel_id == "main"
    assert source.bot_token == "test_token"
    assert source.bot_username == "test_bot"
    assert source.credential_id == "default"
  end

  test "normalize/1 picks an alternate credential profile" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "telegram",
        "channel_id" => "second",
        "config" => %{"credential_id" => "secondary"}
      })

    assert {:ok, source} = Source.normalize(source_config)
    assert source.credential_id == "secondary"
    assert source.bot_token == "other_token"
    assert is_nil(source.bot_username)
  end

  test "Inspect strips bot_token" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "telegram",
        "channel_id" => "main",
        "config" => %{}
      })

    {:ok, source} = Source.normalize(source_config)
    representation = inspect(source)
    refute representation =~ "test_token"
  end

  test "normalize/1 rejects unknown credential_id" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "telegram",
        "channel_id" => "main",
        "config" => %{"credential_id" => "missing"}
      })

    assert {:error, %{"kind" => "config"}} = Source.normalize(source_config)
  end

  test "normalize/1 normalizes attention defaults" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "telegram",
        "channel_id" => "main",
        "config" => %{
          "attention" => %{
            "allowed_chat_ids" => [-100],
            "free_response_chat_ids" => [-200, -300]
          }
        }
      })

    {:ok, source} = Source.normalize(source_config)
    assert source.attention["allowed_chat_ids"] == ["-100"]
    assert source.attention["free_response_chat_ids"] == ["-200", "-300"]
    assert source.attention["require_mention"] == true
  end

  test "normalize/1 rejects invalid commands.sync_policy" do
    {:ok, source_config} =
      SourceConfig.normalize(%{
        "adapter" => "telegram",
        "channel_id" => "main",
        "config" => %{"commands" => %{"sync_policy" => "merge"}}
      })

    assert {:error, %{"kind" => "config"}} = Source.normalize(source_config)
  end

  test "request/3 calls the configured api_module with bot_token" do
    parent = self()

    defmodule FakeApi do
      def request(_token, _method, _params) do
        :forwarded
      end
    end

    fake_api =
      Module.concat([__MODULE__, FakeApi2])
      |> tap(fn module ->
        Code.compile_quoted(
          quote do
            defmodule unquote(module) do
              def request(token, method, params) do
                send(unquote(parent), {:api_request, token, method, params})
                {:ok, %{"id" => 100, "username" => "test_bot"}}
              end
            end
          end
        )
      end)

    source = %Source{
      adapter: "telegram",
      channel_id: "main",
      bot_token: "test_token",
      flood_wait_max_ms: 0,
      api_module: fake_api
    }

    assert {:ok, %{"id" => 100}} = Source.request(source, "getMe", [])
    assert_receive {:api_request, "test_token", "getMe", []}
  end
end
