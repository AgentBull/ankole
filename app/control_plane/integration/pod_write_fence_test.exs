defmodule Ankole.Pod.WriteFenceIntegrationTest do
  @moduledoc "Commits Pod writes only while their authenticated turn is still current."
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  alias Ankole.BackgroundAgentJobs
  alias Ankole.Pod.{DbRecord, Documents, Files, Page, PageChange, Pages, RPCBroker}
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Sessions.{Admission, CodexJob, Run, RunRef}
  alias Ankole.SessionsCase
  alias Ankole.WorkerFilesFake

  setup %{tenant: tenant} do
    :ok = Ankole.Tenants.ensure_scaffold(tenant)
    owner = Ankole.PrincipalsFixtures.human_fixture().principal
    agent = SessionsCase.agent_fixture(%{owner_principal_uid: owner.uid}).principal
    route = "pod-write-fence-#{System.unique_integer([:positive])}"
    {:ok, _worker} = SessionsCase.admit_worker(route, %{worker_id: agent.uid})
    event = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)
    assert {:ok, run} = Admission.admit(event, event)
    ref = %RunRef{agent_uid: agent.uid, session_id: event.session_id, signal_id: event.id}

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        :ok = Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)
        {:ok, value} = Ankole.Tenants.get(tenant.id)
        {:ok, _} = Ankole.Tenants.delete(value)

        result =
          Enum.reduce_while(1..200, :pending, fn _, _ ->
            case Ankole.Tenants.Jobs.Delete.run(%Oban.Job{args: %{"tenant_id" => tenant.id}}) do
              :ok -> {:halt, :ok}
              {:snooze, _} -> {:cont, :pending}
            end
          end)

        assert result == :ok
      end)
    end)

    %{
      owner: owner.uid,
      agent: agent.uid,
      run: run,
      ref: ref,
      route: route,
      ctx: %{route: route, worker_id: agent.uid, request_id: "fence"}
    }
  end

  test "a signed XML relay cannot commit after its RunRef closes", ctx do
    page = shared_page(ctx, "doc")
    Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-page:" <> page.id)

    request =
      pod_request("pages.write", %{
        id: page.id,
        base_revision: 0,
        xml_home_relative_path: "report.xml"
      })

    task = delayed_rpc(ctx, request, run: proto_ref(ctx.ref))
    assert_receive {:relay_waiting, relay}, 2_000
    assert {:ok, _} = Run.finalize(ctx.run, :silent)
    send(relay, :release)

    assert {:ok, envelope} = Task.await(task, 5_000)
    assert SessionsCase.rpc_error_payload!(envelope)["code"] == "run_closed"
    assert Repo.get!(Page, page.id).revision == 0

    assert {:ok, %{content: %{plain_text: ""}}} =
             Pages.get(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

    assert Repo.aggregate(PageChange, :count) == 0
    refute_receive {:page_committed, _id}, 100
  end

  test "a signed file relay cannot commit after its JobTurnRef attempt is replaced", ctx do
    page = shared_page(ctx, "file")
    %{job: job, run: run} = admit_job(ctx)
    Phoenix.PubSub.subscribe(Ankole.PubSub, "pod-page:" <> page.id)

    task =
      delayed_rpc(
        ctx,
        pod_request("files.upload", %{
          id: page.id,
          base_revision: 0,
          home_relative_path: "report.txt",
          name: "report.txt"
        }),
        job_turn: run.job_ref
      )

    assert_receive {:relay_waiting, relay}, 2_000

    assert {:ok, _} =
             Repo.transact(fn ->
               BackgroundAgentJobs.Lifecycle.requeue_retryable_attempt_in_tx(
                 job.id,
                 ctx.agent
               )
             end)

    key = %{agent_uid: ctx.agent, session_id: run.session_id}
    assert {:ok, replacement} = Admission.admit(key, run.event)
    assert replacement.job_ref.attempt == run.job_ref.attempt + 1
    send(relay, :release)

    assert {:ok, envelope} = Task.await(task, 5_000)

    assert SessionsCase.rpc_error_payload!(envelope)["code"] ==
             "background_agent_job_attempt_changed"

    assert {:ok, %{revision: 0, files: []}} =
             Files.manifest(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

    refute_receive {:page_committed, _id}, 100
  end

  test "every Pod RPC write retains its final transaction fence", ctx do
    database = shared_page(ctx, "database")

    {:ok, table} =
      Ankole.Pod.Database.create_table(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        database.id,
        %{name: "Shared"}
      )

    {:ok, field} =
      Ankole.Pod.Database.create_field(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        table.id,
        %{type: "text", name: "Value"}
      )

    {:ok, view} =
      Ankole.Pod.Database.create_view(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        table.id,
        %{type: "grid", name: "Grid 2"}
      )

    applet = shared_page(ctx, "applet")

    {:ok, _} = Run.finalize(ctx.run, :silent)

    for {operation, attrs} <- [
          {"pages.create", %{title: "Must not exist"}},
          {"pages.update", %{id: database.id, title: "Must not change"}},
          {"pages.move", %{id: database.id, private_owner_uid: ctx.owner}},
          {"pages.delete", %{id: database.id}},
          {"pages.restore", %{id: database.id}},
          {"database.create_table", %{id: database.id, name: "Forbidden"}},
          {"database.create_field", %{id: table.id, name: "Forbidden", type: "text"}},
          {"database.update_field", %{id: field.id, name: "Forbidden", version: field.version}},
          {"database.delete_field", %{id: field.id, version: field.version}},
          {"database.create_view", %{id: table.id, name: "Forbidden", type: "grid"}},
          {"database.update_view", %{id: view.id, name: "Forbidden", version: view.version}},
          {"database.delete_view", %{id: view.id, version: view.version}},
          {"database.write", %{id: table.id, creates: [%{data: %{field.id => "Forbidden"}}]}},
          {"database.copy", %{id: table.id, title: "Forbidden"}},
          {"applets.publish",
           %{
             id: applet.id,
             base_revision: 0,
             files: [
               %{path: "src/main.ts", sha256: String.duplicate("0", 64)},
               %{path: "dist/index.html", sha256: String.duplicate("0", 64)}
             ]
           }}
        ] do
      assert {:error, %{"code" => "run_closed"}} =
               RPCBroker.handle_write(ctx.ref, pod_request(operation, attrs), ctx.ctx),
             operation
    end

    assert Repo.aggregate(Page, :count) == 2
    assert Repo.get!(Page, database.id).title == "Shared"
    assert Repo.aggregate(DbRecord, :count) == 0

    assert {:ok, _} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               shared_page(ctx, "doc").id,
               0,
               "<page />"
             )
  end

  defp shared_page(ctx, type) do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        type: type,
        title: "Shared"
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        grants: [%{principal_uid: ctx.agent, role: "edit"}]
      })

    page
  end

  defp admit_job(ctx) do
    assert {:ok, %{job: job, dispatch_event: event}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => ctx.agent,
               "owner_session_id" => ctx.ref.session_id,
               "source_signal_id" => ctx.ref.signal_id,
               "source_tool_call_id" => "pod-fence-job",
               "title" => "Pod write",
               "task" => "Write the shared Pod file.",
               "reply_route" => %{"binding_name" => "test-external"}
             })

    key = %{agent_uid: ctx.agent, session_id: BackgroundAgentJobs.job_session_id(job.id)}
    assert {:ok, run} = CodexJob.admit(key, event, [])
    %{job: job, run: run}
  end

  defp delayed_rpc(ctx, request, opts) do
    parent = self()

    WorkerFilesFake.start!(ctx.route,
      on_read: fn _path ->
        send(parent, {:relay_waiting, self()})

        receive do
          :release -> {:ok, "<page><p>Too late</p></page>"}
        after
          5_000 -> {:error, {"test_timeout", "relay was not released"}}
        end
      end
    )

    Task.async(fn ->
      Repo.with_tenant(ctx.tenant.id, fn ->
        SessionsCase.handle_rpc(
          SessionsCase.rpc_request("delayed-pod-write", "pod.write", request, opts),
          ctx.route,
          ctx.agent
        )
      end)
    end)
  end

  defp proto_ref(ref),
    do: %FabricProto.RunRef{
      session: %FabricProto.SessionKey{session_id: ref.session_id},
      signal_id: ref.signal_id
    }

  defp pod_request(operation, params),
    do: %FabricProto.PodRequest{operation: operation, params_json: Torque.encode!(params)}
end
