defmodule BullXFeishu.DirectCommandTest do
  use ExUnit.Case, async: false

  alias BullXFeishu.{Cache, Config, DirectCommand}

  defmodule GatewayStub do
    def deliver(delivery) do
      send(Process.get(:test_pid), {:delivery, delivery})
      {:ok, delivery.id}
    end
  end

  defmodule AccountsStub do
    def consume_activation_code("VALID", _input), do: {:ok, %{id: "user"}, %{id: "binding"}}
    def consume_activation_code(_code, _input), do: {:error, :invalid_or_expired_code}
    def issue_user_channel_auth_code(:feishu, "default", "feishu:ou_user"), do: {:ok, "WEB123"}
  end

  setup do
    Process.put(:test_pid, self())

    {:ok, config} =
      Config.normalize({:feishu, "default"}, %{
        app_id: "cli_test",
        app_secret: "secret_test",
        gateway_module: GatewayStub,
        accounts_module: AccountsStub
      })

    {:ok, config: config, cache: Cache.new()}
  end

  test "parses slash commands" do
    assert {:ok, %{name: "preauth", args: "ABC"}} = DirectCommand.parse("/preauth ABC")
    assert :error = DirectCommand.parse("hello")
  end

  test "/ping replies PONG without account calls", %{config: config, cache: cache} do
    command = command("ping", "")

    assert {:ok, %{delivery_id: delivery_id}, _cache} =
             DirectCommand.handle(command, config, cache)

    assert_receive {:delivery, delivery}
    assert delivery.id == delivery_id
    assert delivery.content.body["text"] == "PONG!"
  end

  test "/preauth stays available when adapter channel disables web login", %{
    config: config,
    cache: cache
  } do
    config = %{config | web_login_disabled: true}

    assert {:ok, _result, _cache} =
             DirectCommand.handle(command("preauth", "VALID"), config, cache)

    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "Activation complete"
  end

  test "/web_auth issues a web login code for a bound actor", %{config: config, cache: cache} do
    assert {:ok, _result, _cache} =
             DirectCommand.handle(command("web_auth", ""), config, cache)

    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "WEB123"
    assert delivery.content.body["text"] =~ "/sessions/new"
  end

  test "/web_auth refuses when adapter channel disables web login", %{
    config: config,
    cache: cache
  } do
    config = %{config | web_login_disabled: true}

    assert {:ok, _result, _cache} =
             DirectCommand.handle(command("web_auth", ""), config, cache)

    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "Web login is disabled"
    refute delivery.content.body["text"] =~ "WEB123"
  end

  defp command(name, args) do
    %{
      name: name,
      args: args,
      event_id: "evt_#{name}_#{args}",
      channel: {:feishu, "default"},
      channel_id: "default",
      chat_id: "oc_1",
      chat_type: "p2p",
      thread_id: nil,
      message_id: "om_1",
      actor: %{id: "feishu:ou_user", open_id: "ou_user", display: "Alice", bot: false},
      account_input: %{
        adapter: :feishu,
        channel_id: "default",
        external_id: "feishu:ou_user",
        profile: %{},
        metadata: %{}
      },
      source: "bullx://gateway/feishu/default"
    }
  end
end
