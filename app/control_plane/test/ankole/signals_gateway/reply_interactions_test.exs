defmodule Ankole.SignalsGateway.ReplyInteractionsTest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.ReplyPresentation

  @now ~U[2026-07-14 02:30:00.000000Z]

  test "accepts one authorized current choice, locks the controls, and suppresses repeat clicks" do
    %{agent: agent, human: human, event: source_event, action: action} = setup_interaction()

    assert {:ok, %{status: :accepted, actor_event: action_event}} =
             Ingress.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "action-event-1"),
               now: @now
             )

    assert action_event.type == "signal.action.invoked"

    assert get_in(action_event.payload, ["data", "action", "value", "optionValue"]) ==
             "Operators"

    checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint
    assert checkpoint["refresh_pending"]
    assert checkpoint["refresh_reason"] == "interaction"

    assert %{
             "selected_option_id" => "operators",
             "operator_principal_uid" => operator_uid
           } = checkpoint["interactions"]["clarify:call-1"]

    assert operator_uid == human.uid

    assert Enum.all?(checkpoint["presentation"]["actions"], & &1["disabled"])

    assert Enum.find(
             checkpoint["presentation"]["actions"],
             &(&1["selected_option_id"] == "operators")
           )["selected"]

    assert {:ok, %{status: :duplicate_action}} =
             Ingress.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "action-event-2"),
               now: DateTime.add(@now, 1, :second)
             )

    assert action_event_count(agent.uid) == 1
  end

  test "treats a changed, stale, or forged managed choice as a successful no-op" do
    %{agent: agent, human: human, action: action} = setup_interaction()

    stale_action =
      action
      |> Map.put("selectedOptionId", "forged")
      |> Map.put("optionValue", "Forged")

    assert {:ok, %{status: :stale_action}} =
             Ingress.emit_action(
               agent.uid,
               "mock",
               action_input(stale_action, human.uid, "stale-event"),
               now: @now
             )

    assert action_event_count(agent.uid) == 0
  end

  test "re-authorizes the acting principal instead of trusting a visible button" do
    %{agent: agent, human: human, action: action} = setup_interaction()

    human
    |> Principal.status_changeset(%{status: :disabled})
    |> Repo.update!()

    assert {:error, :reply_interaction_operator_unauthorized} =
             Ingress.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "disabled-human-event"),
               now: @now
             )

    assert action_event_count(agent.uid) == 0
  end

  test "accepts a managed callback from any card in the durable CardChain" do
    %{agent: agent, human: human, event: source_event, action: action} = setup_interaction()

    checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint

    checkpoint =
      Map.put(checkpoint, "cards", [
        %{"index" => 0, "message_id" => "card-message-1", "state" => "sealed"},
        %{"index" => 1, "message_id" => "card-message-2", "state" => "open"}
      ])

    assert {:ok, _updated} = Actors.put_reply_preview_checkpoint(source_event.id, checkpoint)

    assert {:ok, %{status: :accepted}} =
             Ingress.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "card-chain-action", "card-message-2"),
               now: @now
             )

    assert action_event_count(agent.uid) == 1
  end

  defp setup_interaction do
    %{principal: agent} = agent_fixture()
    %{principal: human} = human_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: event} =
      emit_addressed_actor_event(
        agent.uid,
        "mock",
        group_entry(%{
          source_event_id: unique_uid("interaction-source"),
          source_entry_id: unique_uid("trigger-message"),
          explicit: true
        })
      )

    action = %{
      "version" => "ankole.interactive_output.action.v1",
      "interactionId" => "clarify:call-1",
      "interactionVersion" => 1,
      "controlId" => "clarify-choice",
      "selectedOptionId" => "operators",
      "optionValue" => "Operators",
      "sourceActorEventId" => event.id
    }

    presentation =
      ReplyPresentation.new()
      |> ReplyPresentation.apply_event("interaction.request", %{
        "revision" => 1,
        "prompt" => "Who should this brief target?",
        "controls" => [
          %{
            "id" => "operators",
            "type" => "button",
            "label" => "Operators",
            "interaction_id" => "clarify:call-1",
            "source_actor_event_id" => event.id,
            "control_id" => "clarify-choice",
            "selected_option_id" => "operators",
            "option_value" => "Operators",
            "revision" => 1
          },
          %{
            "id" => "executives",
            "type" => "button",
            "label" => "Executives",
            "interaction_id" => "clarify:call-1",
            "source_actor_event_id" => event.id,
            "control_id" => "clarify-choice",
            "selected_option_id" => "executives",
            "option_value" => "Executives",
            "revision" => 1
          }
        ]
      })

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-1",
      "message_id" => "card-message-1",
      "streaming_state" => "closed",
      "element_ids" => ["state", "answer", "actions"],
      "presentation" => ReplyPresentation.checkpoint(presentation)
    }

    assert {:ok, _updated} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
    assert :ok = Actors.record_reply_preview_source_entry(event.id, "card-message-1")

    %{agent: agent, human: human, event: event, action: action}
  end

  defp action_input(
         action,
         operator_principal_uid,
         source_event_id,
         source_entry_id \\ "card-message-1"
       ) do
    %{
      source_event_id: source_event_id,
      action_id: source_event_id,
      signal_channel_id: "lark:chat:group-a",
      source_entry_id: source_entry_id,
      provider_thread_id: source_entry_id,
      action: %{
        "name" => "clarify-choice",
        "value" => action,
        "operator_principal_uid" => operator_principal_uid
      }
    }
  end

  defp action_event_count(agent_uid) do
    ActorEvent
    |> where([event], event.agent_uid == ^agent_uid)
    |> where([event], event.type == "signal.action.invoked")
    |> Repo.aggregate(:count)
  end
end
