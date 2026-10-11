defmodule Ankole.Conversations.RunTest do
  use Ankole.DataCase, async: false

  import Ankole.SignalsGateway.ActorRuntimeCase, only: [agent_fixture: 0]
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Conversations.{Admission, Fence, Receipts, Run, ToolResult, Wait}
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker

  setup do
    %{principal: agent} = agent_fixture()
    key = %{agent_uid: agent.uid, session_id: "driver:#{System.unique_integer([:positive])}"}

    {:ok, event} =
      Repo.transact(fn repo ->
        SignalsGateway.append_actor_event_in_tx(repo, %{
          agent_uid: agent.uid,
          session_id: key.session_id,
          sender_key: agent.uid,
          binding_name: "control-plane:test",
          source_event_id: Ecto.UUID.generate(),
          type: "im.message.addressed",
          payload: %{},
          available_at: DateTime.utc_now(:microsecond)
        })
      end)

    {:ok, key: key, event: event}
  end

  test "revocation rejects fresh steers and controls but retains admitted input", %{
    key: key,
    event: event
  } do
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    {:ok, run} = Admission.admit(key, event)

    [admitted, fresh, stop] =
      for type <- ["command.steer", "command.steer", "command.stop"] do
        {:ok, input} =
          Repo.transact(
            &SignalsGateway.append_actor_event_in_tx(&1, %{
              agent_uid: key.agent_uid,
              session_id: key.session_id,
              sender_key: human.uid,
              binding_name: "control-plane:test",
              source_event_id: Ecto.UUID.generate(),
              type: type,
              payload: %{},
              available_at: DateTime.utc_now(:microsecond)
            })
          )

        input
      end

    assert {:ok, [admitted]} = Run.inject(run, [admitted])
    Repo.update!(Ecto.Changeset.change(human, access_version: human.access_version + 1))
    assert {:ok, [retained]} = Run.inject(run, [admitted, fresh])
    assert retained.id == admitted.id
    assert Repo.reload!(fresh).input_state == "dead_letter"
    assert {:ok, _} = Ankole.Conversations.Commands.process(key, stop)
    assert Repo.reload!(stop).input_state == "dead_letter"
    refute Repo.reload!(event).completed_at
  end

  test "ordinary admission and recovery need no Worker (G1, G2)", %{key: key, event: event} do
    worker = Repo.get!(AgentWorker, key.agent_uid)
    assert {:ok, run} = Admission.admit(key, event)
    assert run.event.attempt_count == 1
    assert run.epoch == 1
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
    assert {:ok, {:preparing, restored}} = Run.restore(run)
    assert restored.actor_event_id == event.id
  end

  test "a takeover reclaims the old stream and rejects its driver writes (G3, G6)", %{
    key: key,
    event: event
  } do
    {:ok, old} = Admission.admit(key, event)

    {:ok, live} =
      start_response_run(%{
        subject_uid: key.agent_uid,
        conversation_id: old.conversation.id,
        metadata: %{"request_metadata" => Run.metadata(old)}
      })

    {:ok, current} = Admission.admit(key, event)
    assert {:ok, {:preparing, _}} = Run.restore(current)
    assert Repo.get!(Message, live.id).status == "error"
    assert {:ok, :already_terminal} = StatefulResponses.commit_complete(live, [])
    assert {:error, :stale_driver} = Repo.transact(&Fence.check_in_tx(&1, old))
  end

  test "an unrecorded call is recovered, and a recorded round is never dispatched again (G3)", %{
    key: key,
    event: event
  } do
    {:ok, run} = Admission.admit(key, event)
    run = %{run | iteration: 1}

    {:ok, response} =
      start_response_run(%{
        subject_uid: key.agent_uid,
        conversation_id: run.conversation.id,
        metadata: %{"request_metadata" => Run.metadata(run)}
      })

    call = %{
      "type" => "function_call",
      "name" => "cron",
      "call_id" => "c1",
      "arguments" => "{}",
      "status" => "completed"
    }

    {:ok, response} = StatefulResponses.commit_complete(response, [call])
    {:ok, {:executing_tools, recovered}} = Run.restore(run)
    assert recovered.calls == [call]

    assert {:ok, _receipt} =
             Receipts.execute(run, Run.response_id(response), "c1", fn _ ->
               {:ok, %Ankole.Conversations.ToolResult{output: "committed"}, []}
             end)

    assert {:ok, {:executing_tools, recovered}} = Run.restore(run)
    assert recovered.receipts == %{"c1" => %ToolResult{output: "committed"}}
    assert recovered.results == %{}

    recovered = %{
      recovered
      | results: %{"c1" => %Ankole.Conversations.ToolResult{output: "committed"}}
    }

    assert {:ok, journal} = Run.record_round(recovered)
    assert {:error, :receipt_not_found} = Receipts.fetch(Run.response_id(response), "c1")
    assert {:ok, {:boundary, recovered}} = Run.restore(run)
    assert recovered.calls == []
    assert recovered.receipts == %{}
    assert recovered.anchor == journal.message.id
  end

  test "recovery retains a committed wait and its original observation deadline", %{
    key: key,
    event: event
  } do
    {:ok, run} = Admission.admit(key, event)

    {:ok, response} =
      start_response_run(%{
        subject_uid: key.agent_uid,
        conversation_id: run.conversation.id,
        metadata: %{"request_metadata" => Run.metadata(run)}
      })

    call = %{
      "type" => "function_call",
      "name" => "send_message_to_background_job",
      "call_id" => "waiting",
      "arguments" => "{}",
      "status" => "completed"
    }

    {:ok, response} = StatefulResponses.commit_complete(response, [call])
    wait = %Wait{kind: :job, job_id: 1000, command_event_id: event.id, timeout_ms: 30_000}

    assert {:ok, receipt} =
             Receipts.execute(run, Run.response_id(response), "waiting", fn _ ->
               {:ok, {:await, wait}, []}
             end)

    assert {:ok, {:executing_tools, recovered}} = Run.restore(run)
    assert recovered.calls == [call]
    assert recovered.results == %{}

    assert recovered.receipts == %{
             "waiting" => {:await, %{wait | started_at: receipt.inserted_at}}
           }
  end

  test "shutdown and takeover refund an admission without clearing the backoff clock (G5, G7)", %{
    key: key,
    event: event
  } do
    {:ok, first} = Admission.admit(key, event)
    assert {:ok, refunded} = Run.refund(first, :shutdown)
    assert refunded.attempt_count == 0
    assert refunded.last_attempt_at == first.event.last_attempt_at
    {:ok, second} = Admission.admit(key, refunded)
    {:ok, third} = Admission.admit(key, refunded)
    assert {:ok, refunded} = Run.refund(second, :stale_driver)
    assert refunded.attempt_count == 1
    assert refunded.last_attempt_at == third.event.last_attempt_at
    assert {:ok, :unchanged} = Run.refund(first, :shutdown)
  end

  for rejection <- [:exhausted, :profile_unavailable] do
    test "#{rejection} preserves committed results and consumes taped input (G2, G3)", %{
      key: key,
      event: event
    } do
      {:ok, run} = Admission.admit(key, event)
      {:ok, steer} = append_steer(key)
      {:ok, unread} = append_steer(key)

      {:ok, response} =
        start_response_run(%{
          subject_uid: key.agent_uid,
          conversation_id: run.conversation.id,
          metadata: %{
            "request_metadata" => Run.metadata(%{run | steer_event_ids: [steer.id]})
          }
        })

      call = %{
        "type" => "function_call",
        "name" => "cron",
        "call_id" => "committed-before-crash",
        "arguments" => "{}",
        "status" => "completed"
      }

      {:ok, response} = StatefulResponses.commit_complete(response, [call])

      {:ok, _} =
        Receipts.execute(run, Run.response_id(response), Run.call_id(call), fn _repo ->
          {:ok, %Ankole.Conversations.ToolResult{output: "committed-before-rejection"}, []}
        end)

      result =
        case unquote(rejection) do
          :exhausted ->
            event |> ActorEvent.changeset(%{attempt_count: 5}) |> Repo.update!()
            Admission.admit(key, event)

          :profile_unavailable ->
            Admission.admit(key, event, profile: "missing-profile")
        end

      assert {:ok, %{journal: journal}} = result

      assert [output] = journal.message.content
      assert output["output"] == "committed-before-rejection"
      assert output["call_id"] == Run.call_id(call)

      assert {:error, :receipt_not_found} =
               Receipts.fetch(Run.response_id(response), Run.call_id(call))

      case unquote(rejection) do
        :exhausted ->
          assert Repo.reload!(event).input_state == "dead_letter"
          assert Repo.reload!(steer).input_state == "dead_letter"

        :profile_unavailable ->
          assert Repo.reload!(event).completed_at
          assert Repo.reload!(steer).completed_at
      end

      refute Repo.reload!(unread).completed_at
      assert {:ok, tail} = Ankole.AIGateway.conversation_tail(run.conversation, event.id)
      assert MapSet.member?(tail.recorded_call_ids, Run.call_id(call))
    end
  end

  test "crash recovery has durable backoff and the sixth admission dead-letters (G2, G8)", %{
    key: key,
    event: event
  } do
    now = DateTime.utc_now(:microsecond)

    for attempt <- 1..5 do
      assert {:ok, run} = Admission.admit(key, event, now: now)
      assert run.event.attempt_count == attempt
      assert {:ok, %{event: selected, delay_ms: delay}} = Run.rebuild(key, now)
      assert selected.id == event.id
      assert delay == Run.backoff_seconds(attempt, :execution) * 1_000
    end

    assert {:ok, %{status: :dead_letter}} = Admission.admit(key, event, now: now)
    assert Repo.get!(ActorEvent, event.id).input_state == "dead_letter"
    assert {:ok, :idle} = Run.rebuild(key, now)
  end

  test "takeover refunds are best effort after a newer admission closes the input", %{
    key: key,
    event: event
  } do
    {:ok, first} = Admission.admit(key, event)
    for _ <- 2..5, do: assert({:ok, %Run{}} = Admission.admit(key, event))
    assert {:ok, %{status: :dead_letter}} = Admission.admit(key, event)
    assert {:ok, :unchanged} = Run.refund(first, :stale_driver)
    assert Repo.get!(ActorEvent, event.id).attempt_count == 6
    assert Repo.get!(ActorEvent, event.id).input_state == "dead_letter"
  end

  test "terminal decisions consume only input that reached the model tape (G2)", %{
    key: key,
    event: event
  } do
    {:ok, run} = Admission.admit(key, event)
    {:ok, steer} = append_steer(key)
    {:ok, [steer]} = Run.inject(run, [steer])
    run = %{run | steer_event_ids: [steer.id]}
    assert {:ok, _} = Run.finalize(run, "silent")

    assert %ActorEvent{completed_at: %DateTime{}, turn_outcome: "silent"} =
             Repo.get!(ActorEvent, event.id)

    assert %ActorEvent{completed_at: nil, input_state: "open"} = Repo.get!(ActorEvent, steer.id)
  end

  test "taped input survives loss of the driver's in-memory applied set (G2)", %{
    key: key,
    event: event
  } do
    {:ok, run} = Admission.admit(key, event)
    {:ok, steer} = append_steer(key)
    metadata = Run.metadata(%{run | steer_event_ids: [steer.id], iteration: 1})

    {:ok, response} =
      start_response_run(%{
        subject_uid: key.agent_uid,
        conversation_id: run.conversation.id,
        metadata: %{"request_metadata" => metadata}
      })

    {:ok, _} = StatefulResponses.commit_complete(response, [])
    assert run.steer_event_ids == []
    assert {:ok, _} = Run.finalize(run, "silent")

    assert %ActorEvent{completed_at: %DateTime{}, turn_outcome: "silent"} =
             Repo.get!(ActorEvent, steer.id)
  end

  test "a replaced driver cannot create a late model response (G6)", %{key: key, event: event} do
    {:ok, old} = Admission.admit(key, event)
    {:ok, _current} = Admission.admit(key, event)

    assert {:error, :stale_driver} =
             StatefulResponses.start_planned_response_run(
               %{
                 subject_uid: key.agent_uid,
                 conversation_id: old.conversation.id,
                 expected_previous_response_id: nil
               },
               authorize_run_in_tx: &Fence.check_in_tx(&1, old)
             )

    refute Repo.exists?(
             from m in Message,
               where: m.conversation_id == ^old.conversation.id and m.status == "generating"
           )
  end

  defp append_steer(key) do
    Repo.transact(fn repo ->
      SignalsGateway.append_actor_event_in_tx(repo, %{
        agent_uid: key.agent_uid,
        session_id: key.session_id,
        sender_key: key.agent_uid,
        binding_name: "control-plane:test",
        source_event_id: Ecto.UUID.generate(),
        type: "command.steer",
        payload: %{},
        available_at: DateTime.utc_now(:microsecond)
      })
    end)
  end
end
