defmodule Ankole.Sessions.ReplyRouteTest do
  use Ankole.DataCase, async: false

  import Ankole.FilesFixtures
  import Ankole.AIGatewayCase, only: [background_agent_fixture: 0]

  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.RPCBroker, as: AutomationBroker
  alias Ankole.AutomationJobs.Schemas.Run, as: AutomationRun
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.AIGateway.Conversations
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.RunRef
  alias Ankole.Principals.WorkAccess
  alias Ankole.RuntimeFabric.V1, as: Proto

  alias Ankole.Signals.Signal
  alias Ankole.Signals.WebhookEndpoint
  alias Ankole.Signals.Webhooks
  alias Ankole.Conversations.Route
  alias Ankole.Signals.Webhooks.RPCBroker, as: WebhookBroker
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  @ctx %{route: "b07-worker", request_id: "b07-rpc"}

  test "a normal session keeps its existing ownership without creating a conversation" do
    %{principal: agent} = background_agent_fixture()

    assert {:ok, %{session_id: "main", reply_route: nil}} =
             Route.long_lived_owner(agent.uid, "main")

    assert Repo.aggregate(Ankole.AIGateway.Schemas.Conversation, :count) == 0
  end

  test "the production RPC gate rejects a different Session or Signal before owner resolution" do
    %{principal: agent} = background_agent_fixture()
    source = source!(agent.uid, "origin")
    actual = ref(source)

    assert :ok =
             Ankole.AgentWorkers.WorkerRouteAuth.authorize_turn(
               actual,
               agent.uid,
               :write
             )

    assert {:error, :run_closed} =
             Ankole.AgentWorkers.WorkerRouteAuth.authorize_turn(
               %{actual | session_id: "arbitrary-owner"},
               agent.uid,
               :write
             )

    assert {:error, :run_closed} =
             Ankole.AgentWorkers.WorkerRouteAuth.authorize_turn(
               %{actual | signal_id: Ecto.UUID.generate()},
               agent.uid,
               :write
             )

    source |> change(completed_at: DateTime.utc_now(:microsecond)) |> Repo.update!()

    assert {:error, :run_closed} =
             Ankole.AgentWorkers.WorkerRouteAuth.authorize_turn(
               actual,
               agent.uid,
               :write
             )
  end

  test "nested Jobs resolve the pinned origin even after the parent and its context end" do
    %{principal: agent} = background_agent_fixture()
    source = source!(agent.uid, "origin")
    parent = job!(source)
    child = job!(parent.dispatch_event)
    finish_job!(parent.job)

    conversation =
      Repo.get!(
        Ankole.AIGateway.Schemas.Conversation,
        parent.job.metadata["owner_conversation_id"]
      )

    conversation |> change(ended_at: DateTime.utc_now(:microsecond)) |> Repo.update!()

    assert {:ok, %{session_id: "origin", reply_route: route}} =
             Route.long_lived_owner(agent.uid, child.dispatch_event.session_id)

    assert route == Route.snapshot(ref(source))
    assert child.job.owner_session_id == parent.dispatch_event.session_id
  end

  test "a Workflow task and its delegated Job resolve the same long-lived session" do
    %{principal: agent} = background_agent_fixture()
    source = source!(agent.uid, "workflow-origin")
    {:ok, _} = Conversations.ensure_conversation(agent.uid, source.session_id)
    task = workflow_task!(source)
    task_source = source!(agent.uid, Ankole.Workflow.task_session_id(task.id))
    delegated = job!(task_source)

    for session <- [task_source.session_id, delegated.dispatch_event.session_id] do
      assert {:ok, %{session_id: "workflow-origin", reply_route: route}} =
               Route.long_lived_owner(agent.uid, session)

      assert route == Route.snapshot(ref(source))
    end
  end

  test "missing, deleted, inconsistent and cyclic owners fail without creating a replacement" do
    %{principal: agent} = background_agent_fixture()
    %{principal: other} = background_agent_fixture()
    source = source!(agent.uid, "origin")
    parent = job!(source)

    assert {:error, :long_lived_reply_owner_not_found} =
             Route.long_lived_owner(other.uid, parent.dispatch_event.session_id)

    assert {:error, :long_lived_reply_owner_not_found} =
             Route.long_lived_owner(agent.uid, "job:999999999")

    conversation_id = parent.job.metadata["owner_conversation_id"]
    conversation = Repo.get!(Ankole.AIGateway.Schemas.Conversation, conversation_id)
    parent.job |> change(owner_session_id: "different") |> Repo.update!()

    assert {:error, :long_lived_reply_owner_not_found} =
             Route.long_lived_owner(agent.uid, parent.dispatch_event.session_id)

    parent.job |> change(owner_session_id: source.session_id) |> Repo.update!()
    Repo.delete!(conversation)

    assert {:error, :long_lived_reply_owner_not_found} =
             Route.long_lived_owner(agent.uid, parent.dispatch_event.session_id)

    {:ok, loop} = Conversations.ensure_conversation(agent.uid, parent.dispatch_event.session_id)

    parent.job
    |> change(
      owner_session_id: parent.dispatch_event.session_id,
      metadata: %{"owner_conversation_id" => loop.id}
    )
    |> Repo.update!()

    assert {:error, :long_lived_reply_owner_not_found} =
             Route.long_lived_owner(agent.uid, parent.dispatch_event.session_id)

    assert Repo.aggregate(WebhookEndpoint, :count) == 0
  end

  test "a Workflow call cannot borrow the Run of another Agent" do
    %{principal: agent} = background_agent_fixture()
    %{principal: other} = background_agent_fixture()
    source = source!(agent.uid, "origin")
    task = workflow_task!(source)
    task |> change(agent_uid: other.uid) |> Repo.update!()

    assert {:error, :long_lived_reply_owner_not_found} =
             Route.long_lived_owner(other.uid, Ankole.Workflow.task_session_id(task.id))
  end

  test "Job webhook CRUD shares the origin, retains the actual caller, and survives Job completion" do
    %{principal: agent} = background_agent_fixture()
    source = source!(agent.uid, "origin")
    parent = job!(source)
    turn = job_ref(parent)

    assert {:ok, %{"webhook_endpoint" => %{"id" => id, "url" => url}}} =
             WebhookBroker.handle_create(turn, webhook_request(), @ctx)

    endpoint = Repo.get!(WebhookEndpoint, id)
    assert endpoint.session_id == source.session_id
    assert endpoint.binding_name == source.reply_binding_name
    assert endpoint.conversation_id == source.conversation_id
    assert endpoint.provider_thread_id == source.provider_thread_id
    assert endpoint.source_signal_id == parent.dispatch_event.id
    refute endpoint.source_signal_id == source.id
    assert endpoint.source_provenance["transport_route"] == @ctx.route

    for caller <- [turn, ref(source)] do
      assert {:ok, %{"webhook_endpoints" => [%{"id" => ^id}]}} =
               WebhookBroker.handle_list(caller, %Proto.WebhookEndpointListRequest{}, @ctx)
    end

    finish_job!(parent.job)
    token = url |> String.split("/") |> List.last()
    assert {:ok, %{signal: receipt}} = Webhooks.receive(token, [], "receipt")
    assert receipt.session_id == source.session_id
    assert receipt.data["source_signal_id"] == parent.dispatch_event.id

    assert {:ok, %{"status" => "cancelled"}} =
             WebhookBroker.handle_cancel(
               ref(source),
               %Proto.WebhookEndpointTargetRequest{webhook_endpoint_id: id},
               @ctx
             )
  end

  test "unresolved Job creation fails before writing either long-lived resource" do
    %{principal: agent} = background_agent_fixture()
    parent = job!(source!(agent.uid, "origin"))

    Repo.delete!(
      Repo.get!(
        Ankole.AIGateway.Schemas.Conversation,
        parent.job.metadata["owner_conversation_id"]
      )
    )

    turn = job_ref(parent)
    drive_file_fixture(agent.uid, "automation/b07/main.ts")

    assert {:error, %{"code" => "long_lived_reply_owner_not_found"}} =
             WebhookBroker.handle_create(turn, webhook_request(), @ctx)

    assert {:error, %{"code" => "long_lived_reply_owner_not_found"}} =
             AutomationBroker.handle_create(turn, automation_request(), @ctx)

    assert Repo.aggregate(WebhookEndpoint, :count) == 0
    assert Repo.aggregate(Ankole.AutomationJobs.Schemas.Job, :count) == 0
  end

  test "Job automation create, list, show and cancel use the same origin and caller authorization" do
    %{principal: agent} = background_agent_fixture()
    source = source!(agent.uid, "origin")
    parent = job!(source)
    turn = job_ref(parent)
    drive_file_fixture(agent.uid, "automation/b07/main.ts")

    assert {:ok, %{"automation_job" => %{"id" => id}}} =
             AutomationBroker.handle_create(turn, automation_request(), @ctx)

    job = Repo.get!(Ankole.AutomationJobs.Schemas.Job, id)
    assert job.owner_session_id == source.session_id
    assert job.source_signal_id == parent.dispatch_event.id
    assert job.authorization_kind == parent.dispatch_event.authorization_kind
    assert job.reply_route == Route.snapshot(ref(source))

    for caller <- [turn, ref(source)] do
      assert {:ok, %{"automation_jobs" => [%{"id" => ^id}]}} =
               AutomationBroker.handle_list(caller, %Proto.AutomationJobListRequest{}, @ctx)

      assert {:ok, %{"result" => %{"automation_job" => %{"id" => ^id}}}} =
               AutomationBroker.handle_show(
                 caller,
                 %Proto.AutomationJobShowRequest{automation_job_id: to_string(id)},
                 @ctx
               )
    end

    outside = %{ref(source) | session_id: "unrelated"}

    assert {:error, %{"code" => "automation_job_not_found"}} =
             AutomationBroker.handle_show(
               outside,
               %Proto.AutomationJobShowRequest{automation_job_id: to_string(id)},
               @ctx
             )

    assert {:ok, %{"status" => "cancelled"}} =
             AutomationBroker.handle_cancel(
               turn,
               %Proto.AutomationJobTargetRequest{automation_job_id: to_string(id)},
               @ctx
             )

    parent.dispatch_event |> change(authorization_kind: "review_required") |> Repo.update!()

    assert {:error, %{"code" => "work_authorization_review_required"}} =
             AutomationBroker.handle_create(turn, automation_request(), @ctx)

    assert Repo.aggregate(Ankole.AutomationJobs.Schemas.Job, :count) == 1
  end

  test "legacy webhook routes resolve through the same owner and an orphan does not consume its token" do
    %{principal: agent} = background_agent_fixture()
    source = source!(agent.uid, "origin")
    parent = job!(source)

    assert {:error, :invalid_signal_target} =
             Webhooks.create_endpoint(endpoint_attrs(parent.dispatch_event))

    token = "wh_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    endpoint =
      %WebhookEndpoint{}
      |> WebhookEndpoint.changeset(
        endpoint_attrs(parent.dispatch_event)
        |> Map.merge(%{token_digest: Webhooks.token_digest(token), status: "active"})
      )
      |> Repo.insert!()

    finish_job!(parent.job)
    assert {:ok, %{signal: receipt}} = Webhooks.receive(token, [], "legacy")
    assert receipt.session_id == source.session_id
    assert receipt.conversation_id == source.conversation_id
    assert Repo.reload!(endpoint).session_id == parent.dispatch_event.session_id

    Repo.delete!(
      Repo.get!(
        Ankole.AIGateway.Schemas.Conversation,
        parent.job.metadata["owner_conversation_id"]
      )
    )

    assert {:error, :long_lived_reply_owner_not_found} = Webhooks.receive(token, [], "orphan")
    assert Repo.reload!(endpoint).status == "active"
    assert [legacy] = Webhooks.list_endpoints(agent.uid, nil)
    assert legacy.id == endpoint.id
    assert {:ok, %{status: :cancelled}} = Webhooks.cancel_endpoint(agent.uid, nil, endpoint.id)
  end

  test "legacy automation emits after its calling Job ends and records failed owner notification" do
    %{principal: agent} = background_agent_fixture()
    source = source!(agent.uid, "origin")
    parent = job!(source)
    drive_file_fixture(agent.uid, "automation/b07/main.ts")

    assert {:ok, job} =
             AutomationJobs.create_job(%{
               agent_uid: agent.uid,
               owner_session_id: parent.dispatch_event.session_id,
               source_signal_id: parent.dispatch_event.id,
               source_provenance: %{},
               reply_route: Route.snapshot(job_ref(parent)),
               drive_prefix: "automation/b07",
               label: "Legacy automation",
               wake_on_failure: true
             })

    assert {:ok, %{automation_job_run: queued}} =
             Repo.transact(fn repo ->
               AutomationJobs.enqueue_run_in_tx(repo, job.id, agent.uid, %{"id" => "trigger"})
             end)

    assert {:ok, %{run: run}} = AutomationJobs.start_attempt(queued.id)
    finish_job!(parent.job)
    assert {:ok, emitted} = AutomationJobs.emit_event(agent.uid, run.id, run.attempt_id, %{})
    assert emitted.session_id == source.session_id
    assert emitted.conversation_id == source.conversation_id
    assert emitted.authorization_kind == job.authorization_kind

    Repo.delete!(
      Repo.get!(
        Ankole.AIGateway.Schemas.Conversation,
        parent.job.metadata["owner_conversation_id"]
      )
    )

    assert {:error, :long_lived_reply_owner_not_found} =
             AutomationJobs.emit_event(agent.uid, run.id, run.attempt_id, %{})

    assert {:ok, %AutomationRun{status: "failed", error: error}} =
             AutomationJobs.finish_attempt(run.id, run.attempt_id, %{
               "status" => "failed",
               "error" => String.duplicate("script rejected emission ", 4_000)
             })

    assert error =~ "script rejected emission"
    assert String.ends_with?(error, "; long_lived_reply_owner_not_found")
    assert byte_size(error) <= 65_536
    assert Repo.reload!(run).error == error
    refute Repo.exists?(from(e in Signal, where: e.type == "automation_job.run_failed"))
    assert {:ok, %{automation_job: old}} = AutomationJobs.show_job(agent.uid, nil, job.id)
    assert old.id == job.id
  end

  defp source!(agent_uid, session_id) do
    key = %{agent_uid: agent_uid, session_id: session_id}

    if Ankole.Sessions.driver_pid(key) == :undefined do
      Ankole.SessionsCase.stub_driver(key)
    end

    unique = Ecto.UUID.generate()

    conversation_id =
      Ankole.ExternalConversationsFixtures.external_conversation_id("repo:#{unique}")

    assert {:ok, event} =
             Ankole.Signals.accept(%{
               producer: :kernel,
               target: key,
               authorization: WorkAccess.service(),
               source: "test:reply-route",
               reply_route: %{
                 binding_name: "github",
                 conversation_id: conversation_id,
                 provider_thread_id: "issue:#{unique}",
                 provider_message_id: "comment:#{unique}"
               },
               id: unique,
               type: "conversation.message.addressed",
               data: %{},
               available_at: DateTime.utc_now(:microsecond)
             })

    event
  end

  defp job!(source) do
    assert {:ok, result} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => source.agent_uid,
               "owner_session_id" => source.session_id,
               "source_signal_id" => source.id,
               "source_tool_call_id" => Ecto.UUID.generate(),
               "title" => "B07 delegated work",
               "task" => "Create a durable callback",
               "reply_route" => Route.snapshot(ref(source))
             })

    result
  end

  defp workflow_task!(source) do
    run =
      %Run{}
      |> Run.changeset(%{
        agent_uid: source.agent_uid,
        owner_session_id: source.session_id,
        source_signal_id: source.id,
        source_tool_call_id: Ecto.UUID.generate(),
        reply_route: Route.snapshot(ref(source)),
        title: "B07 workflow",
        script: "return await agent('Prepare callback');",
        args: %{},
        concurrency: 1,
        max_agent_calls: 1,
        authorization_kind: "service"
      })
      |> Repo.insert!()

    %AgentCall{}
    |> AgentCall.changeset(%{
      run_id: run.id,
      agent_uid: source.agent_uid,
      call_seq: 0,
      arguments: %{"task" => "Prepare callback"},
      status: "running"
    })
    |> Repo.insert!()
  end

  defp ref(source),
    do: %RunRef{
      agent_uid: source.agent_uid,
      session_id: source.session_id,
      signal_id: source.id
    }

  defp job_ref(result),
    do: %JobTurnRef{
      agent_uid: result.job.agent_uid,
      session_id: result.dispatch_event.session_id,
      signal_id: result.dispatch_event.id,
      job_id: result.job.id,
      attempt: 1
    }

  defp finish_job!(job),
    do:
      job
      |> Job.changeset(%{status: "succeeded", completed_at: DateTime.utc_now(:microsecond)})
      |> Repo.update!()

  defp webhook_request,
    do: %Proto.WebhookEndpointCreateRequest{
      label: "B07 callback",
      mode: "standing",
      expires_at: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
    }

  defp automation_request,
    do: %Proto.AutomationJobCreateRequest{
      label: "B07 automation",
      drive_prefix: "automation/b07",
      wake_on_failure: true
    }

  defp endpoint_attrs(source),
    do: %{
      agent_uid: source.agent_uid,
      binding_name: source.reply_binding_name,
      session_id: source.session_id,
      conversation_id: source.conversation_id,
      provider_thread_id: source.provider_thread_id,
      source_signal_id: source.id,
      provider_message_id: source.provider_message_id,
      source_provenance: %{},
      label: "Legacy callback",
      mode: "standing",
      expires_at: DateTime.add(DateTime.utc_now(:microsecond), 3600)
    }
end
