defmodule Ankole.Conversations.Delivery.ReplyInteractionsTest do
  use Ankole.DataCase, async: false

  import Ecto.Query
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Repo

  alias Ankole.Signals
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.TurnRuntimeEnv
  alias Ankole.Conversations.Observe
  alias Ankole.Conversations.Delivery.InteractionState
  alias Ankole.Conversations.Delivery.ReplyPresentation

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

    assert InteractionState.interaction(legacy_pending, interaction_id) == nil
    assert InteractionState.pending_interaction_ids(legacy_pending) == []
    assert InteractionState.interaction(legacy_answered, interaction_id) == nil
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
            "source_signal_id" => Ecto.UUID.generate(),
            "control_id" => "decision",
            "selected_option_id" => "approve",
            "option_value" => "yes",
            "revision" => 1
          }
        ]
      })

    checkpoint =
      InteractionState.initialize(%{"message_id" => "1700000000.000001"}, presentation, @now)

    assert {:ok, transition} =
             InteractionState.resolve(checkpoint, "slack-interaction", %{
               "state" => "answered",
               "answer" => %{"kind" => "choice", "option_id" => "approve", "value" => "yes"}
             })

    resolved = InteractionState.merge_checkpoint(checkpoint, transition, fn _ -> true end)

    assert resolved["refresh_pending"] == true
    assert resolved["refresh_reason"] == "interaction"
    assert resolved["presentation"]["interaction_status"] == "answered"
  end

  test "accepts one authorized current choice, locks the controls, and suppresses repeat clicks" do
    %{agent: agent, human: human, event: source_event, action: action} = setup_interaction()

    assert {:ok, %{status: :accepted, signal: action_event}} =
             Observe.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "action-event-1"),
               now: @now
             )

    assert action_event.type == "signal.action.invoked"
    assert action_event.sender_key == human.uid
    assert action_event.authorization_kind == "human"
    assert action_event.human_uid == human.uid
    assert action_event.human_access_version == human.access_version
    assert action_event.conversation_id == source_event.conversation_id
    assert action_event.session_id == "conversation:#{source_event.conversation_id}"

    assert_enqueued(
      worker: Ankole.Sessions.Jobs.EnsureDriver,
      args: %{
        agent_uid: agent.uid,
        session_id: action_event.session_id,
        tenant_id: Repo.tenant_id!()
      }
    )

    assert %{
             "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL" => principal_uid,
             "ANKOLE_RUNTIME_LARK_PROFILE" => "ankole-u-" <> _digest
           } = TurnRuntimeEnv.resolve(action_event)

    assert principal_uid == human.uid

    assert get_in(action_event.data, ["action", "value"]) == %{
             "interaction_id" => "clarify:call-1",
             "source_signal_id" => source_event.id,
             "answer" => %{
               "kind" => "choice",
               "option_id" => "operators",
               "value" => "Operators"
             }
           }

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

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
             Observe.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "action-event-2"),
               now: DateTime.add(@now, 1, :second)
             )

    assert action_event_count(agent.uid) == 1

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == "Ankole.Sessions.Jobs.EnsureDriver",
               where: fragment("?->>'agent_uid'", job.args) == ^agent.uid,
               where: fragment("?->>'session_id'", job.args) == ^action_event.session_id
             ),
             :count
           ) == 1
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
      "sourceSignalId" => source_event.id
    }

    assert {:ok, %{status: :accepted, signal: action_event}} =
             Observe.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "form-action-event"),
               now: @now
             )

    assert get_in(action_event.data, ["action", "value", "answer"]) == %{
             "kind" => "free_text",
             "value" => "Use the latest paragraph above."
           }

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

    assert checkpoint["interactions"]["clarify:call-1"]["state"] == "answered"
    assert checkpoint["presentation"]["interaction_status"] == "answered"

    assert checkpoint["presentation"]["interaction_answer"] ==
             "Use the latest paragraph above."

    assert Enum.all?(checkpoint["presentation"]["actions"], & &1["disabled"])
  end

  test "a newer conversation event supersedes the card and later callbacks are stale" do
    %{agent: agent, human: human, event: source_event, action: action} = setup_interaction()

    assert {:ok, newer_event} =
             accept_signal(source_event, "conversation.message.addressed", "newer-turn",
               now: DateTime.add(@now, 1, :second)
             )

    assert newer_event.queue_sequence > source_event.queue_sequence

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

    interaction = checkpoint["interactions"]["clarify:call-1"]
    assert interaction["state"] == "superseded"
    assert interaction["superseded_by_signal_id"] == newer_event.id
    assert checkpoint["presentation"]["interaction_status"] == "superseded"
    refute Map.has_key?(checkpoint["presentation"], "interaction_answer")
    assert checkpoint["refresh_pending"]
    assert Enum.all?(checkpoint["presentation"]["actions"], & &1["disabled"])

    assert {:ok, %{status: :stale_action}} =
             Observe.emit_action(
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
             accept_signal(source_event, "conversation.message.addressed", "checkpoint-race")

    resolved =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

    stale =
      resolved
      |> Map.put("presentation", resolved["previous_presentation"])
      |> Map.delete("interactions")
      |> Map.delete("refresh_pending")
      |> Map.delete("refresh_reason")

    assert {:ok, _event} =
             PreviewStates.put_checkpoint(source_event.id, stale)

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

    assert checkpoint["interactions"]["clarify:call-1"]["state"] == "superseded"
    assert checkpoint["presentation"]["interaction_status"] == "superseded"
    assert checkpoint["refresh_pending"]
  end

  test "intent delivery projects the latest interaction state before calling an adapter" do
    %{agent: agent, event: source_event} = setup_interaction()

    pending =
      source_event
      |> Repo.reload!()
      |> then(&Ankole.Conversations.Delivery.PreviewStates.get(&1).checkpoint["presentation"])

    assert {:ok, _intent} =
             Ankole.SignalsFixtures.commit_delivery(%{
               agent_uid: agent.uid,
               binding_name: "mock",
               outbound_key: "clarify-projection",
               operation: :post,
               conversation_id: source_event.conversation_id,
               source_signal_id: source_event.id,
               fallback_visible_text: "Choose or reply",
               payload: %{"reply_presentation" => pending}
             })

    assert {:ok, _newer_event} =
             accept_signal(source_event, "conversation.message.addressed", "delivery-race")

    test_process = self()

    assert {:ok, %{status: :sent}} =
             Ankole.Conversations.Delivery.dispatch(
               agent.uid,
               "mock",
               "clarify-projection",
               delivery_adapter([:post_entry], fn intent ->
                 send(test_process, {:delivered, intent.payload["reply_presentation"]})
                 {:ok, %{created_provider_message_id: "clarify-card-projected"}}
               end),
               now: DateTime.add(@now, 1, :second)
             )

    assert_receive {:delivered, delivered}
    assert delivered["interaction_status"] == "superseded"
    assert Enum.all?(delivered["actions"], & &1["disabled"])
  end

  for timing <- [:before_open, :after_open],
      type <- ["com.example.build.finished", "session.reset_due"] do
    @tag external_timing: timing
    test "external #{type} #{timing} preserves enabled controls and accepts one answer", %{
      external_timing: timing
    } do
      type = unquote(type)

      before_open =
        if timing == :before_open, do: &receive_external(&1, type), else: fn _ -> :ok end

      %{agent: agent, human: human, event: source, action: action} =
        setup_interaction(before_open: before_open)

      if timing == :after_open, do: receive_external(source, type)

      checkpoint = PreviewStates.get(source.id).checkpoint
      assert checkpoint["interactions"]["clarify:call-1"]["state"] == "pending"
      assert checkpoint["presentation"]["interaction_status"] == "pending"

      assert {:ok, _} =
               Ankole.SignalsFixtures.commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "mock",
                 outbound_key: "preserved-clarification",
                 operation: :post,
                 conversation_id: source.conversation_id,
                 source_signal_id: source.id,
                 fallback_visible_text: "Choose or reply",
                 payload: %{"reply_presentation" => checkpoint["presentation"]}
               })

      parent = self()

      assert {:ok, %{status: :sent}} =
               Ankole.Conversations.Delivery.dispatch(
                 agent.uid,
                 "mock",
                 "preserved-clarification",
                 delivery_adapter([:post_entry], fn intent ->
                   send(parent, {:preserved_presentation, intent.payload["reply_presentation"]})
                   {:ok, %{created_provider_message_id: "preserved-card"}}
                 end),
                 now: @now
               )

      assert_receive {:preserved_presentation, delivered}
      assert delivered["interaction_status"] == "pending"
      refute Enum.any?(delivered["actions"], & &1["disabled"])

      answer = action_input(action, human.uid, "answer-after-external")
      assert {:ok, %{status: :accepted}} = Observe.emit_action(agent.uid, "mock", answer)
      assert {:ok, %{status: :duplicate_action}} = Observe.emit_action(agent.uid, "mock", answer)
      assert action_event_count(agent.uid) == 1
    end
  end

  for timing <- [:before_open, :after_open],
      type <- [
        "background_agent_job.dispatch",
        "command.compress",
        "command.llm",
        "command.new",
        "command.retry",
        "command.steer",
        "command.stop",
        "conversation.message.addressed",
        "im.message.may_intervene",
        "input.revised",
        "signal.action.invoked",
        "workflow.task.dispatch",
        "workflow.task.message",
        "workflow.task.wakeup"
      ] do
    @tag superseding_timing: timing
    test "declared #{type} #{timing} closes controls and rejects a callback", %{
      superseding_timing: timing
    } do
      type = unquote(type)

      before_open =
        if timing == :before_open,
          do: fn source -> accept_signal(source, type, "superseding-before") end,
          else: fn _ -> :ok end

      %{agent: agent, human: human, event: source, action: action} =
        setup_interaction(before_open: before_open)

      if timing == :after_open, do: accept_signal(source, type, "superseding-after")
      checkpoint = PreviewStates.get(source.id).checkpoint
      assert checkpoint["interactions"]["clarify:call-1"]["state"] == "superseded"
      assert checkpoint["presentation"]["interaction_status"] == "superseded"
      assert Enum.all?(checkpoint["presentation"]["actions"], & &1["disabled"])
      before_actions = action_event_count(agent.uid)

      assert {:ok, %{status: :stale_action}} =
               Observe.emit_action(
                 agent.uid,
                 "mock",
                 action_input(action, human.uid, "late-after-superseding")
               )

      assert action_event_count(agent.uid) == before_actions
    end
  end

  test "a rolled-back intake leaves no supersede or driver job" do
    %{event: source} = setup_interaction()
    before_jobs = Repo.aggregate(Oban.Job, :count)
    before_signals = Repo.aggregate(Signal, :count)

    assert {:error, :rollback_intake} =
             Repo.transact(fn repo ->
               assert {:ok, _} =
                        accept_signal(source, "conversation.message.addressed", "rolled-back",
                          repo: repo
                        )

               assert PreviewStates.get(source.id).checkpoint["interactions"]["clarify:call-1"][
                        "state"
                      ] == "superseded"

               {:error, :rollback_intake}
             end)

    assert PreviewStates.get(source.id).checkpoint["interactions"]["clarify:call-1"]["state"] ==
             "pending"

    assert Repo.aggregate(Signal, :count) == before_signals
    assert Repo.aggregate(Oban.Job, :count) == before_jobs
  end

  test "a passive provider lifecycle event does not supersede a clarification" do
    %{event: source_event} = setup_interaction()

    assert {:ok, _lifecycle_event} =
             accept_signal(source_event, "conversation.message.removed", "passive-lifecycle",
               data: %{"lifecycle" => %{}}
             )

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

    assert checkpoint["interactions"]["clarify:call-1"]["state"] == "pending"
    assert checkpoint["presentation"]["interaction_status"] == "pending"
  end

  test "a queued session reset preserves the card but rejects an answer that would cross the barrier" do
    %{agent: agent, human: human, event: source_event, action: action} = setup_interaction()

    assert {:ok, reset_event} =
             accept_signal(source_event, "session.reset_due", "session-reset",
               data: %{"reset" => %{}}
             )

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

    assert checkpoint["interactions"]["clarify:call-1"]["state"] == "pending"
    assert checkpoint["presentation"]["interaction_status"] == "pending"

    assert {:ok, %{status: :stale_action}} =
             Observe.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "answer-after-reset-barrier"),
               now: DateTime.add(@now, 1, :second)
             )

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

    interaction = checkpoint["interactions"]["clarify:call-1"]
    assert interaction["state"] == "superseded"
    assert interaction["superseded_by_signal_id"] == reset_event.id
    assert checkpoint["presentation"]["interaction_status"] == "superseded"
    assert action_event_count(agent.uid) == 0
  end

  test "a background job result does not supersede an unrelated clarification" do
    %{event: source_event} = setup_interaction()

    assert {:ok, _background_event} =
             accept_signal(source_event, "background_agent_job.failed", "background-job",
               data: %{"job_id" => 1000}
             )

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

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
             Observe.emit_action(
               agent.uid,
               "mock",
               action_input(stale_action, human.uid, "stale-event"),
               now: @now
             )

    assert action_event_count(agent.uid) == 0
  end

  test "re-authorizes the acting principal instead of trusting a visible button" do
    %{agent: agent, human: human, action: action} = setup_interaction()

    {:ok, _} = Ankole.PrincipalsFixtures.disable_principal_fixture(human.uid)

    assert {:error, :reply_interaction_operator_unauthorized} =
             Observe.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "disabled-human-event"),
               now: @now
             )

    assert action_event_count(agent.uid) == 0
  end

  test "accepts a managed callback from any card in the durable CardChain" do
    %{agent: agent, human: human, event: source_event, action: action} = setup_interaction()

    checkpoint =
      Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

    checkpoint =
      Map.put(checkpoint, "cards", [
        %{"index" => 0, "message_id" => "card-message-1", "state" => "sealed"},
        %{"index" => 1, "message_id" => "card-message-2", "state" => "open"}
      ])

    assert {:ok, _updated} =
             PreviewStates.put_checkpoint(
               source_event.id,
               checkpoint
             )

    assert {:ok, %{status: :accepted}} =
             Observe.emit_action(
               agent.uid,
               "mock",
               action_input(action, human.uid, "card-chain-action", "card-message-2"),
               now: @now
             )

    assert action_event_count(agent.uid) == 1
  end

  defp setup_interaction(opts \\ []) do
    %{principal: agent} = agent_fixture()
    %{principal: human} = human_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "lark")

    %{signal: event} =
      emit_addressed_signal(
        agent.uid,
        "mock",
        group_entry(%{
          source_event_id: unique_uid("interaction-source"),
          provider_message_id: unique_uid("trigger-message"),
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
      "sourceSignalId" => event.id
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
            "source_signal_id" => event.id,
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
            "source_signal_id" => event.id,
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
            "source_signal_id" => event.id,
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

    Keyword.get(opts, :before_open, fn _ -> :ok end).(event)

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-1",
      "message_id" => "card-message-1",
      "streaming_state" => "closed",
      "element_ids" => ["state", "answer", "actions"],
      "presentation" => ReplyPresentation.checkpoint(presentation)
    }

    assert {:ok, _updated} = PreviewStates.put_checkpoint(event.id, checkpoint)

    assert {:ok, _} =
             Repo.transact(fn ->
               :ok =
                 Ankole.Sessions.Queue.lock_session_in_tx(event.agent_uid, event.session_id)

               Ankole.Conversations.Delivery.Interactions.open_in_tx(
                 event,
                 presentation,
                 @now
               )
             end)

    assert :ok =
             PreviewStates.record_provider_message(
               event.id,
               "card-message-1"
             )

    %{agent: agent, human: human, event: event, action: action}
  end

  defp action_input(
         action,
         operator_principal_uid,
         source_event_id,
         provider_message_id \\ "card-message-1"
       ) do
    %{
      source_event_id: source_event_id,
      action_id: source_event_id,
      provider_conversation_id: "lark:chat:group-a",
      provider_message_id: provider_message_id,
      provider_thread_id: provider_message_id,
      action: %{
        "name" => "clarify-choice",
        "value" => action,
        "operator_principal_uid" => operator_principal_uid
      }
    }
  end

  defp accept_signal(source, type, id, opts \\ []) do
    now = Keyword.get(opts, :now, @now)

    attrs = %{
      producer: :kernel,
      source: "test://reply-interactions",
      id: unique_uid(id),
      type: type,
      time: now,
      available_at: now,
      target: %{agent_uid: source.agent_uid, conversation_id: source.conversation_id},
      authorization: Ankole.Principals.WorkAccess.service(),
      data: Keyword.get(opts, :data, %{"text" => "A newer conversation turn"}),
      reply_route: %{
        binding_name: source.reply_binding_name,
        conversation_id: source.conversation_id,
        provider_thread_id: source.provider_thread_id,
        provider_message_id: unique_uid("source-message")
      }
    }

    case Keyword.get(opts, :repo) do
      nil -> Signals.accept(attrs)
      _repo -> Signals.accept_in_tx(attrs)
    end
  end

  defp receive_external(source, type) do
    assert {:ok, endpoint} =
             Ankole.Signals.Webhooks.create_endpoint(%{
               label: "Build results",
               expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
               mode: "standing",
               event_format: "cloudevents"
             })

    assert {:ok, _} =
             Ankole.Signals.Bindings.put_binding(
               source.agent_uid,
               "cloudevents",
               "build-results",
               %{
                 "config" => %{"webhook_endpoint_id" => endpoint.webhook_endpoint.id},
                 "target" => %{"session_id" => source.session_id}
               }
             )

    assert {:ok, %{signals: [%Signal{producer: :external}]}} =
             Ankole.Signals.Webhooks.receive_cloudevent(endpoint.token, %{
               "specversion" => "1.0",
               "source" => "https://outside.example/events",
               "id" => unique_uid("external-result"),
               "type" => type,
               "data" => %{"result" => "ok"}
             })
  end

  defp action_event_count(agent_uid) do
    Signal
    |> where([event], event.agent_uid == ^agent_uid)
    |> where([event], event.type == "signal.action.invoked")
    |> Repo.aggregate(:count)
  end
end
