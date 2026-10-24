defmodule Ankole.Sessions.RunTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.DataCase, async: false

  import Ankole.SessionsCase, only: [agent_fixture: 0]
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Fence
  alias Ankole.Sessions.Receipts
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.ToolResult
  alias Ankole.Sessions.Wait
  alias Ankole.Signals
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers.AgentWorker

  setup do
    %{principal: agent} = agent_fixture()
    key = %{agent_uid: agent.uid, session_id: "driver:#{System.unique_integer([:positive])}"}

    {:ok, event} =
      Repo.transact(fn ->
        Signals.accept_in_tx(%{
          producer: :kernel,
          target: %{agent_uid: agent.uid, session_id: key.session_id},
          sender: agent.uid,
          source: "test:run",
          subject: "run",
          id: Ecto.UUID.generate(),
          type: "conversation.message.addressed",
          data: %{},
          available_at: DateTime.utc_now(:microsecond)
        })
      end)

    {:ok, key: key, event: event}
  end

  test "queue reads keep ordinary due order separate from strict Job head and started recovery",
       %{key: key, event: first} do
    now = DateTime.utc_now(:microsecond)
    future = DateTime.add(now, 60)
    first = Repo.update!(Ecto.Changeset.change(first, available_at: future))

    [due, started, closed] =
      for {at, suffix} <- [{now, "due"}, {future, "started"}, {now, "closed"}] do
        assert {:ok, signal} =
                 Repo.transact(fn ->
                   Signals.accept_in_tx(%{
                     producer: :kernel,
                     target: key,
                     sender: key.agent_uid,
                     source: "test:queue",
                     id: suffix,
                     type: "custom.queue",
                     data: %{},
                     available_at: at
                   })
                 end)

        signal
      end

    {:ok, started} =
      Repo.transact(fn _repo ->
        Ankole.Ash.update(started, :start_attempt, %{last_attempt_at: now})
      end)

    assert {:ok, _closed} =
             Repo.transact(fn _repo ->
               Ankole.Ash.update(closed, :complete, %{completed_at: now})
             end)

    assert Ankole.Sessions.Queue.due(key, now) |> Enum.map(& &1.id) == [due.id]
    assert Ankole.Sessions.Queue.next_ready_event(key.agent_uid, key.session_id, now).id == due.id

    assert Ankole.Sessions.Queue.oldest_open(key.agent_uid, key.session_id).id == first.id

    assert Ankole.Sessions.Queue.oldest_started(key.agent_uid, key.session_id).id ==
             started.id

    assert Ankole.Sessions.Queue.due(%{key | session_id: "unrelated"}, now) == []
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
          Repo.transact(fn ->
            Signals.accept_in_tx(%{
              producer: :kernel,
              target: %{agent_uid: key.agent_uid, session_id: key.session_id},
              sender: human.uid,
              source: "test:run",
              subject: "run",
              id: Ecto.UUID.generate(),
              type: type,
              data: %{},
              available_at: DateTime.utc_now(:microsecond)
            })
          end)

        input
      end

    assert {:ok, [admitted]} = Run.inject(run, [admitted])
    Repo.update!(Ecto.Changeset.change(human, access_version: human.access_version + 1))
    assert {:ok, [retained]} = Run.inject(run, [admitted, fresh])
    assert retained.id == admitted.id
    assert Repo.reload!(fresh).status == :dead_letter
    assert {:ok, _} = Ankole.Sessions.Commands.process(key, stop)
    assert Repo.reload!(stop).status == :dead_letter
    refute Repo.reload!(event).completed_at
  end

  test "ordinary admission and recovery need no Worker (G1, G2)", %{key: key, event: event} do
    worker = Repo.get!(AgentWorker, key.agent_uid)
    assert {:ok, run} = Admission.admit(key, event)
    assert run.event.attempt_count == 1
    assert run.epoch == 1
    Ankole.DataCase.assert_persisted_equal(Repo.get!(AgentWorker, key.agent_uid), worker)
    assert {:ok, {:preparing, restored}} = Run.restore(run)
    assert restored.signal_id == event.id
  end

  test "suspension rejects a fresh workflow steer without failing its admitted task", %{
    key: key,
    event: source,
    tenant: tenant
  } do
    assert {:ok, %{run: workflow}} =
             Ankole.Workflow.create_with_dispatch(%{
               "agent_uid" => key.agent_uid,
               "owner_session_id" => key.session_id,
               "source_signal_id" => source.id,
               "source_tool_call_id" => "suspended-workflow-steer",
               "title" => "Suspended steer",
               "script" => "return await agent('Review the case');",
               "reply_route" => %{"binding_name" => "bot"}
             })

    Ankole.SessionsCase.stub_workflow_drivers(workflow)

    assert {:ok, %{new_calls: [call]}} =
             Ankole.Workflow.Replay.commit_replay_pending(
               workflow.id,
               [%{namespace: nil, name: "agent", arguments: %{"prompt" => "Review the case"}}],
               0
             )

    dispatch = Repo.get_by!(Signal, source_event_id: "workflow:call:#{call.id}:dispatch")
    task_key = %{agent_uid: key.agent_uid, session_id: dispatch.session_id}
    assert {:ok, %Run{} = admitted} = Admission.admit(task_key, dispatch)

    assert {:ok, %{event: steer}} =
             Ankole.Workflow.send_task_message(
               workflow.id,
               call.call_seq,
               key.agent_uid,
               "New input before suspension.",
               "suspended-steer"
             )

    tenant
    |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()

    assert {:ok, []} = Run.inject(admitted, [steer])
    rejected = Repo.reload!(steer)
    assert %DateTime{} = rejected.completed_at
    assert is_nil(rejected.last_attempt_at)
    assert rejected.status == :completed
    assert Repo.reload!(call).status == :running
    assert Repo.reload!(workflow).status == :running
    refute Repo.reload!(dispatch).completed_at
    assert Repo.reload!(dispatch).last_attempt_at == admitted.event.last_attempt_at
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
        round_state: old,
        metadata: %{"request_metadata" => Ankole.Sessions.Run.metadata(old)}
      })

    {:ok, current} = Admission.admit(key, event)
    assert {:ok, {:preparing, _}} = Run.restore(current)
    assert Repo.get!(Message, live.id).status == :error
    assert {:ok, :already_terminal} = ResponseCommit.commit_complete(live, [])
    assert {:error, :stale_driver} = Repo.transact(fn -> Fence.check_in_tx(old) end)
  end

  test "a committed round keeps its original progress when the same message is recorded again", %{
    key: key,
    event: event
  } do
    assert {:ok, run} = Admission.admit(key, event)
    run = %{run | iteration: 1, truncated_rounds: 2, repaired: true}

    assert {:ok, response} =
             start_response_run(%{
               subject_uid: key.agent_uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Ankole.Sessions.Run.metadata(run)}
             })

    original = Ankole.Sessions.RoundState.get(response)

    assert {:ok, :ok} =
             Repo.transact(fn ->
               :ok =
                 Ankole.Sessions.RoundState.put_in_tx(
                   %{run | iteration: 99, truncated_rounds: 99, repaired: false},
                   response
                 )

               {:ok, :ok}
             end)

    assert Ankole.Sessions.RoundState.get(response) == original
    assert original.iteration == 1
    assert original.truncated_rounds == 2
    assert original.repaired
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
        round_state: run,
        metadata: %{"request_metadata" => Ankole.Sessions.Run.metadata(run)}
      })

    call = %{
      "type" => "function_call",
      "name" => "cron",
      "call_id" => "c1",
      "arguments" => "{}",
      "status" => "completed"
    }

    {:ok, response} = ResponseCommit.commit_complete(response, [call])
    {:ok, {:executing_tools, recovered}} = Run.restore(run)
    assert recovered.calls == [call]

    assert {:ok, _receipt} =
             Receipts.execute(
               run,
               Run.response_id(response),
               "c1",
               prepare_operation(fn _ ->
                 {:ok, %Ankole.Sessions.ToolResult{output: "committed"}, []}
               end)
             )

    assert {:ok, {:executing_tools, recovered}} = Run.restore(run)
    assert recovered.receipts == %{"c1" => %ToolResult{output: "committed"}}
    assert recovered.results == %{}

    recovered = %{
      recovered
      | results: %{"c1" => %Ankole.Sessions.ToolResult{output: "committed"}}
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
        round_state: run,
        metadata: %{"request_metadata" => Ankole.Sessions.Run.metadata(run)}
      })

    call = %{
      "type" => "function_call",
      "name" => "send_message_to_background_job",
      "call_id" => "waiting",
      "arguments" => "{}",
      "status" => "completed"
    }

    {:ok, response} = ResponseCommit.commit_complete(response, [call])
    wait = %Wait{kind: :job, job_id: 1000, command_event_id: event.id, timeout_ms: 30_000}

    assert {:ok, receipt} =
             Receipts.execute(
               run,
               Run.response_id(response),
               "waiting",
               prepare_operation(fn _ ->
                 {:ok, {:await, wait}, []}
               end)
             )

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
          round_state: %{run | steer_event_ids: [steer.id]},
          metadata: %{"request_metadata" => Run.metadata(run)}
        })

      call = %{
        "type" => "function_call",
        "name" => "cron",
        "call_id" => "committed-before-crash",
        "arguments" => "{}",
        "status" => "completed"
      }

      {:ok, response} = ResponseCommit.commit_complete(response, [call])

      {:ok, _} =
        Receipts.execute(
          run,
          Run.response_id(response),
          Run.call_id(call),
          prepare_operation(fn _repo ->
            {:ok, %Ankole.Sessions.ToolResult{output: "committed-before-rejection"}, []}
          end)
        )

      result =
        case unquote(rejection) do
          :exhausted ->
            event
            |> AshPostgres.DataLayer.to_ecto()
            |> Ecto.Changeset.change(%{attempt_count: 5})
            |> Repo.update!()

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
          assert Repo.reload!(event).status == :dead_letter
          assert Repo.reload!(steer).status == :dead_letter

        :profile_unavailable ->
          assert Repo.reload!(event).completed_at
          assert Repo.reload!(steer).completed_at
      end

      refute Repo.reload!(unread).completed_at

      assert {:ok, tail} =
               Ankole.AIGateway.visible_response_suffix(
                 run.agent_uid,
                 run.conversation.id,
                 {"signal_id", event.id}
               )

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
    assert Repo.get!(Signal, event.id).status == :dead_letter
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
    assert Repo.get!(Signal, event.id).attempt_count == 6
    assert Repo.get!(Signal, event.id).status == :dead_letter
  end

  test "terminal decisions consume only input that reached the model tape (G2)", %{
    key: key,
    event: event
  } do
    {:ok, run} = Admission.admit(key, event)
    {:ok, steer} = append_steer(key)
    {:ok, [steer]} = Run.inject(run, [steer])
    run = %{run | steer_event_ids: [steer.id]}
    assert {:ok, _} = Run.finalize(run, :silent)

    assert %Signal{producer: :kernel, completed_at: %DateTime{}, turn_outcome: "silent"} =
             Repo.get!(Signal, event.id)

    assert %Signal{producer: :kernel, completed_at: nil, status: :running} =
             Repo.get!(Signal, steer.id)
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
        round_state: %{run | steer_event_ids: [steer.id], iteration: 1},
        metadata: %{"request_metadata" => metadata}
      })

    {:ok, _} = ResponseCommit.commit_complete(response, [])
    assert run.steer_event_ids == []
    assert {:ok, _} = Run.finalize(run, :silent)

    assert %Signal{producer: :kernel, completed_at: %DateTime{}, turn_outcome: "silent"} =
             Repo.get!(Signal, steer.id)
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
               authorize_run_in_tx: fn -> Fence.check_in_tx(old) end
             )

    refute Repo.exists?(
             from(m in Message,
               where: m.conversation_id == ^old.conversation.id and m.status == :generating
             )
           )
  end

  defp append_steer(key) do
    Repo.transact(fn ->
      Signals.accept_in_tx(%{
        producer: :kernel,
        target: %{agent_uid: key.agent_uid, session_id: key.session_id},
        sender: key.agent_uid,
        source: "test:run",
        subject: "run",
        id: Ecto.UUID.generate(),
        type: "command.steer",
        data: %{},
        available_at: DateTime.utc_now(:microsecond)
      })
    end)
  end

  defp prepare_operation(operation) do
    fn -> {:ok, [], fn -> operation.(Repo) end} end
  end
end
