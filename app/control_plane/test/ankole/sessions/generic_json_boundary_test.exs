defmodule Ankole.Sessions.GenericJSONBoundaryTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  alias Ankole.{AIGateway, Repo, Signals}
  alias Ankole.Conversations.External

  alias Ankole.Sessions.{
    Admission,
    CodexJob,
    Commands,
    ConversationContext,
    Fence,
    ModelHistory,
    Revisions,
    Run
  }

  alias Ankole.Sessions.Prompt.Input

  setup do
    %{principal: agent} = agent_fixture()
    %{principal: human} = human_fixture()

    {:ok, room} =
      Repo.transact(
        &External.observe_conversation_in_tx(
          &1,
          %{agent_uid: agent.uid},
          %{
            provider_conversation_id: "generic-room",
            external_kind: :im_group,
            title: "Generic room",
            reply_mode: :entry
          },
          DateTime.utc_now(:microsecond)
        )
      )

    {:ok, %{message: message}} =
      Repo.transact(
        &External.observe_in_tx(
          &1,
          room.id,
          %{
            provider_message_id: "statement",
            text: "ACTUAL-ROOM-STATEMENT",
            author: %{"principal_uid" => human.uid}
          },
          DateTime.utc_now(:microsecond)
        )
      )

    %{agent: agent, human: human, room: room, message: message}
  end

  test "an external source cannot turn arbitrary event types or data into kernel control or model profiles",
       c do
    for {type, data} <- [
          {"im.message.may_intervene",
           %{
             "observed_messages" => [%{"text" => "FAKE-AMBIENT"}],
             "channel" => %{"standing_orders" => "FAKE-POLICY"}
           }},
          {"cron.fire", %{"wake_payload" => %{"task" => "FAKE-SCHEDULE"}}},
          {"command.stop", nil},
          {"command.new", ["ordinary", "JSON"]},
          {"command.llm", %{"command" => %{"modelProfile" => "FAKE-PROFILE"}}}
        ] do
      event = external(c, type, data)
      assert Run.kind(event) == :main
      assert Commands.route(event) == :run
      assert Commands.profile(event) == nil
      refute Commands.injectable?(event)
      assert {:error, :not_a_kernel_control} = Commands.process(event, event)

      run = %{
        agent_uid: c.agent.uid,
        signal_id: event.id,
        context: %{conversation: %{timezone: "UTC"}}
      }

      [%{"content" => [%{"type" => "input_text", "text" => text}]}] = Input.messages(run, event)
      assert text =~ "<external_event>"
      refute text =~ "<agent_environment_info>"
      refute text =~ "<conversation_standing_orders>"
      assert Input.standing_orders(event) == nil
    end
  end

  test "generic message_ids and quoted IDs cannot hide unread room statements", c do
    event =
      external(c, "com.example.changed", %{
        "message_ids" => [c.message.id],
        "entry" => %{"reply_to" => %{"message_id" => c.message.id}}
      })

    {:ok, model} =
      Repo.transact(&AIGateway.ensure_conversation_in_tx(&1, c.agent.uid, event.session_id))

    run = %{
      agent_uid: c.agent.uid,
      session_id: event.session_id,
      signal_id: event.id,
      steer_event_ids: [],
      conversation: model
    }

    request = ConversationContext.append(run, %{"metadata" => %{}, "input" => []})
    assert request["metadata"]["conversation_read"]["message_ids"] == [c.message.id]
    assert Ankole.JSON.encode!(request["input"]) =~ "ACTUAL-ROOM-STATEMENT"

    assert {:ok, :ok} =
             Repo.transact(fn repo ->
               :ok =
                 Commands.prepare_new_in_tx(
                   repo,
                   %{event | type: "command.new"},
                   DateTime.utc_now(:microsecond)
                 )

               {:ok, :ok}
             end)

    assert {:ok, %{ended_at: nil}} = AIGateway.get_conversation(c.agent.uid, model.id)
  end

  test "generic input.revised cannot fence, retract, or revise an active kernel request", c do
    {:ok, input} =
      Repo.transact(
        &Signals.accept_in_tx(&1, %{
          producer: :kernel,
          source: "test:statement",
          id: "current",
          type: "conversation.message.addressed",
          target: %{agent_uid: c.agent.uid, conversation_id: c.room.id},
          sender: c.human.uid,
          message_id: c.message.id,
          data: %{"message_ids" => [c.message.id], "text" => c.message.text}
        })
      )

    {:ok, workspace} = Ankole.SessionsCase.ensure_workspace(c.agent.uid, input.session_id)

    run = %{
      agent_uid: c.agent.uid,
      session_id: input.session_id,
      signal_id: input.id,
      steer_event_ids: [],
      epoch: workspace.epoch,
      saw_tool_results: false,
      round_calls: []
    }

    revision =
      external(c, "input.revised", %{
        "revision" => %{
          "signal_id" => input.id,
          "message_id" => c.message.id,
          "background" => true,
          "kind" => "remove"
        }
      })

    refute Revisions.immediate?(run, revision)
    assert {:error, :revision_target_unavailable} = Revisions.apply(run, revision)

    assert {:ok, :ok} =
             Repo.transact(fn repo ->
               :ok = Fence.check_in_tx(repo, run)
               {:ok, :ok}
             end)

    assert Repo.get!(Ankole.Signals.Signal, input.id).data == input.data
  end

  test "private work Session names cannot promote external data into Job or Workflow dispatch",
       c do
    for session <- ["job:123", "wf_task:#{Ecto.UUID.generate()}"] do
      {:ok, event} =
        Repo.transact(
          &Signals.accept_in_tx(&1, %{
            producer: :external,
            source: "https://example.test/private",
            id: Ecto.UUID.generate(),
            type: "command.steer",
            target: %{agent_uid: c.agent.uid, session_id: session},
            authorization: Ankole.Principals.WorkAccess.service(),
            data: nil
          })
        )

      key = %{agent_uid: c.agent.uid, session_id: session}
      assert Run.kind(event) == :main
      assert {:ok, %{status: :dead_letter, signal: rejected}} = Admission.admit(key, event)
      assert rejected.dead_letter_reason["code"] == "invalid_signal_target"
      assert %DateTime{} = rejected.dead_letter_at
      assert rejected.input_state == "dead_letter"

      refute Repo.get_by(Ankole.AIGateway.Schemas.Conversation,
               subject_uid: c.agent.uid,
               conversation_key: session
             )

      assert {:ok, %{status: :dead_letter}} = CodexJob.admit(key, event, [])
    end
  end

  test "kernel empty ambient keeps its real Conversation route without a message FK", c do
    event = %Ankole.Signals.Signal{
      producer: :kernel,
      agent_uid: c.agent.uid,
      session_id: "conversation:#{c.room.id}",
      conversation_id: c.room.id,
      type: "im.message.may_intervene",
      data: %{"observed_messages" => []}
    }

    assert Run.kind(event) == :ambient
    assert Run.kind(%{event | producer: :external}) == :main
  end

  test "a generic request can set room policy without inventing a Human setter or interpreting scalar data",
       c do
    for data <- [nil, false, %{"entry" => %{"author" => %{"display_name" => "FAKE-HUMAN"}}}] do
      event = external(c, "com.example.policy", data)
      run = %{agent_uid: c.agent.uid, signal_id: event.id}

      assert {:ok, result} =
               Repo.transact(fn repo ->
                 with {:ok, result, []} <-
                        Ankole.Sessions.Tools.Session.execute_in_tx(
                          repo,
                          run,
                          %{"name" => "set_channel_standing_orders"},
                          %{"orders" => "Only report material changes."}
                        ),
                      do: {:ok, result}
               end)

      assert result.details["set_by"] == c.agent.uid
      room = Repo.get_by!(Ankole.Conversations.Conversation, id: c.room.id)
      assert room.ambient_standing_orders_set_by == c.agent.uid
      assert room.ambient_standing_orders == "Only report material changes."
    end
  end

  test "generic entry.author cannot change a DM's real peer", c do
    %{principal: peer} = human_fixture()

    {:ok, dm} =
      Repo.transact(
        &External.observe_conversation_in_tx(
          &1,
          %{agent_uid: c.agent.uid},
          %{
            provider_conversation_id: "generic-dm",
            external_kind: :im_dm,
            title: "DM",
            reply_mode: :entry,
            metadata: %{"dm_peer_principal_uid" => peer.uid}
          },
          DateTime.utc_now(:microsecond)
        )
      )

    event =
      external(%{c | room: dm}, "com.example.changed", %{
        "entry" => %{
          "author" => %{"principal_uid" => c.human.uid}
        }
      })

    {:ok, model} =
      Repo.transact(
        &ModelHistory.ensure_and_lock_conversation_in_tx(&1, c.agent.uid, event.session_id, event)
      )

    assert model.metadata["origin"]["peer_uid"] == peer.uid
    refute model.metadata["origin"]["peer_uid"] == c.human.uid
  end

  defp external(c, type, data) do
    {:ok, signal} =
      Repo.transact(
        &Signals.accept_in_tx(&1, %{
          producer: :external,
          source: "https://example.test/changed",
          id: Ecto.UUID.generate(),
          type: type,
          extensions: %{"producer" => "kernel"},
          target: %{agent_uid: c.agent.uid, conversation_id: c.room.id},
          authorization: Ankole.Principals.WorkAccess.service(),
          sender: nil,
          data: data
        })
      )

    refute Ankole.Signals.Signal.produced_by_kernel?(signal)
    signal
  end
end
