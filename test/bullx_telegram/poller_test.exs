defmodule BullXTelegram.PollerTest do
  use ExUnit.Case, async: false

  alias BullXTelegram.{Config, Poller}

  defmodule ApiStub do
    @pid_key {__MODULE__, :pid}
    @agent_key {__MODULE__, :agent}

    def put(pid, agent) do
      :persistent_term.put(@pid_key, pid)
      :persistent_term.put(@agent_key, agent)
    end

    def clear do
      :persistent_term.erase(@pid_key)
      :persistent_term.erase(@agent_key)
    end

    def request(token, method, params) do
      send(:persistent_term.get(@pid_key), {:request, token, method, params})

      Agent.get_and_update(:persistent_term.get(@agent_key), fn
        [response | rest] -> {response, rest}
        [] -> {{:ok, []}, []}
      end)
    end
  end

  defmodule GatewayStub do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear, do: :persistent_term.erase(@pid_key)

    def publish_inbound(input) do
      send(:persistent_term.get(@pid_key), {:publish_inbound, input})
      {:ok, :published}
    end
  end

  defmodule AccountsStub do
    def match_or_create_from_channel(_input), do: {:ok, %{id: "user-1"}, %{id: "binding-1"}}
  end

  setup do
    previous_trap_exit = Process.flag(:trap_exit, true)
    GatewayStub.put_pid(self())
    {:ok, agent} = Agent.start_link(fn -> [] end)
    ApiStub.put(self(), agent)

    on_exit(fn ->
      Process.flag(:trap_exit, previous_trap_exit)
      ApiStub.clear()
      GatewayStub.clear()
      stop_channel()
    end)

    :ok
  end

  test "polling startup clears webhook before calling getUpdates and advances offset" do
    put_responses([
      {:ok, %{"ok" => true}},
      {:ok, %{"id" => 123, "username" => "BullXBot"}},
      {:ok, %{"ok" => true}},
      {:ok, [update(100)]},
      {:ok, []}
    ])

    {:ok, _channel} = start_channel()
    {:ok, poller} = Poller.start_link({{:telegram, "poll"}, config()})

    assert_receive {:request, "bot", "deleteWebhook", [drop_pending_updates: false]}
    assert_receive {:request, "bot", "getMe", []}
    assert_receive {:request, "bot", "setMyCommands", _params}
    assert_receive {:request, "bot", "getUpdates", params}
    refute Keyword.has_key?(params, :offset)
    assert_receive {:publish_inbound, _input}
    assert_receive {:request, "bot", "getUpdates", params}
    assert params[:offset] == 101

    GenServer.stop(poller)
  end

  test "polling conflict crashes after bounded retries" do
    put_responses([
      {:ok, %{"ok" => true}},
      {:ok, %{"id" => 123, "username" => "BullXBot"}},
      {:ok, %{"ok" => true}},
      {:error, "Conflict: terminated by other getUpdates request"}
    ])

    {:ok, _channel} = start_channel()
    {:ok, poller} = Poller.start_link({{:telegram, "poll"}, config(%{poll_retry_max: 0})})
    ref = Process.monitor(poller)

    assert_receive {:DOWN, ^ref, :process, ^poller,
                    {:telegram_polling_conflict, %{"kind" => "network"}}}

    assert_receive {:EXIT, ^poller, {:telegram_polling_conflict, %{"kind" => "network"}}}
  end

  test "polling rejects a second local process for the same bot token" do
    put_responses([
      {:ok, %{"ok" => true}},
      {:ok, %{"id" => 123, "username" => "BullXBot"}},
      {:ok, []}
    ])

    {:ok, poller} =
      Poller.start_link({{:telegram, "poll"}, config(%{commands: %{sync_policy: "off"}})})

    assert_receive {:request, "bot", "deleteWebhook", [drop_pending_updates: false]}
    assert_receive {:request, "bot", "getMe", []}

    assert {:error,
            {:telegram_polling_conflict,
             %{
               "kind" => "config",
               "details" => %{"field" => "bot_token", "channel_id" => "poll-duplicate"}
             }}} =
             Poller.start_link(
               {{:telegram, "poll-duplicate"}, config(%{commands: %{sync_policy: "off"}})}
             )

    GenServer.stop(poller)
  end

  defp start_channel do
    BullXTelegram.Channel.start_link({{:telegram, "poll"}, config(%{start_transport?: false})})
  end

  defp stop_channel do
    case GenServer.whereis(
           {:via, Registry,
            {BullXGateway.AdapterSupervisor.Registry,
             {BullXTelegram.Channel, {:telegram, "poll"}}}}
         ) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp put_responses(responses) do
    Agent.update(:persistent_term.get({ApiStub, :agent}), fn _ -> responses end)
  end

  defp config(attrs \\ %{}) do
    {:ok, config} =
      Config.normalize(
        {:telegram, "poll"},
        Map.merge(
          %{
            bot_token: "bot",
            bot_username: "BullXBot",
            api_module: ApiStub,
            gateway_module: GatewayStub,
            accounts_module: AccountsStub
          },
          attrs
        )
      )

    config
  end

  defp update(id) do
    %{
      "update_id" => id,
      "message" => %{
        "message_id" => 10,
        "date" => 1_777_777_777,
        "chat" => %{"id" => 200, "type" => "private"},
        "from" => %{"id" => 300, "first_name" => "Alice", "is_bot" => false},
        "text" => "hello"
      }
    }
  end
end
