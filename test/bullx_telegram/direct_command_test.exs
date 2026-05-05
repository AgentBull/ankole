defmodule BullXTelegram.DirectCommandTest do
  use ExUnit.Case, async: false

  alias BullXTelegram.{Cache, Config, DirectCommand}

  defmodule GatewayStub do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear, do: :persistent_term.erase(@pid_key)

    def deliver(delivery) do
      send(:persistent_term.get(@pid_key), {:delivery, delivery})
      {:ok, delivery.id}
    end
  end

  defmodule AccountsStub do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear, do: :persistent_term.erase(@pid_key)

    def consume_activation_code(code, input) do
      send(:persistent_term.get(@pid_key), {:consume_activation_code, code, input})
      {:ok, %{id: "user-1"}, %{id: "binding-1"}}
    end

    def issue_user_channel_auth_code(adapter, channel_id, external_id) do
      send(
        :persistent_term.get(@pid_key),
        {:issue_web_auth_code, adapter, channel_id, external_id}
      )

      {:ok, "WEB123"}
    end
  end

  defmodule EndpointStub do
    def url, do: "https://bullx.test"
  end

  setup do
    GatewayStub.put_pid(self())
    AccountsStub.put_pid(self())

    on_exit(fn ->
      GatewayStub.clear()
      AccountsStub.clear()
    end)

    {:ok, config: config(), cache: Cache.new()}
  end

  test "preauth consumes an existing activation code in private chats", %{
    config: config,
    cache: cache
  } do
    command = command(%{name: "preauth", args: "ACT123"})

    assert {:ok, %{command_name: "preauth"}, _cache} =
             DirectCommand.handle(command, config, cache)

    assert_receive {:consume_activation_code, "ACT123", %{external_id: "telegram:user-1"}}
    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "Activation complete"
  end

  test "preauth in groups tells the user to DM and does not consume a code", %{
    config: config,
    cache: cache
  } do
    command = command(%{name: "preauth", args: "ACT123", chat_type: "group"})

    assert {:ok, %{command_name: "preauth"}, _cache} =
             DirectCommand.handle(command, config, cache)

    refute_receive {:consume_activation_code, _, _}
    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "message the bot privately"
  end

  test "web_auth issues a web login code for an already-bound Telegram actor", %{
    config: config,
    cache: cache
  } do
    command = command(%{name: "web_auth"})

    assert {:ok, %{command_name: "web_auth"}, _cache} =
             DirectCommand.handle(command, config, cache)

    assert_receive {:issue_web_auth_code, :telegram, "default", "telegram:user-1"}
    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "WEB123"
    assert delivery.content.body["text"] =~ "https://bullx.test/sessions/new"
  end

  test "commands qualified for another bot are ignored" do
    assert :error = DirectCommand.parse("/ask@OtherBot hi", config())

    {:ok, config_without_username} =
      Config.normalize({:telegram, "default"}, %{
        bot_token: "bot",
        gateway_module: GatewayStub,
        accounts_module: AccountsStub,
        endpoint: EndpointStub
      })

    assert :error = DirectCommand.parse("/ask@OtherBot hi", config_without_username)
  end

  defp config do
    {:ok, config} =
      Config.normalize({:telegram, "default"}, %{
        bot_token: "bot",
        gateway_module: GatewayStub,
        accounts_module: AccountsStub,
        endpoint: EndpointStub
      })

    config
  end

  defp command(attrs) do
    Map.merge(
      %{
        name: "ping",
        args: "",
        event_id: "event-1",
        channel: {:telegram, "default"},
        channel_id: "default",
        chat_id: "chat-1",
        chat_type: "private",
        thread_id: nil,
        message_id: "message-1",
        actor: %{id: "telegram:user-1", user_id: "user-1", display: "Alice"},
        account_input: %{
          adapter: :telegram,
          channel_id: "default",
          external_id: "telegram:user-1"
        },
        source: "bullx://gateway/telegram/default"
      },
      attrs
    )
  end
end
