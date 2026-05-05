defmodule BullXTelegram.ChannelTest do
  use ExUnit.Case, async: false

  alias BullXTelegram.{Channel, Config}

  defmodule GatewayStub do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear, do: :persistent_term.erase(@pid_key)

    def deliver(delivery) do
      send(:persistent_term.get(@pid_key), {:delivery, delivery})
      {:ok, delivery.id}
    end

    def publish_inbound(input) do
      send(:persistent_term.get(@pid_key), {:publish_inbound, input})
      {:ok, :published}
    end
  end

  defmodule AccountsActivationRequired do
    def match_or_create_from_channel(_input), do: {:error, :activation_required}
  end

  defmodule AccountsBanned do
    def match_or_create_from_channel(_input), do: {:error, :user_banned}
  end

  setup do
    GatewayStub.put_pid(self())

    on_exit(fn ->
      GatewayStub.clear()
      stop_channel("gate")
    end)

    :ok
  end

  test "account gate replies with activation prompt and does not publish" do
    {:ok, _pid} = start_channel(AccountsActivationRequired)

    assert {:ok, %{delivery_id: _id}} =
             Channel.handle_update({:telegram, "gate"}, update("private"))

    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "/preauth"
    refute_receive {:publish_inbound, _input}
  end

  test "account gate uses DM guidance for unbound group actors" do
    {:ok, _pid} = start_channel(AccountsActivationRequired)

    assert {:ok, %{delivery_id: _id}} =
             Channel.handle_update(
               {:telegram, "gate"},
               update("group", %{"text" => "@BullXBot hello"})
             )

    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "privately"
    refute_receive {:publish_inbound, _input}
  end

  test "banned actors receive denial and do not publish" do
    {:ok, _pid} = start_channel(AccountsBanned)

    assert {:ok, %{delivery_id: _id}} =
             Channel.handle_update({:telegram, "gate"}, update("private"))

    assert_receive {:delivery, delivery}
    assert delivery.content.body["text"] =~ "not allowed"
    refute_receive {:publish_inbound, _input}
  end

  defp start_channel(accounts_module) do
    Channel.start_link({{:telegram, "gate"}, config(accounts_module)})
  end

  defp stop_channel(channel_id) do
    case GenServer.whereis(
           {:via, Registry,
            {BullXGateway.AdapterSupervisor.Registry,
             {BullXTelegram.Channel, {:telegram, channel_id}}}}
         ) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp config(accounts_module) do
    {:ok, config} =
      Config.normalize({:telegram, "gate"}, %{
        bot_token: "bot",
        bot_username: "BullXBot",
        gateway_module: GatewayStub,
        accounts_module: accounts_module,
        start_transport?: false
      })

    config
  end

  defp update(chat_type, attrs \\ %{}) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" =>
        Map.merge(
          %{
            "message_id" => 10,
            "date" => 1_777_777_777,
            "chat" => %{"id" => 200, "type" => chat_type},
            "from" => %{"id" => 300, "first_name" => "Alice", "is_bot" => false},
            "text" => "hello"
          },
          attrs
        )
    }
  end
end
