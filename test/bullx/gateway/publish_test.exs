defmodule BullX.Gateway.PublishTest.Router do
  @behaviour BullX.Gateway.Router

  @impl true
  def resolve(_signal) do
    {:ok,
     [
       %{
         "route_id" => "route.default",
         "consumer_key" => "test:default",
         "queue" => "gateway_signals",
         "consumer" => %{"type" => "test", "id" => "default"}
       }
     ]}
  end
end

defmodule BullX.Gateway.PublishTest do
  use BullX.DataCase, async: false

  import Ecto.Query

  alias BullX.Gateway.{InboundError, SignalDeliveryWorker, SourceConfig}
  alias BullX.Repo

  setup do
    previous = Application.get_env(:bullx, :gateway)

    Application.put_env(
      :bullx,
      :gateway,
      Keyword.put(previous, :router, BullX.Gateway.PublishTest.Router)
    )

    on_exit(fn -> Application.put_env(:bullx, :gateway, previous) end)

    :ok
  end

  test "publish validates inbound input, resolves router intents, and enqueues Mailbox jobs" do
    source = source()

    assert {:ok, :accepted, signal, [{:enqueued, %Oban.Job{} = job}]} =
             BullX.Gateway.publish(source, inbound_input())

    assert signal.type == "com.agentbull.x.inbound.received"
    assert signal.extensions["bullxoccurkey"] == "feishu:event_1"
    assert job.args["signal"]["id"] == signal.id
    assert job.args["signal_occurrence_key"] == "feishu:event_1"

    count =
      Oban.Job
      |> where([job], job.worker == ^inspect(SignalDeliveryWorker))
      |> Repo.aggregate(:count)

    assert count == 1
  end

  test "publish rejects duplex input without reply_channel before routing" do
    input = Map.delete(inbound_input(), "reply_channel")

    assert {:error, %InboundError{class: :malformed}} = BullX.Gateway.publish(source(), input)

    count =
      Oban.Job
      |> where([job], job.worker == ^inspect(SignalDeliveryWorker))
      |> Repo.aggregate(:count)

    assert count == 0
  end

  defp source do
    %SourceConfig{
      adapter: "feishu",
      channel_id: "main",
      enabled?: true,
      config: %{},
      outbound_retry: %{},
      adapter_module: nil
    }
  end

  defp inbound_input do
    %{
      "adapter" => "feishu",
      "channel_id" => "main",
      "occurrence_key" => "feishu:event_1",
      "content" => [
        %{"kind" => "text", "body" => %{"text" => "hello"}}
      ],
      "event" => %{
        "type" => "message",
        "name" => "feishu.message.posted",
        "version" => 1,
        "data" => %{}
      },
      "actor" => %{"id" => "ou_alice", "display" => "Alice", "bot" => false},
      "scope_id" => "chat_1",
      "thread_id" => nil,
      "refs" => [],
      "reply_channel" => %{
        "adapter" => "feishu",
        "channel_id" => "main",
        "scope_id" => "chat_1",
        "thread_id" => nil,
        "reply_to_external_id" => "message_1"
      },
      "provenance" => %{"provider_event_id" => "event_1"}
    }
  end
end
