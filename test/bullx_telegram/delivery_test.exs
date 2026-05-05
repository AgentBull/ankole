defmodule BullXTelegram.DeliveryTest do
  use ExUnit.Case, async: false

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Content
  alias BullXGateway.Delivery.Outcome
  alias BullXTelegram.{Config, Delivery}

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
      next_response(method)
    end

    defp next_response(method) do
      Agent.get_and_update(:persistent_term.get(@agent_key), fn
        %{responses: [response | rest], count: count} = state ->
          {response, %{state | responses: rest, count: count + 1}}

        %{responses: [], count: count} = state ->
          id = count + 1
          {{:ok, %{"message_id" => id, "method" => method}}, %{state | count: id}}
      end)
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> %{responses: [], count: 0} end)
    ApiStub.put(self(), agent)
    on_exit(&ApiStub.clear/0)

    {:ok, config: config()}
  end

  test "sends text messages with reply parameters and thread IDs", %{config: config} do
    delivery = delivery(%{reply_to_external_id: "9", thread_id: "77"})

    assert {:ok, %Outcome{status: :sent, primary_external_id: "1", warnings: []}} =
             Delivery.deliver(delivery, config)

    assert_receive {:request, "bot", "sendMessage", params}
    assert params[:chat_id] == 123
    assert params[:text] == "hello"
    assert params[:message_thread_id] == 77
    assert params[:reply_parameters] == {:json, %{message_id: 9}}
  end

  test "sends fallback text for media content", %{config: config} do
    delivery =
      delivery(%{
        content: %Content{kind: :image, body: %{"fallback_text" => "[image]"}}
      })

    assert {:ok,
            %Outcome{
              status: :sent,
              primary_external_id: "1",
              warnings: ["image_degraded_to_fallback_text"]
            }} = Delivery.deliver(delivery, config)

    assert_receive {:request, "bot", "sendMessage", [chat_id: 123, text: "[image]"]}
  end

  test "edits a Telegram message and treats not-modified as success", %{config: config} do
    put_responses([{:error, "Bad Request: message is not modified"}])

    edit =
      delivery(%{
        op: :edit,
        target_external_id: "5",
        content: %Content{kind: :text, body: %{"text" => "updated"}}
      })

    assert {:ok, %Outcome{status: :sent, primary_external_id: "5"}} =
             Delivery.deliver(edit, config)
  end

  test "rejects oversized standalone edits", %{config: config} do
    edit =
      delivery(%{
        op: :edit,
        target_external_id: "5",
        content: %Content{kind: :text, body: %{"text" => String.duplicate("a", 4097)}}
      })

    assert {:error, %{"kind" => "payload"}} = Delivery.deliver(edit, config)
  end

  test "splits edits across a known stream message set and deletes stale messages", %{
    config: config
  } do
    edit =
      delivery(%{
        op: :edit,
        target_external_id: "1",
        content: %Content{kind: :text, body: %{"text" => String.duplicate("a", 4097)}},
        extensions: %{"telegram" => %{"stream_message_ids" => ["1", "2", "3"]}}
      })

    assert {:ok, %Outcome{status: :sent, external_message_ids: ["1", "2"]}} =
             Delivery.deliver(edit, config)

    assert_receive {:request, "bot", "editMessageText",
                    [chat_id: 123, message_id: 1, text: first]}

    assert String.length(first) == 4096
    assert_receive {:request, "bot", "editMessageText", [chat_id: 123, message_id: 2, text: "a"]}
    assert_receive {:request, "bot", "deleteMessage", [chat_id: 123, message_id: 3]}
  end

  test "splits text by UTF-16 code units" do
    assert ["😀😀", "😀"] = Delivery.split_message("😀😀😀", 4)
  end

  defp put_responses(responses) do
    Agent.update(:persistent_term.get({ApiStub, :agent}), &%{&1 | responses: responses})
  end

  defp config do
    {:ok, config} =
      Config.normalize({:telegram, "default"}, %{
        bot_token: "bot",
        api_module: ApiStub
      })

    config
  end

  defp delivery(attrs) do
    Map.merge(
      %GatewayDelivery{
        id: "delivery-1",
        op: :send,
        channel: {:telegram, "default"},
        scope_id: "123",
        content: %Content{kind: :text, body: %{"text" => "hello"}}
      },
      attrs
    )
  end
end
