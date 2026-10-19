defmodule Ankole.Pod.RPCBrokerTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Pod.{Documents, Files, Pages, RPCBroker}
  alias Ankole.BackgroundAgentJobs
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Sessions.RunRef
  alias Ankole.Signals.Signal
  alias Ankole.WorkerFilesFake

  setup do
    owner = human_fixture().principal
    agent = Ankole.SessionsCase.agent_fixture().principal
    route = "pod-broker-#{System.unique_integer([:positive])}"
    {:ok, _worker} = Ankole.SessionsCase.admit_worker(route, %{worker_id: agent.uid})

    event = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)
    assert {:ok, run} = Ankole.Sessions.Admission.admit(event, event)

    ref = %Ankole.Sessions.RunRef{
      agent_uid: agent.uid,
      session_id: event.session_id,
      signal_id: event.id
    }

    %{
      ref: ref,
      run: run,
      owner: owner.uid,
      agent: agent.uid,
      route: route,
      ctx: %{route: route, worker_id: agent.uid, request_id: "pod-test"}
    }
  end

  test "document RPC transfers canonical XML over the signed relay and keeps CAS at its owner",
       ctx do
    {:ok, page} = Pages.create(ctx.owner, %{title: "Agent report"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        grants: [%{principal_uid: ctx.agent, role: "edit"}]
      })

    xml = "<page><p>Agent report</p></page>"
    fake = WorkerFilesFake.start!(ctx.route, files: %{"report.xml" => xml})

    assert {:ok, %{"result" => %{"page" => %{"revision" => 1}} = written}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.write", %{
                 id: page.id,
                 base_revision: 0,
                 xml_home_relative_path: "report.xml"
               }),
               ctx.ctx
             )

    refute Map.has_key?(written, "content")
    assert {:ok, detail} = Pages.get(ctx.owner, page.id)
    assert detail.content.plain_text == "Agent report"

    assert {:error, %{"code" => "revision_conflict", "details_json" => %{"revision" => 1}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.write", %{
                 id: page.id,
                 base_revision: 0,
                 xml_home_relative_path: "report.xml"
               }),
               ctx.ctx
             )

    assert {:ok, %{"result" => %{"content" => %{"xml_file" => true}}}} =
             RPCBroker.handle_read(
               nil,
               request("pages.read", %{
                 id: page.id,
                 xml_home_relative_path: "received.xml"
               }),
               ctx.ctx
             )

    assert WorkerFilesFake.files(fake)["received.xml"] == detail.content.content
    assert {:ok, _} = Documents.write(ctx.owner, page.id, 1, "<page><p>Human edit</p></page>")

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        inherit_permissions: false,
        grants: []
      })

    before = WorkerFilesFake.pushes(fake)

    assert {:error, %{"code" => "forbidden"}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("pages.write", %{
                 id: page.id,
                 base_revision: 2,
                 xml_home_relative_path: "report.xml"
               }),
               ctx.ctx
             )

    assert WorkerFilesFake.pushes(fake) == before
    assert {:ok, %{content: %{plain_text: "Human edit"}}} = Pages.get(ctx.owner, page.id)
  end

  test "Pod drive relay requires current access to the page", ctx do
    {:ok, page} = Pages.create(ctx.owner, %{type: "file", title: "Report"})
    {:ok, _} = Files.upload(ctx.owner, page.id, "file", 0, "report.txt", "saved bytes")
    fake = WorkerFilesFake.start!(ctx.route)

    request = %FabricProto.FilesGetRequest{
      pod_drive: true,
      path: "pages/#{page.id}/report.txt",
      home_relative_path: "received/report.txt"
    }

    assert {:error, %{"code" => "forbidden"}} =
             Ankole.Files.RPCBroker.handle_get(ctx.agent, request, ctx.ctx)

    assert WorkerFilesFake.files(fake) == %{}

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        grants: [%{principal_uid: ctx.agent, role: "view"}]
      })

    assert {:ok, %FabricProto.FilesGetResponse{}} =
             Ankole.Files.RPCBroker.handle_get(ctx.agent, request, ctx.ctx)

    assert WorkerFilesFake.files(fake) == %{"received/report.txt" => "saved bytes"}
  end

  test "pages created after completion and multiple Job continuations keep their Human source",
       ctx do
    {source, parent} = page_request(ctx)
    {job, ref} = start_job(ctx, source)
    assert created_page(ctx, ref, parent, "Report")["saved_from_message_id"] == source.message_id

    wake = complete_job(job)
    assert wake.producer == :kernel
    assert wake.type == "background_agent_job.completed"
    assert wake.message_id == nil
    assert wake.data["job_id"] == job.id

    main_ref = %RunRef{agent_uid: ctx.agent, session_id: wake.session_id, signal_id: wake.id}

    assert created_page(ctx, main_ref, parent, "Main result")["saved_from_message_id"] ==
             source.message_id

    {continued, ref} = start_job(ctx, wake, job)

    assert created_page(ctx, ref, parent, "Applet", "applet")["saved_from_message_id"] ==
             source.message_id

    {_, ref} = start_job(ctx, complete_job(continued), continued)

    assert created_page(ctx, ref, parent, "Second continuation")["saved_from_message_id"] ==
             source.message_id
  end

  test "a new Human follow-up owns the continued Job's new pages", ctx do
    {original, parent} = page_request(ctx)
    {job, _ref} = start_job(ctx, original)
    _wake = complete_job(job)
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.post(ctx.owner, original.conversation_id, %{
               message_id: message_id,
               text: "Create another result from this new request."
             })

    source = Repo.get_by!(Signal, message_id: message_id)
    {continued, ref} = start_job(ctx, source, job)
    assert created_page(ctx, ref, parent, "Follow-up")["saved_from_message_id"] == message_id
    assert original_request(ref)["text"] == "Create another result from this new request."

    {_, ref} = start_job(ctx, complete_job(continued), continued)

    assert created_page(ctx, ref, parent, "Follow-up continuation")["saved_from_message_id"] ==
             message_id
  end

  test "a continuation without a message source terminates on a cyclic Job chain", ctx do
    {source, parent} = page_request(ctx)
    service = Ankole.WorkFixtures.service_source(ctx.agent)
    reply_route = %{"conversation_id" => source.conversation_id}
    {first, _ref} = start_job(ctx, service, nil, reply_route)
    assert {:ok, _} = BackgroundAgentJobs.request_stop(first.id, %{"agent_uid" => ctx.agent})
    {second, ref} = start_job(ctx, service, nil, reply_route)

    # Public respawn cannot create a cycle. Exercise the persisted traversal guard.
    first |> Ecto.Changeset.change(continued_from_job_id: second.id) |> Repo.update!()
    second |> Ecto.Changeset.change(continued_from_job_id: first.id) |> Repo.update!()

    assert created_page(ctx, ref, parent, "No inferred source")["saved_from_message_id"] == nil
  end

  test "Job execution carries the original Human text independently of the delegated task", ctx do
    text =
      "Prepare the report.\nDo not add the sample now; I will add it myself. Keep \"quoted\" text."

    {source, parent} = page_request(ctx, text)
    {job, ref} = start_job(ctx, source)
    assert job.task == "Save the deliverable as a Page."

    assert Ankole.Conversations.Route.human_request(ref) == %{
             "message_id" => source.message_id,
             "text" => text
           }

    # A later UI edit cannot replace this already-consumed Signal version.
    Repo.get_by!(Ankole.Conversations.Message, id: source.message_id)
    |> Ecto.Changeset.change(text: "Use a relaxed implementation plan.")
    |> Repo.update!()

    assert original_request(ref)["text"] == text

    assert created_page(ctx, ref, parent, "Original request")["saved_from_message_id"] ==
             source.message_id

    wake = complete_job(job)

    main = %{
      agent_uid: ctx.agent,
      signal_id: wake.id,
      context: %{conversation: %{timezone: "UTC"}}
    }

    messages = Ankole.Sessions.Prompt.user(main, wake)
    parts = Enum.flat_map(messages, & &1["content"])

    block =
      Enum.find_value(parts, fn part ->
        value = part["text"]
        if is_binary(value) and String.contains?(value, "<original_human_request>"), do: value
      end)

    assert decode_original_request(block) == %{"message_id" => source.message_id, "text" => text}

    {_, continued_ref} = start_job(ctx, wake, job)
    assert original_request(continued_ref)["text"] == text
  end

  test "only an applied new Human steer changes execution context, not creation provenance",
       ctx do
    {source, parent} = page_request(ctx, "Request A: build the report; I will add the sample.")
    {job, ref} = start_job(ctx, source)
    text = "Request B: change the report language. Do not perform my reserved step."
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.post(ctx.owner, source.conversation_id, %{
               message_id: message_id,
               text: text
             })

    follow_up = Repo.get_by!(Signal, message_id: message_id)

    assert {:ok, %{command_event: steer}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => ctx.agent,
               "request_id" => Ecto.UUID.generate(),
               "source_signal_id" => follow_up.id,
               "message" => "Delegated summary with less detail."
             })

    assert steer.data["source_signal_id"] == follow_up.id
    assert original_request(ref)["text"] =~ "Request A:"

    # The live mailbox delivers B with its summary, without changing context
    # before the Worker acknowledges that it actually applied the message.
    envelope = Ankole.Sessions.TurnEnvelope.mailbox_updated(ref, steer)
    assert {:mailbox_updated, update} = envelope.body

    assert decode_original_request(
             Torque.decode!(update.signal.payload_json)["original_human_request"]
           )["text"] == text

    assert original_request(ref)["text"] =~ "Request A:"

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               ctx.agent,
               %{
                 "status" => "running",
                 "runtime_thread_id" => "human-request-#{job.id}",
                 "metadata" => %{"applied_source_signal_id" => follow_up.id}
               },
               turn_ref: ref,
               worker_id: ctx.agent
             )

    refute Map.has_key?(running.metadata, "applied_source_signal_id")

    # A successful Codex steer is already a persisted client receipt before
    # terminal status. Recovery must start with B, not start with A and wait
    # for a later polling cycle to resend B.
    record_request_turn(running, ref, ctx.agent, steer.id, "in_progress")
    checkpointed = BackgroundAgentJobs.get_job_for_agent(job.id, ctx.agent)
    assert checkpointed.status == "running"
    assert checkpointed.metadata["applied_source_signal_id"] == steer.id
    assert Repo.reload!(steer).completed_at == nil
    assert original_request(ref)["text"] == text
    assert original_request(ref, "adopt")["text"] == text

    assert created_page(ctx, ref, parent, "After applied B")["saved_from_message_id"] ==
             source.message_id

    assert {:ok, %{command_event: summary}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => ctx.agent,
               "request_id" => Ecto.UUID.generate(),
               "source_signal_id" => source.id,
               "message" => "Check the result again."
             })

    assert {:mailbox_updated, summary_update} =
             Ankole.Sessions.TurnEnvelope.mailbox_updated(ref, summary).body

    assert decode_original_request(
             Torque.decode!(summary_update.signal.payload_json)["original_human_request"]
           )["text"] == text

    record_request_turn(running, ref, ctx.agent, steer.id, "completed")

    assert {:ok, %{job: completed, wakeup_event: wake}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               ctx.agent,
               %{
                 "status" => "succeeded",
                 "metadata" => %{"applied_source_signal_id" => source.id},
                 "result" => %{"output_text" => "Report ready."}
               },
               turn_ref: ref,
               worker_id: ctx.agent,
               applied_signal_ids: [summary.id, steer.id]
             )

    assert completed.source_signal_id == source.id
    assert completed.metadata["applied_source_signal_id"] == steer.id
    assert Repo.reload!(steer).completed_at != nil
    assert original_request(ref)["text"] == text
    assert Ankole.Conversations.Route.source_message_id(ref) == source.message_id

    # Worker-supplied metadata cannot clear the CP's applied reference.
    assert {:ok, %{job: unchanged}} =
             BackgroundAgentJobs.commit_status_with_wakeup(job.id, ctx.agent, %{
               "status" => "succeeded",
               "metadata" => %{"applied_source_signal_id" => nil}
             })

    assert unchanged.metadata["applied_source_signal_id"] == steer.id

    {_, continued_ref} = start_job(ctx, wake, completed)
    assert original_request(continued_ref)["text"] == text

    assert created_page(ctx, continued_ref, parent, "Continued after B")["saved_from_message_id"] ==
             source.message_id
  end

  test "a provider readmission in an older source Chat cannot reset applied cross-Chat intent",
       ctx do
    {source, _parent} = page_request(ctx, "Old Chat request A")
    {job, ref} = start_job(ctx, source)
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.create(ctx.owner, %{
               conversation_id: Ecto.UUID.generate(),
               message_id: message_id,
               agent_uid: ctx.agent,
               text: "New Chat request B"
             })

    follow_up = Repo.get_by!(Signal, message_id: message_id)

    assert {:ok, %{command_event: steer}} =
             BackgroundAgentJobs.send_message(job.id, %{
               "agent_uid" => ctx.agent,
               "request_id" => Ecto.UUID.generate(),
               "source_signal_id" => follow_up.id,
               "message" => "Use this new request."
             })

    assert {:ok, %{job: running}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               ctx.agent,
               %{"status" => "running", "runtime_thread_id" => "cross-chat-#{job.id}"},
               turn_ref: ref,
               worker_id: ctx.agent
             )

    record_request_turn(running, ref, ctx.agent, steer.id, "in_progress")

    source
    |> Ecto.Changeset.change(
      last_attempt_at: DateTime.add(DateTime.utc_now(:microsecond), 60, :second)
    )
    |> Repo.update!()

    assert original_request(ref)["text"] == "New Chat request B"
  end

  test "a Job without a native Human source does not invent original instructions", ctx do
    {source, _parent} = page_request(ctx)
    service = Ankole.WorkFixtures.service_source(ctx.agent)
    {_job, ref} = start_job(ctx, service, nil, %{"conversation_id" => source.conversation_id})
    assert Ankole.Conversations.Route.human_request(ref) == nil
    assert original_request(ref) == nil
  end

  defp original_request(ref, mode \\ "start") do
    signal = Repo.get!(Signal, ref.signal_id)

    envelope =
      Ankole.Sessions.TurnEnvelope.turn_start(ref, signal, %{request_context: %{}}, mode, nil)

    bytes = Ankole.Kernel.RuntimeFabric.encode_envelope(envelope)

    assert {:ok, %{body: {:turn_start, start}}} =
             Ankole.Kernel.RuntimeFabric.decode_envelope(bytes)

    context = Torque.decode!(start.request_context_json)

    case context["original_human_request"] do
      "" -> nil
      block -> decode_original_request(block)
    end
  end

  defp decode_original_request(block) do
    [_, json] = String.split(block, "<original_human_request>\n", parts: 2)
    json |> String.trim_trailing("\n</original_human_request>") |> Torque.decode!()
  end

  defp record_request_turn(job, ref, worker, receipt_id, status) do
    now = DateTime.utc_now(:microsecond)

    user = %{
      "position" => 0,
      "item_key" => "client:#{receipt_id}",
      "item" => %{
        "type" => "userMessage",
        "id" => receipt_id,
        "clientId" => receipt_id,
        "content" => [%{"type" => "text", "text" => "Applied Human B and delegated message."}]
      }
    }

    final = %{
      "position" => 1,
      "item_key" => "final",
      "item" => %{
        "type" => "agentMessage",
        "id" => "final",
        "text" => "Report ready."
      }
    }

    assert {:ok, _} =
             BackgroundAgentJobs.upsert_turn_from_worker(
               job.id,
               job.agent_uid,
               %{
                 "attempt" => job.attempts,
                 "runtime_thread_id" => job.runtime_thread_id,
                 "runtime_turn_id" => "human-request-turn-#{job.id}",
                 "kind" => "agent",
                 "status" => status,
                 "revision" => if(status == "completed", do: 1, else: 0),
                 "trajectory" => %{"format" => "ankole_chatml", "version" => 1},
                 "turn_items" => if(status == "completed", do: [user, final], else: [user]),
                 "progress" => %{
                   "completed_items" => if(status == "completed", do: 2, else: 1),
                   "tool_calls" => 0,
                   "tools_used" => [],
                   "files_changed" => []
                 },
                 "error" => %{},
                 "started_at" => job.started_at,
                 "completed_at" => if(status == "completed", do: now)
               },
               ref,
               worker
             )
  end

  defp page_request(ctx, text \\ "Create a report and an applet.") do
    message_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.create(ctx.owner, %{
               conversation_id: Ecto.UUID.generate(),
               message_id: message_id,
               agent_uid: ctx.agent,
               text: text
             })

    {:ok, parent} = Pages.create(ctx.owner, %{title: "Agent deliverables"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, parent.id, %{
        grants: [%{principal_uid: ctx.agent, role: "edit"}]
      })

    {Repo.get_by!(Signal, message_id: message_id), parent.id}
  end

  defp start_job(ctx, source, previous \\ nil, reply_route \\ nil) do
    attrs = %{
      "agent_uid" => ctx.agent,
      "owner_session_id" => source.session_id,
      "source_signal_id" => source.id,
      "source_tool_call_id" => Ecto.UUID.generate(),
      "reply_route" => reply_route || Ankole.Conversations.Route.snapshot(%{signal_id: source.id})
    }

    result =
      if previous do
        BackgroundAgentJobs.respawn_with_dispatch(
          previous.id,
          Map.put(attrs, "message", "Continue the task.")
        )
      else
        BackgroundAgentJobs.create_with_dispatch(
          Map.merge(attrs, %{
            "title" => "Create deliverable",
            "task" => "Save the deliverable as a Page."
          })
        )
      end

    assert {:ok, %{job: job, dispatch_event: dispatch}} = result
    assert {:ok, attempt} = Ankole.Sessions.Admission.admit(dispatch, dispatch)
    {job, attempt.job_ref}
  end

  defp complete_job(job) do
    assert {:ok, %{wakeup_event: wake}} =
             BackgroundAgentJobs.commit_status_with_wakeup(
               job.id,
               job.agent_uid,
               %{"status" => "succeeded", "runtime_thread_id" => "source-test-#{job.id}"},
               external_completion: true
             )

    wake
  end

  defp created_page(ctx, ref, parent, title, type \\ "doc") do
    assert {:ok, %{"result" => page}} =
             RPCBroker.handle_write(
               ref,
               request("pages.create", %{parent_id: parent, title: title, type: type}),
               ctx.ctx
             )

    page
  end

  test "Applet RPC retains Agent identity, logs and the current RunRef on each capability write",
       ctx do
    {:ok, database} = Pages.create(ctx.owner, %{type: "database"})
    {:ok, table} = Ankole.Pod.Database.create_table(ctx.owner, database.id, %{name: "Orders"})

    {:ok, field} =
      Ankole.Pod.Database.create_field(ctx.owner, table.id, %{type: "text", name: "Label"})

    {:ok, applet} = Pages.create(ctx.owner, %{type: "applet"})

    for page <- [database, applet] do
      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
          grants: [%{principal_uid: ctx.agent, role: "edit"}]
        })
    end

    source = """
    export default {
      'POST /write':async r=>{console.log('writing-as',r.principal.uid); const result=await AnkoleRuntime.db.write('#{table.id}',r.body);return {principal:r.principal,result}},
      'GET /crash':()=>{console.warn('debug-log');throw new Error('agent-debug')}
    }
    """

    manifest =
      Enum.map(
        [{"src/main.tsx", "source"}, {"dist/index.html", "frontend"}, {"server/main.js", source}],
        fn {path, bytes} ->
          {:ok, blob} = Ankole.Files.store(bytes)

          {:ok, _} =
            Ankole.Files.commit(ctx.agent, [
              %{path: "publish/#{applet.id}/#{path}", sha256: blob.sha256, source: "agent"}
            ])

          %{path: path, sha256: blob.sha256}
        end
      )

    {:ok, _} = Files.publish(ctx.agent, applet.id, 0, manifest, {ctx.ref, ctx.agent})

    attrs = %{
      id: applet.id,
      method: "POST",
      path: "/write",
      body: %{creates: [%{data: %{field.id => "Committed"}}]}
    }

    assert {:ok,
            %{
              "result" => %{
                "status" => 200,
                "body" => %{"principal" => principal},
                "logs" => logs
              }
            }} = RPCBroker.handle_write(ctx.ref, request("applets.call", attrs), ctx.ctx)

    assert principal["uid"] == ctx.agent
    assert principal["kind"] == "agent"
    assert Enum.any?(logs, &String.contains?(&1["message"], ctx.agent))
    assert {:ok, _} = Ankole.Sessions.Run.finalize(ctx.run, :silent)

    assert {:ok,
            %{"result" => %{"status" => 422, "body" => %{"error" => %{"code" => "run_closed"}}}}} =
             RPCBroker.handle_write(ctx.ref, request("applets.call", attrs), ctx.ctx)

    assert {:ok, %{records: [record]}} = Ankole.Pod.Database.query(ctx.owner, table.id, %{})
    assert record["data"][field.id] == "Committed"

    assert {:ok,
            %{"result" => %{"status" => 500, "debug" => %{"message" => debug}, "logs" => [_]}}} =
             RPCBroker.handle_write(
               ctx.ref,
               request("applets.call", %{id: applet.id, method: "GET", path: "/crash"}),
               ctx.ctx
             )

    assert debug =~ "agent-debug"
  end

  defp request(operation, params),
    do: %FabricProto.PodRequest{operation: operation, params_json: Torque.encode!(params)}
end
