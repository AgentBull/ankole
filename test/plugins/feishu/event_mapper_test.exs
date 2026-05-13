defmodule Feishu.EventMapperTest do
  use ExUnit.Case, async: false

  alias BullX.Gateway.SourceConfig
  alias Feishu.{EventMapper, Source}
  alias FeishuOpenAPI.Event

  setup do
    previous_plugins = Application.get_env(:bullx, :plugins)

    Application.put_env(:bullx, :plugins, %{
      feishu: %{
        credentials: %{
          "default" => %{"app_id" => "cli_test", "app_secret" => "secret_test"}
        }
      }
    })

    {:ok, source} =
      Source.normalize(%SourceConfig{
        adapter: "feishu",
        channel_id: "main",
        enabled?: true,
        config: %{"credential_id" => "default", "bot_open_id" => "ou_bot"}
      })

    on_exit(fn -> restore_env(:plugins, previous_plugins) end)

    {:ok, source: source}
  end

  test "maps message events to Gateway input", %{source: source} do
    event = message_event("hello")

    assert {:ok, %{input: input, account_input: account_input}} =
             EventMapper.map_event("im.message.receive_v1", event, source)

    assert input["adapter"] == "feishu"
    assert input["channel_id"] == "main"
    assert input["scope_id"] == "oc_1"
    assert input["actor"]["id"] == "feishu:ou_user"
    assert input["content"] == [%{"kind" => "text", "body" => %{"text" => "hello"}}]
    assert account_input["external_id"] == "feishu:ou_user"
    assert account_input["metadata"]["tenant_key"] == "tenant_1"
  end

  test "maps non-built-in slash commands to slash_command inputs", %{source: source} do
    event = message_event("/deploy production")

    assert {:ok, %{input: input}} =
             EventMapper.map_event("im.message.receive_v1", event, source)

    assert input["event"]["type"] == "slash_command"
    assert input["event"]["data"]["command_name"] == "deploy"
    assert input["event"]["data"]["args"] == "production"
  end

  test "intercepts built-in direct commands before publish", %{source: source} do
    event = message_event("/ping")

    assert {:direct_command, command} =
             EventMapper.map_event("im.message.receive_v1", event, source)

    assert command.name == "ping"
    assert command.chat_id == "oc_1"
    assert command.actor.id == "feishu:ou_user"
  end

  test "resolves open_id before publishing when event only carries user_id" do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    Req.Test.stub({__MODULE__, :resolve_open_id}, fn conn ->
      case conn.request_path do
        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "expire" => 7200,
            "tenant_access_token" => "tenant-token"
          })

        "/open-apis/contact/v3/users/u_user" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{"user" => %{"open_id" => "ou_resolved"}}
          })
      end
    end)

    {:ok, source} =
      Source.normalize(%SourceConfig{
        adapter: "feishu",
        channel_id: "main",
        enabled?: true,
        config: %{
          "credential_id" => "default",
          "bot_open_id" => "ou_bot",
          "req_options" => [plug: {Req.Test, {__MODULE__, :resolve_open_id}}]
        }
      })

    event =
      "hello"
      |> message_event()
      |> put_in([Access.key!(:content), "sender", "sender_id"], %{"user_id" => "u_user"})

    assert {:ok, %{input: input, account_input: account_input}} =
             EventMapper.map_event("im.message.receive_v1", event, source)

    assert input["actor"]["id"] == "feishu:ou_resolved"
    assert account_input["external_id"] == "feishu:ou_resolved"
  end

  test "ignores configured self-sent bot messages", %{source: source} do
    event =
      message_event("bot echo")
      |> put_in([Access.key!(:content), "sender", "sender_type"], "bot")
      |> put_in([Access.key!(:content), "sender", "sender_id", "open_id"], "ou_bot")

    assert {:ignore, :self_sent_bot_message} =
             EventMapper.map_event("im.message.receive_v1", event, source)
  end

  defp message_event(text) do
    %Event{
      id: "evt_1",
      type: "im.message.receive_v1",
      tenant_key: "tenant_1",
      app_id: "cli_test",
      raw: %{},
      content: %{
        "sender" => %{
          "sender_type" => "user",
          "sender_id" => %{"open_id" => "ou_user", "user_id" => "u_user"},
          "name" => "Alice"
        },
        "message" => %{
          "message_id" => "om_1",
          "chat_id" => "oc_1",
          "chat_type" => "p2p",
          "message_type" => "text",
          "content" => Jason.encode!(%{"text" => text})
        }
      }
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
