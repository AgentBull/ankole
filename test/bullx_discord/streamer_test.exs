defmodule BullXDiscord.StreamerTest do
  use ExUnit.Case, async: false

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Outcome
  alias BullXDiscord.{Config, Streamer}

  defmodule MessageAPI do
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

    def create(channel_id, options) do
      id =
        Agent.get_and_update(:persistent_term.get(@agent_key), fn count ->
          id = "message-#{count + 1}"
          {id, count + 1}
        end)

      send(:persistent_term.get(@pid_key), {:create, channel_id, options, id})
      {:ok, %{id: id}}
    end

    def edit(channel_id, message_id, options) do
      send(:persistent_term.get(@pid_key), {:edit, channel_id, message_id, options})
      {:ok, %{id: message_id}}
    end

    def delete(channel_id, message_id) do
      send(:persistent_term.get(@pid_key), {:delete, channel_id, message_id})
      :ok
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    MessageAPI.put(self(), agent)
    on_exit(&MessageAPI.clear/0)

    {:ok, config: config()}
  end

  test "streams by creating additional Discord messages at the soft chunk limit", %{
    config: config
  } do
    delivery = delivery()

    assert {:ok,
            %Outcome{
              status: :sent,
              external_message_ids: ["message-1", "message-2"],
              primary_external_id: "message-1"
            }} = Streamer.stream(delivery, ["hello", "world"], config)

    assert_receive {:create, 123, %{content: "hello"}, "message-1"}
    assert_receive {:edit, 123, "message-1", %{content: "hello"}}
    assert_receive {:create, 123, %{content: "world"}, "message-2"}
    assert_receive {:edit, 123, "message-1", %{content: "hello"}}
    assert_receive {:edit, 123, "message-2", %{content: "world"}}
  end

  test "does not edit the active message before the throttle interval" do
    config = config(%{stream_chunk_soft_limit: 100, stream_update_interval_ms: 60_000})

    assert {:ok, %Outcome{external_message_ids: ["message-1"]}} =
             Streamer.stream(delivery(), ["he", "llo"], config)

    assert_receive {:create, 123, %{content: "he"}, "message-1"}
    assert_receive {:edit, 123, "message-1", %{content: "hello"}}
    refute_receive {:edit, 123, "message-1", %{content: "hello"}}
  end

  test "edits the active message when the throttle interval permits it" do
    config = config(%{stream_chunk_soft_limit: 100, stream_update_interval_ms: 0})

    assert {:ok, %Outcome{external_message_ids: ["message-1"]}} =
             Streamer.stream(delivery(), ["he", "llo"], config)

    assert_receive {:create, 123, %{content: "he"}, "message-1"}
    assert_receive {:edit, 123, "message-1", %{content: "hello"}}
    assert_receive {:edit, 123, "message-1", %{content: "hello"}}
  end

  test "final replacement removes extra stream messages when the final text shrinks", %{
    config: config
  } do
    delivery = delivery()

    assert {:ok, %Outcome{external_message_ids: ["message-1"]}} =
             Streamer.stream(
               delivery,
               [
                 "hello",
                 "world",
                 %{"replace_text" => "done"}
               ],
               config
             )

    assert_receive {:delete, 123, "message-2"}
  end

  test "missing replayable stream content returns a payload error", %{config: config} do
    assert {:error, %{"kind" => "payload"}} = Streamer.stream(delivery(), nil, config)
  end

  defp config(attrs \\ %{}) do
    {:ok, config} =
      Config.normalize(
        {:discord, "default"},
        Map.merge(
          %{
            application_id: "app",
            bot_token: "bot",
            client_secret: "secret",
            message_api: MessageAPI,
            stream_chunk_soft_limit: 5,
            stream_update_interval_ms: 60_000
          },
          attrs
        )
      )

    config
  end

  defp delivery do
    %GatewayDelivery{
      id: "stream-1",
      op: :stream,
      channel: {:discord, "default"},
      scope_id: "123"
    }
  end
end
