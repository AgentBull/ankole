defmodule Ankole.Sessions.DerivedAuthorizationTest do
  use Ankole.DataCase, async: false

  alias Ankole.{AuthZ, BackgroundAgentJobs, Conversations, Schedule, Workflow}
  alias Ankole.AgentWorkers.WorkerRoute
  alias Ankole.Pod.{Pages, RPCBroker}
  alias Ankole.RuntimeFabric.V1.{PodRequest, ReadToolRequest}
  alias Ankole.Sessions.{Admission, Context, ReadToolBroker, ToolCatalog, Tools}
  alias Ankole.Signals.Signal

  setup do
    human = Ankole.PrincipalsFixtures.human_fixture().principal
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: human.uid}).principal
    %{human: human, agent: agent}
  end

  for kind <- [:workflow_task, :scheduled] do
    test "human-owned #{kind} enforces tool names, arguments and the native ingress IP", ctx do
      source = native_source(ctx)
      run = derived_run(unquote(kind), source)
      assert run.kind == unquote(kind)
      assert run.event.authorization_kind == "human"
      assert run.event.human_uid == ctx.human.uid
      call = call("web_fetch", %{"urls" => ["https://example.com"], "result_offset" => 0})
      assert {:error, %{failure_kind: "forbidden"}} = Tools.prepare(run, call)

      grant(
        ctx.human.uid,
        "agent:#{ctx.agent.uid}:tool:web_fetch",
        "invoke",
        ~s|context.request.ip == "10.20.1.10" && context.request.surface == "agent_tool" && context.request.authn.provider_scope == "tenant" && context.request.authn.amr.contains("oidc") && context.request.args.result_offset == 0|
      )

      assert {:ok, _, %{"result_offset" => 0}} = Tools.prepare(run, call)

      assert {:error, %{failure_kind: "forbidden"}} =
               Tools.prepare(
                 run,
                 call("web_fetch", %{"urls" => ["https://example.com"], "result_offset" => 10})
               )

      assert {:error, %{failure_kind: "forbidden"}} =
               Tools.prepare(
                 run,
                 call("create_background_job", %{"title" => "Report", "task" => "Research"})
               )

      assert Conversations.request_context(%{run.event | producer: :external}) == %{}
    end

    test "service-owned #{kind} uses Agent authority without a human tool grant", ctx do
      source = Ankole.WorkFixtures.service_source(ctx.agent.uid)
      run = derived_run(unquote(kind), source)
      assert run.event.authorization_kind == "service"

      assert {:ok, _, _} =
               Tools.prepare(
                 run,
                 call("web_fetch", %{"urls" => ["https://example.com"], "result_offset" => 0})
               )

      assert Conversations.request_context(run.event) == %{}
    end
  end

  test "closing guest collaboration rejects a running guest's previously granted tools", ctx do
    guest = Ankole.PrincipalsFixtures.human_fixture(%{membership: :guest}).principal
    source = native_source(%{ctx | human: guest})
    run = derived_run(:workflow_task, source)
    grant(guest.uid, "agent:#{ctx.agent.uid}:tool:web_fetch", "invoke", "true")
    call = call("web_fetch", %{"urls" => ["https://example.com"], "result_offset" => 0})
    assert {:ok, _, _} = Tools.prepare(run, call)
    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.allow_external_guests", false)
    assert {:error, %{failure_kind: "forbidden"}} = Tools.prepare(run, call)
  end

  test "nested work follows its persisted source and refuses foreign or cyclic provenance", ctx do
    source = native_source(ctx)
    task = derived_run(:workflow_task, source)
    attempt = job_attempt(task.event)

    assert Conversations.request_context(attempt.event) == %{
             "ip" => "10.20.1.10",
             "authn" => %{"ip" => "10.20.1.10", "provider_scope" => "tenant", "amr" => ["oidc"]}
           }

    foreign_human = Ankole.PrincipalsFixtures.human_fixture().principal
    foreign = native_source(%{ctx | human: foreign_human})
    workflow = Repo.get!(Ankole.Workflow.Schemas.Run, task.event.data["run_id"])

    for source_id <- [foreign.id, task.event.id, nil] do
      workflow
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(source_signal_id: source_id)
      |> Repo.update!()

      assert Conversations.request_context(attempt.event) == %{}
    end
  end

  test "cron fires and automation emissions retain their creator's trusted request context",
       ctx do
    source = native_source(ctx)
    now = DateTime.utc_now(:microsecond)

    assert {:ok, %{cron_schedule: cron}} =
             Schedule.create_cron_schedule(
               %{
                 agent_uid: source.agent_uid,
                 owner_session_id: source.session_id,
                 name: "Authorized cron",
                 idempotency_key: Ecto.UUID.generate(),
                 schedule: %{
                   "kind" => "every",
                   "every_ms" => 60_000,
                   "anchor_at" => DateTime.to_iso8601(now),
                   "timezone" => "UTC"
                 },
                 payload: %{"task" => "Report"},
                 delivery: %{"targets" => [reply_route(source)]}
               },
               now: now,
               created_by: %{"signal_id" => source.id}
             )

    assert {:ok, %{signal: fire}} = Schedule.fire_cron(cron.id, now: cron.next_fire_at)

    assert Conversations.request_context(fire) == %{
             "ip" => "10.20.1.10",
             "authn" => %{"ip" => "10.20.1.10", "provider_scope" => "tenant", "amr" => ["oidc"]}
           }

    Ankole.FilesFixtures.drive_file_fixture(ctx.agent.uid, "automation/authz/main.ts")

    assert {:ok, job} =
             Ankole.AutomationJobs.create_job(%{
               agent_uid: ctx.agent.uid,
               owner_session_id: source.session_id,
               source_signal_id: source.id,
               reply_route: reply_route(source),
               drive_prefix: "automation/authz",
               label: "Authorization"
             })

    assert {:ok, %{automation_job_run: run}} =
             Repo.transact(fn ->
               Ankole.AutomationJobs.enqueue_run_in_tx(
                 job.id,
                 ctx.agent.uid,
                 %{"id" => Ecto.UUID.generate(), "type" => "test.trigger"},
                 now: now
               )
             end)

    assert {:ok, _} =
             Ankole.SessionsCase.admit_worker("automation-authz-#{Ecto.UUID.generate()}", %{
               worker_id: ctx.agent.uid
             })

    assert {:ok, %{run: attempt}} = Ankole.AutomationJobs.start_attempt(run.id, now: now)

    assert {:ok, emitted} =
             Ankole.AutomationJobs.emit_event(
               ctx.agent.uid,
               run.id,
               attempt.attempt_id,
               %{"report" => "ready"},
               now: now
             )

    assert Conversations.request_context(emitted) == %{
             "ip" => "10.20.1.10",
             "authn" => %{"ip" => "10.20.1.10", "provider_scope" => "tenant", "amr" => ["oidc"]}
           }
  end

  test "a human-owned background job intersects Pod reads and writes and retains ingress IP",
       ctx do
    source = native_source(ctx)
    attempt = job_attempt(source)
    owner = Ankole.PrincipalsFixtures.human_fixture().principal

    assert {:ok, page} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
               title: "Protected"
             })

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
               inherit_permissions: false,
               grants: [%{principal_uid: owner.uid, role: "manage"}]
             })

    pattern = "pod:**:#{page.id}:page"
    condition = ~s(context.request.ip == "10.20.1.10" && context.request.surface == "agent_rpc")
    agent_grants = page_grants(ctx.agent.uid, pattern)
    refute page.id in rpc_page_ids(attempt)
    assert {:error, %{"code" => "forbidden"}} = rpc_update(attempt, page.id, "Denied")

    Enum.each(agent_grants, fn grant ->
      assert {:ok, _} = AuthZ.delete_permission_grant(grant.id)
    end)

    page_grants(ctx.agent.uid, pattern, condition)
    human_grants = page_grants(ctx.human.uid, pattern, condition)
    assert page.id in rpc_page_ids(attempt)
    assert {:ok, %{"result" => %{"title" => "Allowed"}}} = rpc_update(attempt, page.id, "Allowed")

    Enum.each(human_grants, fn grant ->
      assert {:ok, _} = AuthZ.delete_permission_grant(grant.id)
    end)

    refute page.id in rpc_page_ids(attempt)
    assert {:error, %{"code" => "forbidden"}} = rpc_update(attempt, page.id, "Denied again")

    assert {:ok, %{page: %{title: "Allowed"}}} =
             Pages.get(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), page.id)
  end

  test "a service-owned background job uses only the Agent's Pod grant", ctx do
    source = Ankole.WorkFixtures.service_source(ctx.agent.uid)
    attempt = job_attempt(source)
    owner = Ankole.PrincipalsFixtures.human_fixture().principal

    assert {:ok, page} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
               title: "Service page"
             })

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
               inherit_permissions: false,
               grants: [%{principal_uid: owner.uid, role: "manage"}]
             })

    page_grants(ctx.agent.uid, "pod:**:#{page.id}:page")
    assert page.id in rpc_page_ids(attempt)

    assert {:ok, %{"result" => %{"title" => "Service write"}}} =
             rpc_update(attempt, page.id, "Service write")
  end

  test "background hosted reads enforce the human's tool grant before returning rendered content",
       ctx do
    attempt = ctx |> native_source() |> job_attempt()

    request = %ReadToolRequest{
      name: "web_fetch",
      arguments_json: Torque.encode!(%{"urls" => ["https://example.com"]}),
      rendered_body_json:
        Torque.encode!(%{
          "results" => [%{"url" => "https://example.com", "text" => "Report content"}]
        })
    }

    rpc = rpc_context(attempt)

    assert {:error, %{"code" => "forbidden"}} =
             ReadToolBroker.handle_read(attempt.job_ref, request, rpc)

    permission =
      grant(
        ctx.human.uid,
        "agent:#{ctx.agent.uid}:tool:web_fetch",
        "invoke",
        ~s(context.request.ip == "10.20.1.10" && context.request.args.urls == ["https://example.com"])
      )

    assert {:ok, %{"output" => output}} =
             ReadToolBroker.handle_read(attempt.job_ref, request, rpc)

    assert output =~ "Report content"
    assert {:ok, _} = AuthZ.delete_permission_grant(permission.id)

    assert {:error, %{"code" => "forbidden"}} =
             ReadToolBroker.handle_read(attempt.job_ref, request, rpc)
  end

  test "background hosted reads use service authority and reject a different Signal's session",
       ctx do
    source = Ankole.WorkFixtures.service_source(ctx.agent.uid)
    attempt = job_attempt(source)

    request = %ReadToolRequest{
      name: "web_fetch",
      arguments_json: Torque.encode!(%{"urls" => ["https://example.com"]}),
      rendered_body_json:
        Torque.encode!(%{
          "results" => [%{"url" => "https://example.com", "text" => "Service content"}]
        })
    }

    assert {:ok, %{"output" => output}} =
             ReadToolBroker.handle_read(attempt.job_ref, request, rpc_context(attempt))

    assert output =~ "Service content"

    wrong_turn = %{attempt.job_ref | signal_id: source.id}

    assert {:error, %{"code" => "signal_not_owned"}} =
             ReadToolBroker.handle_read(wrong_turn, request, rpc_context(attempt))
  end

  defp native_source(ctx) do
    Ankole.ConversationsFixtures.grant_chat(ctx.human.uid, ctx.agent.uid)
    id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.create(
               Ankole.PrincipalsFixtures.actor_fixture(
                 actor_context(ctx.human.uid, "10.20.1.10")
               ),
               %{
                 conversation_id: id,
                 message_id: Ecto.UUID.generate(),
                 agent_uid: ctx.agent.uid,
                 text: "Research this"
               }
             )

    Repo.get_by!(Signal, conversation_id: id)
  end

  defp derived_run(:workflow_task, source) do
    assert {:ok, %{run: workflow}} =
             Workflow.create_with_dispatch(%{
               "agent_uid" => source.agent_uid,
               "owner_session_id" => source.session_id,
               "source_signal_id" => source.id,
               "source_tool_call_id" => "workflow",
               "reply_route" => reply_route(source),
               "title" => "Research",
               "script" => "return await agent('Research');",
               "args" => %{}
             })

    Ankole.SessionsCase.stub_workflow_drivers(workflow)

    assert {:ok, %{new_calls: [call]}} =
             Workflow.Replay.commit_replay_pending(
               workflow.id,
               [%{namespace: nil, name: "agent", arguments: %{"prompt" => "Research"}}],
               0
             )

    event = Repo.get_by!(Signal, source_event_id: "workflow:call:#{call.id}:dispatch")
    admit(event)
  end

  defp derived_run(:scheduled, source) do
    now = DateTime.utc_now(:microsecond)
    due = DateTime.add(now, 5, :minute)

    assert {:ok, %{scheduled_event: event}} =
             Schedule.create_check_back_later(
               %{
                 source_signal_id: source.id,
                 agent_uid: source.agent_uid,
                 session_id: source.session_id,
                 tool_call_id: "check",
                 idempotency_key: Ecto.UUID.generate(),
                 schedule: %{"at" => DateTime.to_iso8601(due), "timezone" => "UTC"},
                 reason: "Follow up",
                 check: "Report changes"
               },
               now: now
             )

    assert {:ok, %{signal: signal}} = Schedule.fire_due_event(event.id, now: due)
    admit(signal, now: due)
  end

  defp admit(signal, opts \\ []) do
    assert {:ok, run} = Admission.admit(signal, signal, opts)
    assert {:ok, context} = Context.resolve(run.agent_uid, run.session_id)
    run = %{run | context: context}
    {tools, _} = ToolCatalog.for_run(run)
    %{run | tools: tools}
  end

  defp job_attempt(source) do
    assert {:ok, primary} =
             Ankole.AIAgent.ModelProfiles.resolve_runtime_profile(source.agent_uid, "primary")

    assert {:ok, _} =
             Ankole.AIAgent.ModelProfiles.put_model_profile(
               source.agent_uid,
               "coding",
               Map.take(primary, ["provider_id", "model", "provider_options"])
             )

    assert {:ok, %{dispatch_event: event}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               agent_uid: source.agent_uid,
               owner_session_id: source.session_id,
               source_signal_id: source.id,
               source_tool_call_id: "job",
               title: "Read",
               task: "Read protected page",
               reply_route: reply_route(source)
             })

    route = "derived-job-#{Ecto.UUID.generate()}"
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, _} = Ankole.SessionsCase.admit_worker(route, %{worker_id: source.agent_uid})
    assert {:ok, attempt} = Admission.admit(event, event)
    attempt
  end

  defp reply_route(%{conversation_id: id}) when is_binary(id), do: %{"conversation_id" => id}
  defp reply_route(_source), do: %{"binding_name" => "bot"}

  defp rpc_page_ids(attempt) do
    assert {:ok, %{"result" => pages}} =
             RPCBroker.handle_read(
               attempt.job_ref,
               %PodRequest{operation: "pages.list", params_json: "{}"},
               rpc_context(attempt)
             )

    Enum.map(pages, & &1["id"])
  end

  defp rpc_update(attempt, id, title),
    do:
      RPCBroker.handle_write(
        attempt.job_ref,
        %PodRequest{
          operation: "pages.update",
          params_json: Torque.encode!(%{id: id, title: title})
        },
        rpc_context(attempt)
      )

  defp rpc_context(attempt),
    do: %{
      worker_id: attempt.agent_uid,
      route: attempt.job_worker.transport_route,
      request_id: "derived-authz"
    }

  defp call(name, args),
    do: %{"name" => name, "call_id" => Ecto.UUID.generate(), "arguments" => Torque.encode!(args)}

  defp page_grants(uid, resource, condition \\ "true"),
    do: Enum.map(["page_view", "page_edit"], &grant(uid, resource, &1, condition))

  defp grant(uid, resource, action, condition) do
    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: uid,
               resource_pattern: resource,
               action: action,
               condition: condition
             })

    grant
  end

  defp actor_context(uid, ip) do
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    %{actor | authn: %{"ip" => ip, "provider_scope" => "tenant", "amr" => ["oidc"]}}
  end
end
