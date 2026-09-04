defmodule Ankole.SignalsGateway.ReplyInteractionsTest do
  use Ankole.DataCase, async: true

  import Ecto.Query
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorRuntime.TurnRuntimeEnv
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SignalsGateway.ReplyInteractionState
  alias Ankole.SignalsGateway.ReplyPresentation

  @now ~U[2026-07-14 02:30:00.000000Z]

  test "treats checkpoints from before the interaction state contract as stale" do
    interaction_id = "clarify:legacy"

    legacy_pending = %{
      "presentation" => %{
        "state" => "awaiting_input",
        "interaction_status" => "pending",
        "actions" => [%{"interaction_id" => interaction_id}]
      }
    }

    legacy_answered =
      Map.put(legacy_pending, "interactions", %{
        interaction_id => %{
          "interaction_id" => interaction_id,
          "selected_option_id" => "operators",
          "option_value" => "Operators"
        }
      })

    assert ReplyInteractionState.interaction(legacy_pending, interaction_id) == nil
    assert ReplyInteractionState.pending_interaction_ids(legacy_pending) == []
    assert ReplyInteractionState.interaction(legacy_answered, interaction_id) == nil
  end

  test "a Slack message checkpoint schedules the same durable interaction refresh" do
    presentation =
      ReplyPresentation.new(state: "awaiting_input")
      |> ReplyPresentation.apply_event("interaction.request", %{
        "revision" => 1,
        "prompt" => "Choose one",
        "controls" => [
          %{
            "type" => "button",
            "id" => "approve",
            "label" => "Approve",
            "interaction_id" => "slack-interaction",
            "source_actor_event_id" => Ecto.UUID.generate(),
            "control_id" => "decision",
            "selected_option_id" => "approve",
            "option_value" => "yes",
            "revision" => 1
          }
        ]
      })

    checkpoint =
      ReplyInteractionState.initialize(%{"message_id" => "1700000000.000001"}, presentation, @now)

    assert {:ok, transition} =
             ReplyInteractionState.resolve(checkpoint, "slack-interaction", %{
               "state" => "answered",
               "answer" => %{"kind" => "choice", "option_id" => "approve", "value" => "yes"}
             })

    resolved = ReplyInteractionState.merge_checkpoint(checkpoint, transition, fn _ -> true end)

    assert resolved["refresh_pending"] == true
    assert resolved["refresh_reason"] == "interaction"
    assert resolved["presentation"]["interaction_status"] == "answered"
  end

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
    assert action_event.sender_key == human.uid

    assert TurnRuntimeEnv.resolve(action_event) == %{
             "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL" => human.uid
           }

    assert get_in(action_event.payload, ["data", "action", "value"]) == %{
             "interaction_id" => "clarify:call-1",
             "source_actor_event_id" => source_event.id,
             "answer" => %{
               "kind" => "choice",
               "option_id" => "operators",
               "value" => "Operators"
             }
           }

    checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint
    assert checkpoint["refresh_pending"]
    assert checkpoint["refresh_reason"] == "interaction"

    assert %{
             "state" => "answered",
             "answer" => %{"kind" => "choice", "option_id" => "operators"},
             "operator_principal_uid" => operator_uid
           } = checkpoint["interactions"]["clarify:call-1"]

    assert operator_uid == human.uid
    assert checkpoint["presentation"]["interaction_status"] == "answered"

    assert checkpoint["presentation"]["interaction_answer"] == "Operators"

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

  test "accepts one free-text form answer through the same durable resolver" do
    %{agent: agent, human: human, event: source_event} = setup_interaction()

    action = %{
      "version" => "ankole.interactive_output.action.v1",
      "answerKind" => "free_text",
      "interactionId" => "clarify:call-1",
      "interactionVersion" => 1,
      "controlId" => "clarify-free-input",
      "inputName" => "clarify-answer",
      "formValue" => %{"clarify-answer" => "  Use the latest paragraph above.  "},
      "sourceActorEventId" => source_event.id
    }

    assert {:ok, %{status: :accepted, actor_event: action_event}} =
             Ingress.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "form-action-event"),
               now: @now
             )

    assert get_in(action_event.payload, ["data", "action", "value", "answer"]) == %{
             "kind" => "free_text",
             "value" => "Use the latest paragraph above."
           }

    checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint
    assert checkpoint["interactions"]["clarify:call-1"]["state"] == "answered"
    assert checkpoint["presentation"]["interaction_status"] == "answered"

    assert checkpoint["presentation"]["interaction_answer"] ==
             "Use the latest paragraph above."

    assert Enum.all?(checkpoint["presentation"]["actions"], & &1["disabled"])
  end

  test "a newer conversation event supersedes the card and later callbacks are stale" do
    %{agent: agent, human: human, event: source_event, action: action} = setup_interaction()

    assert {:ok, newer_event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: source_event.agent_uid,
               binding_name: source_event.binding_name,
               session_id: source_event.session_id,
               source_event_id: unique_uid("newer-turn"),
               signal_channel_id: source_event.signal_channel_id,
               provider_thread_id: source_event.provider_thread_id,
               source_entry_id: unique_uid("newer-entry"),
               type: "im.message.addressed",
               available_at: DateTime.add(@now, 1, :second),
               payload: %{"type" => "im.message.addressed", "data" => %{"entry" => %{}}}
             })

    assert newer_event.queue_sequence > source_event.queue_sequence

    checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint
    interaction = checkpoint["interactions"]["clarify:call-1"]
    assert interaction["state"] == "superseded"
    assert interaction["superseded_by_actor_event_id"] == newer_event.id
    assert checkpoint["presentation"]["interaction_status"] == "superseded"
    refute Map.has_key?(checkpoint["presentation"], "interaction_answer")
    assert checkpoint["refresh_pending"]
    assert Enum.all?(checkpoint["presentation"]["actions"], & &1["disabled"])

    assert {:ok, %{status: :stale_action}} =
             Ingress.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "late-action-event"),
               now: DateTime.add(@now, 2, :second)
             )

    assert action_event_count(agent.uid) == 0
  end

  test "a delayed CardKit checkpoint write cannot reopen a superseded interaction" do
    %{event: source_event} = setup_interaction()

    assert {:ok, _newer_event} =
             Repo.transact(fn repo ->
               SignalsGateway.append_actor_event_in_tx(repo, %{
                 agent_uid: source_event.agent_uid,
                 binding_name: source_event.binding_name,
                 session_id: source_event.session_id,
                 source_event_id: unique_uid("checkpoint-race"),
                 type: "im.message.addressed",
                 available_at: @now,
                 payload: %{"type" => "im.message.addressed", "data" => %{"entry" => %{}}}
               })
             end)

    resolved = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint

    stale =
      resolved
      |> Map.put("presentation", resolved["previous_presentation"])
      |> Map.delete("interactions")
      |> Map.delete("refresh_pending")
      |> Map.delete("refresh_reason")

    assert {:ok, _event} = Actors.put_reply_preview_checkpoint(source_event.id, stale)

    checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint
    assert checkpoint["interactions"]["clarify:call-1"]["state"] == "superseded"
    assert checkpoint["presentation"]["interaction_status"] == "superseded"
    assert checkpoint["refresh_pending"]
  end

  test "outbox delivery projects the latest interaction state before calling an adapter" do
    %{agent: agent, event: source_event} = setup_interaction()

    pending =
      source_event |> Repo.reload!() |> then(& &1.reply_preview_checkpoint["presentation"])

    assert {:ok, _outbox} =
             SignalsGateway.commit_outbox(%{
               agent_uid: agent.uid,
               binding_name: "mock",
               outbound_key: "clarify-projection",
               operation: :post,
               signal_channel_id: source_event.signal_channel_id,
               source_actor_event_id: source_event.id,
               fallback_visible_text: "Choose or reply",
               payload: %{"reply_presentation" => pending}
             })

    assert {:ok, _newer_event} =
             Repo.transact(fn repo ->
               SignalsGateway.append_actor_event_in_tx(repo, %{
                 agent_uid: source_event.agent_uid,
                 binding_name: source_event.binding_name,
                 session_id: source_event.session_id,
                 source_event_id: unique_uid("delivery-race"),
                 type: "im.message.addressed",
                 available_at: @now,
                 payload: %{"type" => "im.message.addressed", "data" => %{"entry" => %{}}}
               })
             end)

    test_process = self()

    assert {:ok, %{status: :succeeded}} =
             SignalsGateway.dispatch_outbox(
               agent.uid,
               "mock",
               "clarify-projection",
               outbox_adapter([:post_entry], fn outbox ->
                 send(test_process, {:delivered, outbox.payload["reply_presentation"]})
                 {:ok, %{created_source_entry_id: "clarify-card-projected"}}
               end),
               now: DateTime.add(@now, 1, :second)
             )

    assert_receive {:delivered, delivered}
    assert delivered["interaction_status"] == "superseded"
    assert Enum.all?(delivered["actions"], & &1["disabled"])
  end

  test "a passive provider lifecycle event does not supersede a clarification" do
    %{event: source_event} = setup_interaction()

    assert {:ok, _lifecycle_event} =
             Repo.transact(fn repo ->
               SignalsGateway.append_actor_event_in_tx(repo, %{
                 agent_uid: source_event.agent_uid,
                 binding_name: source_event.binding_name,
                 session_id: source_event.session_id,
                 source_event_id: unique_uid("passive-lifecycle"),
                 type: "signal.entry.removed",
                 available_at: @now,
                 payload: %{"type" => "signal.entry.removed", "data" => %{"lifecycle" => %{}}}
               })
             end)

    checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint
    assert checkpoint["interactions"]["clarify:call-1"]["state"] == "pending"
    assert checkpoint["presentation"]["interaction_status"] == "pending"
  end

  test "a queued session reset preserves the card but rejects an answer that would cross the barrier" do
    %{agent: agent, human: human, event: source_event, action: action} = setup_interaction()

    assert {:ok, reset_event} =
             Repo.transact(fn repo ->
               SignalsGateway.append_actor_event_in_tx(repo, %{
                 agent_uid: source_event.agent_uid,
                 binding_name: "__session_lifecycle__",
                 session_id: source_event.session_id,
                 source_event_id: unique_uid("session-reset"),
                 type: "session.reset_due",
                 available_at: @now,
                 payload: %{"type" => "session.reset_due", "data" => %{"reset" => %{}}}
               })
             end)

    checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint
    assert checkpoint["interactions"]["clarify:call-1"]["state"] == "pending"
    assert checkpoint["presentation"]["interaction_status"] == "pending"

    assert {:ok, %{status: :stale_action}} =
             Ingress.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "answer-after-reset-barrier"),
               now: DateTime.add(@now, 1, :second)
             )

    checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint
    interaction = checkpoint["interactions"]["clarify:call-1"]
    assert interaction["state"] == "superseded"
    assert interaction["superseded_by_actor_event_id"] == reset_event.id
    assert checkpoint["presentation"]["interaction_status"] == "superseded"
    assert action_event_count(agent.uid) == 0
  end

  test "a background job result does not supersede an unrelated clarification" do
    %{event: source_event} = setup_interaction()

    assert {:ok, _background_event} =
             Repo.transact(fn repo ->
               SignalsGateway.append_actor_event_in_tx(repo, %{
                 agent_uid: source_event.agent_uid,
                 binding_name: source_event.binding_name,
                 session_id: source_event.session_id,
                 source_event_id: unique_uid("background-job"),
                 type: "background_agent_job.failed",
                 available_at: @now,
                 payload: %{
                   "type" => "background_agent_job.failed",
                   "data" => %{"job_id" => 1000}
                 }
               })
             end)

    checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint
    assert checkpoint["interactions"]["clarify:call-1"]["state"] == "pending"
    assert checkpoint["presentation"]["interaction_status"] == "pending"
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
    binding_fixture(agent.uid, "mock", :ignore, adapter: "lark")

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
      "answerKind" => "choice",
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
          },
          %{
            "id" => "clarify-free-input",
            "type" => "form",
            "label" => "Reply",
            "interaction_id" => "clarify:call-1",
            "source_actor_event_id" => event.id,
            "control_id" => "clarify-free-input",
            "revision" => 1,
            "fields" => [
              %{
                "id" => "clarify-answer",
                "type" => "input",
                "label" => "Your answer",
                "required" => true,
                "multiline" => true,
                "max_length" => 1_000
              }
            ]
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
      "presentation" => ReplyPresentation.checkpoint(presentation),
      "interactions" => %{
        "clarify:call-1" => %{
          "interaction_id" => "clarify:call-1",
          "state" => "pending",
          "opened_at" => DateTime.to_iso8601(@now)
        }
      }
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
