defmodule BullXDiscord.DeliveryTest do
  use ExUnit.Case, async: false

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXGateway.Delivery.Content
  alias BullXGateway.Delivery.Outcome
  alias BullXDiscord.{Config, Delivery}

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
      send(:persistent_term.get(@pid_key), {:create, channel_id, options})
      next_response()
    end

    def edit(channel_id, message_id, options) do
      send(:persistent_term.get(@pid_key), {:edit, channel_id, message_id, options})
      {:ok, %{id: message_id}}
    end

    def delete(channel_id, message_id) do
      send(:persistent_term.get(@pid_key), {:delete, channel_id, message_id})
      :ok
    end

    defp next_response do
      Agent.get_and_update(:persistent_term.get(@agent_key), fn
        %{responses: [response | rest], count: count} = state ->
          {response, %{state | responses: rest, count: count + 1}}

        %{responses: [], count: count} = state ->
          id = "message-#{count + 1}"
          {{:ok, %{id: id}}, %{state | count: count + 1}}
      end)
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> %{responses: [], count: 0} end)
    MessageAPI.put(self(), agent)
    on_exit(&MessageAPI.clear/0)

    {:ok, config: config()}
  end

  test "sends text messages with safe allowed mentions and reply references", %{config: config} do
    delivery = delivery(%{reply_to_external_id: "999"})

    assert {:ok, %Outcome{status: :sent, primary_external_id: "message-1", warnings: []}} =
             Delivery.deliver(delivery, config)

    assert_receive {:create, 123,
                    %{
                      content: "hello",
                      allowed_mentions: %{"parse" => ["users"], "replied_user" => true},
                      message_reference: %{message_id: 999, fail_if_not_exists: false}
                    }}
  end

  test "sends fallback text for media content", %{config: config} do
    delivery =
      delivery(%{
        content: %Content{kind: :image, body: %{"fallback_text" => "[image]"}}
      })

    assert {:ok,
            %Outcome{
              status: :sent,
              primary_external_id: "message-1",
              warnings: ["image_degraded_to_fallback_text"]
            }} = Delivery.deliver(delivery, config)

    assert_receive {:create, 123, %{content: "[image]"}}
  end

  test "degrades missing reply targets to a normal scope send", %{config: config} do
    put_responses([
      {:error,
       %Nostrum.Error.ApiError{
         status_code: 404,
         response: %{code: 10_008, message: "Unknown Message"}
       }},
      {:ok, %{id: "fallback-message"}}
    ])

    delivery = delivery(%{reply_to_external_id: "404"})

    assert {:ok,
            %Outcome{
              status: :degraded,
              primary_external_id: "fallback-message",
              warnings: ["reply_target_missing_sent_to_scope"]
            }} = Delivery.deliver(delivery, config)

    assert_receive {:create, 123, %{message_reference: %{message_id: 404}}}
    assert_receive {:create, 123, fallback_options}
    refute Map.has_key?(fallback_options, :message_reference)
  end

  test "edits a single Discord message and rejects multi-message edits", %{config: config} do
    edit =
      delivery(%{
        op: :edit,
        target_external_id: "message-1",
        content: %Content{kind: :text, body: %{"text" => "updated"}}
      })

    assert {:ok, %Outcome{status: :sent, primary_external_id: "message-1"}} =
             Delivery.deliver(edit, config)

    assert_receive {:edit, 123, "message-1", %{content: "updated"}}

    too_long =
      delivery(%{
        op: :edit,
        target_external_id: "message-1",
        content: %Content{kind: :text, body: %{"text" => String.duplicate("x", 2_001)}}
      })

    assert {:error, %{"kind" => "payload"}} = Delivery.deliver(too_long, config)
  end

  defp put_responses(responses) do
    Agent.update(:persistent_term.get({MessageAPI, :agent}), &%{&1 | responses: responses})
  end

  defp config do
    {:ok, config} =
      Config.normalize({:discord, "default"}, %{
        application_id: "app",
        bot_token: "bot",
        client_secret: "secret",
        message_api: MessageAPI
      })

    config
  end

  defp delivery(attrs) do
    Map.merge(
      %GatewayDelivery{
        id: "delivery-1",
        op: :send,
        channel: {:discord, "default"},
        scope_id: "123",
        content: %Content{kind: :text, body: %{"text" => "hello"}}
      },
      attrs
    )
  end
end
