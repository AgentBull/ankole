defmodule Ankole.Conversations.NativeDriverTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.AIGatewayCase,
    only: [start_upstream_server: 1, chat_completion_stream_events: 2]

  import Ankole.SessionsCase,
    only: [agent_fixture: 1, cache_actor_runtime_models: 1]

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ResponseChain
  alias Ankole.Conversations
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Message
  alias Ankole.Sessions.Jobs.EnsureDriver
  alias Ankole.Signals.Signal
  alias Ankole.SessionsCase, as: RuntimeCase

  setup %{tenant: tenant} do
    drivers = RuntimeCase.driver_pids()
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture(%{mobile: nil})

    %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
    {:ok, profile} = ModelProfiles.get_model_profile(agent.uid, "primary")
    owner = self()
    script = start_supervised!({Agent, fn -> %{rounds: [], requests: 0, block_first?: true} end})

    url =
      start_upstream_server(fn request ->
        assert request.request_path == "/chat/completions"
        assert request.body["stream"] == true
        send(owner, {:native_model_request, request})

        {round, blocked?} =
          Agent.get_and_update(script, fn state ->
            {{Enum.at(state.rounds, state.requests, {:text, "A committed native answer."}),
              state.requests == 0 and state.block_first?},
             %{state | requests: state.requests + 1}}
          end)

        if blocked? do
          send(owner, {:native_model_waiting, self()})

          receive do
            :release_model -> :ok
          after
            30_000 -> raise "the test did not release its model response"
          end
        end

        case round do
          {:text, text} ->
            {:sse, 200, chat_completion_stream_events(request, text)}

          :tool ->
            {:sse, 200, tool_events(request)}

          {:scheduled, text} ->
            {:sse, 200,
             tool_events(request, "finish_scheduled", %{"outcome" => "reply", "reply" => text})}

          :silent ->
            {:sse, 200,
             tool_events(request, "finish_scheduled", %{
               "outcome" => "silent_success",
               "reply" => nil
             })}
        end
      end)

    {:ok, _} = ProviderConfigs.update_provider(profile["provider_id"], %{base_url: url})
    :ok = cache_actor_runtime_models(profile["provider_id"])

    on_exit(
      Repo.bind_tenant(fn ->
        RuntimeCase.stop_new_drivers(drivers)
        Repo.delete_all(Conversation)

        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'agent_uid'", j.args) == ^agent.uid)
        )

        :ok =
          Ankole.AgentWorkers.WorkerEnv.delete_agent_rows_in_tx(agent.uid)

        Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)
        {:ok, _} = ProviderConfigs.delete_provider(profile["provider_id"])
        {:ok, _} = ProviderConfigs.delete_provider(profile["provider_id"])
        cleanup_tenant!(tenant)
      end)
    )

    {:ok, human: human, agent: agent, script: script}
  end

  test "native activity stays responsive while the terminal transaction waits", %{
    human: human,
    agent: agent
  } do
    message_id = Ecto.UUID.generate()

    assert {:ok, detail} =
             Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{
               conversation_id: Ecto.UUID.generate(),
               agent_uid: agent.uid,
               message_id: message_id,
               text: "Complete this native reply."
             })

    _ = await_request()
    assert_receive {:native_model_waiting, provider}, 5_000
    key = %{agent_uid: agent.uid, session_id: detail.session_id}
    signal_id = event_for(message_id).id
    native_signal_id = Ecto.UUID.dump!(signal_id)
    owner = self()
    handler = "responsive-finalizing-#{message_id}"

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn
        _,
        _,
        %{
          source: "signals",
          result: {:ok, %Postgrex.Result{command: :update, columns: columns, rows: [values]}}
        },
        parent ->
          case Map.new(Enum.zip(columns, values)) do
            %{
              "id" => ^native_signal_id,
              "status" => "completed",
              "completed_at" => completed_at
            }
            when not is_nil(completed_at) ->
              send(parent, {:terminal_waiting, self()})

              receive do
                :release_terminal -> :ok
              after
                10_000 -> raise "terminal transaction was not released"
              end

            _row ->
              :ok
          end

        _, _, _, _ ->
          :ok
      end,
      owner
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    send(provider, :release_model)
    assert_receive {:terminal_waiting, finalizer}, 5_000

    try do
      driver = Ankole.Sessions.driver_pid(key)
      assert {%{state: "active", agentUID: uid}, ^driver} = Ankole.Sessions.Activity.current(key)
      assert uid == agent.uid
      assert {:finalizing, _} = :sys.get_state(driver)
      send(driver, {:inbox, signal_id})
      send(driver, {:recover_preview, signal_id})
      assert {%{state: "active", agentUID: ^uid}, ^driver} = Ankole.Sessions.Activity.current(key)
    after
      :telemetry.detach(handler)
      send(finalizer, :release_terminal)
    end

    assert wait_for_completion(event_for(message_id).id).completed_at
  end

  test "native messages stream through AIGateway and continue the same model conversation",
       context do
    %{human: human, agent: agent, script: script} = context
    baseline = gateway_row_counts()
    id = Ecto.UUID.generate()
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()

    Agent.update(
      script,
      &%{&1 | rounds: [{:text, "Six times seven is 42."}, {:text, "Twice that is 84."}]}
    )

    assert {:ok, first_detail} =
             Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{
               conversation_id: id,
               agent_uid: agent.uid,
               message_id: first_id,
               text: "What is six times seven?"
             })

    first_request = await_request()
    assert Ankole.JSON.encode!(first_request.body["messages"]) =~ "What is six times seven?"
    assert_receive {:native_model_waiting, provider}, 5_000
    assert :ok = Events.subscribe(agent.uid, first_detail.model_conversation_id)
    assert :ok = Conversations.Events.subscribe(id)
    send(provider, :release_model)

    assert_receive {:ai_gateway_event, :output_text_delta,
                    %{conversation_id: model_id, payload: %{text: "Six times seven is 42."}}},
                   5_000

    assert model_id == first_detail.model_conversation_id
    first_event = event_for(first_id)
    assert wait_for_completion(first_event.id).attempt_count == 1
    assert_receive {:conversation_event, ^id, :message}, 5_000

    assert {:ok, completed} =
             Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id)

    assert Ankole.Sessions.status(%{agent_uid: agent.uid, session_id: completed.session_id}).state ==
             :idle

    assert Enum.map(completed.messages, &{&1.seq, &1.author_type, &1.text}) ==
             [{1, :human, "What is six times seven?"}, {2, :agent, "Six times seven is 42."}]

    assert {:ok, continued} =
             Conversations.post(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id, %{
               message_id: second_id,
               text: "And twice that?"
             })

    second_request = await_request()
    assert Ankole.JSON.encode!(second_request.body["messages"]) =~ "Six times seven is 42."
    assert Ankole.JSON.encode!(second_request.body["messages"]) =~ "And twice that?"
    assert continued.model_conversation_id == model_id
    assert wait_for_completion(event_for(second_id).id).attempt_count == 1

    assert {:ok, final} =
             Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id)

    assert Enum.map(final.messages, &{&1.seq, &1.author_type, &1.text}) ==
             [
               {1, :human, "What is six times seven?"},
               {2, :agent, "Six times seven is 42."},
               {3, :human, "And twice that?"},
               {4, :agent, "Twice that is 84."}
             ]

    [first_reply, second_reply] = Enum.filter(final.messages, &(&1.author_type == :agent))
    assert first_reply.signal_id == first_event.id
    assert first_reply.reply_to_message_id == first_id
    assert second_reply.reply_to_message_id == second_id
    assert first_reply.session_id == Ankole.Sessions.Key.conversation(id)
    assert ResponseChain.latest_visible_leaf(model_id)
    assert gateway_row_counts() == baseline

    assert {:ok, replayed_first} =
             Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{
               conversation_id: id,
               agent_uid: agent.uid,
               message_id: first_id,
               text: "What is six times seven?"
             })

    assert {:ok, replayed_second} =
             Conversations.post(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id, %{
               message_id: second_id,
               text: "And twice that?"
             })

    assert replayed_first.messages == final.messages
    assert replayed_second.messages == final.messages
    assert Agent.get(script, & &1.requests) == 2
    assert event_for(first_id).id == first_event.id
    assert event_for(second_id).attempt_count == 1
    refute_receive {:native_model_request, _}, 100
  end

  test "a detail read cannot combine an old transcript with a completed status", context do
    %{human: human, agent: agent} = context
    id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{
               conversation_id: id,
               agent_uid: agent.uid,
               message_id: message_id,
               text: "Read this reply consistently."
             })

    _ = await_request()
    assert_receive {:native_model_waiting, provider}, 5_000
    signal = event_for(message_id)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata.source == "conversation_messages" and Process.get(handler) == :armed do
            Process.put(handler, :waiting)
            send(owner, {:detail_messages_read, self()})

            receive do
              :release_detail -> :ok
            after
              5_000 -> raise "the test did not release its detail read"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    reader =
      Task.async(
        Repo.bind_tenant(fn ->
          Repo.checkout(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(owner, {:detail_backend, backend})
            Process.put(handler, :armed)
            detail_response(human.uid, id)
          end)
        end)
      )

    assert_receive {:detail_backend, backend}, 5_000
    assert_receive {:detail_messages_read, reader_pid}, 5_000
    send(provider, :release_model)

    try do
      await_detail_completion_boundary(signal.id, backend)
    after
      send(reader_pid, :release_detail)
    end

    detail = Task.await(reader, 5_000)

    assert Enum.find(detail["pendingQueues"], &(&1["agentUID"] == agent.uid))["workStatus"][
             "state"
           ] == "running"

    assert [%{"id" => ^message_id}] = detail["messages"]

    _ = wait_for_completion(signal.id)
    completed = detail_response(human.uid, id)

    assert Enum.find(completed["pendingQueues"], &(&1["agentUID"] == agent.uid))["workStatus"][
             "state"
           ] == "idle"

    assert [_, %{"authorType" => "agent", "text" => "A committed native answer."}] =
             completed["messages"]
  end

  test "a follow-up while generating joins the active turn exactly once", context do
    %{human: human, agent: agent, script: script} = context
    baseline = gateway_row_counts()
    id = Ecto.UUID.generate()
    first_id = Ecto.UUID.generate()
    followup_id = Ecto.UUID.generate()

    Agent.update(
      script,
      &%{&1 | rounds: [:tool, {:text, "The report includes the operator runbook."}]}
    )

    assert {:ok, _} =
             Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{
               conversation_id: id,
               agent_uid: agent.uid,
               message_id: first_id,
               text: "Prepare the report."
             })

    _ = await_request()
    assert_receive {:native_model_waiting, provider}, 5_000

    driver =
      Ankole.Sessions.driver_pid(%{
        agent_uid: agent.uid,
        session_id: Ankole.Sessions.Key.conversation(id)
      })

    assert {:ok, _} =
             Conversations.post(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id, %{
               message_id: followup_id,
               text: "Include the operator runbook."
             })

    send(provider, :release_model)
    next = await_request()

    assert Enum.count(next.body["messages"], fn message ->
             String.contains?(Ankole.JSON.encode!(message), "Include the operator runbook.")
           end) == 1

    assert Ankole.Sessions.driver_pid(%{
             agent_uid: agent.uid,
             session_id: Ankole.Sessions.Key.conversation(id)
           }) ==
             driver

    first = wait_for_completion(event_for(first_id).id)
    followup = wait_for_completion(event_for(followup_id).id)
    assert first.attempt_count == 1
    assert followup.last_attempt_at
    assert first.completed_at == followup.completed_at

    assert {:ok, detail} =
             Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id)

    assert Enum.map(detail.messages, & &1.author_type) == [:human, :human, :agent]
    assert List.last(detail.messages).text == "The report includes the operator runbook."
    assert Agent.get(script, & &1.requests) == 2
    assert gateway_row_counts() == baseline
    refute_receive {:native_model_request, _}, 100
  end

  test "the durable wakeup resumes admitted native input after the driver crashes", context do
    %{human: human, agent: agent} = context
    baseline = gateway_row_counts()
    id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()
    key = %{agent_uid: agent.uid, session_id: Ankole.Sessions.Key.conversation(id)}

    assert {:ok, {:ok, _}} =
             Repo.transact(fn ->
               {:ok,
                Conversations.create_in_tx(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{
                  conversation_id: id,
                  agent_uid: agent.uid,
                  message_id: message_id,
                  text: "Recover this committed request."
                })}
             end)

    assert Ankole.Sessions.driver_pid(key) == :undefined

    job =
      Repo.one!(
        from(j in Oban.Job,
          where:
            j.worker == "Ankole.Sessions.Jobs.EnsureDriver" and
              fragment("?->>'session_id'", j.args) == ^key.session_id
        )
      )

    assert :ok = EnsureDriver.perform(job)
    _ = await_request()
    assert_receive {:native_model_waiting, provider}, 5_000
    event = event_for(message_id)
    assert Repo.reload!(event).last_attempt_at

    assert Repo.aggregate(
             from(m in Message, where: m.conversation_id == ^id and m.author_type == :agent),
             :count
           ) == 0

    driver = Ankole.Sessions.driver_pid(key)
    monitor = Process.monitor(driver)
    Process.exit(driver, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^driver, :killed}, 5_000
    send(provider, :release_model)
    assert :ok = EnsureDriver.perform(job)
    retried = await_request()
    assert Ankole.JSON.encode!(retried.body["messages"]) =~ "Recover this committed request."
    completed = wait_for_completion(event.id)
    assert completed.attempt_count == 2

    assert {:ok, detail} =
             Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id)

    assert Enum.map(detail.messages, & &1.author_type) == [:human, :agent]
    assert List.last(detail.messages).text == "A committed native answer."

    assert Ankole.Sessions.status(%{agent_uid: agent.uid, session_id: detail.session_id}).state ==
             :idle

    assert gateway_row_counts() == baseline
  end

  for ingress <- [:cloudevents, :raw] do
    @ingress ingress
    @tag :external_signal_roundtrip
    test "#{ingress} HTTP input reaches the native Session and replay does not answer twice",
         %{human: human, agent: agent, script: script} do
      Agent.update(
        script,
        &%{
          &1
          | block_first?: false,
            rounds: [
              {:text, "Initial native answer."},
              {:text, "External report received."}
            ]
        }
      )

      id = Ecto.UUID.generate()
      message_id = Ecto.UUID.generate()
      nonce = Ecto.UUID.generate()

      assert {:ok, _} =
               Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{
                 conversation_id: id,
                 agent_uid: agent.uid,
                 message_id: message_id,
                 text: "Watch incoming external reports."
               })

      _ = await_request()
      source = wait_for_completion(event_for(message_id).id)
      expires = DateTime.add(DateTime.utc_now(:microsecond), 1, :hour)

      attrs =
        case @ingress do
          :cloudevents ->
            %{
              label: "External report",
              mode: "standing",
              event_format: "cloudevents",
              expires_at: expires
            }

          :raw ->
            %{
              label: "External receipt",
              mode: "one_shot",
              agent_uid: agent.uid,
              session_id: source.session_id,
              conversation_id: id,
              source_signal_id: source.id,
              source_provenance: %{"kind" => "integration"},
              expires_at: expires
            }
        end

      assert {:ok, endpoint} = Ankole.Signals.Webhooks.create_endpoint(attrs)

      if @ingress == :cloudevents do
        assert {:ok, _} =
                 Ankole.Signals.Bindings.put_binding(agent.uid, "cloudevents", "reports", %{
                   "config" => %{"webhook_endpoint_id" => endpoint.webhook_endpoint.id},
                   "target" => %{"conversation_id" => id},
                   "filters" => %{"cel" => "signal.data.priority == 'urgent'"}
                 })
      end

      on_exit(
        Repo.bind_tenant(fn ->
          Repo.delete_all(
            from(b in Ankole.Signals.Binding,
              where: b.agent_uid == ^agent.uid and b.adapter == "cloudevents"
            )
          )

          Repo.delete_all(
            from(e in Ankole.Signals.WebhookEndpoint,
              where: e.id == ^endpoint.webhook_endpoint.id
            )
          )
        end)
      )

      server =
        start_supervised!(
          {Bandit, plug: AnkoleWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: :signal_ingress
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)

      {path, content_type, body, type, status} =
        case @ingress do
          :cloudevents ->
            {"/signals/v1/cloudevents/#{endpoint.token}", "application/cloudevents+json",
             %{
               "specversion" => "1.0",
               "id" => nonce,
               "source" => "https://reports.example/changes",
               "type" => "report.changed",
               "data" => %{"priority" => "urgent", "nonce" => nonce}
             }, "report.changed", 202}

          :raw ->
            {"/webhooks/v1/event-callbacks/#{endpoint.token}", "application/json",
             %{"nonce" => nonce}, "webhook.received", 204}
        end

      url = "http://127.0.0.1:#{port}#{path}"
      headers = [{"content-type", content_type}]

      if @ingress == :cloudevents do
        filtered = put_in(body, ["data", "priority"], "low")

        assert %{status: 202, body: %{"signal_ids" => []}} =
                 Req.post!(url, headers: headers, json: filtered)

        refute_receive {:native_model_request, _}, 100
      end

      assert %{status: ^status} = Req.post!(url, headers: headers, json: body)
      request = await_request()
      assert Ankole.JSON.encode!(request.body["messages"]) =~ nonce
      signal = Repo.one!(from(s in Signal, where: s.agent_uid == ^agent.uid and s.type == ^type))
      assert wait_for_completion(signal.id).attempt_count == 1
      assert signal.session_id == source.session_id
      assert signal.conversation_id == id

      assert {:ok, detail} =
               Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id)

      assert List.last(detail.messages).text == "External report received."
      assert List.last(detail.messages).signal_id == signal.id

      assert %{status: ^status} = Req.post!(url, headers: headers, json: body)
      assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
      refute_receive {:native_model_request, _}, 150

      assert Repo.aggregate(
               from(s in Signal, where: s.agent_uid == ^agent.uid and s.type == ^type),
               :count
             ) == 1

      assert {:ok, after_replay} =
               Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id)

      assert length(after_replay.messages) == length(detail.messages)
      assert Agent.get(script, & &1.requests) == 2
    end
  end

  test "a native cron report is a committed statement that the owning session reads once",
       context do
    %{human: human, agent: agent, script: script} = context

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: human.uid,
        resource_pattern: "agent:#{agent.uid}:tool:finish_scheduled",
        action: "invoke"
      })

    Agent.update(
      script,
      &%{
        &1
        | block_first?: false,
          rounds: [
            {:text, "Initial native answer."},
            {:scheduled, "Cron observed 17 new records."},
            {:text, "I read the cron report."},
            :silent
          ]
      }
    )

    id = Ecto.UUID.generate()
    input_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{
               conversation_id: id,
               message_id: input_id,
               agent_uid: agent.uid,
               text: "Review the records."
             })

    _ = await_request()
    _ = wait_for_completion(event_for(input_id).id)
    assert :ok = Conversations.Events.subscribe(id)

    schedule = native_cron(context, id, true)
    assert is_nil(schedule.binding_name)

    assert {:ok, %{status: :fired, signal: cron}} =
             Ankole.Schedule.fire_cron(schedule.id, now: schedule.next_fire_at)

    request = await_request()

    refute Enum.any?(request.body["messages"], fn message ->
             message["role"] == "user" and Ankole.JSON.encode!(message) =~ "Review the records."
           end)

    assert cron.session_id == Ankole.Schedule.Cron.execution_session_id(schedule.id)
    cron_model = Ankole.Sessions.ModelHistory.active_conversation(agent.uid, cron.session_id)

    native_model =
      Ankole.Sessions.ModelHistory.active_conversation(
        agent.uid,
        Ankole.Sessions.Key.conversation(id)
      )

    assert cron_model.id != native_model.id
    _ = wait_for_completion(cron.id)
    assert_receive {:conversation_event, ^id, :message}, 5_000

    assert {:ok, detail} =
             Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id)

    report = List.last(detail.messages)
    assert report.text == "Cron observed 17 new records."
    assert report.session_id == Ankole.Schedule.Cron.execution_session_id(schedule.id)
    assert report.signal_id == cron.id
    assert is_nil(report.reply_to_message_id)

    assert Ankole.Sessions.status(%{agent_uid: agent.uid, session_id: detail.session_id}).state ==
             :idle

    follow_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.post(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id, %{
               message_id: follow_id,
               text: "Interpret the new records."
             })

    follow = await_request()
    encoded = Ankole.JSON.encode!(follow.body["messages"])
    assert length(Regex.scan(~r/Cron observed 17 new records\./, encoded)) == 1
    assert length(Regex.scan(~r/Interpret the new records\./, encoded)) == 1
    _ = wait_for_completion(event_for(follow_id).id)

    assert {:ok, %{status: :created, cron_schedule: quiet}} =
             Ankole.Schedule.create_cron_schedule(
               %{
                 agent_uid: agent.uid,
                 owner_session_id: Ankole.Sessions.Key.conversation(id),
                 name: "Quiet native monitor",
                 schedule: recurrence(),
                 payload: %{"task" => "Check silently when there is no change."},
                 delivery: %{"targets" => [%{"conversation_id" => id}], "quiet_success" => true},
                 idempotency_key: Ecto.UUID.generate()
               },
               created_by: %{"principal_uid" => to_string(Ankole.ActorRef.from_principal(human))},
               now: DateTime.add(DateTime.utc_now(:microsecond), -5, :second)
             )

    assert {:ok, %{signal: silent}} =
             Ankole.Schedule.fire_cron(quiet.id, now: quiet.next_fire_at)

    _ = await_request()
    _ = wait_for_completion(silent.id)

    assert {:ok, after_silent} =
             Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(human.uid), id)

    assert length(after_silent.messages) == 5
  end

  test "a cron report arriving during a model call is read at the following request boundary",
       context do
    %{human: human, agent: agent, script: script} = context

    Agent.update(
      script,
      &%{
        &1
        | rounds: [
            :tool,
            {:scheduled, "A late cron report."},
            {:text, "The late report is included."}
          ]
      }
    )

    id = Ecto.UUID.generate()
    input_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{
               conversation_id: id,
               message_id: input_id,
               agent_uid: agent.uid,
               text: "Prepare a report."
             })

    first = await_request()
    refute Ankole.JSON.encode!(first.body["messages"]) =~ "A late cron report."
    assert_receive {:native_model_waiting, provider}, 5_000
    schedule = native_cron(context, id, false)

    assert {:ok, %{signal: cron}} =
             Ankole.Schedule.fire_cron(schedule.id, now: schedule.next_fire_at)

    _ = await_request()
    _ = wait_for_completion(cron.id)
    send(provider, :release_model)
    next = await_request()
    encoded = Ankole.JSON.encode!(next.body["messages"])
    assert length(Regex.scan(~r/A late cron report\./, encoded)) == 1
    _ = wait_for_completion(event_for(input_id).id)
  end

  for change <- [:edit, :remove] do
    @quote_change change
    test "a quoted statement #{@quote_change} follows the stored-input withdrawal contract",
         context do
      %{human: human, agent: agent, script: script} = context
      Agent.update(script, &%{&1 | rounds: [{:text, "Stale answer."}, {:text, "Fresh answer."}]})

      assert {:ok, room} =
               Repo.transact(fn ->
                 Ankole.Conversations.External.observe_conversation_in_tx(
                   %{agent_uid: agent.uid},
                   %{
                     provider_conversation_id: "quote-room",
                     external_kind: :im_dm,
                     title: "Quoted request",
                     reply_mode: :channel,
                     metadata: %{"dm_peer_principal_uid" => human.uid}
                   },
                   DateTime.utc_now(:microsecond)
                 )
               end)

      now = DateTime.utc_now(:microsecond)

      quote_attrs = %{
        provider_message_id: "quoted",
        text: "Original code OLD-101",
        author: %{"principal_uid" => human.uid}
      }

      assert {:ok, %{message: quote}} =
               Repo.transact(fn ->
                 Ankole.Conversations.External.observe_in_tx(room.id, quote_attrs, now)
               end)

      assert {:ok, %{message: current}} =
               Repo.transact(fn ->
                 Ankole.Conversations.External.observe_in_tx(
                   room.id,
                   %{
                     provider_message_id: "request",
                     text: "Use the quoted code.",
                     author: %{"principal_uid" => human.uid}
                   },
                   now
                 )
               end)

      data = %{
        "message_ids" => [current.id],
        "text" => current.text,
        "entry" => %{
          "text" => current.text,
          "author" => %{"principal_uid" => human.uid},
          "reply_to_provider_message_id" => "quoted",
          "reply_to" => %{
            "message_id" => quote.id,
            "provider_message_id" => "quoted",
            "resolution" => "resolved",
            "text" => quote.text
          }
        }
      }

      assert {:ok, signal} =
               Ankole.Signals.accept(%{
                 producer: :kernel,
                 source: "test:quoted-request",
                 id: Ecto.UUID.generate(),
                 type: "conversation.message.addressed",
                 target: %{agent_uid: agent.uid, conversation_id: room.id},
                 sender: human.uid,
                 message_id: current.id,
                 data: data,
                 time: now,
                 reply_route: %{conversation_id: room.id, provider_message_id: "request"}
               })

      first = await_request()
      assert length(Regex.scan(~r/OLD-101/, Ankole.JSON.encode!(first.body["messages"]))) == 1
      assert_receive {:native_model_waiting, provider}, 5_000

      case @quote_change do
        :edit ->
          assert {:ok, _} =
                   Repo.transact(fn ->
                     Ankole.Conversations.External.observe_in_tx(
                       room.id,
                       %{quote_attrs | text: "Updated code NEW-202"},
                       DateTime.utc_now(:microsecond)
                     )
                   end)

        :remove ->
          assert {:ok, _} =
                   Repo.transact(fn ->
                     Ankole.Conversations.External.remove_in_tx(room.id, "quoted")
                   end)
      end

      assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
      send(provider, :release_model)
      completed = wait_for_completion(signal.id)

      if @quote_change == :edit do
        assert completed.turn_outcome == "loop_finished"
      else
        refute Repo.exists?(
                 from(intent in Ankole.Conversations.Delivery.Intent,
                   where:
                     intent.source_signal_id == ^signal.id and
                       intent.delivery_class == :durable_ai_reply
                 )
               )
      end

      assert Repo.reload!(signal).data == data

      assert Ankole.Principals.WorkAccess.fields(Repo.reload!(signal)) ==
               Ankole.Principals.WorkAccess.fields(signal)

      refute Repo.exists?(from(revision in Signal, where: revision.type == "input.revised"))
      assert Agent.get(script, & &1.requests) == 1
    end
  end

  defp recurrence do
    %{
      "kind" => "every",
      "every_ms" => 3_600_000,
      "anchor_at" =>
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(:microsecond), -1, :second)),
      "timezone" => "UTC"
    }
  end

  defp native_cron(context, id, quiet) do
    assert {:ok, %{status: :created, cron_schedule: schedule}} =
             Ankole.Schedule.create_cron_schedule(
               %{
                 agent_uid: context.agent.uid,
                 owner_session_id: Ankole.Sessions.Key.conversation(id),
                 name: "Native monitor",
                 schedule: recurrence(),
                 payload: %{"task" => "Report new records."},
                 delivery: %{"targets" => [%{"conversation_id" => id}], "quiet_success" => quiet},
                 idempotency_key: Ecto.UUID.generate()
               },
               created_by: %{
                 "principal_uid" => to_string(Ankole.ActorRef.from_principal(context.human))
               },
               now: DateTime.add(DateTime.utc_now(:microsecond), -5, :second)
             )

    schedule
  end

  defp detail_response(human_uid, id) do
    input =
      Ash.ActionInput.for_action(Ankole.Pod.Chat.Browser, :show, %{id: id},
        tenant: Repo.tenant_id!()
      )

    assert {:ok, detail} =
             Ankole.Ash.run_action_authorized(
               input,
               Ankole.PrincipalsFixtures.actor_fixture(human_uid)
             )

    detail |> Ankole.JSON.encode!() |> Ankole.JSON.decode!()
  end

  defp await_detail_completion_boundary(id, backend, attempts \\ 200)

  defp await_detail_completion_boundary(_id, _backend, 0),
    do: flunk("completion neither committed nor waited for the detail read")

  defp await_detail_completion_boundary(id, backend, attempts) do
    waiting =
      Repo.query!(
        """
        SELECT pid FROM pg_stat_activity
        WHERE datname = current_database() AND $1 = ANY(pg_blocking_pids(pid))
        LIMIT 1
        """,
        [backend]
      ).rows

    unless waiting != [] or Repo.get!(Signal, id).completed_at do
      Process.sleep(25)
      await_detail_completion_boundary(id, backend, attempts - 1)
    end
  end

  defp event_for(message_id), do: Repo.get_by!(Signal, source_event_id: message_id)

  defp gateway_row_counts do
    for schema <- [
          Ankole.Signals.Binding,
          Ankole.Conversations.ExternalMessageRef,
          Ankole.Conversations.Delivery.Intent
        ],
        into: %{},
        do: {schema, Repo.aggregate(schema, :count)}
  end

  defp await_request do
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)

    receive do
      {:native_model_request, request} -> request
    after
      10_000 ->
        drivers =
          Enum.map(RuntimeCase.driver_pids(), fn pid ->
            {state, data} = :sys.get_state(pid)
            %{state: state, tasks: Enum.map(data.tasks, fn {_ref, {kind, _pid}} -> kind end)}
          end)

        signals =
          Repo.all(
            from(s in Signal,
              select: %{
                id: s.id,
                type: s.type,
                status: s.status,
                attempts: s.attempt_count,
                completed_at: s.completed_at
              }
            )
          )

        flunk("native model request timed out: #{inspect(%{drivers: drivers, signals: signals})}")
    end
  end

  defp wait_for_completion(id, attempts \\ 400)

  defp wait_for_completion(id, 0),
    do: flunk("native input did not complete: #{inspect(Repo.get!(Signal, id))}")

  defp wait_for_completion(id, attempts) do
    case Repo.get!(Signal, id) do
      %Signal{completed_at: %DateTime{}} = event ->
        event

      %Signal{status: :dead_letter} = event ->
        flunk("native input failed: #{inspect(event.dead_letter_reason)}")

      _ ->
        Process.sleep(25)
        wait_for_completion(id, attempts - 1)
    end
  end

  defp tool_events(request, name \\ "todo", args \\ %{}) do
    [
      %{
        "id" => "chatcmpl_native_tool",
        "object" => "chat.completion.chunk",
        "created" => 1_764_967_971,
        "model" => request.body["model"],
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "native_plan",
                  "type" => "function",
                  "function" => %{"name" => name, "arguments" => Ankole.JSON.encode!(args)}
                }
              ]
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7, "total_tokens" => 12}
      }
    ]
  end
end
