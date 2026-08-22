defmodule Ankole.Plugins.SlackAdapterMentionRoutingTest do
  use Ankole.DataCase, async: true

  alias Ankole.Plugins.SlackAdapter.Inbound
  alias Ankole.SignalsGateway.AdapterContext
  alias SlackOpenAPI.Event

  test "group mention routing is fail-closed without a configured bot identity" do
    consumer = consumer(%{})

    assert {:ok, %{explicit: false, mentions: [%{"targets_current_agent" => false}]}} =
             normalize(consumer, "<@UBOT> hello")
  end

  test "another bot mention does not claim the message" do
    consumer = consumer(%{"runtimeBotUserID" => "UTHIS"})
    assert {:ok, %{explicit: false}} = normalize(consumer, "<@UOTHER> hello")
  end

  test "current bot mention claims the message and is stripped from visible text" do
    consumer = consumer(%{"runtimeBotUserID" => "UTHIS"})

    assert {:ok, %{explicit: true, text: "hello", mentions: [%{"agent_uid" => "agent-a"}]}} =
             normalize(consumer, "<@UTHIS> hello")
  end

  test "direct messages are explicit without mentions" do
    consumer = consumer(%{})
    event = event("hello") |> Map.update!(:content, &Map.put(&1, "channel_type", "im"))

    assert {:ok, %{explicit: true, text: "hello"}} =
             Inbound.normalize_message_receive(event, consumer)
  end

  defp normalize(consumer, text), do: Inbound.normalize_message_receive(event(text), consumer)

  defp consumer(overrides) do
    context =
      AdapterContext.new(
        agent_uid: "agent-a",
        binding_name: "slack-a",
        adapter: "slack",
        user_name: "Slack"
      )

    config =
      Map.merge(
        %{
          "botToken" => "xoxb-bot",
          "appToken" => "xapp-app",
          "platformSubjectNamespace" => "slack-main"
        },
        overrides
      )

    Inbound.chat_consumer(context, config)
  end

  defp event(text) do
    %Event{
      id: "Ev-#{System.unique_integer([:positive])}",
      type: "message",
      team_id: "T1",
      created_at: ~U[2026-07-11 00:00:00Z],
      raw: %{},
      content: %{
        "channel" => "C1",
        "channel_type" => "channel",
        "user" => "U1",
        "text" => text,
        "ts" => "1700000000.000100"
      }
    }
  end
end
