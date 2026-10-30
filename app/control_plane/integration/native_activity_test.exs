defmodule AnkoleWeb.NativeActivityTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag sandbox: false, host: :pod
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
    Ankole.ConversationsFixtures.grant_chat(human_uid, agent.uid)

    for tool <- ["list_background_jobs", "read_file"] do
      assert {:ok, _} =
               Ankole.AuthZ.create_permission_grant(%{
                 principal_uid: human_uid,
                 resource_pattern: "agent:#{agent.uid}:tool:#{tool}",
                 action: "invoke"
               })
    end

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

  test "native HTTP references reach the real provider request body", %{
    conn: conn,
    agent: agent,
    human_uid: human_uid
  } do
    actor = Ankole.PrincipalsFixtures.actor_fixture(human_uid)
    assert {:ok, page} = Ankole.Pod.Pages.create(actor, %{title: "Provider reference source"})
    source_id = Ecto.UUID.generate()

    assert {:ok, quoted} =
             Ankole.ConversationsFixtures.create(human_uid, %{
               conversation_id: Ecto.UUID.generate(),
               message_id: source_id,
               agent_uid: agent.uid,
               text: "The source quote for this provider request."
             })

    quote = hd(quoted.messages)
    source = Repo.get_by!(Ankole.Signals.Signal, message_id: quote.id)

    assert {:ok, _} =
             Repo.transact(fn ->
               Ankole.Sessions.Queue.mark_event_completed_in_tx(
                 source,
                 DateTime.utc_now(:microsecond)
               )
             end)

    id = Ecto.UUID.generate()

    response =
      api_post(conn, ~p"/api/v2/pod/conversations", %{
        "conversationID" => id,
        "agentUID" => agent.uid,
        "messageID" => Ecto.UUID.generate(),
        "text" => "Read the selected page and quote",
        "links" => [
          %{"kind" => "page", "id" => page.id},
          %{"kind" => "message", "id" => quote.id, "quote" => quote.text}
        ]
      })

    assert Phoenix.ConnTest.json_response(response, 201)
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
    assert_receive {:activity_model_request, request}, 5_000
    wire = Ankole.JSON.encode!(request.body)
    assert wire =~ "ankole:page/#{page.id}"
    assert wire =~ quote.id
    assert wire =~ quote.text
    assert_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, _opened}}}, 5_000
    key = %{agent_uid: agent.uid, session_id: Sessions.Key.conversation(id)}
    {:executing_tools, data} = :sys.get_state(Sessions.driver_pid(key))
    assert {:ok, _} = Run.finalize(data.turn.run, :silent)
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

    assert Phoenix.ConnTest.json_response(conn, 201)
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

    assert [%{"operation_id" => "native-jobs", "phase" => "completed"}] = waiting.tools
    assert waiting.state == "active"
    # No SSE existed when the one-shot capacity phase was produced.
    first = sse_snapshot(conn, id)
    second = sse_snapshot(conn, id)
    assert first["phase"]["label_key"] == waiting.phase["label_key"]
    assert second == first
    assert first["epoch"] == waiting.epoch
    assert first["revision"] == waiting.revision
    shown = conn |> recycle_api() |> api_get(~p"/api/v2/pod/conversations/#{id}")
    assert Phoenix.ConnTest.json_response(shown, 200)["activities"] == [first]

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

    assert {:ok, detail} =
             Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(human_uid), id)

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

    assert {:ok, after_stale} =
             Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(human_uid), id)

    assert after_stale.messages == detail.messages
    refute_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, _}}}, 100
  end

  test "late join and reconnect restore the real streaming text and thinking before new deltas",
       ctx do
    owner = self()

    url =
      start_upstream_server(fn request ->
        chunk = fn text, thinking ->
          [
            %{
              "type" => "response.reasoning_summary_text.delta",
              "item_id" => "thinking",
              "output_index" => 0,
              "summary_index" => 0,
              "delta" => thinking
            },
            %{
              "type" => "response.output_text.delta",
              "item_id" => "reply",
              "output_index" => 1,
              "content_index" => 0,
              "delta" => text
            }
          ]
        end

        output = [
          %{
            "type" => "reasoning",
            "id" => "thinking",
            "summary" => [
              %{"type" => "summary_text", "text" => "Think prefix. Think middle. Think suffix."}
            ]
          },
          %{
            "type" => "message",
            "id" => "reply",
            "role" => "assistant",
            "status" => "completed",
            "content" => [
              %{"type" => "output_text", "text" => "prefix middle suffix.", "annotations" => []}
            ]
          }
        ]

        terminal = %{
          "type" => "response.completed",
          "response" => %{
            "id" => "resp_snapshot",
            "status" => "completed",
            "model" => request.body["model"],
            "output" => output,
            "usage" => %{"input_tokens" => 5, "output_tokens" => 8, "total_tokens" => 13}
          }
        }

        tail =
          Stream.resource(
            fn ->
              send(owner, {:snapshot_peer, self(), :prefix})
              :middle
            end,
            fn
              :middle ->
                receive do
                  :middle -> {chunk.("middle ", "Think middle. "), :suffix}
                end

              :suffix ->
                send(owner, {:snapshot_peer, self(), :middle})

                receive do
                  :finish -> {chunk.("suffix.", "Think suffix.") ++ [terminal], :done}
                end

              :done ->
                {:halt, :done}
            end,
            fn _ -> :ok end
          )

        prefix =
          [
            %{
              "type" => "response.created",
              "response" => %{"id" => "resp_snapshot", "status" => "in_progress", "output" => []}
            },
            %{
              "type" => "response.output_item.added",
              "output_index" => 0,
              "item" => %{"type" => "reasoning", "id" => "thinking", "summary" => []}
            },
            %{
              "type" => "response.reasoning_summary_part.added",
              "item_id" => "thinking",
              "output_index" => 0,
              "summary_index" => 0,
              "part" => %{"type" => "summary_text", "text" => ""}
            },
            %{
              "type" => "response.output_item.added",
              "output_index" => 1,
              "item" => %{
                "type" => "message",
                "id" => "reply",
                "role" => "assistant",
                "status" => "in_progress",
                "content" => []
              }
            },
            %{
              "type" => "response.content_part.added",
              "item_id" => "reply",
              "output_index" => 1,
              "content_index" => 0,
              "part" => %{"type" => "output_text", "text" => "", "annotations" => []}
            }
          ] ++ chunk.("prefix ", "Think prefix. ")

        events =
          Stream.concat(prefix, tail)
          |> Stream.with_index()
          |> Stream.map(fn {event, index} -> Map.put(event, "sequence_number", index) end)

        {:sse, 200, events}
      end)

    provider_id = "native-snapshot-" <> Ecto.UUID.generate()

    assert {:ok, _} =
             Ankole.AIGateway.ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: url,
               credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "sk-test"}]}
             })

    assert {:ok, _} =
             Ankole.AIAgent.ModelProfiles.put_model_profile(ctx.agent.uid, "primary", %{
               provider_id: provider_id,
               model: "gpt-5.5"
             })

    id = Ecto.UUID.generate()

    key = %{agent_uid: ctx.agent.uid, session_id: Sessions.Key.conversation(id)}
    assert Sessions.driver_pid(key) == :undefined
    assert Sessions.Driver.display_snapshot(key) == nil
    assert Sessions.driver_pid(key) == :undefined

    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.create(ctx.human_uid, %{
               conversation_id: id,
               message_id: message_id,
               agent_uid: ctx.agent.uid,
               text: "Keep the streamed response across refresh."
             })

    ready_conn = api_get(ctx.conn, "/api/v2/pod/conversations/#{id}")
    assert api_response(ready_conn, 200)
    waiting = start_stream(ready_conn, id)
    assert_receive {:stream_frame, waiting_pid, initial_frames}, 2_000
    assert frame_payloads(initial_frames, "snapshot") == []

    conn =
      api_post(ready_conn, "/api/v2/pod/conversations", %{
        "conversationID" => id,
        "messageID" => message_id,
        "agentUID" => ctx.agent.uid,
        "text" => "Keep the streamed response across refresh."
      })

    assert Phoenix.ConnTest.json_response(conn, 201)
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
    assert_receive {:snapshot_peer, peer, :prefix}, 5_000
    await_display(key, "prefix ")

    send(waiting_pid, :continue)
    transitioned = await_stream_prefix(waiting_pid)
    assert transitioned.text == "prefix "
    assert transitioned.thinking == "Think prefix. "
    send(waiting_pid, :close)
    assert %Plug.Conn{state: :chunked} = Task.await(waiting)

    first = start_stream(conn, id)
    assert_receive {:stream_frame, first_pid, frames}, 2_000
    [initial] = frame_payloads(frames, "snapshot")
    assert initial["text"] == "prefix "
    assert initial["thinkingSummary"] == "Think prefix. "
    send(first_pid, :close)
    assert %Plug.Conn{state: :chunked} = Task.await(first)

    send(peer, :middle)
    assert_receive {:snapshot_peer, ^peer, :middle}, 2_000
    await_display(key, "prefix middle ")
    reconnected = start_stream(conn, id)
    assert_receive {:stream_frame, stream_pid, frames}, 2_000
    [restored] = frame_payloads(frames, "snapshot")
    assert restored["responseID"] == initial["responseID"]
    assert restored["signalIDs"] == initial["signalIDs"]
    assert restored["text"] == "prefix middle "
    assert restored["thinkingSummary"] == "Think prefix. Think middle. "
    send(stream_pid, :continue)
    send(peer, :finish)

    tail = collect_stream(stream_pid, "")
    assert Enum.map_join(frame_payloads(tail, "delta"), & &1["text"]) == "suffix."
    assert Enum.map_join(frame_payloads(tail, "reasoning_delta"), & &1["text"]) == "Think suffix."
    send(stream_pid, :close)
    assert %Plug.Conn{state: :chunked} = Task.await(reconnected)

    message = await_reply(ctx.conn, id)
    assert message["text"] == "prefix middle suffix."

    assert message["richContent"]["execution"]["thinking_summary"] ==
             "Think prefix. Think middle. Think suffix."
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

    assert Phoenix.ConnTest.json_response(conn, 201)
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, _}}}, 5_000
    key = %{agent_uid: agent.uid, session_id: Sessions.Key.conversation(id)}
    {active, driver} = Activity.current(key)
    stream = start_stream(conn, id)
    assert_receive {:stream_frame, stream_pid, initial}, 1_000
    assert initial =~ "event: connected\n"
    assert initial =~ "event: activity\n"
    assert initial =~ agent.uid
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
    assert_receive {:stream_frame, ^stream_pid, "event: conversation\n" <> _}, 1_000
    send(stream_pid, :close)
    assert %Plug.Conn{state: :chunked} = Task.await(stream)
  end

  test "Stop preserves completed and interrupted tools in the reloaded native timeline", ctx do
    {conn, id, calls} = start_worker_turn(ctx)
    progress(ctx.agent.uid, hd(calls), "running", "Read the first report")

    stopped =
      api_post(conn, "/api/v2/pod/conversations/#{id}/queue", %{
        "action" => "stop",
        "agentUID" => ctx.agent.uid,
        "commandID" => Ecto.UUID.generate()
      })

    assert Phoenix.ConnTest.json_response(stopped, 201)
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
    key = %{agent_uid: ctx.agent.uid, session_id: Sessions.Key.conversation(id)}
    await_activity(key, &(&1.state == "settled"))
    notice = persisted_execution_notice(conn, id, "stopped")

    assert Enum.any?(notice["richContent"]["execution"]["steps"], fn step ->
             step["tool"] == "list_background_jobs" and step["status"] == "completed"
           end)

    assert Enum.count(notice["richContent"]["execution"]["steps"], fn step ->
             step["tool"] == "read_file" and step["status"] == "stopped"
           end) == 2
  end

  test "an actual model adapter error preserves the finished tools in a failed native notice",
       ctx do
    counter = :atomics.new(1, [])

    url =
      start_upstream_server(fn request ->
        if :atomics.add_get(counter, 1, 1) == 1,
          do: {:sse, 200, tool_events(request)},
          else: {:json, 400, %{"error" => %{"message" => "Invalid model request"}}}
      end)

    {:ok, profile} = Ankole.AIAgent.ModelProfiles.get_model_profile(ctx.agent.uid, "primary")

    assert {:ok, _} =
             Ankole.AIGateway.ProviderConfigs.update_provider(profile["provider_id"], %{
               base_url: url
             })

    :ok = RuntimeCase.cache_actor_runtime_models(profile["provider_id"])
    {conn, id, calls} = start_worker_turn(ctx)

    for call <- calls do
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
                          Ankole.JSON.encode!([%{"type" => "text", "text" => "Report read"}]),
                        details_json: "{}"
                      }}
                 },
                 %{worker_id: ctx.agent.uid}
               )
    end

    key = %{agent_uid: ctx.agent.uid, session_id: Sessions.Key.conversation(id)}
    await_activity(key, &(&1.state == "settled"))
    notice = persisted_execution_notice(conn, id, "failed")
    assert length(notice["richContent"]["execution"]["steps"]) == 3
    assert Enum.all?(notice["richContent"]["execution"]["steps"], &(&1["status"] == "completed"))
  end

  test "ordinary empty replies repair while a listening Agent can finish silently", ctx do
    owner = self()
    counter = :atomics.new(1, [])

    url =
      start_upstream_server(fn request ->
        number = :atomics.add_get(counter, 1, 1)
        send(owner, {:empty_reply_request, number, request.body})
        text = if number == 2, do: "Ready to help.", else: ""

        {:sse, 200,
         [
           %{
             "id" => "empty-reply-#{number}",
             "object" => "chat.completion.chunk",
             "created" => 1_764_967_971,
             "model" => request.body["model"],
             "choices" => [
               %{
                 "index" => 0,
                 "delta" => %{"role" => "assistant", "content" => text},
                 "finish_reason" => "stop"
               }
             ],
             "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 1, "total_tokens" => 6}
           }
         ]}
      end)

    {:ok, profile} = Ankole.AIAgent.ModelProfiles.get_model_profile(ctx.agent.uid, "primary")

    assert {:ok, _} =
             Ankole.AIGateway.ProviderConfigs.update_provider(profile["provider_id"], %{
               base_url: url
             })

    :ok = RuntimeCase.cache_actor_runtime_models(profile["provider_id"])
    actor = Ankole.PrincipalsFixtures.actor_fixture(ctx.human_uid)
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.create(actor, %{
               conversation_id: id,
               agent_uid: ctx.agent.uid,
               message_id: Ecto.UUID.generate(),
               text: "Tell me the status."
             })

    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
    assert_receive {:empty_reply_request, 1, _}, 5_000
    assert_receive {:empty_reply_request, 2, repair}, 5_000
    assert Ankole.JSON.encode!(repair) =~ "This turn was started by an event that requires one"
    key = %{agent_uid: ctx.agent.uid, session_id: Sessions.Key.conversation(id)}
    await_activity(key, &(&1.state == "settled"))
    assert {:ok, detail} = Conversations.get(actor, id)

    assert Enum.count(
             detail.messages,
             &(&1.author_type == :agent and &1.text == "Ready to help.")
           ) == 1

    listener = additional_agent()

    Ankole.ConversationsFixtures.grant_chat(ctx.human_uid, listener.uid)
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [listener.uid]})
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.post(actor, id, %{
               message_id: message_id,
               text: "A note for the group."
             })

    optional = Repo.one!(from s in Ankole.Signals.Signal, where: s.message_id == ^message_id)
    assert optional.data["optional_reply"] == true
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
    assert_receive {:empty_reply_request, 3, listening}, 5_000
    assert Ankole.JSON.encode!(listening) =~ "You can finish with no visible reply."
    await_activity(key, &(&1.state == "settled"))
    refute_receive {:empty_reply_request, 4, _}, 200
    assert Repo.reload!(optional).status == :completed
    assert {:ok, detail} = Conversations.get(actor, id)
    assert Enum.count(detail.messages, &(&1.author_type == :agent)) == 1
  end

  test "two members racing on a native card commit one answer and one continuation", ctx do
    actor = Ankole.PrincipalsFixtures.actor_fixture(ctx.human_uid)
    bob = Ankole.PrincipalsFixtures.human_fixture(%{display_name: "Bob"}).principal

    on_exit(
      Repo.bind_tenant(fn ->
        Repo.delete_all(
          from a in Ankole.BrowserSessions.Authentication,
            where: a.tenant_id == ^bob.tenant_id and a.subject_id == ^bob.uid
        )

        Repo.delete_all(
          from a in Ankole.BrowserSessions.PodAuthentication, where: a.principal_uid == ^bob.uid
        )

        Repo.delete_all(from p in Ankole.Principals.Principal, where: p.uid == ^bob.uid)
      end)
    )

    bob_conn = authenticated_conn(ctx.tenant, bob)
    Ankole.ConversationsFixtures.grant_chat(bob.uid, ctx.agent.uid)
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.create(actor, %{
               conversation_id: id,
               agent_uid: ctx.agent.uid,
               message_id: Ecto.UUID.generate(),
               text: "Choose the report destination."
             })

    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [bob.uid]})
    source = Repo.one!(from s in Ankole.Signals.Signal, where: s.conversation_id == ^id)
    now = DateTime.utc_now(:microsecond)

    prompt = %{
      "interaction_id" => "clarify:race",
      "body" => "Publish or draft?",
      "version" => 1,
      "control_id" => "clarify-choice",
      "free_input" => true,
      "choices" => [
        %{"id" => "publish", "label" => "Publish", "value" => "Publish"},
        %{"id" => "draft", "label" => "Draft", "value" => "Draft"}
      ]
    }

    assert {:ok, %{messages: [card]}} =
             Repo.transact_top_level(fn ->
               with {:ok, posted} <-
                      Sessions.Presentation.post_in_tx(source, %Conversations.Statement{
                        signal: source,
                        now: now,
                        completion: %{
                          final_text: nil,
                          attachments: [],
                          clarify_prompt: %{"interactive_output" => prompt}
                        }
                      }),
                    {:ok, _} <- Sessions.Queue.mark_event_completed_in_tx(source, now),
                    do: {:ok, posted}
             end)

    interaction_id = card.rich_content["clarify"]["interaction_id"]
    owner = self()

    requests =
      for {conn, choice} <- [{ctx.conn, "publish"}, {bob_conn, "draft"}],
          kind <- [:answer, :read] do
        {kind, conn, choice}
      end

    tasks =
      for {kind, conn, choice} <- requests do
        Task.async(
          Repo.bind_tenant(fn ->
            send(owner, {:answer_ready, self()})

            receive do
              :answer ->
                result =
                  case kind do
                    :answer ->
                      api_post(
                        conn,
                        "/api/v2/pod/conversations/#{id}/interactions/#{interaction_id}/answer",
                        %{"choiceID" => choice}
                      )

                    :read ->
                      api_patch(conn, "/api/v2/pod/conversations/#{id}", %{
                        "lastReadSeq" => card.seq
                      })
                  end

                {kind, result.status, result.resp_body}
            end
          end)
        )
      end

    for _ <- tasks, do: assert_receive({:answer_ready, _}, 1_000)
    Enum.each(tasks, &send(&1.pid, :answer))
    results = Task.await_many(tasks, 10_000)

    assert Enum.sort(for {:answer, status, _} <- results, do: status) == [201, 409],
           inspect(results)

    assert Enum.all?(for {:read, status, _} <- results, do: status == 200), inspect(results)

    assert Enum.any?(results, fn {kind, status, body} ->
             kind == :answer and status == 409 and body =~ "interaction_not_pending"
           end)

    interaction =
      Conversations.Delivery.Interactions.native_interaction(source.id, interaction_id)

    assert interaction["state"] == "answered"
    assert interaction["answered_by_uid"] in [ctx.human_uid, bob.uid]

    assert Repo.aggregate(
             from(s in Ankole.Signals.Signal, where: s.conversation_id == ^id),
             :count
           ) == 2

    assert Repo.aggregate(
             from(m in Conversations.Message,
               where: m.conversation_id == ^id and m.text in ["Publish", "Draft"]
             ),
             :count
           ) == 1
  end

  test "a live room subscribes to an invited Agent and closes when its anchor is deleted", ctx do
    actor = Ankole.PrincipalsFixtures.actor_fixture(ctx.human_uid)
    assert {:ok, page} = Ankole.Pod.Pages.create(actor, %{title: "Room context"})
    id = Ecto.UUID.generate()

    conn =
      api_post(ctx.conn, ~p"/api/v2/pod/conversations", %{
        "conversationID" => id,
        "agentUID" => ctx.agent.uid,
        "messageID" => Ecto.UUID.generate(),
        "text" => "Discuss this page.",
        "pageID" => page.id,
        "accessScope" => "anchor_page"
      })

    assert Phoenix.ConnTest.json_response(conn, 201)
    stream = start_stream(conn, id)
    assert_receive {:stream_frame, stream_pid, initial}, 1_000
    assert initial =~ "event: connected\n"
    assert initial =~ ctx.agent.uid
    send(stream_pid, :continue)

    invited = additional_agent()

    Ankole.ConversationsFixtures.grant_chat(ctx.human_uid, invited.uid)
    assert {:ok, _} = Conversations.manage_participants(actor, id, %{add_uids: [invited.uid]})
    assert_receive {:stream_frame, ^stream_pid, updated}, 1_000
    assert updated =~ "event: conversation\n"
    assert updated =~ invited.uid
    assert updated =~ "event: activity\n"
    send(stream_pid, :continue)

    assert {:ok, _} = Ankole.Pod.Pages.delete(actor, page.id)
    assert_receive {:stream_frame, ^stream_pid, revoked}, 1_000
    assert "event: access_revoked\ndata: " <> data = revoked

    assert Ankole.JSON.decode!(String.trim(data)) == %{
             "conversationID" => id,
             "reason" => "access_revoked"
           }

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

    assert Phoenix.ConnTest.json_response(conn, 201)
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
      "key" => "conversations.delivery.reply.activity.read_file",
      "bindings" => %{"path" => "one", "hidden" => %{secret: true}}
    })

    progress(agent.uid, second, "running", "Read the second report")

    {snapshot, _} =
      await_activity(
        key,
        &(Enum.count(&1.tools, fn tool ->
            tool["operation_id"] in [first.call_id, second.call_id]
          end) == 2)
      )

    assert Enum.any?(
             snapshot.tools,
             &(&1["label_key"] == "conversations.delivery.reply.activity.read_file")
           )

    refute Ankole.JSON.encode!(snapshot) =~ "secret"

    assert Enum.map(snapshot.tools, & &1["operation_id"]) |> Enum.sort() ==
             Enum.sort(["native-jobs", first.call_id, second.call_id])

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

    {one, _} =
      await_activity(
        key,
        &Enum.any?(&1.tools, fn tool ->
          tool["operation_id"] == first.call_id and tool["phase"] == "completed"
        end)
      )

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

  defp authenticated_conn(tenant, principal) do
    conn =
      build_conn()
      |> assign(:test_tenant, tenant)
      |> pod_conn(tenant)
      |> Plug.Test.init_test_session(%{})
      |> AnkoleWeb.Session.ensure_browser()

    {:ok, completed} =
      Ankole.BrowserSessions.authenticate(
        AnkoleWeb.Session.browser_reference(conn),
        %{
          "principal_uid" => principal.uid,
          "access_version" => principal.access_version,
          "provider_id" => "lark-main",
          "external_id" => principal.uid
        }
      )

    conn = AnkoleWeb.Session.put_authentication(conn, completed.browser, completed.authentication)

    conn |> with_console_csrf() |> get(~p"/api/v2/browser/session") |> recycle_api()
  end

  defp additional_agent do
    agent = Ankole.PrincipalsFixtures.agent_fixture().principal

    on_exit(
      Repo.bind_tenant(fn ->
        :ok = Ankole.AgentWorkers.WorkerEnv.delete_agent_rows_in_tx(agent.uid)
        Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)
      end)
    )

    agent
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

  defp start_worker_turn(ctx) do
    id = Ecto.UUID.generate()

    conn =
      api_post(ctx.conn, "/api/v2/pod/conversations", %{
        "conversationID" => id,
        "agentUID" => ctx.agent.uid,
        "messageID" => Ecto.UUID.generate(),
        "text" => "Read both reports."
      })

    assert Phoenix.ConnTest.json_response(conn, 201)
    assert %{failure: 0} = Oban.drain_queue(queue: :conversations, with_scheduled: true)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:workspace_open, opened}}}, 5_000

    assert :ok =
             SessionLane.handle(
               %Proto.Envelope{body: {:workspace_ready, %Proto.WorkspaceReady{run: opened.run}}},
               %{worker_id: ctx.agent.uid}
             )

    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, first}}}, 5_000
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, second}}}, 5_000
    {conn, id, [first, second]}
  end

  defp persisted_execution_notice(conn, id, status) do
    read = fn ->
      conn
      |> recycle_api()
      |> api_get("/api/v2/pod/conversations/#{id}")
      |> Phoenix.ConnTest.json_response(200)
      |> Map.fetch!("messages")
      |> Enum.find(
        &(&1["kind"] == "notice" and get_in(&1, ["richContent", "execution", "status"]) == status)
      )
    end

    notice = read.()
    assert notice
    assert is_binary(notice["text"]) and notice["text"] != ""
    assert read.() == notice
    notice
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
          %{
            Plug.Test.conn(:get, "/api/v2/pod/conversations/#{id}/events")
            | host: conn.host,
              port: conn.port,
              scheme: conn.scheme
          }
          |> Plug.Test.init_test_session(get_session(conn))
          |> copy_authentication_cookies(conn)
          |> put_req_header("accept", "text/event-stream")

        @endpoint.call(%{request | adapter: {StreamAdapter, owner}}, @endpoint.init([]))
      end)
    )
  end

  defp frame_payloads(frames, event) do
    prefix = "event: #{event}\ndata: "

    for frame <- String.split(frames, "\n\n", trim: true),
        String.starts_with?(frame, prefix),
        do: frame |> String.replace_prefix(prefix, "") |> Ankole.JSON.decode!()
  end

  defp await_display(key, text, remaining \\ 100)

  defp await_display(_key, _text, 0),
    do: flunk("the provider prefix did not reach the stream owner")

  defp await_display(key, text, remaining) do
    case Sessions.Driver.display_snapshot(key) do
      %{text: ^text} = snapshot ->
        snapshot

      _ ->
        Process.sleep(20)
        await_display(key, text, remaining - 1)
    end
  end

  defp collect_stream(pid, frames) do
    receive do
      {:stream_frame, ^pid, data} ->
        frames = frames <> data

        if frame_payloads(frames, "delta") != [] and
             frame_payloads(frames, "reasoning_delta") != [] and
             frame_payloads(frames, "conversation") != [] do
          frames
        else
          send(pid, :continue)
          collect_stream(pid, frames)
        end
    after
      5_000 -> flunk("the reconnected stream did not receive the provider suffix")
    end
  end

  defp await_stream_prefix(pid, state \\ %{text: "", thinking: ""}) do
    receive do
      {:stream_frame, ^pid, frames} ->
        state =
          Enum.reduce(String.split(frames, "\n\n", trim: true), state, fn frame, current ->
            case String.split(frame, "\ndata: ", parts: 2) do
              ["event: " <> event, json] when event in ["snapshot", "delta", "reasoning_delta"] ->
                payload = Ankole.JSON.decode!(json)

                case event do
                  "snapshot" ->
                    %{text: payload["text"] || "", thinking: payload["thinkingSummary"] || ""}

                  "delta" ->
                    %{current | text: current.text <> payload["text"]}

                  "reasoning_delta" ->
                    %{current | thinking: current.thinking <> payload["text"]}
                end

              _ ->
                current
            end
          end)

        if state == %{text: "prefix ", thinking: "Think prefix. "} do
          state
        else
          send(pid, :continue)
          await_stream_prefix(pid, state)
        end
    after
      5_000 -> flunk("the existing stream did not receive the complete text and thinking prefix")
    end
  end

  defp await_reply(conn, id, remaining \\ 100)
  defp await_reply(_conn, _id, 0), do: flunk("the response did not commit to the room")

  defp await_reply(conn, id, remaining) do
    detail =
      conn |> recycle_api() |> api_get("/api/v2/pod/conversations/#{id}") |> api_response(200)

    case Enum.find(detail["messages"], &(&1["authorType"] == "agent")) do
      nil ->
        Process.sleep(20)
        await_reply(conn, id, remaining - 1)

      message ->
        message
    end
  end

  defp sse_snapshot(conn, id) do
    request =
      %{
        Plug.Test.conn(:get, "/api/v2/pod/conversations/#{id}/events")
        | host: conn.host,
          port: conn.port,
          scheme: conn.scheme
      }
      |> Plug.Test.init_test_session(get_session(conn))
      |> copy_authentication_cookies(conn)
      |> put_req_header("accept", "text/event-stream")

    request = %{request | adapter: {SnapshotAdapter, self()}}
    assert %Plug.Conn{state: :chunked} = @endpoint.call(request, @endpoint.init([]))
    assert_receive {:snapshot_frame, frames}, 1_000
    assert frames =~ "event: connected\n"

    activity =
      frames
      |> String.split("\n\n", trim: true)
      |> Enum.find(&String.starts_with?(&1, "event: activity\ndata: "))

    "event: activity\ndata: " <> data = activity
    Ankole.JSON.decode!(data)
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
