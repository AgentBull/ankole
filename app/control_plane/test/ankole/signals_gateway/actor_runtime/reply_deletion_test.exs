defmodule Ankole.SignalsGateway.ActorRuntime.ReplyDeletionTest do
  @moduledoc false
  # Retraction asks the adapter that owns the checkpoint which provider entries
  # the preview surface holds, so a page ledger and a card chain both produce
  # deletion intents without the host reading provider keys.
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.ReplyDeletion
  alias Ankole.SignalsGateway.Actors

  test "dingtalk page card instances become deletion targets" do
    event = actor_event_on("dingtalk", "dingtalk:cidDel")

    {:ok, _event} =
      Actors.put_reply_preview_checkpoint(event.id, %{
        "streaming_state" => "closed",
        "pages" => [
          %{"index" => 0, "out_track_id" => "ankole:#{event.id}:0", "sealed" => true},
          %{"index" => 1, "out_track_id" => "ankole:#{event.id}:1", "sealed" => true}
        ]
      })

    targets =
      Repo
      |> ReplyDeletion.outbox_intents(event.id)
      |> Enum.map(&{&1.operation, &1.target_source_entry_id})

    assert targets == [
             {:delete, "ankole:#{event.id}:0"},
             {:delete, "ankole:#{event.id}:1"}
           ]
  end

  test "lark card ids are handles and only card messages become deletion targets" do
    event = actor_event_on("lark", "lark:chat:group-del")

    {:ok, _event} =
      Actors.put_reply_preview_checkpoint(event.id, %{
        "card_id" => "card-b",
        "message_id" => "om_b",
        "active_card_index" => 1,
        "streaming_state" => "closed",
        "cards" => [
          %{"index" => 0, "card_id" => "card-a", "message_id" => "om_a"},
          %{"index" => 1, "card_id" => "card-b", "message_id" => "om_b"}
        ]
      })

    targets =
      Repo
      |> ReplyDeletion.outbox_intents(event.id)
      |> Enum.map(& &1.target_source_entry_id)

    assert targets == ["om_a", "om_b"]
  end

  defp actor_event_on(adapter, channel) do
    %{principal: agent} = agent_fixture()
    binding_name = "#{adapter}-deletion"
    binding_fixture(agent.uid, binding_name, :ignore, adapter: adapter)

    %{actor_event: event} =
      emit_addressed_actor_event(
        agent.uid,
        binding_name,
        group_entry(%{
          source_event_id: unique_uid("#{adapter}-deletion-event"),
          source_entry_id: unique_uid("#{adapter}-deletion-trigger"),
          signal_channel_id: channel,
          explicit: true
        })
      )

    event
  end
end
