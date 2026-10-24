defmodule AnkoleWeb.NativeActivityTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag sandbox: false
  import Ecto.Query
  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  alias Ankole.{Conversations, Repo, Sessions}
  alias Ankole.Sessions.{Activity, Run, SessionLane}
  alias Ankole.SessionsCase, as: RuntimeCase
  alias Ankole.RuntimeFabric.V1, as: Proto
  alias Ankole.AgentWorkers.WorkerRoute

  defmodule SnapshotAdapter do
    def send_chunked(state, _status, _headers), do: {:ok, "", state}

    def chunk(owner, data) do
      send(owner, {:snapshot_frame, IO.iodata_to_binary(data)})
      {:error, :closed}
    end
  end

  defmodule StreamAdapter do
    def send_chunked(state, _status, _headers), do: {:ok, "", state}

    def chunk(owner, data) do
      send(owner, {:stream_frame, self(), IO.iodata_to_binary(data)})

      receive do
        :continue -> :ok
        :close -> {:error, :closed}
      end
    end
  end

  setup %{conn: conn, tenant: tenant} do
    site_config =
      for key <- ["setup.completed", "tenants.privileged_tenant_id"],
          do: {key, Ankole.AppConfigure.get_global_by_key_in_tx(key)}

    restore_site_config = fn ->
      for {key, value} <- site_config do
        case value do
          {:ok, value} -> {:ok, _} = Ankole.AppConfigure.put_global_by_key(key, value)
          :error -> :ok = Ankole.AppConfigure.delete_global_by_key(key)
        end
      end
    end

    on_exit(restore_site_config)

    Ankole.AppConfigure.Cache.clear_for_test()
    drivers = RuntimeCase.driver_pids()
    {conn, human_uid} = console_conn_with_principal(conn)
    Repo.put_tenant_id(tenant.id)
    %{principal: agent} = RuntimeCase.agent_fixture(%{owner_principal_uid: human_uid})
    {:ok, profile} = Ankole.AIAgent.ModelProfiles.get_model_profile(agent.uid, "primary")
    owner = self()

    url =
      start_upstream_server(fn request ->
        send(owner, {:activity_model_request, request})
        {:sse, 200, tool_events(request)}
      end)

    {:ok, _} =
      Ankole.AIGateway.ProviderConfigs.update_provider(profile["provider_id"], %{base_url: url})

    :ok = RuntimeCase.cache_actor_runtime_models(profile["provider_id"])
    route = RuntimeCase.unique_route()
    :ok = WorkerRoute.register_local_worker(route, self())
    {:ok, _} = RuntimeCase.admit_worker(route, %{worker_id: agent.uid})

    on_exit(
      Repo.bind_tenant(fn ->
        try do
          RuntimeCase.stop_new_drivers(drivers)
          WorkerRoute.unregister_local_worker(route)
          Repo.delete_all(Conversations.Conversation)

          Repo.delete_all(
            from j in Oban.Job, where: fragment("?->>'agent_uid'", j.args) == ^agent.uid
          )

          :ok = Ankole.AgentWorkers.WorkerEnv.delete_agent_rows_in_tx(agent.uid)
          Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)

          # The provider owner first disables an active row, then deletes it.
          {:ok, _} = Ankole.AIGateway.ProviderConfigs.delete_provider(profile["provider_id"])
          {:ok, _} = Ankole.AIGateway.ProviderConfigs.delete_provider(profile["provider_id"])
        after
          restore_site_config.()
        end

        Ankole.DataCase.cleanup_tenant!(tenant)
      end)
    )

    {:ok, conn: conn, agent: agent, human_uid: human_uid}
  end

  test "native POST starts activity before SSE; late joins and reconnect observe capacity, then silent completion fences stale progress",
       %{conn: conn, agent: agent, human_uid: human_uid} do
    id = Ecto.UUID.generate()
    :ok = Sessions.Events.subscribe(agent.uid, Sessions.Key.conversation(id))

    conn =
      api_post(conn, ~p"/api/v2/pod/conversations", %{
        "conversationID" => id,
        "agentUID" => agent.uid,
        "messageID" => Ecto.UUID.generate(),
        "text" => "Check the report."
      })

    assert Phoenix.ConnTest.json_response(conn, 200)
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
    assert_receive {:activity_model_request, _}, 5_000
    assert_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, opened}}}, 5_000

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:workspace_ready, %Proto.WorkspaceReady{run: opened.run, reason: :CAPACITY}}
               },
               %{worker_id: agent.uid}
             )

    key = %{agent_uid: agent.uid, session_id: Sessions.Key.conversation(id)}

    {waiting, driver} =
      await_activity(
        key,
        &(&1.phase && String.ends_with?(&1.phase["label_key"], "computer_busy"))
      )

    assert_receive {:session_event, _, _,
                    {:activity, _publisher,
                     %{
                       tools: [
                         %{
                           "operation_id" => "native-jobs",
                           "label_key" =>
                             "conversations.delivery.reply.activity.background_job_list"
                         }
                       ]
                     }}},
                   1_000

    assert waiting.tools == []
    assert waiting.state == "active"
    # No SSE existed when the one-shot capacity phase was produced.
    first = sse_snapshot(conn, id)
    second = sse_snapshot(conn, id)
    assert first["phase"]["label_key"] == waiting.phase["label_key"]
    assert second == first
    assert first["epoch"] == waiting.epoch
    assert first["revision"] == waiting.revision
    shown = conn |> recycle_api() |> api_get(~p"/api/v2/pod/conversations/#{id}")
    assert Phoenix.ConnTest.json_response(shown, 200)["status"]["activity"] == first

    :ok = :sys.suspend(driver)

    try do
      {timed_out, ^driver} = Activity.current(key)
      assert timed_out.state == "unavailable"
      assert timed_out.phase == nil
      assert timed_out.tools == []

      assert {%{state: "unavailable", revision: revision}, true} =
               AnkoleWeb.PodStream.merge_activity(waiting, timed_out)

      assert revision == waiting.revision
    after
      :ok = :sys.resume(driver)
    end

    {:executing_tools, data} = :sys.get_state(driver)
    assert {:ok, _} = Run.finalize(data.turn.run, :silent)
    settled = sse_snapshot(conn, id)
    assert settled["state"] == "settled"
    assert settled["tools"] == []
    assert settled["phase"] == nil
    refute Activity.valid?(waiting)
    assert {:ok, detail} = Conversations.get(human_uid, id)
    assert length(detail.messages) == 1

    # The old process is still alive, but PostgreSQL has closed its Run.
    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:tool_progress,
                    %Proto.ToolProgress{
                      run: opened.run,
                      response_id: Run.response_id(data.turn.run.model_response),
                      call_id: "native-read-one",
                      presentation_json:
                        Ankole.JSON.encode!(%{
                          "kind" => "tool.activity",
                          "payload" => %{
                            "operation_id" => "native-read-one",
                            "phase" => "running",
                            "activity" => "Late stale tool"
                          }
                        })
                    }}
               },
               %{worker_id: agent.uid}
             )

    assert sse_snapshot(conn, id)["state"] == "settled"
    assert {:ok, after_stale} = Conversations.get(human_uid, id)
    assert after_stale.messages == detail.messages
    refute_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, _}}}, 100
  end

  test "an absent or dead Driver yields generic status without starting a process", %{
    conn: conn,
    agent: agent
  } do
    id = Ecto.UUID.generate()

    conn =
      api_post(conn, ~p"/api/v2/pod/conversations", %{
        "conversationID" => id,
        "agentUID" => agent.uid,
        "messageID" => Ecto.UUID.generate(),
        "text" => "Start a wait."
      })

    assert Phoenix.ConnTest.json_response(conn, 200)
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, _}}}, 5_000
    key = %{agent_uid: agent.uid, session_id: Sessions.Key.conversation(id)}
    {active, driver} = Activity.current(key)
    stream = start_stream(conn, id)
    assert_receive {:stream_frame, stream_pid, ": ping\n\nevent: activity\ndata: " <> _}, 1_000
    send(stream_pid, :continue)
    monitor = Process.monitor(driver)
    Process.exit(driver, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^driver, :killed}, 5_000
    {snapshot, nil} = Activity.current(key)
    assert snapshot.state == "unavailable"
    assert snapshot.phase == nil
    assert snapshot.tools == []
    assert Sessions.driver_pid(key) == :undefined
    assert_receive {:stream_frame, ^stream_pid, "event: activity\ndata: " <> down}, 1_000
    assert Ankole.JSON.decode!(String.trim(down))["state"] == "unavailable"
    # Simulate cross-node PubSub forwarding reaching the subscriber after DOWN.
    send(
      stream_pid,
      {:session_event, agent.uid, key.session_id,
       {:activity, driver, %{active | revision: active.revision + 1}}}
    )

    send(stream_pid, {:session_event, agent.uid, key.session_id, :status})
    send(stream_pid, :continue)
    assert_receive {:stream_frame, ^stream_pid, "event: status\n" <> _}, 1_000
    send(stream_pid, :close)
    assert %Plug.Conn{state: :chunked} = Task.await(stream)
  end

  test "real parallel Worker calls retain separate bounded labels and reject old response, call, epoch and terminal progress",
       %{conn: conn, agent: agent} do
    id = Ecto.UUID.generate()

    conn =
      api_post(conn, ~p"/api/v2/pod/conversations", %{
        "conversationID" => id,
        "agentUID" => agent.uid,
        "messageID" => Ecto.UUID.generate(),
        "text" => "Read both reports."
      })

    assert Phoenix.ConnTest.json_response(conn, 200)
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, opened}}}, 5_000

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body: {:workspace_ready, %Proto.WorkspaceReady{run: opened.run}}
               },
               %{worker_id: agent.uid}
             )

    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, first}}}, 5_000
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, second}}}, 5_000
    key = %{agent_uid: agent.uid, session_id: Sessions.Key.conversation(id)}

    progress(agent.uid, first, "running", %{
      "key" => "signals_gateway.reply.activity.read_file",
      "bindings" => %{"path" => "one", "hidden" => %{secret: true}}
    })

    progress(agent.uid, second, "running", "Read the second report")
    {snapshot, _} = await_activity(key, &(length(&1.tools) == 2))

    assert Enum.any?(
             snapshot.tools,
             &(&1["label_key"] == "conversations.delivery.reply.activity.read_file")
           )

    refute Ankole.JSON.encode!(snapshot) =~ "secret"

    assert Enum.map(snapshot.tools, & &1["operation_id"]) |> Enum.sort() ==
             Enum.sort([first.call_id, second.call_id])

    # These are accepted fabric envelopes for a real pending call. Invalid
    # optional diagnostics must neither kill the Driver nor change execution.
    for payload <- [nil, [], "malformed"] do
      progress_event(agent.uid, first, %{"kind" => "tool.activity", "payload" => payload})
    end

    progress_event(agent.uid, first, %{"kind" => 123, "payload" => %{}})
    {unaffected, driver} = Activity.current(key)
    assert Process.alive?(driver)
    assert unaffected == snapshot

    progress_event(agent.uid, first, %{
      "kind" => "tool.activity",
      "payload" => %{
        "phase" => %{"raw" => "secret"},
        "state" => ["secret"],
        "consequential" => %{"secret" => true},
        "label" => "Safe visible label",
        "raw_arguments" => "secret"
      }
    })

    {bounded, ^driver} =
      await_activity(
        key,
        &Enum.any?(&1.tools, fn tool -> tool["label"] == "Safe visible label" end)
      )

    refute Ankole.JSON.encode!(bounded) =~ "secret"
    assert Enum.find(bounded.tools, &(&1["operation_id"] == first.call_id))["phase"] == nil

    progress(agent.uid, %{first | response_id: "resp_old"}, "running", "Wrong response")
    progress(agent.uid, %{first | call_id: "ended-call"}, "running", "Wrong call")
    {same, _} = Activity.current(key)
    assert same.revision == bounded.revision
    progress(agent.uid, first, "completed", "Completed")
    {one, _} = await_activity(key, &(length(&1.tools) == 1))
    progress(agent.uid, first, "running", "Late running")
    {late, _} = Activity.current(key)
    assert late.tools == one.tools

    Repo.update_all(
      from(w in Sessions.SessionWorkspace,
        where: w.agent_uid == ^agent.uid and w.session_id == ^key.session_id
      ),
      inc: [epoch: 1]
    )

    refute Activity.valid?(snapshot)
    {stale, _} = Activity.current(key)
    assert stale.state == "unavailable"
    assert stale.tools == []
    assert stale.epoch > snapshot.epoch
  end

  defp progress(uid, call, phase, activity) do
    progress_event(uid, call, %{
      "kind" => "tool.activity",
      "payload" => %{
        "operation_id" => call.call_id,
        "phase" => phase,
        "activity" => activity,
        "raw_arguments" => "must not appear in native activity"
      }
    })
  end

  defp progress_event(uid, call, event) do
    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{
                 body:
                   {:tool_progress,
                    %Proto.ToolProgress{
                      run: call.run,
                      response_id: call.response_id,
                      call_id: call.call_id,
                      presentation_json: Ankole.JSON.encode!(event)
                    }}
               },
               %{worker_id: uid}
             )
  end

  defp start_stream(conn, id) do
    owner = self()

    Task.async(
      Repo.bind_tenant(fn ->
        request =
          Plug.Test.conn(:get, "/api/v2/pod/conversations/#{id}/events")
          |> Plug.Test.init_test_session(get_session(conn))
          |> copy_authentication_cookies(conn)
          |> put_req_header("accept", "text/event-stream")

        @endpoint.call(%{request | adapter: {StreamAdapter, owner}}, @endpoint.init([]))
      end)
    )
  end

  defp sse_snapshot(conn, id) do
    request =
      Plug.Test.conn(:get, "/api/v2/pod/conversations/#{id}/events")
      |> Plug.Test.init_test_session(get_session(conn))
      |> copy_authentication_cookies(conn)
      |> put_req_header("accept", "text/event-stream")

    request = %{request | adapter: {SnapshotAdapter, self()}}
    assert %Plug.Conn{state: :chunked} = @endpoint.call(request, @endpoint.init([]))
    assert_receive {:snapshot_frame, ": ping\n\nevent: activity\ndata: " <> data}, 1_000
    Ankole.JSON.decode!(String.trim(data))
  end

  defp copy_authentication_cookies(request, source) do
    source = Plug.Conn.fetch_cookies(source)

    cookies =
      Map.merge(
        source.req_cookies,
        Map.new(source.resp_cookies, fn {name, cookie} -> {name, cookie.value} end)
      )

    Enum.reduce(cookies, request, fn {name, value}, request ->
      Plug.Test.put_req_cookie(request, name, value)
    end)
  end

  defp await_activity(key, predicate, remaining \\ 100)
  defp await_activity(_key, _predicate, 0), do: flunk("activity never reached the expected state")

  defp await_activity(key, predicate, remaining) do
    {snapshot, pid} = Activity.current(key)

    if predicate.(snapshot),
      do: {snapshot, pid},
      else:
        (
          Process.sleep(20)
          await_activity(key, predicate, remaining - 1)
        )
  end

  defp tool_events(request) do
    calls = [
      {"native-jobs", "list_background_jobs", %{}},
      {"native-read-one", "read_file", %{"path" => "/tmp/report-one.txt"}},
      {"native-read-two", "read_file", %{"path" => "/tmp/report-two.txt"}}
    ]

    [
      %{
        "id" => "chatcmpl_native_activity",
        "object" => "chat.completion.chunk",
        "created" => 1_764_967_971,
        "model" => request.body["model"],
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "role" => "assistant",
              "tool_calls" =>
                Enum.with_index(calls, fn {id, name, args}, index ->
                  %{
                    "index" => index,
                    "id" => id,
                    "type" => "function",
                    "function" => %{"name" => name, "arguments" => Ankole.JSON.encode!(args)}
                  }
                end)
            },
            "finish_reason" => "tool_calls"
          }
        ],
        "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7, "total_tokens" => 12}
      }
    ]
  end
end
