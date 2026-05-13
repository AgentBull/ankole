defmodule Feishu.GatewayAdapterTest do
  use ExUnit.Case, async: false

  alias BullX.Gateway.SourceConfig
  alias Feishu.GatewayAdapter

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

  test "connectivity_check verifies credentials without leaking secrets" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/open-apis/auth/v3/tenant_access_token/internal"

      Req.Test.json(conn, %{
        "code" => 0,
        "expire" => 7200,
        "tenant_access_token" => "tenant-token"
      })
    end)

    assert {:ok, result} =
             GatewayAdapter.connectivity_check(
               source_config(req_options: [plug: {Req.Test, __MODULE__}])
             )

    assert result.adapter == "feishu"
    assert result.channel_id == "main"
    assert result.details["domain"] == "feishu"
    assert inspect(result) =~ "verified"
    refute inspect(result) =~ "secret_test"
    refute inspect(result) =~ "tenant-token"
  end

  test "connectivity_check maps auth errors safely" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"code" => 99_991_663, "msg" => "invalid app credentials"})
    end)

    assert {:error, error} =
             GatewayAdapter.connectivity_check(
               source_config(req_options: [plug: {Req.Test, __MODULE__}])
             )

    assert error["kind"] == "auth"
    assert error["message"] == "invalid app credentials"
    refute inspect(error) =~ "secret_test"
  end

  defp source_config(extra_config) do
    %SourceConfig{
      adapter: "feishu",
      channel_id: "main",
      enabled?: true,
      config:
        Map.merge(%{"credential_id" => "default", "domain" => "feishu"}, Map.new(extra_config))
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
