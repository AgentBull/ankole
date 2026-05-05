defmodule BullXTelegram.StreamerTest do
  use ExUnit.Case, async: false

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Outcome
  alias BullXTelegram.{Config, Streamer}

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

      Agent.get_and_update(:persistent_term.get(@agent_key), fn count ->
        next = count + 1
        {{:ok, %{"message_id" => next}}, next}
      end)
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    ApiStub.put(self(), agent)
    on_exit(&ApiStub.clear/0)
    {:ok, config: config()}
  end

  test "streams by creating and editing Telegram messages", %{config: config} do
    delivery = delivery()

    assert {:ok, %Outcome{status: :sent, primary_external_id: "1", external_message_ids: ["1"]}} =
             Streamer.stream(delivery, ["hello", " world"], config)

    assert_receive {:request, "bot", "sendMessage", [chat_id: 123, text: "hello"]}

    assert_receive {:request, "bot", "editMessageText",
                    [chat_id: 123, message_id: 1, text: "hello world"]}
  end

  test "returns payload error when stream content is absent", %{config: config} do
    assert {:error, %{"kind" => "payload"}} = Streamer.stream(delivery(), [], config)
  end

  test "opens additional messages when stream content exceeds the soft chunk limit", %{
    config: config
  } do
    delivery = delivery()

    assert {:ok, %Outcome{external_message_ids: ["1", "2"]}} =
             Streamer.stream(delivery, ["abcdef"], %{config | stream_chunk_soft_limit: 3})

    assert_receive {:request, "bot", "sendMessage", [chat_id: 123, text: "abc"]}
    assert_receive {:request, "bot", "sendMessage", [chat_id: 123, text: "def"]}
  end

  test "final replace deletes stale messages when the stream shrinks", %{config: config} do
    delivery = delivery()

    assert {:ok, %Outcome{external_message_ids: ["1"], primary_external_id: "1"}} =
             Streamer.stream(
               delivery,
               ["abcdef", %{replace_text: "xy"}],
               %{config | stream_chunk_soft_limit: 3}
             )

    assert_receive {:request, "bot", "sendMessage", [chat_id: 123, text: "abc"]}
    assert_receive {:request, "bot", "sendMessage", [chat_id: 123, text: "def"]}
    assert_receive {:request, "bot", "editMessageText", [chat_id: 123, message_id: 2, text: "xy"]}
    assert_receive {:request, "bot", "editMessageText", [chat_id: 123, message_id: 1, text: "xy"]}
    assert_receive {:request, "bot", "deleteMessage", [chat_id: 123, message_id: 2]}
  end

  defp config do
    {:ok, config} =
      Config.normalize({:telegram, "default"}, %{
        bot_token: "bot",
        api_module: ApiStub,
        stream_update_interval_ms: 0
      })

    config
  end

  defp delivery do
    %GatewayDelivery{
      id: "delivery-1",
      op: :stream,
      channel: {:telegram, "default"},
      scope_id: "123",
      content: []
    }
  end
end
