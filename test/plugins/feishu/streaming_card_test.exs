defmodule Feishu.StreamingCardTest do
  use ExUnit.Case, async: false

  alias BullX.Gateway.SourceConfig
  alias Feishu.{Source, StreamingCard}

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

  test "streams through CardKit create, content update, and final settings calls" do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/auth/v3/tenant_access_token/internal" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "expire" => 7200,
            "tenant_access_token" => "tenant-token"
          })

        "/open-apis/cardkit/v1/cards" ->
          Req.Test.json(conn, %{"code" => 0, "data" => %{"card_id" => "card_1"}})

        "/open-apis/im/v1/messages" ->
          Req.Test.json(conn, %{"code" => 0, "data" => %{"message_id" => "om_stream"}})

        "/open-apis/cardkit/v1/cards/card_1/elements/content/content" ->
          Req.Test.json(conn, %{"code" => 0, "data" => %{}})

        "/open-apis/cardkit/v1/cards/card_1/settings" ->
          Req.Test.json(conn, %{"code" => 0, "data" => %{}})
      end
    end)

    {:ok, source} =
      Source.normalize(%SourceConfig{
        adapter: "feishu",
        channel_id: "main",
        enabled?: true,
        config: %{
          "credential_id" => "default",
          "stream_update_interval_ms" => 1,
          "req_options" => [plug: {Req.Test, __MODULE__}]
        }
      })

    delivery = %{
      "id" => BullX.Ext.gen_uuid_v7(),
      "scope_id" => "oc_1"
    }

    assert {:ok, outcome} = StreamingCard.stream(delivery, ["hello", " world\n"], source)
    assert outcome["status"] == "sent"
    assert outcome["primary_external_id"] == "om_stream"
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
