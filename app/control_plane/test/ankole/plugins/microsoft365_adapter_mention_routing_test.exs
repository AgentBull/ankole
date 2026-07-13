defmodule Ankole.Plugins.Microsoft365AdapterMentionRoutingTest do
  use Ankole.DataCase, async: false

  alias Ankole.Plugins.Microsoft365Adapter.Inbound
  alias Ankole.SignalsGateway.AdapterContext

  test "current bot mention claims the message and is stripped from visible text" do
    assert {:ok, %{explicit: true, text: "hello", mentions: [%{"agent_uid" => "agent-a"}]}} =
             normalize(
               "<at>Ankole</at> hello",
               [mention("<at>Ankole</at>", "28:this-bot", "Ankole")]
             )
  end

  test "another participant mention does not claim the message" do
    assert {:ok, %{explicit: false, text: "@Ada hello", mentions: [mention]}} =
             normalize("<at>Ada</at> hello", [mention("<at>Ada</at>", "29:ada", "Ada")])

    assert mention["targets_current_agent"] == false
  end

  test "mention routing is fail-closed when the activity lacks a recipient" do
    activity =
      "channel"
      |> activity("<at>Ankole</at> hello", [mention("<at>Ankole</at>", "28:this-bot", "Ankole")])
      |> Map.delete("recipient")

    assert {:ok, %{explicit: false, mentions: [%{"targets_current_agent" => false}]}} =
             Inbound.normalize_message_receive(activity, consumer())
  end

  test "personal chats are explicit without mentions" do
    assert {:ok, %{explicit: true, text: "hello"}} =
             Inbound.normalize_message_receive(activity("personal", "hello", []), consumer())
  end

  defp normalize(text, entities),
    do: Inbound.normalize_message_receive(activity("channel", text, entities), consumer())

  defp mention(key, id, name),
    do: %{"type" => "mention", "text" => key, "mentioned" => %{"id" => id, "name" => name}}

  defp consumer do
    context =
      AdapterContext.new(
        agent_uid: "agent-a",
        binding_name: "teams-a",
        adapter: "teams",
        user_name: "Teams"
      )

    Inbound.chat_consumer(context, %{
      "appID" => "11111111-2222-3333-4444-555555555555",
      "platformSubjectNamespace" => "entra-id-main"
    })
  end

  defp activity(conversation_type, text, entities) do
    conversation_id =
      case conversation_type do
        "personal" -> "a:1personal"
        _group -> "19:room@thread.tacv2;messageid=1690000000001"
      end

    %{
      "type" => "message",
      "id" => "activity-#{System.unique_integer([:positive])}",
      "timestamp" => "2026-07-13T10:00:00.000Z",
      "serviceUrl" => "https://smba.trafficmanager.net/teams/",
      "from" => %{"id" => "29:user", "aadObjectId" => "oid-user", "name" => "User"},
      "recipient" => %{"id" => "28:this-bot", "name" => "Ankole"},
      "conversation" => %{"id" => conversation_id, "conversationType" => conversation_type},
      "text" => text,
      "entities" => entities
    }
  end
end
