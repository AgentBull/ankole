defmodule Ankole.Sessions.DriverTest do
  alias Ankole.AIGateway.ResponseChain
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  import Ankole.SessionsCase,
    only: [agent_fixture: 1, cache_actor_runtime_models: 1, cache_actor_runtime_models: 2]

  import Ankole.AIGatewayCase,
    only: [start_upstream_server: 1, chat_completion_body: 2, chat_completion_stream_events: 2]

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Reconciler
  alias Ankole.Sessions.Receipts
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Worker
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.SessionWorkspace
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.Sessions.SessionLane
  alias Ankole.AgentWorkers.WorkerRoute
  alias Ankole.SessionsCase, as: RuntimeCase
  alias Ankole.RuntimeFabric.V1, as: Proto
  alias Ankole.Workflow.Schemas.AgentCall

  setup %{tenant: tenant} do
    drivers = RuntimeCase.driver_pids()
    suffix = Ecto.UUID.generate()

    %{principal: owner} =
      Ankole.PrincipalsFixtures.human_fixture(%{
        email: "driver-#{suffix}@example.com",
        mobile: nil
      })

    %{principal: agent} =
      agent_fixture(%{handle: "agent-driver-#{suffix}", owner_principal_uid: owner.uid})

    owner_principal_uid = owner.uid
    owner_access_version = owner.access_version
    owner = self()

    script =
      start_supervised!(
        {Agent,
         fn ->
           %{calls: [], requests: 0, requests_by_event: %{}, block_first?: false, rounds: nil}
         end}
      )

    url =
      start_upstream_server(fn
        %{method: :get, request_path: "/models"} ->
          {:json, 200,
           %{
             "data" =>
               Enum.map(
                 ["google/gemini-3.5-flash", "openai/gpt-5.4-nano", "openai/gpt-5.6-sol"],
                 fn id ->
                   %{
                     "id" => id,
                     "architecture" => %{"input_modalities" => ["text"]},
                     "top_provider" => %{"max_completion_tokens" => 65536}
                   }
                 end
               )
           }}

        request ->
          if request.body["stream"] != true do
            send(owner, {:model_request, request})

            {:json, 200,
             chat_completion_body(request.body["model"], "A screenshot of a completed chart.")}
          else
            refute Map.has_key?(request.body, "metadata")
            refute Map.has_key?(request.body, "model_profile")

            event_id =
              Repo.with_tenant(tenant.id, fn ->
                Repo.one!(
                  from(m in Message,
                    where: m.subject_uid == ^agent.uid and m.status == "generating",
                    order_by: [desc: m.inserted_at, desc: m.id],
                    limit: 1,
                    select: fragment("?->'request_metadata'->>'signal_id'", m.metadata)
                  )
                )
              end)

            send(owner, {:model_request, Map.put(request, :signal_id, event_id)})

            {round, block?} =
              Agent.get_and_update(script, fn state ->
                round =
                  if Map.get(state, :repeat_until_tool?, false) do
                    if Enum.any?(request.body["messages"] || [], &(&1["role"] == "tool")) do
                      {:text, "The answer is 42."}
                    else
                      {:calls, state.calls}
                    end
                  else
                    if state.rounds do
                      Enum.at(state.rounds, state.requests, {:text, "The answer is 42."})
                    else
                      if state.requests == 0 and state.calls != [] do
                        {:calls, state.calls}
                      else
                        {:text, "The answer is 42."}
                      end
                    end
                  end

                {{round,
                  Map.get(state, :block_all?, false) or
                    (state.requests == Map.get(state, :block_at, 0) and state.block_first?)},
                 %{
                   state
                   | requests: state.requests + 1,
                     requests_by_event:
                       Map.update(
                         state.requests_by_event,
                         event_id,
                         1,
                         &(&1 + 1)
                       )
                 }}
              end)

            if block? do
              model_pid = self()
              send(owner, {:model_waiting, model_pid})

              receive do
                :release_model -> :ok
              after
                30000 -> raise "the test did not release its model response"
              end
            end

            case round do
              {:text, text} ->
                # A vision fallback description is one non-streaming request.
                if request.body["stream"] == true do
                  {:sse, 200, chat_completion_stream_events(request, text)}
                else
                  {:json, 200, chat_completion_body(request.body["model"], text)}
                end

              {:calls, calls} ->
                {:sse, 200, tool_events(request, calls)}

              {:error, status} ->
                {:json, status,
                 %{
                   "error" => %{
                     "code" => "upstream_response_failed",
                     "message" => "Provider rejected the request."
                   }
                 }}
            end
          end
      end)

    {:ok, profile} = ModelProfiles.get_model_profile(agent.uid, "primary")
    {:ok, _} = ProviderConfigs.update_provider(profile["provider_id"], %{base_url: url})
    :ok = cache_actor_runtime_models(profile["provider_id"])
    key = %{agent_uid: agent.uid, session_id: "driver-flow:#{Ecto.UUID.generate()}"}
    worker = Repo.get!(AgentWorker, agent.uid)

    on_exit(
      Repo.bind_tenant(fn ->
        RuntimeCase.stop_new_drivers(drivers)

        case Ankole.Sessions.driver_pid(key) do
          pid when is_pid(pid) -> DynamicSupervisor.terminate_child(Ankole.Sessions.Drivers, pid)
          _missing -> :ok
        end

        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'agent_uid'", j.args) == ^agent.uid)
        )

        :ok = Ankole.AgentWorkers.WorkerEnv.delete_agent_rows_in_tx(Repo, agent.uid)
        Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)
        # The first deletion disables the provider; the second removes it.
        {:ok, _} = ProviderConfigs.delete_provider(profile["provider_id"])
        {:ok, _} = ProviderConfigs.delete_provider(profile["provider_id"])

        cleanup_tenant!(tenant)
      end)
    )

    {:ok,
     key: key,
     worker: worker,
     script: script,
     profile: profile,
     owner_principal_uid: owner_principal_uid,
     owner_access_version: owner_access_version}
  end

  test "the durable wakeup recovers input published before subscription and later hints wake the Driver",
       %{key: key, script: script} do
    assert :undefined = Ankole.Sessions.driver_pid(key)
    assert {:ok, first} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, attrs(key)))
    :ok = Ankole.Sessions.Events.publish_input(key.agent_uid, key.session_id, first.id)
    assert :undefined = Ankole.Sessions.driver_pid(key)

    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
    driver = Ankole.Sessions.driver_pid(key)
    assert is_pid(driver)
    _ = await_request(key)
    assert wait_for_completion(first.id).turn_outcome == "loop_finished"

    assert {:ok, second} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, attrs(key)))
    :ok = Ankole.Sessions.Events.publish_input(key.agent_uid, key.session_id, second.id)
    :ok = Ankole.Sessions.Events.publish_input(key.agent_uid, key.session_id, second.id)
    _ = await_request(key)
    assert wait_for_completion(second.id).turn_outcome == "loop_finished"
    assert Ankole.Sessions.driver_pid(key) == driver
    assert Agent.get(script, & &1.requests) == 2
  end

  test("a gateway HTTP 503 preserves the capacity deadline through driver restart", %{
    key: key,
    script: script
  }) do
    Agent.update(script, &%{&1 | rounds: List.duplicate({:error, 503}, 20)})
    {:ok, event} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, attrs(key)))
    {:ok, driver} = Ankole.Sessions.ensure_driver(key)
    send(driver, :reconcile_inbox)
    _ = await_request(key)
    wait_for_retry(event, 1)
    retried = Repo.reload!(event)
    assert retried.attempt_count == 1
    assert retried.provider_capacity_attempt_count == 1
    assert DateTime.diff(retried.available_at, retried.last_attempt_at) >= 30
    assert :ok = DynamicSupervisor.terminate_child(Ankole.Sessions.Drivers, driver)
    assert Repo.reload!(event).available_at == retried.available_at

    for _ <- List.duplicate(nil, Agent.get(script, & &1.requests) - 1) do
      await_request(key)
    end

    {:ok, restarted} = Ankole.Sessions.ensure_driver(key)
    refute_receive {:model_request, _}, 100
    assert Repo.reload!(event).attempt_count == 1
    Agent.update(script, &%{&1 | rounds: nil})
    Repo.update!(change(retried, available_at: DateTime.utc_now(:microsecond)))
    send(restarted, :reconcile_inbox)
    _ = await_request(key)
    completed = wait_for_completion(event.id)
    assert completed.provider_capacity_attempt_count == 1
    assert completed.attempt_count == 2
  end

  test("an input revision after a capacity failure starts a new admission", %{
    key: key,
    script: script
  }) do
    Agent.update(script, &%{&1 | rounds: List.duplicate({:error, 503}, 20)})
    {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    wait_for_retry(event, 1)

    for _ <- List.duplicate(nil, Agent.get(script, & &1.requests) - 1) do
      await_request(key)
    end

    {:ok, _} =
      Ankole.Signals.accept(%{
        attrs(key)
        | type: "input.revised",
          data: %{
            "revision" => %{
              "signal_id" => event.id,
              "kind" => "edit",
              "entry" => Map.put(event.data["entry"], "text", "Updated after rate limit")
            }
          }
      })

    _ = await_request(key)
    wait_for_retry(event, 2)
    assert Repo.reload!(event).attempt_count == 2
    assert Repo.reload!(event).provider_capacity_attempt_count == 2
  end

  test(
    "capacity and execution failures use separate ladders and retain five execution attempts",
    %{key: key}
  ) do
    alias Ankole.Sessions.Run
    {:ok, event} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, attrs(key)))
    now = DateTime.add(DateTime.utc_now(:microsecond), 1)

    {event, now} =
      Enum.reduce([30, 120, 300, 750, 750, 750], {event, now}, fn delay, {event, now} ->
        {:ok, run} = Admission.admit(key, event, now: now)
        error = %{"code" => "rate_limit_exceeded", "retryable" => true}
        assert {:ok, retried} = Run.defer_retry(run, error, now)
        assert DateTime.diff(retried.available_at, now) == delay
        assert retried.provider_capacity_attempt_count == retried.attempt_count
        assert {:ok, same} = Run.defer_retry(run, error, now)
        assert same == retried
        assert {:ok, :idle} = Run.rebuild(key, DateTime.add(retried.available_at, -1))
        assert {:ok, %{delay_ms: 0}} = Run.rebuild(key, retried.available_at)
        {retried, DateTime.add(retried.available_at, 1)}
      end)

    {event, now} =
      Enum.reduce([5, 10, 20, 40, 80], {event, now}, fn delay, {event, now} ->
        {:ok, run} = Admission.admit(key, event, now: now)

        assert {:ok, retried} =
                 Run.defer_retry(
                   run,
                   %{"code" => "websocket_read_failed", "retryable" => true},
                   now
                 )

        assert DateTime.diff(retried.available_at, now) == delay
        assert retried.provider_capacity_attempt_count == 6
        {retried, DateTime.add(retried.available_at, 1)}
      end)

    assert event.attempt_count == 11
    assert {:ok, %{status: :dead_letter, signal: closed}} = Admission.admit(key, event, now: now)
    assert closed.provider_capacity_attempt_count == 6
    assert closed.attempt_count == 12
  end

  test("credential exhaustion uses the gateway retry_at without changing the execution budget", %{
    key: key
  }) do
    alias Ankole.Sessions.Run
    {:ok, event} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, attrs(key)))
    now = DateTime.add(DateTime.utc_now(:microsecond), 1)
    {:ok, run} = Admission.admit(key, event, now: now)
    deadline = DateTime.add(now, 600)

    error = %{
      "code" => "credential_pool_exhausted",
      "retryable" => true,
      "retry_at" => DateTime.to_iso8601(deadline)
    }

    assert {:ok, retried} = Run.defer_retry(run, error, now)
    assert retried.available_at == deadline
    assert retried.provider_capacity_attempt_count == 1
    assert {:ok, :idle} = Run.rebuild(key, DateTime.add(deadline, -1))
    assert {:ok, %{delay_ms: 0}} = Run.rebuild(key, deadline)
  end

  test("a credential pool exhausted before admission preserves its recovery instant", %{
    key: key,
    profile: profile
  }) do
    alias Ankole.AIGateway.CredentialPool
    {:ok, event} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, attrs(key)))
    {:ok, provider} = ProviderConfigs.fetch_provider(profile["provider_id"])
    deadline = DateTime.add(DateTime.utc_now(:second), 600)

    for credential <- provider.credential_pool["entries"] do
      assert :ok =
               CredentialPool.mark_exhausted(provider.id, credential, 429, %{
                 "x-codex-primary-reset-at" => Integer.to_string(DateTime.to_unix(deadline))
               })
    end

    assert {:ok, driver} = Ankole.Sessions.ensure_driver(key)
    send(driver, :reconcile_inbox)

    assert eventually(fn ->
             DateTime.compare(Repo.reload!(event).available_at, DateTime.utc_now()) == :gt
           end)

    retried = Repo.reload!(event)
    assert DateTime.compare(retried.available_at, deadline) == :eq
    assert retried.provider_capacity_attempt_count == 1
    assert retried.attempt_count == 1
    assert retried.attempt_count - retried.provider_capacity_attempt_count == 0
    refute retried.dead_letter_at
    refute_receive {:model_request, _}, 100
    assert :ok = DynamicSupervisor.terminate_child(Ankole.Sessions.Drivers, driver)
    assert {:ok, _} = Ankole.Sessions.ensure_driver(key)
    assert DateTime.compare(Repo.reload!(event).available_at, deadline) == :eq
    assert Repo.reload!(event).attempt_count == 1
  end

  test("pool exhaustion on retry releases the Run from the prior admission", %{
    key: key,
    profile: profile,
    script: script
  }) do
    Agent.update(script, &%{&1 | rounds: List.duplicate({:error, 503}, 20)})
    {:ok, event} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, attrs(key)))
    {:ok, driver} = Ankole.Sessions.ensure_driver(key)
    send(driver, :reconcile_inbox)
    _ = await_request(key)
    wait_for_retry(event, 1)

    for _ <- List.duplicate(nil, Agent.get(script, & &1.requests) - 1) do
      await_request(key)
    end

    {:ok, provider} = ProviderConfigs.fetch_provider(profile["provider_id"])
    deadline = DateTime.add(DateTime.utc_now(:second), 600)

    for credential <- provider.credential_pool["entries"] do
      assert :ok =
               Ankole.AIGateway.CredentialPool.mark_exhausted(provider.id, credential, 429, %{
                 "x-codex-primary-reset-at" => Integer.to_string(DateTime.to_unix(deadline))
               })
    end

    wait_for_retry(event, 2)
    retried = Repo.reload!(event)
    assert retried.attempt_count == 2
    assert retried.provider_capacity_attempt_count == 2
    assert DateTime.compare(retried.available_at, deadline) == :eq
    refute_receive {:model_request, _}, 100
  end

  @tag timeout: 90000
  test(
    "an expired acquisition stays failed through the next model tool round and commits its answer",
    %{key: key, script: script}
  ) do
    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})

    Agent.update(
      script,
      &%{
        &1
        | block_first?: true,
          rounds: [
            calls: [tool_call("before-expiry", "command", %{"command" => "printf first"})],
            calls: [tool_call("after-expiry", "command", %{"command" => "printf second"})],
            text: "The computer is busy. I can answer without it."
          ]
      }
    )

    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    assert_receive {:model_waiting, provider}, 5000
    Agent.update(script, &Map.put(&1, :block_at, 2))
    started = System.monotonic_time(:millisecond)
    send(provider, :release_model)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, opened}}}, 5000

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:workspace_ready, %Proto.WorkspaceReady{run: opened.run, reason: :CAPACITY}}
               },
               %{worker_id: key.agent_uid}
             )

    second = await_request(key, 65000)
    assert System.monotonic_time(:millisecond) - started >= 59000
    [error] = Enum.filter(second.body["messages"], &(&1["role"] == "tool"))
    assert error["tool_call_id"] == "before-expiry"
    assert error["content"] =~ "busy with other tasks"
    third = await_request(key, 2000)
    errors = Enum.filter(third.body["messages"], &(&1["role"] == "tool"))
    assert Enum.map(errors, & &1["tool_call_id"]) == ["before-expiry", "after-expiry"]
    assert Enum.all?(errors, &(&1["content"] =~ "busy with other tasks"))
    refute_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, _}}}, 100
    refute_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, _}}}, 100
    assert_receive {:model_waiting, final_provider}, 1000
    send(final_provider, :release_model)
    completed = wait_for_completion(event.id)
    assert completed.turn_outcome == "loop_finished"
    assert Agent.get(script, & &1.requests) == 3
    final = Repo.get!(Message, String.replace_prefix(completed.final_response_id, "resp_", ""))

    assert Ankole.Conversations.Delivery.Text.visible_text(final.content) =~
             "I can answer without it"
  end

  test("a rejected Worker open records a safe tool error and continues without probe", %{
    key: key,
    script: script,
    worker: worker
  }) do
    Repo.update!(
      change(worker,
        state: "absent",
        state_changed_at: DateTime.add(DateTime.utc_now(:microsecond), -3600),
        last_error: "fixture start failure",
        last_error_kind: "rejected",
        transport_route: nil
      )
    )

    Agent.update(
      script,
      &%{&1 | calls: [tool_call("open-error", "command", %{"command" => "printf done"})]}
    )

    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    next = await_request(key)
    [result] = Enum.filter(next.body["messages"], &(&1["role"] == "tool"))
    assert result["tool_call_id"] == "open-error"
    assert result["content"] =~ "administrator must fix it in the Console"
    refute result["content"] =~ "fixture start failure"
    refute result["content"] =~ "unknown_route"
    assert wait_for_completion(event.id).turn_outcome == "loop_finished"
    assert Agent.get(script, & &1.requests) == 2
    refute_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, _}}}, 100
  end

  for reason <- [:unknown_route, :stale_route, :socket_closed, :backpressure, :timeout] do
    @tag workspace_send_error: reason
    test("WorkerRoute owns #{reason} classification and preserves the current route fence", %{
      key: key,
      script: script,
      workspace_send_error: reason
    }) do
      route = RuntimeCase.unique_route()
      incarnation = "open-owner-" <> Ecto.UUID.generate()

      assert {:ok, original} =
               RuntimeCase.admit_worker(route, %{
                 worker_id: key.agent_uid,
                 incarnation_id: incarnation
               })

      if reason != :unknown_route do
        owner = self()

        start_supervised!(
          {Task,
           fn ->
             meta =
               WorkerRoute.directory_meta(
                 if reason == :stale_route do
                   "old"
                 else
                   incarnation
                 end
               )

             assert {:ok, _} =
                      Phoenix.Tracker.track(
                        Ankole.AgentWorkers.WorkerTracker,
                        self(),
                        WorkerRoute.topic(key.agent_uid),
                        route,
                        meta
                      )

             send(owner, {:workspace_failure_channel, self()})

             receive do
               {:"$gen_call", from, {:deliver, envelope}} ->
                 send(owner, {:workspace_failure_send, envelope})
                 GenServer.reply(from, {:error, reason})
             end

             receive do
               :stop -> :ok
             end
           end}
        )

        assert_receive {:workspace_failure_channel, _channel}, 1000
      end

      Agent.update(script, &%{&1 | block_first?: true})
      assert {:ok, event} = Ankole.Signals.accept(attrs(key))
      _ = await_request(key)
      assert_receive {:model_waiting, provider}, 5000
      :ok
      run = stored_run(key, event)
      assert {:ok, row, message} = Worker.prepare_open(run)
      assert Worker.send_open(row, message) == {:wait, :retrying}
      current = Repo.get!(AgentWorker, key.agent_uid)
      assert current.generation == original.generation
      assert current.incarnation_id == original.incarnation_id

      if reason in [:unknown_route, :socket_closed] do
        assert current.state == "stale"
        assert current.transport_route == nil
      else
        assert current.state == "ready"
        assert current.transport_route == route
      end

      if reason in [:socket_closed, :backpressure, :timeout] do
        assert_receive {:workspace_failure_send,
                        %Proto.Envelope{body: {:workspace_open, opened}}},
                       1000

        assert opened.run == Worker.ref(run)
      else
        refute_receive {:workspace_failure_send, _}, 100
      end

      send(provider, :release_model)
      assert wait_for_completion(event.id).turn_outcome == "loop_finished"
    end
  end

  @tag :worker_replacement_regression
  test "a live Driver probes a sent command after Worker replacement without executing it twice",
       %{key: key, script: script} do
    route = RuntimeCase.unique_route()
    next_route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    :ok = WorkerRoute.register_local_worker(next_route, self())

    on_exit(fn ->
      WorkerRoute.unregister_local_worker(route)
      WorkerRoute.unregister_local_worker(next_route)
    end)

    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})

    Agent.update(
      script,
      &%{&1 | calls: [tool_call("once", "command", %{"command" => "printf side-effect"})]}
    )

    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    ready_workspace(key)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, original}}}, 5000
    assert original.mode == "execute"
    driver = Ankole.Sessions.driver_pid(key)

    assert {:ok, :marked_stale} =
             Ankole.AgentWorkers.WorkerAdmission.mark_route_unusable(route, :socket_closed)

    assert {:ok, _} =
             RuntimeCase.admit_worker(next_route, %{
               worker_id: key.agent_uid,
               incarnation_id: "replacement"
             })

    ready_workspace(key)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, probe}}}, 5000
    assert probe.mode == "probe"

    assert {probe.call_id, probe.response_id, probe.run} ==
             {original.call_id, original.response_id, original.run}

    assert Ankole.Sessions.driver_pid(key) == driver

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:tool_status,
                    %Proto.ToolStatus{
                      run: probe.run,
                      response_id: probe.response_id,
                      call_id: probe.call_id,
                      state: "unknown"
                    }}
               },
               %{worker_id: key.agent_uid}
             )

    next = await_request(key)

    assert [%{"tool_call_id" => "once", "content" => content}] =
             Enum.filter(next.body["messages"], &(&1["role"] == "tool"))

    assert content =~ "interrupted"
    assert wait_for_completion(event.id).attempt_count == 1
    refute_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, _}}}, 100
  end

  for recovered? <- [false, true] do
    @tag adopted_worker_call: recovered?
    test(
      "a missing route retains #{if recovered? do
        "adopted"
      else
        "fresh"
      end} calls until the same Worker rejoins",
      %{key: key, script: script, adopted_worker_call: recovered?}
    ) do
      old_route = RuntimeCase.unique_route()
      route = RuntimeCase.unique_route()
      incarnation = "retained-" <> Ecto.UUID.generate()

      if recovered? do
        WorkerRoute.register_local_worker(old_route, self())
      end

      on_exit(fn -> WorkerRoute.unregister_local_worker(old_route) end)

      assert {:ok, original} =
               RuntimeCase.admit_worker(old_route, %{
                 worker_id: key.agent_uid,
                 incarnation_id: incarnation
               })

      Agent.update(
        script,
        &%{&1 | calls: [tool_call("route-gap", "command", %{"command" => "printf done"})]}
      )

      assert {:ok, event} = Ankole.Signals.accept(attrs(key))
      _ = await_request(key)

      original_call =
        if recovered? do
          ready_workspace(key)
          assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, call}}}, 5000
          assert call.mode == "execute"

          assert :ok =
                   DynamicSupervisor.terminate_child(
                     Ankole.Sessions.Drivers,
                     Ankole.Sessions.driver_pid(key)
                   )

          :ok = WorkerRoute.unregister_local_worker(old_route)
          assert {:ok, _} = Ankole.Sessions.ensure_driver(key)
          call
        end

      wait_for_worker_request(key)
      assert eventually(fn -> Repo.get!(AgentWorker, key.agent_uid).state == "stale" end)
      stale = Repo.get!(AgentWorker, key.agent_uid)
      assert stale.state == "stale"
      assert stale.transport_route == nil
      assert stale.generation == original.generation
      assert stale.incarnation_id == original.incarnation_id
      assert Ankole.Sessions.RoundState.get(latest_response(key)).results == %{}
      refute_receive {:model_request, _}, 100
      assert Repo.reload!(event).completed_at == nil
      :ok = WorkerRoute.register_local_worker(route, self())
      on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)

      assert {:ok, rejoined} =
               RuntimeCase.admit_worker(route, %{
                 worker_id: key.agent_uid,
                 incarnation_id: incarnation
               })

      assert rejoined.generation == original.generation
      assert rejoined.incarnation_id == original.incarnation_id
      assert_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, opened}}}, 5000

      assert :ok =
               SessionLane.handle(
                 %Proto.Envelope{
                   body: {:workspace_ready, %Proto.WorkspaceReady{run: opened.run}}
                 },
                 %{worker_id: key.agent_uid}
               )

      assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, call}}}, 5000

      assert call.mode ==
               (if recovered? do
                  "probe"
                else
                  "execute"
                end)

      assert call.call_id == "route-gap"

      if recovered? do
        assert call.run == original_call.run
        assert call.response_id == original_call.response_id
        assert call.call_id == original_call.call_id
      end

      complete_worker_call(key, call)
      next = await_request(key)
      [output] = Enum.filter(next.body["messages"], &(&1["role"] == "tool"))
      assert output["tool_call_id"] == "route-gap"
      assert output["content"] == "done"
      assert wait_for_completion(event.id).turn_outcome == "loop_finished"
      assert Agent.get(script, & &1.requests) == 2
      refute_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, _}}}, 100
    end
  end

  test("an expired transient failure renews demand and completes after a Worker joins", %{
    key: key,
    script: script,
    worker: worker
  }) do
    Repo.update!(
      change(worker,
        last_error: "temporary platform outage",
        last_error_kind: "transient",
        wanted_until: DateTime.add(DateTime.utc_now(), -600)
      )
    )

    Agent.update(
      script,
      &%{&1 | calls: [tool_call("retry-computer", "command", %{"command" => "printf done"})]}
    )

    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    wait_for_worker_request(key)

    assert DateTime.compare(
             Repo.get!(AgentWorker, key.agent_uid).wanted_until,
             DateTime.utc_now()
           ) == :gt

    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})
    ready_workspace(key)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, call}}}, 5000
    assert call.mode == "execute"
    complete_worker_call(key, call)
    next = await_request(key)
    assert Enum.any?(next.body["messages"], &(&1["role"] == "tool" and &1["content"] == "done"))
    assert wait_for_completion(event.id).turn_outcome == "loop_finished"
  end

  for failure <- [:configuration, :platform_rejection] do
    test("a waiting tool reports #{failure} after one production reconciliation step", %{
      key: key,
      script: script
    }) do
      Agent.update(
        script,
        &%{&1 | calls: [tool_call("rejected-computer", "command", %{"command" => "printf done"})]}
      )

      assert {:ok, event} = Ankole.Signals.accept(attrs(key))
      _ = await_request(key)
      wait_for_worker_request(key)
      provider_id = Repo.get!(AgentWorker, key.agent_uid).provider_id

      case unquote(failure) do
        :configuration ->
          Repo.update_all(
            from(p in Ankole.AgentWorkers.Providers.Provider,
              where: p.provider_id == ^provider_id
            ),
            set: [config: "unknown: true\n"]
          )

        :platform_rejection ->
          previous = Application.get_env(:ankole, :docker_api_req_options)

          Application.put_env(:ankole, :docker_api_req_options,
            plug: {Req.Test, :acquisition_rejection}
          )

          on_exit(fn ->
            if previous do
              Application.put_env(:ankole, :docker_api_req_options, previous)
            else
              Application.delete_env(:ankole, :docker_api_req_options)
            end
          end)

          Req.Test.stub(:acquisition_rejection, fn conn ->
            path = String.replace_prefix(conn.request_path, "/v1.42", "")

            case {conn.method, path} do
              {"GET", "/containers/json"} ->
                Req.Test.json(conn, [])

              {"GET", "/images/" <> _} ->
                Req.Test.json(conn, %{})

              {"POST", "/volumes/create"} ->
                {:ok, body, conn} = Plug.Conn.read_body(conn)

                conn
                |> Plug.Conn.put_status(201)
                |> Req.Test.json(Ankole.JSON.decode!(body) |> Map.put("Options", %{}))

              {"POST", "/containers/create"} ->
                conn
                |> Plug.Conn.put_status(400)
                |> Req.Test.json(%{"message" => "raw platform rejection"})

              other ->
                flunk("Unexpected Docker request: #{inspect(other)}")
            end
          end)
      end

      started = System.monotonic_time(:millisecond)

      assert {:error, _} =
               perform_job(Ankole.AgentWorkers.ReconcileJob, %{agent_uid: key.agent_uid})

      assert %{state: "absent", last_error_kind: "rejected"} =
               Repo.get!(AgentWorker, key.agent_uid)

      next = await_request(key, 5000)
      assert System.monotonic_time(:millisecond) - started < 5000
      [output] = Enum.filter(next.body["messages"], &(&1["role"] == "tool"))
      assert output["content"] =~ "administrator must fix it in the Console"
      refute output["content"] =~ "raw platform rejection"
      assert wait_for_completion(event.id).turn_outcome == "loop_finished"
    end
  end

  @tag timeout: 90000
  test(
    "a full computer returns every queued call within one real 60 second acquisition deadline",
    %{key: key, script: script}
  ) do
    calls =
      for id <- 1..6 do
        tool_call("busy-#{id}", "command", %{"command" => "printf #{id}"})
      end

    Agent.update(script, &%{&1 | calls: calls})
    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, opened}}}, 5000

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:workspace_ready, %Proto.WorkspaceReady{run: opened.run, reason: :CAPACITY}}
               },
               %{worker_id: key.agent_uid}
             )

    started = System.monotonic_time(:millisecond)
    next = await_request(key, 65000)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 59000 and elapsed < 63000
    outputs = Enum.filter(next.body["messages"], &(&1["role"] == "tool"))
    assert length(outputs) == length(calls)
    assert Enum.all?(outputs, &String.contains?(&1["content"], "busy with other tasks"))
    assert wait_for_completion(event.id).turn_outcome == "loop_finished"
    refute_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, _}}}, 100
  end

  test("a used workspace closes in the background while the next input is admitted", %{
    key: key,
    script: script
  }) do
    owner = self()
    route = RuntimeCase.unique_route()

    :ok =
      WorkerRoute.register_local_worker(route, fn envelope ->
        case envelope.body do
          {:workspace_close, _} ->
            send(owner, {:close_pending, self()})

            receive do
              :release_close -> :ok
            after
              10000 -> raise "test did not release workspace close"
            end

          _ ->
            send(owner, {:actor_lane, envelope})
            :ok
        end
      end)

    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})

    Agent.update(
      script,
      &%{&1 | calls: [tool_call("close-computer", "command", %{"command" => "printf done"})]}
    )

    assert {:ok, first} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    ready_workspace(key)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, call}}}, 5000
    complete_worker_call(key, call)
    _ = await_request(key)
    assert wait_for_completion(first.id).turn_outcome == "loop_finished"
    assert_receive {:close_pending, closing}, 5000
    started = System.monotonic_time(:millisecond)
    assert {:ok, second} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key, 2000)
    assert System.monotonic_time(:millisecond) - started < 2000
    assert wait_for_completion(second.id).turn_outcome == "loop_finished"
    assert Process.alive?(closing)
    send(closing, :release_close)
    refute_receive {:actor_lane, _}, 100
  end

  test("pure questions send zero Worker messages even with a connected unresponsive computer", %{
    key: key
  }) do
    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})

    for _ <- 1..2 do
      assert {:ok, event} = Ankole.Signals.accept(attrs(key))
      _ = await_request(key, 2000)
      assert wait_for_completion(event.id).turn_outcome == "loop_finished"
    end

    refute_receive {:actor_lane, _}, 100
  end

  defp complete_worker_call(key, call) do
    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:tool_result,
                    %Proto.ToolResult{
                      run: call.run,
                      response_id: call.response_id,
                      call_id: call.call_id,
                      content_json: Ankole.JSON.encode!([%{"type" => "text", "text" => "done"}]),
                      details_json: "{}"
                    }}
               },
               %{worker_id: key.agent_uid}
             )
  end

  @tag :cluster
  @tag timeout: 120_000
  test(
    "two BEAM nodes share one writer, recover planned shutdown, and invalidate settings (G1, G2, G5, G6, G7)",
    %{key: key, script: script, worker: worker}
  ) do
    {peer, remote} = start_peer!()
    cold_key = %{key | session_id: key.session_id <> ":cold"}
    assert :undefined = Ankole.Sessions.driver_pid(cold_key)
    caller = self()

    claims =
      for i <- 1..8 do
        Task.async(fn ->
          send(caller, {:claim_ready, self()})

          receive do
            :claim ->
              Repo.with_tenant(worker.tenant_id, fn ->
                if rem(i, 2) == 0,
                  do:
                    tenant_rpc(remote, worker.tenant_id, Ankole.Sessions, :ensure_driver, [
                      cold_key
                    ]),
                  else: Ankole.Sessions.ensure_driver(cold_key)
              end)
          end
        end)
      end

    for task <- claims do
      pid = task.pid
      assert_receive {:claim_ready, ^pid}, 5_000
    end

    Enum.each(claims, &send(&1.pid, :claim))
    results = Task.await_many(claims, 30_000)
    assert [{:ok, cold_driver} | _] = results
    assert Enum.all?(results, &(&1 == {:ok, cold_driver}))

    assert :ok =
             :rpc.call(node(cold_driver), DynamicSupervisor, :terminate_child, [
               Ankole.Sessions.Drivers,
               cold_driver
             ])

    definition = Ankole.Sessions.AgentConfig.max_iterations_definition()
    opts = []

    assert {:ok, before} =
             tenant_rpc(remote, worker.tenant_id, Ankole.AppConfigure, :resolve, [
               definition,
               opts
             ])

    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key(definition.key, before.value + 1)
    on_exit(Repo.bind_tenant(fn -> Ankole.AppConfigure.delete_tenant_by_key(definition.key) end))

    assert eventually(fn ->
             case tenant_rpc(remote, worker.tenant_id, Ankole.AppConfigure, :resolve, [
                    definition,
                    opts
                  ]) do
               {:ok, value} -> value.value == before.value + 1
               _ -> false
             end
           end)

    Agent.update(script, &Map.put(&1, :block_all?, true))
    assert {:ok, input} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    assert_receive {:model_waiting, first_model}, 10000
    first = Ankole.Sessions.driver_pid(key)
    old_run = stored_run(key, input)

    assert {:ok, ^first} =
             tenant_rpc(remote, worker.tenant_id, Ankole.Sessions, :ensure_driver, [key])

    claimed =
      Task.async_stream(1..8, fn i ->
        Repo.with_tenant(worker.tenant_id, fn ->
          if rem(i, 2) == 0 do
            tenant_rpc(remote, worker.tenant_id, Ankole.Sessions, :ensure_driver, [key])
          else
            Ankole.Sessions.ensure_driver(key)
          end
        end)
      end)
      |> Enum.to_list()

    assert Enum.all?(claimed, &(&1 == {:ok, {:ok, first}}))
    assert :ok = DynamicSupervisor.terminate_child(Ankole.Sessions.Drivers, first)
    assert Repo.reload!(input).attempt_count == 0

    assert {:ok, second} =
             tenant_rpc(remote, worker.tenant_id, Ankole.Sessions, :ensure_driver, [key])

    assert node(second) == remote
    assert eventually(fn -> session_workspace(key).epoch > old_run.epoch end)
    assert Repo.reload!(input).attempt_count == 1
    _ = await_request(key)
    assert_receive {:model_waiting, second_model}, 10000

    assert {:error, :stale_driver} =
             Repo.transact(fn repo -> Ankole.Sessions.Fence.check_in_tx(repo, old_run) end)

    assert :ok = :rpc.call(remote, Application, :stop, [:ankole], 30000)
    assert Repo.reload!(input).attempt_count == 0
    :ok = :peer.stop(peer)
    assert eventually(fn -> Ankole.Sessions.driver_pid(key) == :undefined end)
    reconcile_at = DateTime.add(DateTime.utc_now(:microsecond), 61)
    # The crash backoff is made due in durable state; exercise the site worker.
    Repo.update!(change(Repo.reload!(input), available_at: DateTime.add(reconcile_at, -62)))
    assert :ok = perform_job(Reconciler, %{})
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: reconcile_at)
    assert eventually(fn -> session_workspace(key).epoch > old_run.epoch + 1 end)
    _ = await_request(key)
    assert_receive {:model_waiting, third_model}, 10000
    send(first_model, :release_model)
    send(second_model, :release_model)
    send(third_model, :release_model)
    assert wait_for_completion(input.id).attempt_count == 1

    messages =
      Repo.all(
        from(m in Message, where: m.conversation_id == ^old_run.conversation.id, select: m.id)
      )

    old_run = %{old_run | anchor: ResponseChain.latest_visible_leaf(old_run.conversation.id)}
    assert {:error, :stale_driver} = Ankole.Sessions.Model.open(old_run, self())

    assert Repo.all(
             from(m in Message,
               where: m.conversation_id == ^old_run.conversation.id,
               select: m.id
             )
           ) == messages

    assert Repo.get!(AgentWorker, key.agent_uid) == worker
  end

  @tag :cluster
  @tag timeout: 120_000
  test(
    "WorkerRoute reaches a tracked channel on another BEAM node and rejects a stale incarnation (G7)",
    %{key: key}
  ) do
    {_peer, remote} = start_peer!()
    route = RuntimeCase.unique_route()
    :ok = Ankole.AIGatewayCase.put_ready_worker!(key.agent_uid, route)
    worker = Repo.get!(AgentWorker, key.agent_uid)

    assert {:ok, channel} =
             :rpc.call(remote, Ankole.AgentWorkers.LocalWorkerRoutes, :start_tracked_channel, [
               worker,
               self()
             ])

    assert_receive {:tracked_channel, ^channel}, 10000

    assert eventually(fn ->
             Phoenix.Tracker.get_by_key(
               Ankole.AgentWorkers.WorkerTracker,
               WorkerRoute.topic(key.agent_uid),
               route
             ) != []
           end)

    envelope = %Proto.Envelope{message_id: "cluster-route-probe"}
    target = %{worker_id: key.agent_uid, transport_route: route}
    assert {:ok, :sent_or_queued} = WorkerRoute.send_mandatory(target, envelope)
    assert_receive {:tracked_delivery, ^channel, ^envelope}, 5000
    worker |> Ecto.Changeset.change(incarnation_id: Ecto.UUID.generate()) |> Repo.update!()
    assert {:error, :stale_route} = WorkerRoute.send_mandatory(target, envelope)
    refute_receive {:tracked_delivery, ^channel, _envelope}, 100
  end

  defp tenant_rpc(remote, tenant_id, module, function, args) do
    # The ExUnit module exists only on this node. Build the callback on the peer.
    case :rpc.call(remote, Code, :eval_string, [
           "Ankole.Repo.with_tenant(tenant_id, fn -> apply(module, function, args) end)",
           [tenant_id: tenant_id, module: module, function: function, args: args]
         ]) do
      {:badrpc, _reason} = error -> error
      {result, _bindings} -> result
    end
  end

  defp start_peer! do
    assert Node.alive?(),
           "Run this suite with elixir --sname ankole_session_checks -S mix test integration/session_driver_test.exs"

    name = String.to_atom("ankole_peer_#{System.unique_integer([:positive])}")

    {:ok, peer, remote} =
      :peer.start(%{
        name: name,
        longnames: :net_kernel.longnames(),
        host:
          node() |> Atom.to_string() |> String.split("@") |> List.last() |> String.to_charlist(),
        connection: :standard_io,
        args:
          [~c"+S", ~c"2:2", ~c"-setcookie", Atom.to_charlist(Node.get_cookie()), ~c"-pa"] ++
            :code.get_path(),
        wait_boot: 30000
      })

    on_exit(fn ->
      if Process.alive?(peer) do
        :peer.stop(peer)
      end
    end)

    config =
      Enum.map(Application.loaded_applications(), fn {app, _, _} ->
        {app, Application.get_all_env(app)}
      end)

    :ok = :peer.call(peer, Application, :put_all_env, [config])

    repo =
      Application.get_env(:ankole, Repo)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 4)

    :ok = :peer.call(peer, Application, :put_env, [:ankole, Repo, repo])
    assert {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ankole], 30000)
    assert true == :peer.call(peer, Node, :connect, [node()])
    :ok = :global.sync()
    :ok = :rpc.call(remote, :global, :sync, [])
    {peer, remote}
  end

  defp eventually(fun, remaining \\ 200)

  defp eventually(_fun, 0) do
    false
  end

  defp eventually(fun, remaining) do
    if fun.() do
      true
    else
      receive do
      after
        25 -> eventually(fun, remaining - 1)
      end
    end
  end

  test(
    "a Workflow empty turn retries on the same tape and submits without losing its open trigger (G1, G2, G4)",
    %{key: owner, script: script, worker: worker}
  ) do
    Agent.update(
      script,
      &%{
        &1
        | rounds: [
            text: " \n ",
            text: "",
            calls: [tool_call("submit", "submit_result", %{"result" => true})]
          ]
      }
    )

    {key, event, call} = workflow_task(owner)
    {:ok, _} = Ankole.Sessions.ensure_driver(key)
    first = await_request(key)
    repair = await_request(key)

    expected =
      ~w(create_background_job send_message_to_background_job show_background_job_details stop_background_job sleep submit_result web_fetch)

    names = Enum.map(first.body["tools"], &get_in(&1, ["function", "name"]))
    assert Enum.all?(expected, &(&1 in names)), inspect(names)
    assert Enum.all?(names -- expected, &(&1 in ~w(recall get_page entity whoknows delta)))

    assert Enum.map(repair.body["tools"], &get_in(&1, ["function", "name"])) |> Enum.sort() == [
             "sleep",
             "submit_result"
           ]

    retry = await_request(key)
    assert Enum.map(retry.body["tools"], &get_in(&1, ["function", "name"])) == names
    assert wait_for_completion(event.id).completed_at
    stored = Repo.get!(Ankole.Workflow.Schemas.AgentCall, call.id)
    assert stored.status == "succeeded"
    assert stored.attempts == 2
    assert stored.result == %{"ok" => true, "value" => true}
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
    refute_receive {:model_request, _}, 100
  end

  @tag :b17_progress
  test("a real Workflow Driver renews progress between rounds and still submits its result", %{
    key: owner,
    script: script,
    worker: worker
  }) do
    {key, event, call, _driver} = progressing_workflow(script, owner)
    _first = await_request(key)
    assert_receive {:model_waiting, first_model}, 10000
    stale_at = DateTime.add(DateTime.utc_now(:microsecond), -7200)
    Repo.update!(Ecto.Changeset.change(Repo.reload!(call), updated_at: stale_at))
    send(first_model, :release_model)
    second = await_request(key)
    assert_receive {:model_waiting, second_model}, 10000
    assert Enum.any?(second.body["messages"], &(&1["role"] == "tool"))
    assert DateTime.after?(Repo.reload!(call).updated_at, stale_at)
    now = DateTime.utc_now(:microsecond)

    assert {:ok, %{reconciled: 0}} =
             Ankole.Workflow.reconcile_stale_tasks(call.run_id, DateTime.add(now, -3600), now)

    assert %AgentCall{status: "running", attempts: 1} = Repo.reload!(call)
    send(second_model, :release_model)
    assert wait_for_completion(event.id).completed_at
    assert %AgentCall{status: "succeeded", attempts: 1} = Repo.reload!(call)
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
    refute_receive {:model_request, _}, 100
  end

  @tag :b17_progress
  test("cancellation waits for a locked round commit and then closes the real task", %{
    key: owner,
    script: script
  }) do
    {key, event, call, driver} = progressing_workflow(script, owner)
    _first = await_request(key)
    assert_receive {:model_waiting, first_model}, 10000
    handler = hold_workflow_progress(driver)
    send(first_model, :release_model)
    assert_receive {:workflow_progress_locked, ^driver, backend}, 10000

    cancel =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact(fn repo ->
            Ankole.Workflow.cancel_in_tx(repo, call.run_id, key.agent_uid)
          end)
        end)
      )

    assert_blocked_by(backend)
    send(driver, :continue_workflow_progress)
    assert {:ok, %{run: %{status: "cancelled"}} = cancelled} = Task.await(cancel, 10000)
    :telemetry.detach(handler)
    assert Repo.reload!(call).status == "cancelled"
    assert {:ok, _} = Ankole.Workflow.cleanup_terminal_transition({:ok, cancelled})
    assert wait_for_completion(event.id).completed_at
    assert Repo.reload!(call).status == "cancelled"
  end

  @tag :b17_progress
  test("a real late round waits for reclaim and cannot renew the newer attempt", %{
    key: owner,
    script: script
  }) do
    {key, _event, call, driver} = progressing_workflow(script, owner)
    _first = await_request(key)
    assert_receive {:model_waiting, first_model}, 10000
    now = DateTime.utc_now(:microsecond)
    Repo.update!(Ecto.Changeset.change(Repo.reload!(call), updated_at: DateTime.add(now, -7200)))
    parent = self()

    reclaim =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.transact(fn repo ->
            assert {:ok, %{reconciled: 1}} =
                     Ankole.Workflow.reconcile_stale_tasks(
                       call.run_id,
                       DateTime.add(now, -3600),
                       now
                     )

            assert {:ok, %{call: %{attempts: 2} = current}} =
                     Ankole.Workflow.claim_task_in_tx(repo, call.id, key.agent_uid, 8)

            %{rows: [[backend]]} = repo.query!("SELECT pg_backend_pid()")
            send(parent, {:workflow_reclaimed_locked, self(), backend})

            receive do
              :commit_workflow_reclaim -> {:ok, current}
            after
              10000 -> raise "the Workflow reclaim was not released"
            end
          end)
        end)
      )

    assert_receive {:workflow_reclaimed_locked, reclaimer, backend}, 10000
    send(first_model, :release_model)
    assert_blocked_by(backend)
    send(reclaimer, :commit_workflow_reclaim)
    assert {:ok, reclaimed} = Task.await(reclaim, 10000)
    second = await_request(key)
    assert_receive {:model_waiting, second_model}, 10000
    assert Enum.any?(second.body["messages"], &(&1["role"] == "tool"))
    assert Repo.reload!(call) == reclaimed
    assert reclaimed.status == "running"
    assert reclaimed.attempts == 2
    assert :ok = DynamicSupervisor.terminate_child(Ankole.Sessions.Drivers, driver)
    send(second_model, :release_model)
  end

  defp progressing_workflow(script, owner) do
    Agent.update(
      script,
      &Map.merge(&1, %{
        block_all?: true,
        rounds: [
          calls: [tool_call("progress", "show_background_job_details", %{"job_id" => 9_999_999})],
          calls: [tool_call("submit", "submit_result", %{"result" => true})]
        ]
      })
    )

    {key, event, call} = workflow_task(owner)
    {:ok, driver} = Ankole.Sessions.ensure_driver(key)
    {key, event, call, driver}
  end

  defp hold_workflow_progress(driver) do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == driver and String.contains?(metadata.query, "workflow_agent_calls") and
               String.contains?(metadata.query, "FOR UPDATE") do
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:workflow_progress_locked, self(), backend})

            receive do
              :continue_workflow_progress -> :ok
            after
              10000 -> raise "the Workflow progress lock was not released"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  defp assert_blocked_by(backend) do
    assert eventually(fn ->
             %{rows: rows} =
               Repo.query!(
                 "SELECT pid FROM pg_stat_activity WHERE datname = current_database() AND $1 = ANY(pg_blocking_pids(pid))",
                 [backend]
               )

             rows != []
           end)
  end

  @tag :subtraction_delivery
  test("a committed Workflow dispatch starts the real Driver without a manual wake", %{
    key: owner,
    script: script
  }) do
    Agent.update(
      script,
      &%{&1 | rounds: [calls: [tool_call("submit", "submit_result", %{"result" => true})]]}
    )

    {key, event, call} = workflow_task(owner, deliver_after_commit?: true)
    _ = await_request(key)
    assert wait_for_completion(event.id).completed_at

    assert %AgentCall{status: "succeeded", result: %{"ok" => true, "value" => true}} =
             Repo.reload!(call)
  end

  @tag :subtraction_delivery
  test("a committed attention sleep wakes the real owner Driver", %{key: owner, script: script}) do
    Agent.update(
      script,
      &%{
        &1
        | rounds: [
            calls: [tool_call("sleep", "sleep", workflow_ending_args("sleep"))],
            text: "I will answer the task."
          ]
      }
    )

    {key, event, call} = workflow_task(owner, deliver_after_commit?: true)
    _ = await_request(key)
    assert wait_for_completion(event.id).completed_at
    wake_committed_session!(owner)
    _ = await_request(owner)
    assert %AgentCall{status: "sleeping", attention: true} = Repo.reload!(call)

    attention =
      Repo.get_by!(Signal,
        agent_uid: owner.agent_uid,
        session_id: owner.session_id,
        type: "workflow.run.attention"
      )

    assert wait_for_completion(attention.id).completed_at
  end

  test(
    "Workflow prose followed by an empty repair is a terminal schema failure (G2, G4, G8)",
    %{key: owner, script: script}
  ) do
    Agent.update(script, &%{&1 | rounds: [text: "I have completed the task.", text: ""]})
    {key, event, call} = workflow_task(owner)
    {:ok, _} = Ankole.Sessions.ensure_driver(key)
    _ = await_request(key)
    _ = await_request(key)
    assert wait_for_completion(event.id).completed_at
    stored = Repo.get!(Ankole.Workflow.Schemas.AgentCall, call.id)
    assert stored.status == "failed"
    assert stored.attempts == 1
    assert stored.error["code"] == "schema_noncompliance"
    refute_receive {:model_request, _}, 100
  end

  for tool <- ["sleep", "submit_result"],
      attempt <- 1..3,
      boundary <- [:receipt_committed, :round_recorded],
      suspended? <- [false, true] do
    @tag terminal_tool: tool,
         workflow_attempt: attempt,
         boundary: boundary,
         suspended?: suspended?
    test(
      "Workflow #{tool} attempt #{attempt} survives Driver loss after #{boundary} with suspended=#{suspended?}",
      %{
        key: owner,
        script: script,
        worker: worker,
        terminal_tool: tool,
        workflow_attempt: attempt,
        boundary: boundary,
        suspended?: suspended?
      }
    ) do
      args = workflow_ending_args(tool)
      Agent.update(script, &%{&1 | calls: [tool_call("end", tool, args)]})
      {key, event, call} = workflow_task(owner, sibling?: tool == "sleep", concurrency: 1)

      # Earlier failed attempts are fixture state; the next claim, model stream,
      # tool transaction, tape commit and Driver replacement use the real path.
      Repo.update!(change(call, attempts: attempt - 1))
      handler = hold_workflow_commit(boundary)
      {:ok, first} = Ankole.Sessions.ensure_driver(key)
      _ = await_request(key)
      assert_receive {:workflow_commit, writer}, 10000
      stored_call = Repo.reload!(call)
      assert Repo.reload!(event).completed_at == nil

      [response] =
        Repo.all(
          from(m in Message,
            where:
              m.subject_uid == ^key.agent_uid and
                fragment("?->'request_metadata'->>'signal_id'", m.metadata) == ^event.id and
                fragment("COALESCE(?->>'tool_result_journal', 'false')", m.metadata) != "true"
          )
        )

      assert Ankole.Sessions.RoundState.get(response).workflow_attempt == attempt
      kill_driver(first)
      :telemetry.detach(handler)
      send(writer, :continue_workflow_commit)

      if suspended? do
        suspend_driver_tenant()
      end

      {:ok, replacement} = Ankole.Sessions.ensure_driver(key)
      assert replacement != first
      assert_workflow_ending(key, event, stored_call, tool, script, worker)

      if tool == "sleep" and not suspended? do
        sibling = Repo.get_by!(AgentCall, run_id: call.run_id, call_seq: 1)

        input =
          Repo.get_by!(Signal,
            agent_uid: key.agent_uid,
            source_event_id: "workflow:call:#{sibling.id}:dispatch"
          )

        assert {:ok, %{kind: :workflow_task}} =
                 Admission.admit(%{key | session_id: input.session_id}, input)

        assert %AgentCall{status: "running", attempts: 1} = Repo.reload!(sibling)
        assert Repo.reload!(call) == stored_call
      end
    end
  end

  for tool <- ["sleep", "submit_result"] do
    @tag terminal_tool: tool
    test(
      "Workflow #{tool} committed between recovery inspection and claim is settled under the admission lock",
      %{key: owner, script: script, worker: worker, terminal_tool: tool}
    ) do
      Agent.update(
        script,
        &%{&1 | calls: [tool_call("end", tool, workflow_ending_args(tool))], block_first?: true}
      )

      {key, event, call} = workflow_task(owner)
      {:ok, first} = Ankole.Sessions.ensure_driver(key)
      _ = await_request(key)
      assert_receive {:model_waiting, model}, 10000
      handler = hold_workflow_admission_gap(key, first)
      send(model, :release_model)
      assert_receive {:workflow_tool_before_lock, tool_task}, 10000
      kill_driver(first)
      {:ok, _} = Ankole.Sessions.ensure_driver(key)
      assert_receive {:workflow_inspection_complete, recovering_driver}, 10000
      send(tool_task, :commit_workflow_tool)
      assert_receive {:workflow_tool_committed, ^tool_task}, 10000
      stored_call = Repo.reload!(call)
      assert Repo.reload!(event).completed_at == nil
      send(recovering_driver, :continue_workflow_admission)
      :telemetry.detach(handler)
      assert_workflow_ending(key, event, stored_call, tool, script, worker)
    end
  end

  defp workflow_ending_args("sleep") do
    %{"wake_after_ms" => 28_800_000, "note" => "Wait for parent input", "attention" => true}
  end

  defp workflow_ending_args("submit_result") do
    %{"result" => true}
  end

  defp hold_workflow_commit(boundary) do
    parent = self()
    fired = :atomics.new(1, [])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if persistence_cut?(boundary, metadata.query) do
            Process.put(handler, true)
          end

          if metadata.query == "commit" and Process.delete(handler) == true and
               :atomics.compare_exchange(fired, 1, 0, 1) == :ok do
            send(parent, {:workflow_commit, self()})

            receive do
              :continue_workflow_commit -> :ok
            after
              10000 -> raise "the Workflow commit was not released"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  defp hold_workflow_admission_gap(key, _original_driver) do
    parent = self()
    stages = :atomics.new(2, [])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler,
        [[:ankole, :repo, :query], [:ankole, :sessions, :receipt, :execute]],
        fn event, _, metadata, _ ->
          query = Map.get(metadata, :query, "")

          if event == [:ankole, :sessions, :receipt, :execute] and
               metadata.agent_uid == key.agent_uid and metadata.session_id == key.session_id and
               metadata.call_id == "end" and :atomics.compare_exchange(stages, 1, 0, 1) == :ok do
            send(parent, {:workflow_tool_before_lock, self()})

            receive do
              :commit_workflow_tool -> :ok
            after
              15000 -> raise "the Workflow tool was not released"
            end
          end

          if String.starts_with?(query, "INSERT INTO \"session_tool_receipts\"") do
            Process.put({handler, :receipt}, true)
          end

          if query == "commit" and Process.delete({handler, :receipt}) == true do
            send(parent, {:workflow_tool_committed, self()})
          end

          if self() == Ankole.Sessions.driver_pid(key) and String.starts_with?(query, "SELECT") and
               String.contains?(query, "FROM \"workflow_agent_calls\"") and
               String.contains?(query, "INNER JOIN \"workflow_runs\"") and
               not String.contains?(query, "FOR UPDATE") and
               :atomics.compare_exchange(stages, 2, 0, 1) == :ok do
            send(parent, {:workflow_inspection_complete, self()})

            receive do
              :continue_workflow_admission -> :ok
            after
              15000 -> raise "the Workflow admission was not released"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  defp kill_driver(driver) do
    monitor = Process.monitor(driver)
    Process.exit(driver, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^driver, :killed}, 5000
  end

  defp suspend_driver_tenant do
    Repo.get!(Ankole.Tenants.Tenant, Repo.tenant_id!())
    |> change(suspended_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()
  end

  defp assert_workflow_ending(key, event, stored_call, tool, script, worker) do
    completed = wait_for_completion(event.id, 600)
    assert completed.attempt_count == 1
    assert Repo.reload!(stored_call) == stored_call
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
    id = event.id
    assert Agent.get(script, &Map.get(&1.requests_by_event, id, 0)) == 1

    for other_id <- Agent.get(script, &Map.keys(&1.requests_by_event)), other_id != id do
      assert Repo.get!(Signal, other_id).session_id != key.session_id
    end

    assert Repo.aggregate(from(r in Receipts, where: r.agent_uid == ^key.agent_uid), :count) == 0

    assert Repo.aggregate(
             from(c in AgentCall, where: c.agent_uid == ^key.agent_uid and c.status == "running"),
             :count
           ) == 0

    [journal] =
      Repo.all(
        from(m in Message,
          where:
            m.subject_uid == ^key.agent_uid and
              fragment("?->>'tool_result_journal'", m.metadata) == "true"
        )
      )

    [output] = Enum.filter(journal.content, &(&1["call_id"] == "end"))
    details = Ankole.JSON.decode!(output["output"])
    response = Repo.get!(Message, journal.previous_message_id)
    assert get_in(response.metadata, ["request_metadata", "signal_id"]) == event.id
    assert get_in(journal.metadata, ["request_metadata", "signal_id"]) == event.id

    assert Ankole.Sessions.RoundState.get(journal).workflow_attempt ==
             Ankole.Sessions.RoundState.get(response).workflow_attempt

    case tool do
      "sleep" ->
        assert details["task_status"] == "sleeping"
        assert stored_call.status == "sleeping"
        assert stored_call.attempts == 0
        assert stored_call.attention
        assert stored_call.wake_count == 1

        wake =
          Repo.get_by!(Signal,
            agent_uid: key.agent_uid,
            source_event_id: "workflow:call:#{stored_call.id}:wake:1"
          )

        assert wake.available_at == stored_call.sleeping_until
        assert DateTime.compare(wake.available_at, DateTime.utc_now(:microsecond)) == :gt
        assert wake.input_state == "open"
        refute wake.completed_at
        "sleeping"

      "submit_result" ->
        assert details["accepted"]
        assert details["task_status"] == "succeeded"
        assert stored_call.status == "succeeded"
        assert stored_call.result == %{"ok" => true, "value" => true}
        "submitted"
    end

    assert completed.turn_outcome == nil
    {:ok, driver} = Ankole.Sessions.ensure_driver(key)
    send(driver, :reconcile_inbox)
    send(driver, {:inbox, id})
    refute_receive {:model_request, %{signal_id: ^id}}, 100
    assert Repo.reload!(completed).completed_at == completed.completed_at

    workspace =
      Repo.get_by!(SessionWorkspace, agent_uid: key.agent_uid, session_id: key.session_id)

    assert {:ok, %{status: :completed, signal: replayed} = result} = Admission.admit(key, event)
    refute Map.has_key?(result, :run)
    refute Map.has_key?(result, :outcome)
    assert replayed == completed
    assert Repo.reload!(completed) == completed
    assert Repo.reload!(stored_call) == stored_call
    assert Repo.reload!(workspace) == workspace
    refute_receive {:model_request, %{signal_id: ^id}}, 100
  end

  defp workflow_task(owner, opts \\ []) do
    argument = %{
      namespace: nil,
      name: "agent",
      arguments: %{"prompt" => "Verify the answer.", "schema" => %{"type" => "boolean"}}
    }

    arguments =
      List.duplicate(
        argument,
        if Keyword.get(opts, :sibling?, false) do
          2
        else
          1
        end
      )

    create = fn repo ->
      with {:ok, source} <- Ankole.Signals.accept_in_tx(repo, attrs(owner)),
           {:ok, source} <-
             Ankole.Sessions.Queue.mark_event_completed_in_tx(
               repo,
               source,
               DateTime.utc_now(:microsecond)
             ),
           {:ok, %{run: workflow}} <-
             Ankole.Workflow.create_with_dispatch(%{
               "agent_uid" => owner.agent_uid,
               "owner_session_id" => owner.session_id,
               "source_signal_id" => source.id,
               "source_tool_call_id" => Ecto.UUID.generate(),
               "reply_route" => %{"binding_name" => "control-plane:test"},
               "title" => "Verify the answer",
               "script" => "return await agent('Verify the answer');",
               "concurrency" => Keyword.get(opts, :concurrency, 8),
               "args" => %{}
             }) do
        {:ok, workflow}
      end
    end

    dispatch = fn workflow -> Ankole.Workflow.commit_replay_pending(workflow.id, arguments, 0) end

    result =
      if Keyword.get(opts, :deliver_after_commit?, false) do
        with {:ok, workflow} <- Repo.transact(create) do
          dispatch.(workflow)
        end
      else
        Repo.transact(fn repo ->
          with {:ok, workflow} <- create.(repo) do
            dispatch.(workflow)
          end
        end)
      end

    {:ok, %{new_calls: [call | _]}} = result

    key = %{agent_uid: owner.agent_uid, session_id: Ankole.Workflow.task_session_id(call.id)}

    if Keyword.get(opts, :deliver_after_commit?, false), do: wake_committed_session!(key)

    event =
      Repo.get_by!(Signal,
        agent_uid: key.agent_uid,
        source_event_id: "workflow:call:#{call.id}:dispatch"
      )

    {key, event, call}
  end

  test(
    "inbox notices during admission keep new instructions and one model request (G1, G4)",
    %{key: key, worker: worker}
  ) do
    owner = self()
    handler = "driver-admission-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, parent ->
          if String.starts_with?(metadata.query, "UPDATE \"sessions\" SET") do
            send(parent, {:admission_before_commit, self()})

            receive do
              :commit_admission -> :ok
            after
              10000 -> raise "the test did not release the admission transaction"
            end
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, event} =
      Ankole.Signals.accept(%{
        attrs(key)
        | type: "command.new",
          data: %{"command" => %{"name" => "new", "argsText" => "Fresh task"}}
      })

    assert {:ok, driver} = Ankole.Sessions.ensure_driver(key)
    assert_receive {:admission_before_commit, admitting}, 5000
    send(driver, {:inbox, event.id})
    send(driver, {:inbox, event.id})
    refute_receive {:model_request, _}, 100
    send(admitting, :commit_admission)
    :telemetry.detach(handler)
    request = await_request(key)
    assert Ankole.JSON.encode!(request.body["messages"]) =~ "Fresh task"
    assert wait_for_completion(event.id).attempt_count == 1
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
    refute_receive {:model_request, _}, 100
  end

  test(
    "stop cancels a generating model and consumes the run and command without a Worker (G1, G2)",
    %{key: key, worker: worker, script: script}
  ) do
    Agent.update(script, &%{&1 | block_first?: true})
    {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    assert_receive {:model_waiting, provider}, 5000
    :ok
    owner = self()
    handler = "driver-finalizing-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, parent ->
          if String.starts_with?(metadata.query, "UPDATE \"signals\" SET") and
               String.contains?(metadata.query, "\"completed_at\"") do
            send(parent, {:finalizing_before_commit, self()})

            receive do
              :commit_finalizing -> :ok
            after
              10000 -> raise "the test did not release the finalizing transaction"
            end
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, stop} =
      Ankole.Signals.accept(%{
        attrs(key)
        | type: "command.stop",
          data: %{"command" => %{"name" => "stop", "argsText" => ""}}
      })

    assert_receive {:finalizing_before_commit, finalizing}, 5000
    ref = Process.monitor(finalizing)
    driver = Ankole.Sessions.driver_pid(key)
    send(driver, {:inbox, stop.id})
    send(driver, {:inbox, stop.id})
    refute_receive {:DOWN, ^ref, :process, ^finalizing, _}, 100
    :telemetry.detach(handler)
    send(finalizing, :commit_finalizing)
    Process.demonitor(ref, [:flush])
    assert wait_for_completion(stop.id).completed_at
    assert wait_for_completion(event.id).completed_at
    send(provider, :release_model)
    assert Repo.get!(AgentWorker, key.agent_uid) == worker

    assert Repo.aggregate(
             from(m in Message,
               where: m.subject_uid == ^key.agent_uid and m.status == "generating"
             ),
             :count
           ) == 0

    refute_receive {:model_request, _}, 100
  end

  test("stop consumes an injected steer and bypasses a queued reset (G2, G4)", %{
    key: key,
    script: script
  }) do
    Agent.update(script, &%{&1 | block_first?: true, calls: [tool_call("plan", "todo", %{})]})
    {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    assert_receive {:model_waiting, first_provider}, 5000

    {:ok, steer} =
      Ankole.Signals.accept(%{
        attrs(key)
        | type: "command.steer",
          data: %{"command" => %{"name" => "steer", "argsText" => "Add the runbook."}}
      })

    Agent.update(script, &Map.put(&1, :block_at, 1))
    send(first_provider, :release_model)
    _ = await_request(key)
    assert_receive {:model_waiting, second_provider}, 5000
    {:ok, reset} = Ankole.Signals.accept(%{attrs(key) | type: "session.reset_due", data: %{}})

    {:ok, stop} =
      Ankole.Signals.accept(%{
        attrs(key)
        | type: "command.stop",
          data: %{"command" => %{"name" => "stop", "argsText" => ""}}
      })

    assert wait_for_completion(stop.id).completed_at
    assert wait_for_completion(event.id).completed_at
    assert wait_for_completion(steer.id).completed_at
    assert wait_for_completion(reset.id).completed_at
    send(second_provider, :release_model)
    refute_receive {:model_request, _}, 100
  end

  test("a steer received during generation reaches the next boundary once (G2, G4)", %{
    key: key,
    script: script
  }) do
    Agent.update(script, &%{&1 | block_first?: true, calls: [tool_call("plan", "todo", %{})]})
    {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    assert_receive {:model_waiting, provider}, 5000

    {:ok, steer} =
      Ankole.Signals.accept(%{
        attrs(key)
        | type: "command.steer",
          data: %{
            "command" => %{"name" => "steer", "argsText" => "Include the operator runbook."}
          }
      })

    send(provider, :release_model)
    next = await_request(key)

    assert Enum.count(
             next.body["messages"],
             &String.contains?(Ankole.JSON.encode!(&1), "Include the operator runbook.")
           ) == 1

    assert wait_for_completion(event.id).completed_at
    assert wait_for_completion(steer.id).completed_at
    assert Repo.get!(Signal, steer.id).last_attempt_at
    refute_receive {:model_request, _}, 100
  end

  test("invalid targeted retries give feedback and leave the live model running (G4)", %{
    key: key,
    script: script
  }) do
    Agent.update(script, &%{&1 | block_first?: true})
    {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    assert_receive {:model_waiting, provider}, 5000

    for id <- [nil, Ecto.UUID.generate(), event.id] do
      {:ok, command} =
        Ankole.Signals.accept(%{
          attrs(key)
          | type: "command.retry",
            data: %{"command" => %{"name" => "retry", "targetSignalId" => id}}
        })

      assert wait_for_completion(command.id).completed_at
      refute Repo.reload!(event).completed_at

      assert Repo.exists?(
               from(m in Message,
                 where: m.subject_uid == ^key.agent_uid and m.status == "generating"
               )
             )

      refute_receive {:model_request, _}, 50
    end

    send(provider, :release_model)
    assert wait_for_completion(event.id).turn_outcome == "loop_finished"
    refute_receive {:model_request, _}, 100
  end

  test("reset defers later input until the next conversation (G2, G4)", %{
    key: key,
    script: script
  }) do
    Agent.update(script, &%{&1 | block_first?: true})
    {:ok, first} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    assert_receive {:model_waiting, provider}, 5000
    {:ok, reset} = Ankole.Signals.accept(%{attrs(key) | type: "session.reset_due", data: %{}})

    {:ok, later} =
      Ankole.Signals.accept(%{attrs(key) | data: %{"entry" => %{"text" => "New day work"}}})

    refute Repo.reload!(reset).completed_at
    refute Repo.reload!(later).last_attempt_at
    send(provider, :release_model)
    next = await_request(key)
    assert Ankole.JSON.encode!(next.body["messages"]) =~ "New day work"
    assert wait_for_completion(first.id).completed_at
    assert wait_for_completion(reset.id).completed_at
    assert wait_for_completion(later.id).completed_at

    old =
      Repo.get!(
        Message,
        String.replace_prefix(Repo.reload!(first).final_response_id, "resp_", "")
      )

    new =
      Repo.get!(
        Message,
        String.replace_prefix(Repo.reload!(later).final_response_id, "resp_", "")
      )

    assert old.conversation_id != new.conversation_id
    assert Repo.get!(Ankole.AIGateway.Schemas.Conversation, old.conversation_id).ended_at
    refute_receive {:model_request, _}, 100
  end

  test("bare retry interrupts generation even after ordinary input was queued (G2, G4)", %{
    key: key,
    script: script
  }) do
    Agent.update(script, &%{&1 | block_first?: true})
    {:ok, first} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    assert_receive {:model_waiting, provider}, 5000

    {:ok, queued} =
      Ankole.Signals.accept(%{
        attrs(key)
        | data: %{"entry" => %{"text" => "Handle this after retry"}}
      })

    {:ok, retry} =
      Ankole.Signals.accept(%{
        attrs(key)
        | type: "command.retry",
          data: %{"command" => %{"name" => "retry", "argsText" => ""}}
      })

    _ = await_request(key)
    assert wait_for_completion(retry.id).completed_at
    send(provider, :release_model)
    _ = await_request(key)
    assert wait_for_completion(first.id).completed_at
    assert wait_for_completion(queued.id).completed_at

    assert Repo.aggregate(
             from(m in Message,
               where: m.subject_uid == ^key.agent_uid and m.status == "generating"
             ),
             :count
           ) == 0
  end

  test("bare retry preserves the attachment receipt and continues the same tape (G2, G3, G4)", %{
    key: key,
    script: script
  }) do
    Ankole.FilesFixtures.drive_file_fixture(key.agent_uid, "reports/retry.txt", "Original report")

    Agent.update(script, fn state ->
      state
      |> Map.put(:block_at, 1)
      |> Map.merge(%{
        block_first?: true,
        calls: [
          tool_call("attachment-retry", "reply_attachment", %{"drive_path" => "reports/retry.txt"})
        ]
      })
    end)

    {:ok, first} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    _ = await_request(key)
    assert_receive {:model_waiting, provider}, 5000
    Ankole.FilesFixtures.drive_file_fixture(key.agent_uid, "reports/retry.txt", "Later edit")

    {:ok, retry} =
      Ankole.Signals.accept(%{
        attrs(key)
        | type: "command.retry",
          data: %{"command" => %{"name" => "retry", "argsText" => ""}}
      })

    next = await_request(key)
    send(provider, :release_model)

    outputs =
      Enum.filter(
        next.body["messages"],
        &(&1["role"] == "tool" and &1["tool_call_id"] == "attachment-retry")
      )

    assert [output] = outputs
    assert Ankole.JSON.encode!(next.body["messages"]) =~ "The user requested retry"

    assert [%{"path" => "reports/retry.txt", "blob_ref" => blob_ref}] =
             Ankole.JSON.decode!(output["content"])["attachments"]

    assert blob_ref == Base.encode16(:crypto.hash(:sha256, "Original report"), case: :lower)
    assert {:ok, _, "Later edit"} = Ankole.Files.read(key.agent_uid, "reports/retry.txt")
    assert wait_for_completion(first.id).completed_at
    assert wait_for_completion(retry.id).completed_at

    [called] =
      Repo.all(
        from(m in Message,
          where:
            m.subject_uid == ^key.agent_uid and m.type == "message" and m.status == "complete"
        )
      )
      |> Enum.filter(fn message ->
        Enum.any?(
          message.content,
          &(&1["type"] == "function_call" and &1["call_id"] == "attachment-retry")
        )
      end)

    assert called.status == "complete"
    refute_receive {:model_request, _}, 100
  end

  test("provider failure uses the Workflow call budget and settles its input (G2, G4, G8)", %{
    key: owner,
    script: script
  }) do
    Agent.update(script, &%{&1 | rounds: [error: 400, error: 400, error: 400]})
    {key, event, call} = workflow_task(owner)
    {:ok, _} = Ankole.Sessions.ensure_driver(key)
    _ = await_request(key)
    _ = await_request(key, 15000)
    _ = await_request(key, 15000)
    assert wait_for_completion(event.id).completed_at
    stored = Repo.get!(Ankole.Workflow.Schemas.AgentCall, call.id)
    assert stored.status == "failed"
    assert stored.attempts == 3
    assert stored.error["code"] == "upstream_response_failed"
    refute_receive {:model_request, _}, 100
  end

  test(
    "tool errors and a plan reach the next model request through one durable round (G1, G4)",
    %{key: key, worker: worker, script: script}
  ) do
    calls = [
      tool_call("unknown-1", "unknown_tool", %{}),
      tool_call("invalid-1", "clarify", %{"question" => " "}),
      tool_call("plan-1", "todo", %{
        "todos" => [%{"id" => "one", "content" => "Check the result", "status" => "in_progress"}]
      })
    ]

    Agent.update(script, &%{&1 | calls: calls})
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _first = await_request(key)
    next = await_request(key)
    messages = next.body["messages"]
    results = Enum.filter(messages, &(&1["role"] == "tool"))
    assert Enum.map(results, & &1["tool_call_id"]) == Enum.map(calls, & &1["id"])
    assert Enum.at(results, 0)["content"] =~ "Unknown tool"
    assert Enum.at(results, 1)["content"] =~ "Invalid arguments"
    assert Enum.at(results, 2)["content"] =~ "Check the result"
    assert wait_for_completion(event.id).turn_outcome == "loop_finished"
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
    assert Repo.aggregate(from(r in Receipts, where: r.agent_uid == ^key.agent_uid), :count) == 0
  end

  test(
    "a round with only rejected calls reaches the model without a Worker (G1, G2, G4)",
    %{key: key, worker: worker, script: script}
  ) do
    calls = [
      tool_call("unknown-1", "unknown_tool", %{}),
      tool_call("invalid-1", "send_message_to_background_job", %{
        "job_id" => 0,
        "message" => "Continue",
        "wait_reply" => false
      })
    ]

    Agent.update(script, &%{&1 | calls: calls})
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _first = await_request(key)
    next = await_request(key)
    results = Enum.filter(next.body["messages"], &(&1["role"] == "tool"))
    assert Enum.map(results, & &1["tool_call_id"]) == Enum.map(calls, & &1["id"])
    assert Enum.at(results, 0)["content"] =~ "Unknown tool"
    assert Enum.at(results, 1)["content"] =~ "Invalid arguments"
    assert wait_for_completion(event.id).turn_outcome == "loop_finished"
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
  end

  test(
    "a receipt survives driver loss before tape and preserves a later file edit (G1, G2, G3)",
    %{key: key, worker: worker, script: script}
  ) do
    Ankole.FilesFixtures.drive_file_fixture(key.agent_uid, "reports/q3.txt", "original report")

    Agent.update(
      script,
      &%{
        &1
        | calls: [
            tool_call("attachment-1", "reply_attachment", %{"drive_path" => "reports/q3.txt"})
          ]
      }
    )

    {event, receipt} = crash_after_receipt(key)
    Ankole.FilesFixtures.drive_file_fixture(key.agent_uid, "reports/q3.txt", "operator revision")
    assert {:ok, _pid} = Ankole.Sessions.ensure_driver(key)
    next = await_request(key)

    result =
      Enum.find(
        next.body["messages"],
        &(&1["role"] == "tool" and &1["tool_call_id"] == "attachment-1")
      )

    assert result["content"] == receipt.result["output"]

    assert [%{"path" => "reports/q3.txt", "blob_ref" => blob_ref}] =
             receipt.result["details"]["attachments"]

    assert blob_ref == Base.encode16(:crypto.hash(:sha256, "original report"), case: :lower)

    assert {:error, {:reply_attachment_not_in_drive, "reports/q3.txt"}} =
             Ankole.Conversations.Delivery.Attachment.verify_in_drive(
               key.agent_uid,
               receipt.result["details"]["attachments"]
             )

    assert {:ok, _, "operator revision"} = Ankole.Files.read(key.agent_uid, "reports/q3.txt")
    completed = wait_for_completion(event.id)
    assert completed.attempt_count == 2
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
    assert Repo.aggregate(from(r in Receipts, where: r.agent_uid == ^key.agent_uid), :count) == 0
    response_id = String.replace_prefix(completed.final_response_id, "resp_", "")
    conversation_id = Repo.get!(Message, response_id).conversation_id

    assert Repo.aggregate(
             from(m in Message,
               where:
                 m.conversation_id == ^conversation_id and
                   fragment("?->>'tool_result_journal'", m.metadata) == "true"
             ),
             :count
           ) == 1
  end

  test("takeover restores a created Job after its custom model profile is removed", %{
    key: key,
    script: script,
    profile: profile
  }) do
    assert {:ok, _} =
             ModelProfiles.put_model_profile(
               key.agent_uid,
               "temporary",
               Map.take(profile, ~w(provider_id model provider_options))
               |> Map.put("description", "Temporary test profile")
             )

    Agent.update(script, fn state ->
      %{
        state
        | calls: [
            tool_call("create-job", "create_background_job", %{
              "title" => "Committed Job",
              "task" => "Inspect the report.",
              "model_profile" => "temporary"
            })
          ]
      }
    end)

    {event, receipt} = crash_after_receipt(key)
    assert {:ok, _} = ModelProfiles.put_model_profile(key.agent_uid, "temporary", nil)
    assert {:ok, _} = Ankole.Sessions.ensure_driver(key)
    next = await_request(key)
    result = Enum.find(next.body["messages"], &(&1["tool_call_id"] == "create-job"))
    assert result["content"] == receipt.result["output"]

    assert [job] =
             Repo.all(
               from(j in Ankole.BackgroundAgentJobs.Schemas.Job,
                 where: j.agent_uid == ^key.agent_uid
               )
             )

    assert job.id == receipt.result["details"]["job_id"]
    assert wait_for_completion(event.id).attempt_count == 2
  end

  test("takeover observes the committed Job message without sending it again", %{
    key: key,
    script: script
  }) do
    {:ok, %{job: job}} =
      Ankole.BackgroundAgentJobs.create_with_dispatch(%{
        "source_signal_id" => Ankole.WorkFixtures.service_source(key.agent_uid).id,
        "agent_uid" => key.agent_uid,
        "owner_session_id" => key.session_id,
        "source_tool_call_id" => "observed-job",
        "title" => "Observed Job",
        "task" => "Wait for a Worker.",
        "reply_route" => %{"binding_name" => "control-plane:test"}
      })

    Agent.update(script, fn state ->
      %{
        state
        | calls: [
            tool_call("message-job", "send_message_to_background_job", %{
              "job_id" => job.id,
              "message" => "Inspect the report.",
              "wait_reply" => true,
              "wait_timeout_ms" => 60000
            })
          ]
      }
    end)

    {event, receipt} = crash_after_receipt(key)
    assert receipt.result["wait"]["kind"] == "job"
    assert receipt.result["wait"]["timeout_ms"] == 60000
    expired_at = DateTime.add(DateTime.utc_now(:microsecond), -120, :second)

    assert {1, nil} =
             Repo.update_all(from(r in Receipts, where: r.agent_uid == ^key.agent_uid),
               set: [inserted_at: expired_at]
             )

    assert {:ok, _} = Ankole.Sessions.ensure_driver(key)
    # Reopening the 60-second window would miss this deadline.
    next = await_request(key, 20000)
    result = Enum.find(next.body["messages"], &(&1["tool_call_id"] == "message-job"))
    assert result["content"] =~ "the foreground observation window expired"
    assert result["content"] =~ "The message is already stored; do not resend it."

    commands =
      Repo.all(
        from(e in Signal,
          where:
            e.agent_uid == ^key.agent_uid and
              e.session_id == ^Ankole.BackgroundAgentJobs.job_session_id(job.id) and
              e.type == "command.steer"
        )
      )

    assert [command] = commands
    assert command.id == receipt.result["wait"]["command_event_id"]
    assert wait_for_completion(event.id).attempt_count == 2
  end

  for boundary <- [
        :admitted,
        :response_created,
        :receipt_committed,
        :round_recorded,
        :finalized,
        :pending_stop
      ] do
    @tag boundary: boundary
    test(
      "rebuild after the #{boundary} transaction preserves input, tape and one attachment receipt",
      %{key: key, script: script, worker: worker, boundary: boundary}
    ) do
      Ankole.FilesFixtures.drive_file_fixture(key.agent_uid, "reports/cut.txt", "original")

      Agent.update(
        script,
        &(Map.put(&1, :repeat_until_tool?, true)
          |> Map.put(:calls, [
            tool_call("cut-attachment", "reply_attachment", %{"drive_path" => "reports/cut.txt"})
          ]))
      )

      parent = self()
      fired = :atomics.new(1, [])
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:ankole, :repo, :query],
          fn _, _, metadata, _ ->
            query = metadata.query
            cut? = persistence_cut?(boundary, query)

            if cut? do
              Process.put(handler, true)
            end

            if query == "commit" and Process.delete(handler) == true and
                 :atomics.compare_exchange(fired, 1, 0, 1) == :ok do
              send(parent, {:committed_cut, self()})

              receive do
                :continue_after_cut -> :ok
              after
                10000 -> raise "transaction cut was not released"
              end
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      {:ok, event} = Ankole.Signals.accept(attrs(key))
      assert_receive {:committed_cut, writer}, 10000
      driver = Ankole.Sessions.driver_pid(key)
      monitor = Process.monitor(driver)
      Process.exit(driver, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^driver, :killed}, 5000
      :telemetry.detach(handler)
      send(writer, :continue_after_cut)

      if boundary in [:receipt_committed, :round_recorded, :finalized, :pending_stop] do
        Ankole.FilesFixtures.drive_file_fixture(
          key.agent_uid,
          "reports/cut.txt",
          "operator revision"
        )
      end

      stop =
        if boundary == :pending_stop do
          {:ok, stop} =
            Repo.transact(
              &Ankole.Signals.accept_in_tx(&1, %{
                attrs(key)
                | type: "command.stop",
                  data: %{"command" => %{"name" => "stop", "argsText" => ""}}
              })
            )

          stop
        end

      assert {:ok, _} = Ankole.Sessions.ensure_driver(key)
      completed = wait_for_completion(event.id, 600)

      if stop do
        assert completed.turn_outcome == nil
        assert wait_for_completion(stop.id).completed_at
        assert Agent.get(script, & &1.requests) == 1
      else
        assert completed.turn_outcome == "loop_finished"
      end

      assert Repo.get!(AgentWorker, key.agent_uid) == worker

      assert Repo.aggregate(from(r in Receipts, where: r.agent_uid == ^key.agent_uid), :count) ==
               0

      journals =
        Repo.all(
          from(m in Message,
            where:
              m.subject_uid == ^key.agent_uid and
                fragment("?->>'tool_result_journal'", m.metadata) == "true"
          )
        )

      assert length(journals) == 1
      output = hd(journals).content |> Enum.find(&(&1["call_id"] == "cut-attachment"))
      details = Ankole.JSON.decode!(output["output"])
      assert [%{"path" => "reports/cut.txt", "blob_ref" => blob_ref}] = details["attachments"]
      assert blob_ref == Base.encode16(:crypto.hash(:sha256, "original"), case: :lower)

      expected =
        if boundary in [:receipt_committed, :round_recorded, :finalized, :pending_stop] do
          "operator revision"
        else
          "original"
        end

      assert {:ok, _, ^expected} = Ankole.Files.read(key.agent_uid, "reports/cut.txt")
    end
  end

  defp persistence_cut?(:admitted, query) do
    String.starts_with?(query, "UPDATE \"signals\"") and String.contains?(query, "attempt_count")
  end

  defp persistence_cut?(:response_created, query) do
    String.starts_with?(query, "INSERT INTO \"ai_gateway_messages\"")
  end

  defp persistence_cut?(boundary, query) when boundary in [:receipt_committed, :pending_stop] do
    String.starts_with?(query, "INSERT INTO \"session_tool_receipts\"")
  end

  defp persistence_cut?(:round_recorded, query) do
    String.starts_with?(query, "DELETE FROM \"session_tool_receipts\"")
  end

  defp persistence_cut?(:finalized, query) do
    String.starts_with?(query, "UPDATE \"signals\"") and String.contains?(query, "completed_at")
  end

  test("a scheduled turn sends its reply contract in the first model request (G1, G4)", %{
    key: key,
    script: script,
    worker: worker
  }) do
    Agent.update(script, fn state ->
      %{
        state
        | rounds: [
            calls: [
              tool_call("finish", "finish_scheduled", %{
                "outcome" => "silent_success",
                "reply" => nil
              })
            ]
          ]
      }
    end)

    event_attrs = %{
      attrs(key)
      | type: "cron.fire",
        data: %{
          "wake_payload" => %{
            "payload" => %{"prompt" => "Check for changes."},
            "delivery" => %{"quiet_success" => true}
          }
        }
    }

    event = fire_checkback!(key, event_attrs)
    request = await_request(key)

    assert Enum.any?(
             request.body["tools"],
             &(get_in(&1, ["function", "name"]) == "finish_scheduled")
           )

    assert Enum.any?(
             request.body["messages"],
             &(&1["role"] == "system" and &1["content"] =~ "finish_scheduled")
           )

    refute Map.has_key?(request.body, "response_format")
    assert wait_for_completion(event.id).turn_outcome == "silent"
    assert Agent.get(script, & &1.requests) == 1
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
  end

  test("a scheduled ordinary reply reaches the channel without a terminal tool", %{
    key: key,
    script: script
  }) do
    :ok = RuntimeCase.use_mock_signal_provider_plugin(%{})

    Ankole.SignalsFixtures.binding_fixture(key.agent_uid, "b01", :record_only,
      adapter: "mock-provider"
    )

    channel_id = "mock:b01:" <> Ecto.UUID.generate()

    {:ok, conversation} =
      Repo.transact(fn repo ->
        Ankole.Conversations.External.observe_conversation_in_tx(
          repo,
          %{agent_uid: key.agent_uid},
          %{
            provider_conversation_id: channel_id,
            external_kind: :im_group,
            reply_mode: :channel,
            title: "Scheduled reply"
          },
          DateTime.utc_now(:microsecond)
        )
      end)

    channel_id = conversation.id

    Agent.update(script, &%{&1 | rounds: [text: "The check needs your attention."]})

    event_attrs =
      Map.merge(attrs(key), %{
        type: "cron.fire",
        reply_route: %{binding_name: "b01", conversation_id: channel_id},
        data: %{
          "wake_payload" => %{
            "payload" => %{"prompt" => "Check for changes."},
            "delivery" => %{
              "quiet_success" => true,
              "targets" => [%{"binding_name" => "b01", "conversation_id" => channel_id}]
            }
          }
        }
      })

    event = fire_checkback!(key, event_attrs)
    _ = await_request(key)
    completed = wait_for_completion(event.id)
    assert completed.turn_outcome == "loop_finished"
    assert completed.dead_letter_reason == nil
    assert Agent.get(script, & &1.requests) == 1

    assert Repo.one!(
             from(o in Ankole.Conversations.Delivery.Intent,
               where: o.source_signal_id == ^event.id,
               select: o.fallback_visible_text
             )
           ) == "The check needs your attention."
  end

  test("a scheduled turn rejects unauthorized silence and journals its accepted reply", %{
    key: key,
    script: script,
    worker: worker
  }) do
    Agent.update(
      script,
      &%{
        &1
        | rounds: [
            calls: [
              tool_call("quiet", "finish_scheduled", %{
                "outcome" => "silent_success",
                "reply" => nil
              })
            ],
            calls: [
              tool_call("reply", "finish_scheduled", %{
                "outcome" => "reply",
                "reply" => "The check needs your attention."
              })
            ]
          ]
      }
    )

    event_attrs = %{
      attrs(key)
      | type: "cron.fire",
        data: %{
          "wake_payload" => %{
            "payload" => %{"prompt" => "Check for changes."},
            "delivery" => %{"quiet_success" => false}
          }
        }
    }

    event = fire_checkback!(key, event_attrs)
    _ = await_request(key)
    corrected = await_request(key)

    assert Enum.any?(corrected.body["messages"], fn message ->
             message["role"] == "tool" and message["tool_call_id"] == "quiet" and
               message["content"] =~ "schedule_silent_success_not_allowed"
           end)

    completed = wait_for_completion(event.id)
    assert completed.turn_outcome == "loop_finished"
    final = Repo.get!(Message, String.replace_prefix(completed.final_response_id, "resp_", ""))
    result = Ankole.Sessions.RoundState.get(final).results["reply"]
    assert result["terminate"] == true
    assert result["final_text"] == "The check needs your attention."
    assert Agent.get(script, & &1.requests) == 2
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
    refute_receive {:model_request, _}, 100
  end

  test(
    "committed input reaches a durable answer without creating or reserving a Worker (G1, G2)",
    %{key: key, worker: worker}
  ) do
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    request = await_request(key)
    assert Ankole.JSON.encode!(request.body["messages"]) =~ "What is six times seven?"
    completed = wait_for_completion(event.id)
    assert completed.turn_outcome == "loop_finished"
    assert is_binary(completed.final_response_id)
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
    refute_receive {:model_request, _}, 100

    # The conversation loop spends the Agent token quota like an Agent token.
    assert [%UsageRecord{origin: "agent"}] =
             Repo.all(from(r in UsageRecord, where: r.subject_uid == ^key.agent_uid))
  end

  test("a hosted Brain recall reaches a durable final answer without Driver redispatch", %{
    key: key,
    worker: worker,
    script: script
  }) do
    Agent.update(
      script,
      &%{&1 | calls: [tool_call("brain-1", "recall", %{"query" => "test number"})]}
    )

    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    _ = await_request(key)
    completed = wait_for_completion(event.id)
    assert completed.turn_outcome == "loop_finished"
    response = Repo.get!(Message, String.replace_prefix(completed.final_response_id, "resp_", ""))
    assert Enum.any?(response.content, &(&1["type"] == "brain_call"))
    assert Enum.any?(response.content, &(&1["type"] == "brain_output"))
    refute Enum.any?(response.content, &(&1["type"] == "function_call_output"))
    assert Repo.get!(AgentWorker, key.agent_uid) == worker
    refute_receive {:model_request, _}, 100
  end

  test("successive tool rounds reuse one ready workspace and commit the final answer", %{
    key: key,
    script: script
  }) do
    Agent.update(
      script,
      &%{
        &1
        | rounds: [
            calls: [tool_call("reuse-1", "command", %{"command" => "printf first"})],
            calls: [tool_call("reuse-2", "command", %{"command" => "printf second"})],
            text: "Both commands completed."
          ]
      }
    )

    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    ready_workspace(key)

    for {id, text} <- [{"reuse-1", "first"}, {"reuse-2", "second"}] do
      assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, call}}}, 5000
      assert call.call_id == id
      assert call.mode == "execute"

      assert :ok =
               SessionLane.handle(
                 %Proto.Envelope{
                   body:
                     {:tool_result,
                      %Proto.ToolResult{
                        run: call.run,
                        response_id: call.response_id,
                        call_id: call.call_id,
                        content_json: Ankole.JSON.encode!([%{"type" => "text", "text" => text}]),
                        details_json: "{}"
                      }}
                 },
                 %{worker_id: key.agent_uid}
               )

      next = await_request(key)
      assert Enum.any?(next.body["messages"], &(&1["role"] == "tool" and &1["content"] == text))
      refute_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, _}}}, 100
    end

    completed = wait_for_completion(event.id)
    assert completed.turn_outcome == "loop_finished"
    final = Repo.get!(Message, String.replace_prefix(completed.final_response_id, "resp_", ""))
    assert Ankole.JSON.encode!(final.content) =~ "Both commands completed."
    assert Agent.get(script, & &1.requests) == 3
    refute_receive {:model_request, _}, 100
  end

  test(
    "the first command executes after a lazy Worker join, and shutdown adopts it (G1, G3, G5)",
    %{key: key, script: script}
  ) do
    Agent.update(
      script,
      &%{&1 | calls: [tool_call("command-1", "command", %{"command" => "printf done"})]}
    )

    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _request = await_request(key)
    wait_for_worker_request(key)
    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})
    ready_workspace(key)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, call}}}, 5000
    assert call.mode == "execute"
    assert call.name == "command"

    assert :ok =
             DynamicSupervisor.terminate_child(
               Ankole.Sessions.Drivers,
               Ankole.Sessions.driver_pid(key)
             )

    refunded = Repo.get!(Signal, event.id)
    assert refunded.attempt_count == 0
    refute_receive {:actor_lane, %Proto.Envelope{body: {:tool_cancel, _}}}, 50
    refute_receive {:actor_lane, %Proto.Envelope{body: {:workspace_close, _}}}, 50
    # A shutdown refund keeps the backoff clock.
    recovery_timeout_ms = Run.retry_delay_ms(refunded, DateTime.utc_now(:microsecond)) + 5000
    assert {:ok, _} = Ankole.Sessions.ensure_driver(key)
    ready_workspace(key, recovery_timeout_ms)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, adopted}}}, 5000
    assert adopted.mode == "probe"
    assert adopted.run == call.run
    assert adopted.response_id == call.response_id
    assert adopted.call_id == call.call_id

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:tool_status,
                    %Proto.ToolStatus{
                      run: call.run,
                      response_id: call.response_id,
                      call_id: call.call_id,
                      state: "running"
                    }}
               },
               %{worker_id: key.agent_uid}
             )

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:tool_result,
                    %Proto.ToolResult{
                      run: call.run,
                      response_id: call.response_id,
                      call_id: call.call_id,
                      content_json: Ankole.JSON.encode!([%{"type" => "text", "text" => "done"}]),
                      details_json: "{}"
                    }}
               },
               %{worker_id: key.agent_uid}
             )

    next = await_request(key)
    assert Enum.any?(next.body["messages"], &(&1["role"] == "tool" and &1["content"] == "done"))
    assert wait_for_completion(event.id).attempt_count == 1
  end

  test("a late tool result for a closed input cannot enter history or intent", %{
    key: key,
    script: script
  }) do
    Agent.update(
      script,
      &%{&1 | calls: [tool_call("late-call", "command", %{"command" => "printf done"})]}
    )

    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _ = await_request(key)
    wait_for_worker_request(key)
    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})
    ready_workspace(key)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, call}}}, 5000
    driver = Ankole.Sessions.driver_pid(key)
    monitor = Process.monitor(driver)

    before_history =
      Repo.all(from(m in Message, where: m.subject_uid == ^key.agent_uid, select: m.id))

    Repo.update!(
      Signal.changeset(Repo.get!(Signal, event.id), %{
        completed_at: DateTime.utc_now(:microsecond)
      })
    )

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:tool_result,
                    %Proto.ToolResult{
                      run: call.run,
                      response_id: call.response_id,
                      call_id: call.call_id,
                      content_json:
                        Ankole.JSON.encode!([
                          %{"type" => "text", "text" => "late output must not commit"}
                        ]),
                      details_json: "{}"
                    }}
               },
               %{worker_id: key.agent_uid}
             )

    assert_receive {:DOWN, ^monitor, :process, ^driver, :normal}, 5000

    assert Repo.all(from(m in Message, where: m.subject_uid == ^key.agent_uid, select: m.id)) ==
             before_history

    refute Enum.any?(
             Repo.all(from(m in Message, where: m.subject_uid == ^key.agent_uid)),
             &(Ankole.JSON.encode!(&1.content) =~ "late output must not commit")
           )

    refute Repo.exists?(
             from(o in Ankole.Conversations.Delivery.Intent,
               where: o.source_signal_id == ^event.id
             )
           )

    refute_receive {:model_request, _}, 100
  end

  test(
    "an image from a Worker tool reaches a vision model as a converted image",
    %{key: key, script: script, profile: profile}
  ) do
    :ok = cache_actor_runtime_models(profile["provider_id"], ["google/gemini-3.5-flash"])
    {text, images, []} = image_tool_round(key, script)
    assert text =~ "Image file: chart.png (image/png"
    assert ["data:image/webp;base64," <> encoded] = images
    assert <<"RIFF", _size::little-32, "WEBP", _::binary>> = Base.decode64!(encoded)
  end

  test(
    "a Worker join during its readiness query opens the workspace without another notification",
    %{key: key, script: script}
  ) do
    parent = self()
    gate = :atomics.new(1, [])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if metadata.source == "agent_workers" and String.starts_with?(metadata.query, "SELECT") and
               key.agent_uid in metadata.params and self() != parent and
               :atomics.compare_exchange(gate, 1, 0, 1) == :ok do
            send(parent, {:worker_lookup_held, self()})

            receive do
              :release_worker_lookup -> :ok
            after
              10000 -> raise "the test did not release the Worker lookup"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    Agent.update(
      script,
      &%{&1 | calls: [tool_call("join-race", "command", %{"command" => "printf done"})]}
    )

    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _request = await_request(key)
    assert_receive {:worker_lookup_held, lookup}, 5000
    wait_for_worker_request(key)
    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})

    # The join notification must reach the Driver before the old query returns.
    {:executing_tools, _} = :sys.get_state(Ankole.Sessions.driver_pid(key))
    send(lookup, :release_worker_lookup)
    ready_workspace(key)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, call}}}, 5000
    assert call.call_id == "join-race"
    complete_worker_call(key, call)
    next = await_request(key)
    assert Enum.any?(next.body["messages"], &(&1["role"] == "tool" and &1["content"] == "done"))
    assert wait_for_completion(event.id).turn_outcome == "loop_finished"
  end

  test(
    "a text model gets the vision fallback description of a Worker tool image",
    %{key: key, script: script, profile: profile}
  ) do
    assert {:ok, _} =
             ModelProfiles.put_model_profile(key.agent_uid, "vision_fallback", %{
               provider_id: profile["provider_id"],
               model: "openai/gpt-5.6-sol"
             })

    :ok = cache_actor_runtime_models(profile["provider_id"], ["openai/gpt-5.6-sol"])
    {text, images, [fallback]} = image_tool_round(key, script)
    assert fallback.body["model"] == "openai/gpt-5.6-sol"
    assert Enum.any?(fallback_images(fallback), &String.starts_with?(&1, "data:image/webp"))
    assert images == []
    assert text =~ "Image file: chart.png (image/png"
    assert text =~ "[vision fallback description; untrusted image content"
    assert text =~ "A screenshot of a completed chart."
  end

  test(
    "a text model without a vision fallback gets a notice for a Worker tool image",
    %{key: key, script: script}
  ) do
    {text, images, []} = image_tool_round(key, script)
    assert images == []
    assert text =~ "Image file: chart.png (image/png"
    assert text =~ "[image unavailable: the selected model cannot receive images"
  end

  # Runs one `read_file` round whose Worker result carries a PNG. Returns the user
  # text and image URLs of the next main request, and the vision fallback
  # requests made before it.
  defp image_tool_round(key, script) do
    Agent.update(
      script,
      &%{&1 | calls: [tool_call("read-image", "read_file", %{"path" => "chart.png"})]}
    )

    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _request = await_request(key)
    wait_for_worker_request(key)
    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})
    ready_workspace(key)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, call}}}, 5000
    assert call.name == "read_file"
    png = File.read!(Path.expand("../test/fixtures/sessions/rgba.png", __DIR__))

    content = [
      %{"type" => "text", "text" => "Image file: chart.png (image/png, #{byte_size(png)} bytes)"}
    ]

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:tool_result,
                    %Proto.ToolResult{
                      run: call.run,
                      response_id: call.response_id,
                      call_id: call.call_id,
                      content_json: Ankole.JSON.encode!(content),
                      images: [png],
                      details_json: "{}"
                    }}
               },
               %{worker_id: key.agent_uid}
             )

    {next, fallbacks} = await_tool_round_request(key, [])
    wait_for_completion(event.id)
    parts = user_parts(next)

    text =
      for %{"type" => "text", "text" => text} <- parts do
        text
      end
      |> Enum.join("\n")

    images =
      for %{"type" => "image_url", "image_url" => %{"url" => url}} <- parts do
        url
      end

    {text, images, fallbacks}
  end

  defp await_tool_round_request(key, fallbacks) do
    request = await_request(key)

    if Enum.any?(request.body["messages"], &(&1["role"] == "tool")) do
      {request, Enum.reverse(fallbacks)}
    else
      await_tool_round_request(key, [request | fallbacks])
    end
  end

  defp fallback_images(request) do
    for %{"type" => "image_url", "image_url" => %{"url" => url}} <- user_parts(request) do
      url
    end
  end

  defp user_parts(request) do
    for %{"role" => "user", "content" => content} <- request.body["messages"],
        part <- List.wrap(content) do
      if is_binary(part) do
        %{"type" => "text", "text" => part}
      else
        part
      end
    end
  end

  test(
    "capacity notices and tool results before transport receipts keep one execution (G2, G3)",
    %{key: key, script: script}
  ) do
    Agent.update(
      script,
      &%{&1 | calls: [tool_call("command-opening", "command", %{"command" => "printf done"})]}
    )

    owner = self()
    route = RuntimeCase.unique_route()

    :ok =
      WorkerRoute.register_local_worker(route, fn envelope ->
        send(owner, {:actor_lane, envelope, self()})

        if elem(envelope.body, 0) in [:workspace_open, :tool_call] do
          receive do
            :release_receipt -> :ok
          after
            10000 -> raise "the test did not release the transport receipt"
          end
        end
      end)

    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _request = await_request(key)
    wait_for_worker_request(key)
    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})
    assert_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, opened}}, opening}, 5000

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{body: {:workspace_ready, %Proto.WorkspaceReady{run: opened.run}}},
               %{worker_id: key.agent_uid}
             )

    driver = Ankole.Sessions.driver_pid(key)
    send(driver, {:worker_changed, key.agent_uid})
    send(driver, {:worker_changed, key.agent_uid})
    refute_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, _}}, _}, 100
    send(opening, :release_receipt)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, call}}, sending}, 5000
    assert call.call_id == "command-opening"
    assert call.mode == "execute"

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:tool_result,
                    %Proto.ToolResult{
                      run: call.run,
                      response_id: call.response_id,
                      call_id: call.call_id,
                      content_json: Ankole.JSON.encode!([%{"type" => "text", "text" => "done"}]),
                      details_json: "{}"
                    }}
               },
               %{worker_id: key.agent_uid}
             )

    next = await_request(key)
    assert Enum.any?(next.body["messages"], &(&1["role"] == "tool" and &1["content"] == "done"))
    assert wait_for_completion(event.id).attempt_count == 1
    refute Process.alive?(sending)
    refute_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, _}}, _}, 100
    refute_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, _}}, _}, 100
  end

  defp ready_workspace(key, timeout_ms \\ 5000) do
    assert_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, opened}}}, timeout_ms

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{body: {:workspace_ready, %Proto.WorkspaceReady{run: opened.run}}},
               %{worker_id: key.agent_uid}
             )
  end

  defp wait_for_retry(event, attempts, polls \\ 1800)

  defp wait_for_retry(event, _attempts, 0) do
    flunk("input did not reach its retry deadline: #{inspect(Repo.reload!(event))}")
  end

  defp wait_for_retry(event, attempts, polls) do
    stored = Repo.reload!(event)

    if stored.attempt_count == attempts and stored.provider_capacity_attempt_count == attempts and
         DateTime.compare(stored.available_at, DateTime.utc_now()) == :gt do
      :ok
    else
      Process.sleep(25)
      wait_for_retry(event, attempts, polls - 1)
    end
  end

  defp wait_for_worker_request(key) do
    assert eventually(fn ->
             worker = Repo.get!(AgentWorker, key.agent_uid)

             worker.wanted_until &&
               DateTime.compare(worker.wanted_until, DateTime.utc_now()) == :gt
           end)
  end

  defp session_workspace(key) do
    Repo.get_by!(SessionWorkspace, agent_uid: key.agent_uid, session_id: key.session_id)
  end

  defp latest_response(key) do
    conversation = Ankole.Sessions.ModelHistory.active_conversation(key.agent_uid, key.session_id)

    Repo.one!(
      from(m in Message,
        where: m.conversation_id == ^conversation.id,
        order_by: [desc: m.id],
        limit: 1
      )
    )
  end

  defp stored_run(key, event) do
    workspace = session_workspace(key)
    {:ok, spec} = Ankole.Sessions.Context.runtime(key)
    {:ok, context} = Ankole.Sessions.Context.resolve(key.agent_uid, key.session_id)

    %Ankole.Sessions.Run{
      agent_uid: key.agent_uid,
      session_id: key.session_id,
      signal_id: event.id,
      epoch: workspace.epoch,
      workspace_id: workspace.id,
      event: Repo.reload!(event),
      conversation:
        Ankole.Sessions.ModelHistory.active_conversation(key.agent_uid, key.session_id),
      context: context,
      spec:
        Map.put(
          spec,
          :runtime_env,
          Ankole.Sessions.TurnRuntimeEnv.resolve(event)
        )
    }
  end

  @tag timeout: 120_000
  test(
    "a deferred Job starts at its deadline and job observations retain the acceptance timer (G2, G4)",
    %{key: key}
  ) do
    {:ok, %{job: job, dispatch_event: event}} =
      Repo.transact(fn _repo ->
        Ankole.BackgroundAgentJobs.create_with_dispatch(%{
          "source_signal_id" => Ankole.WorkFixtures.service_source(key.agent_uid).id,
          "agent_uid" => key.agent_uid,
          "owner_session_id" => key.session_id,
          "source_tool_call_id" => "deferred-job",
          "title" => "Deferred Job",
          "task" => "Resume when the Worker is ready.",
          "reply_route" => job_reply_route(key, "deferred-job-test")
        })
      end)

    job_key = %{key | session_id: Ankole.BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, driver} = Ankole.Sessions.ensure_driver(job_key)

    assert eventually(fn ->
             DateTime.compare(Repo.reload!(event).available_at, DateTime.utc_now()) == :gt
           end)

    assert Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, job.id).attempts == 0
    assert Repo.get!(AgentWorker, key.agent_uid).wanted_until
    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _worker} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})
    assert_receive {:actor_lane, %Proto.Envelope{body: {:turn_start, start}}}, 35000
    assert start.turn.signal_id == event.id
    assert start.turn.job_id == job.id
    assert start.turn.attempt == 1
    assert Ankole.Sessions.driver_pid(job_key) == driver
    assert Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, job.id).status == "running"
    send(driver, {:job_turn, job.id, 1})
    assert_receive {:actor_lane, %Proto.Envelope{body: {:turn_start, observed}}}, 2000
    assert observed.turn == start.turn
    assert observed.mode == start.mode
    assert_receive {:actor_lane, %Proto.Envelope{body: {:turn_start, retry}}}, 65000
    assert retry.turn == start.turn
    assert retry.mode == start.mode
    assert Repo.get!(Ankole.BackgroundAgentJobs.Schemas.Job, job.id).attempts == 1
    assert Repo.reload!(event).last_attempt_at
  end

  test("stopping a running Job controls the Worker and closes its trigger", %{key: key}) do
    {job, event, _job_key, _driver, start} = start_live_job(key, "direct-stop")

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{body: {:turn_accepted, %Proto.TurnAccepted{turn: start.turn}}},
               %{worker_id: key.agent_uid}
             )

    assert Repo.reload!(job).status == "running"

    assert {:ok, %{job: stopped, turn: turn}} =
             Ankole.BackgroundAgentJobs.request_stop(job.id, %{"agent_uid" => key.agent_uid})

    assert :ok = Ankole.Sessions.stop_job_turn(stopped, turn)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:turn_control, control}}}, 2000
    assert control.command == "stop"
    assert control.turn == start.turn
    assert %DateTime{} = wait_for_completion(event.id).completed_at
    assert Repo.reload!(job).status == "stopped"
    assert Repo.reload!(job).attempts == 1
    refute_receive {:actor_lane, %Proto.Envelope{body: {:turn_start, _}}}, 100
  end

  @tag timeout: 120_000
  test("a rejected unaccepted Job retries the next durable attempt", %{key: key}) do
    {job, event, _job_key, _driver, start} = start_live_job(key, "unaccepted-retry")
    {:ok, ref} = Ankole.Sessions.JobTurnRef.from_proto(start.turn, key.agent_uid)

    assert {:ok, _} =
             Ankole.Sessions.CodexJob.abort(ref, key.agent_uid, %{
               "code" => "job_attempt_unknown",
               "message" => "Worker does not retain this Job attempt",
               "details_json" => %{"retryable" => true, "runtime" => "bun"}
             })

    assert Repo.reload!(job).status == "queued"

    assert DateTime.compare(Repo.reload!(event).available_at, DateTime.utc_now(:microsecond)) ==
             :gt

    assert_receive {:actor_lane, %Proto.Envelope{body: {:turn_start, retry}}}, 65000
    assert retry.turn.job_id == job.id
    assert retry.turn.signal_id == event.id
    assert retry.turn.attempt == start.turn.attempt + 1
    assert retry.mode == "start"
    assert Repo.reload!(job).attempts == retry.turn.attempt
  end

  defp start_live_job(key, suffix) do
    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: key.agent_uid})

    {:ok, %{job: job, dispatch_event: event}} =
      Ankole.BackgroundAgentJobs.create_with_dispatch(%{
        "source_signal_id" => Ankole.WorkFixtures.service_source(key.agent_uid).id,
        "agent_uid" => key.agent_uid,
        "owner_session_id" => key.session_id,
        "source_tool_call_id" => suffix,
        "title" => "Live Job",
        "task" => "Inspect the report.",
        "reply_route" => job_reply_route(key, suffix)
      })

    job_key = %{key | session_id: Ankole.BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, driver} = Ankole.Sessions.ensure_driver(job_key)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:turn_start, start}}}, 2000
    {job, event, job_key, driver, start}
  end

  test("Reconciler includes admitted input after a crash without any new message (G2, G8)", %{
    key: key
  }) do
    now = DateTime.utc_now(:microsecond)
    {:ok, event} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, attrs(key)))
    {:ok, run} = Ankole.Sessions.Admission.admit(key, event, now: DateTime.add(now, -10))

    Repo.update!(
      change(run.event, inserted_at: DateTime.add(now, -30), available_at: DateTime.add(now, -30))
    )

    other = create_tenant()

    other_key =
      Repo.with_tenant(other.id, fn ->
        %{principal: other_agent} = Ankole.PrincipalsFixtures.agent_fixture()

        other_key = %{
          agent_uid: other_agent.uid,
          session_id: "site-recovery-#{Ecto.UUID.generate()}"
        }

        assert {:ok, _} = Repo.transact(&Ankole.Signals.accept_in_tx(&1, attrs(other_key)))
        other_key
      end)

    assert Ankole.Sessions.driver_pid(key) == :undefined
    assert :ok = perform_job(Reconciler, %{})

    assert_enqueued(
      worker: Ankole.Sessions.Jobs.EnsureDriver,
      args: %{
        agent_uid: other_key.agent_uid,
        session_id: other_key.session_id,
        tenant_id: other.id
      }
    )

    assert %Oban.Job{
             args: %{"agent_uid" => uid, "session_id" => session, "tenant_id" => tenant_id}
           } =
             job =
             Repo.one!(
               from(j in Oban.Job,
                 where:
                   j.worker == "Ankole.Sessions.Jobs.EnsureDriver" and
                     fragment("?->>'session_id'", j.args) == ^key.session_id
               )
             )

    assert uid == key.agent_uid
    assert session == key.session_id
    assert tenant_id == Repo.tenant_id!()
    assert :ok = Ankole.Sessions.Jobs.EnsureDriver.perform(job)
    _request = await_request(key)
    completed = wait_for_completion(event.id)
    assert completed.attempt_count == 2
    assert completed.turn_outcome == "loop_finished"
  end

  @tag :b01
  test("a withdrawn context is omitted from the next Driver request", context) do
    exercise_context_withdrawal(context, false)
  end

  @tag :b01
  test("a withdrawn resolved reply is omitted from the next Driver request", context) do
    exercise_context_withdrawal(context, false, true)
  end

  @tag :b01
  test("context withdrawal preserves a tool effect already committed by the Driver", context) do
    exercise_context_withdrawal(context, true)
  end

  @tag :b01
  test(
    "resolved reply withdrawal preserves a tool effect already committed by the Driver",
    context
  ) do
    exercise_context_withdrawal(context, true, true)
  end

  defp exercise_context_withdrawal(
         %{
           key: original_key,
           script: script,
           owner_principal_uid: owner_uid,
           owner_access_version: owner_version
         },
         tool_effect?,
         quoted? \\ false
       ) do
    :ok = RuntimeCase.use_mock_signal_provider_plugin(%{})

    Ankole.SignalsFixtures.binding_fixture(original_key.agent_uid, "b01", :record_only,
      adapter: "mock-provider"
    )

    suffix = Ecto.UUID.generate()
    channel_id = "mock:b01:" <> suffix
    context_id = "context:" <> suffix
    now = DateTime.add(DateTime.utc_now(:microsecond), -2, :second)

    common = %{
      provider_conversation_id: channel_id,
      provider_thread_id: "b01-thread:" <> suffix,
      author:
        Ankole.SignalsFixtures.provider_author_fixture(owner_uid, "b01-owner:" <> suffix, %{
          provider: "mock-signal-provider",
          display_name: "Owner"
        }),
      channel: %{kind: :im_group, reply_mode: :entry, name: "B01 withdrawal"},
      provider_time: now
    }

    assert {:ok, %{status: :recorded}} =
             RuntimeCase.emit_entry(
               original_key.agent_uid,
               "b01",
               RuntimeCase.group_entry(
                 Map.merge(common, %{
                   source_event_id: "context-event:" <> suffix,
                   provider_message_id: context_id,
                   provider_time: DateTime.add(now, -1, :second),
                   text: "Use this private context.",
                   explicit: false
                 })
               ),
               now: DateTime.add(now, -1, :second)
             )

    calls =
      if tool_effect? do
        [
          tool_call("orders", "set_channel_standing_orders", %{
            "orders" => "Keep the completed channel orders."
          })
        ]
      else
        []
      end

    Agent.update(script, fn state ->
      state
      |> Map.put(:calls, calls)
      |> Map.put(:block_first?, true)
      |> Map.put(
        :block_at,
        if tool_effect? do
          1
        else
          0
        end
      )
    end)

    assert {:ok, %{signal: event}} =
             RuntimeCase.emit_entry(
               original_key.agent_uid,
               "b01",
               RuntimeCase.group_entry(
                 Map.merge(common, %{
                   source_event_id: "input-event:" <> suffix,
                   provider_message_id: "input:" <> suffix,
                   text: "Complete this request.",
                   reply_to_provider_message_id: if(quoted?, do: context_id, else: nil),
                   explicit: true
                 })
               ),
               now: now
             )

    assert event.authorization_kind == "human"
    refute context_id in Signal.provider_message_ids(event)
    refute context_id in Signal.input_provider_message_ids(event)

    key = %{agent_uid: event.agent_uid, session_id: event.session_id}
    {:ok, driver} = Ankole.Sessions.ensure_driver(key)
    send(driver, :reconcile_inbox)
    assert DateTime.compare(event.available_at, DateTime.utc_now(:microsecond)) == :lt
    _ = await_request(key)

    if tool_effect? do
      await_request(key)
    end

    assert_receive {:model_waiting, provider}, 10000

    if tool_effect? do
      assert Repo.get_by!(Ankole.Conversations.Conversation, provider_conversation_id: channel_id).ambient_standing_orders ==
               "Keep the completed channel orders."
    end

    journal =
      if tool_effect? do
        Repo.one!(
          from(m in Message,
            where:
              m.subject_uid == ^key.agent_uid and
                fragment("?::text LIKE ?", m.content, "%function_call_output%")
          )
        )
      end

    if journal do
      assert Ankole.JSON.encode!(journal.content) =~ "Keep the completed channel orders."
    end

    assert {:ok, %{canceled_signals: 0}} =
             Ankole.Conversations.Observe.emit_entry_removed(
               key.agent_uid,
               "b01",
               RuntimeCase.lifecycle_entry(%{
                 source_event_id: "withdraw-context:" <> suffix,
                 provider_message_id: context_id,
                 provider_conversation_id: channel_id,
                 provider_thread_id: common.provider_thread_id,
                 channel: common.channel
               }),
               now: DateTime.utc_now(:microsecond)
             )

    Agent.update(script, &Map.put(&1, :block_first?, false))
    send(provider, :release_model)
    assert wait_for_completion(event.id).completed_at
    assert Repo.reload!(event).human_uid == owner_uid
    assert Repo.reload!(event).human_access_version == owner_version

    assert Agent.get(script, &Map.fetch!(&1.requests_by_event, event.id)) ==
             if(tool_effect?, do: 2, else: 1)

    notice =
      Repo.get_by!(Ankole.Conversations.Delivery.Intent,
        source_signal_id: event.id,
        outbound_key: "ai-turn-stopped:" <> event.id
      )

    assert notice.payload["metadata"]["reason"] == "context_withdrawn"

    if tool_effect? do
      assert Repo.get_by!(Ankole.Conversations.Conversation, provider_conversation_id: channel_id).ambient_standing_orders ==
               "Keep the completed channel orders."

      assert Repo.reload!(journal) == journal
    end
  end

  defp attrs(key) do
    %{
      producer: :kernel,
      target: key,
      sender: key.agent_uid,
      authorization: Ankole.Principals.WorkAccess.service(),
      source: "test://session-driver",
      reply_route: %{binding_name: "control-plane:test"},
      id: Ecto.UUID.generate(),
      type: "conversation.message.addressed",
      available_at: DateTime.utc_now(:microsecond),
      data: %{"entry" => %{"text" => "What is six times seven?"}}
    }
  end

  defp fire_checkback!(key, event_attrs) do
    now = DateTime.utc_now(:microsecond)
    source = Ankole.WorkFixtures.service_source(key.agent_uid)
    wake = event_attrs.data["wake_payload"]

    {:ok, %{scheduled_event: event}} =
      Ankole.Schedule.create_check_back_later(
        %{
          agent_uid: key.agent_uid,
          session_id: key.session_id,
          source_signal_id: source.id,
          binding_name: event_attrs.reply_route[:binding_name],
          reply_route:
            Map.take(event_attrs.reply_route, [
              :conversation_id,
              :provider_thread_id,
              :provider_message_id
            ]),
          tool_call_id: "driver-check:" <> Ecto.UUID.generate(),
          idempotency_key: Ecto.UUID.generate(),
          schedule: %{
            "at" => DateTime.to_iso8601(DateTime.add(now, -60, :second)),
            "timezone" => "UTC"
          },
          reason: "Driver scheduled contract",
          check: wake["payload"]["prompt"],
          quiet_success: wake["delivery"]["quiet_success"]
        },
        now: DateTime.add(now, -360, :second)
      )

    {:ok, %{signal: signal}} = Ankole.Schedule.fire_due_event(event.id, now: now)
    wake_committed_session!(key)
    signal
  end

  defp wake_committed_session!(key) do
    job =
      Repo.one!(
        from(j in Oban.Job,
          where:
            j.worker == "Ankole.Sessions.Jobs.EnsureDriver" and
              fragment("?->>'agent_uid'", j.args) == ^key.agent_uid and
              fragment("?->>'session_id'", j.args) == ^key.session_id and
              j.state in ["available", "scheduled", "retryable"],
          order_by: [asc: j.scheduled_at, asc: j.id],
          limit: 1
        )
      )

    assert DateTime.compare(job.scheduled_at, DateTime.utc_now(:microsecond)) in [:lt, :eq]
    assert :ok = Ankole.Sessions.Jobs.EnsureDriver.perform(job)
  end

  defp job_reply_route(key, suffix) do
    {:ok, conversation} =
      Repo.transact(fn repo ->
        Ankole.Conversations.External.observe_conversation_in_tx(
          repo,
          %{agent_uid: key.agent_uid},
          %{
            provider_conversation_id: "mock:driver-job:" <> suffix,
            external_kind: :im_group,
            reply_mode: :channel,
            title: "Driver Job reply"
          },
          DateTime.utc_now(:microsecond)
        )
      end)

    %{"binding_name" => "control-plane:test", "conversation_id" => conversation.id}
  end

  defp tool_call(id, name, args) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{"name" => name, "arguments" => Ankole.JSON.encode!(args)}
    }
  end

  defp tool_events(request, calls) do
    %{
      "id" => "chatcmpl_tools",
      "object" => "chat.completion.chunk",
      "created" => 1_764_967_971,
      "model" => request.body["model"],
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{
            "role" => "assistant",
            "tool_calls" => Enum.with_index(calls, &Map.put(&1, "index", &2))
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7, "total_tokens" => 12}
    }
    |> List.wrap()
  end

  defp crash_after_receipt(key) do
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, parent ->
          if String.starts_with?(metadata.query, "INSERT INTO \"session_tool_receipts\"") do
            send(parent, {:receipt_before_commit, self()})

            receive do
              :commit_receipt -> :ok
            after
              10000 -> raise "receipt transaction was not released"
            end
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, event} = Ankole.Signals.accept(attrs(key))
    _first = await_request(key)
    assert_receive {:receipt_before_commit, tool_pid}, 10000
    pid = Ankole.Sessions.driver_pid(key)
    :ok = :sys.suspend(pid)
    send(tool_pid, :commit_receipt)
    receipt = wait_for_receipt(key.agent_uid)
    :telemetry.detach(handler)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5000
    {event, receipt}
  end

  defp wait_for_receipt(uid, attempts \\ 200)

  defp wait_for_receipt(_uid, 0) do
    flunk("the tool receipt did not commit")
  end

  defp wait_for_receipt(uid, attempts) do
    case Repo.one(from(r in Receipts, where: r.agent_uid == ^uid)) do
      nil ->
        Process.sleep(25)
        wait_for_receipt(uid, attempts - 1)

      receipt ->
        receipt
    end
  end

  defp await_request(key, timeout \\ 10000) do
    receive do
      {:model_request, request} -> request
    after
      timeout ->
        pid = Ankole.Sessions.driver_pid(key)

        inputs =
          Repo.all(
            from(e in Signal,
              where: e.agent_uid == ^key.agent_uid and e.session_id == ^key.session_id,
              select: {e.id, e.input_state, e.completed_at, e.available_at}
            )
          )

        flunk("no model request; driver: #{inspect(pid)}; inputs: #{inspect(inputs)}")
    end
  end

  defp wait_for_completion(id, attempts \\ 200)

  defp wait_for_completion(id, 0) do
    flunk("input #{id} did not complete: #{inspect(Repo.get!(Signal, id))}")
  end

  defp wait_for_completion(id, attempts) do
    case Repo.get!(Signal, id) do
      %Signal{completed_at: %DateTime{}} = event ->
        event

      %Signal{input_state: "dead_letter"} = event ->
        flunk("input failed: #{inspect(event.dead_letter_reason)}")

      _open ->
        Process.sleep(25)
        wait_for_completion(id, attempts - 1)
    end
  end
end
