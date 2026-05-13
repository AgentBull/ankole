defmodule Feishu.ContentMapperTest do
  use ExUnit.Case, async: false

  alias BullX.Gateway.SourceConfig
  alias Feishu.{ContentMapper, Source}

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

  test "uploads outbound data URI images as native Feishu media" do
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

        "/open-apis/im/v1/images" ->
          Req.Test.json(conn, %{"code" => 0, "data" => %{"image_key" => "img_v2_x"}})
      end
    end)

    {:ok, source} =
      Source.normalize(%SourceConfig{
        adapter: "feishu",
        channel_id: "main",
        enabled?: true,
        config: %{"credential_id" => "default", "req_options" => [plug: {Req.Test, __MODULE__}]}
      })

    content = %{
      "kind" => "image",
      "body" => %{
        "url" => "data:image/png;base64,aGVsbG8=",
        "filename" => "hello.png",
        "fallback_text" => "image"
      }
    }

    assert {:ok, rendered, []} = ContentMapper.render_outbound(content, source)
    assert rendered.msg_type == "image"
    assert Jason.decode!(rendered.content) == %{"image_key" => "img_v2_x"}
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
