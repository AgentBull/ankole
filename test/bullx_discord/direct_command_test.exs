defmodule BullXDiscord.DirectCommandTest do
  use ExUnit.Case, async: false

  alias BullXDiscord.{Cache, Config, DirectCommand}

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

  test "preauth consumes an existing activation code in DMs", %{config: config, cache: cache} do
    command = command(%{name: "preauth", args: "ACT123", dm?: true})

    assert {:ok, %{command_name: "preauth"}, _cache} =
             DirectCommand.handle(command, config, cache)

    assert_receive {:consume_activation_code, "ACT123", %{external_id: "discord:user-1"}}
    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "Activation complete"
  end

  test "preauth in guilds tells the user to DM the bot and does not consume a code", %{
    config: config,
    cache: cache
  } do
    command = command(%{name: "preauth", args: "ACT123", dm?: false})

    assert {:ok, %{command_name: "preauth"}, _cache} =
             DirectCommand.handle(command, config, cache)

    refute_receive {:consume_activation_code, _, _}
    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "DM the bot"
  end

  test "web_auth issues a web login code for an already-bound Discord actor", %{
    config: config,
    cache: cache
  } do
    command = command(%{name: "web_auth", dm?: true})

    assert {:ok, %{command_name: "web_auth"}, _cache} =
             DirectCommand.handle(command, config, cache)

    assert_receive {:issue_web_auth_code, :discord, "default", "discord:user-1"}
    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "WEB123"
    assert delivery.content.body["text"] =~ "https://bullx.test/sessions/new"
  end

  test "direct command results are deduped inside the adapter cache", %{
    config: config,
    cache: cache
  } do
    command = command(%{name: "ping"})

    assert {:ok, _result, cache} = DirectCommand.handle(command, config, cache)
    assert {:ok, {:duplicate, _result}, _cache} = DirectCommand.handle(command, config, cache)

    assert_receive {:delivery, _delivery}
    refute_receive {:delivery, _delivery}
  end

  defp config do
    {:ok, config} =
      Config.normalize({:discord, "default"}, %{
        application_id: "app",
        bot_token: "bot",
        client_secret: "secret",
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
        channel: {:discord, "default"},
        channel_id: "default",
        discord_channel_id: "dm-1",
        guild_id: nil,
        message_id: "message-1",
        actor: %{id: "discord:user-1", user_id: "user-1", display: "Alice"},
        account_input: %{adapter: :discord, channel_id: "default", external_id: "discord:user-1"},
        source: "bullx://gateway/discord/default",
        transport: :message,
        dm?: true
      },
      attrs
    )
  end
end
