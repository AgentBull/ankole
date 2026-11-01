defmodule Ankole.Pod.WriteFenceIntegrationTest do
  @moduledoc "Commits Pod writes only while their authenticated turn is still current."
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  alias Ankole.BackgroundAgentJobs
  alias Ankole.Pod.{BaseRecord, Documents, Files, Page, PageChange, Pages, RPCBroker}
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
    Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-node:" <> page.id)

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
    refute_receive {:node_committed, _id}, 100
  end

  test "a signed file relay cannot commit after its JobTurnRef attempt is replaced", ctx do
    page = shared_page(ctx, "file")
    # First content is authorized by the parent; later overwrites use the file's edit grant.
    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: ctx.agent,
        resource_pattern: "drive:**:#{page.parent_id}:node",
        action: "node_contribute"
      })

    %{job: job, run: run} = admit_job(ctx)
    Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-node:" <> page.id)

    task =
      delayed_rpc(
        ctx,
        pod_request("files.upload", %{
          id: page.id,
          base_object_id: nil,
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

    refute_receive {:node_committed, _id}, 100
  end

  test "every Pod RPC write retains its final transaction fence", ctx do
    database = shared_page(ctx, "base")

    {:ok, table} =
      Ankole.Pod.Bases.create_table(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        database.id,
        %{name: "Shared"}
      )

    {:ok, field} =
      Ankole.Pod.Bases.create_field(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        table.id,
        %{type: "text", name: "Value"}
      )

    {:ok, view} =
      Ankole.Pod.Bases.create_view(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        table.id,
        %{type: "grid", name: "Grid 2"}
      )

    {:ok, _} =
      Ankole.Pod.Bases.create_field(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        table.id,
        %{type: "link", name: "Parent", config: %{"table_id" => table.id}}
      )

    applet = shared_page(ctx, "applet")

    publish_files =
      for {path, content} <- [
            {"src/main.ts", "export {}"},
            {"dist/index.html", "<!doctype html><p>Published</p>"}
          ] do
        {:ok, stored} = Ankole.Files.store(content)
        Map.merge(stored, %{path: path, source: "agent", source_path: path})
      end

    assert {:ok, _} = Ankole.Files.commit(ctx.agent, publish_files)

    {:ok, _} = Run.finalize(ctx.run, :silent)

    for {operation, attrs} <- [
          {"pages.create", %{title: "Must not exist"}},
          {"pages.update", %{id: database.id, title: "Must not change"}},
          {"pages.move", %{id: database.id, private_owner_uid: ctx.owner}},
          {"pages.delete", %{id: database.id}},
          {"pages.restore", %{id: database.id}},
          {"base.create_table", %{id: database.id, name: "Forbidden"}},
          {"base.create_field", %{id: table.id, name: "Forbidden", type: "text"}},
          {"base.update_field", %{id: field.id, name: "Forbidden", version: field.version}},
          {"base.delete_field", %{id: field.id, version: field.version}},
          {"base.create_view", %{id: table.id, name: "Forbidden", type: "grid"}},
          {"base.update_view", %{id: view.id, name: "Forbidden", version: view.version}},
          {"base.delete_view", %{id: view.id, version: view.version}},
          {"base.write", %{id: table.id, creates: [%{data: %{field.id => "Forbidden"}}]}},
          {"base.copy", %{id: table.id, title: "Forbidden"}},
          {"applets.publish",
           %{
             id: applet.id,
             base_revision: 0,
             files: publish_files
           }}
        ] do
      assert {:error, %{"code" => "run_closed"}} =
               RPCBroker.handle_write(ctx.ref, pod_request(operation, attrs), ctx.ctx),
             operation
    end

    assert Repo.aggregate(Ankole.Pod.Properties, :count) == 2
    assert Repo.get!(Page, database.id).title == "Shared"
    assert Repo.aggregate(BaseRecord, :count) == 0

    assert {:ok, %{records: []}} =
             Ankole.Pod.Bases.query(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               table.id,
               %{}
             )

    assert {:ok, _} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               shared_page(ctx, "doc").id,
               0,
               "<page />"
             )
  end

  test "Run finalization waits for an admitted physical record commit", ctx do
    actor = Ankole.PrincipalsFixtures.actor_fixture(ctx.owner)
    page = shared_page(ctx, "base")
    {:ok, %{tables: [table]}} = Ankole.Pod.Bases.list_tables(actor, page.id)

    {:ok, _} =
      Ankole.Pod.Bases.create_field(actor, table.id, %{
        name: "Link",
        type: "link",
        config: %{"table_id" => table.id}
      })

    owner = self()
    request = pod_request("base.write", %{id: table.id, creates: [%{data: %{}}]})

    assert {:ok, {writer, closer}} =
             Ankole.Pod.BaseRepo.with_shard(ctx.tenant.base_db_id, fn ->
               Ankole.Pod.BaseRepo.transact(fn ->
                 Ankole.Pod.BaseRepo.query!(
                   "SELECT table_id FROM #{Ankole.Pod.BaseRepo.states()} WHERE table_id=$1::text::uuid FOR UPDATE",
                   [table.id]
                 )

                 writer =
                   Task.async(fn ->
                     Repo.with_tenant(ctx.tenant.id, fn ->
                       Repo.checkout(fn ->
                         [[pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
                         send(owner, {:writer_backend, pid})
                         RPCBroker.handle_write(ctx.ref, request, ctx.ctx)
                       end)
                     end)
                   end)

                 assert_receive {:writer_backend, writer_pid}, 5_000

                 assert {:ok, true} =
                          wait_until(deadline(3_000), fn ->
                            Ankole.Pod.BaseRepo.query!("SELECT pg_stat_clear_snapshot()", [])

                            Ankole.Pod.BaseRepo.query!(
                              "SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%_table_states%FOR UPDATE%' LIMIT 1",
                              []
                            ).rows != []
                          end)

                 closer =
                   Task.async(fn ->
                     Repo.with_tenant(ctx.tenant.id, fn ->
                       Repo.checkout(fn ->
                         [[pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
                         send(owner, {:closer_backend, pid})
                         Run.finalize(ctx.run, :silent)
                       end)
                     end)
                   end)

                 assert_receive {:closer_backend, closer_pid}, 5_000

                 assert {:ok, true} =
                          wait_until(deadline(2_000), fn ->
                            Repo.query!("SELECT $1::integer=ANY(pg_blocking_pids($2::integer))", [
                              writer_pid,
                              closer_pid
                            ]).rows == [[true]]
                          end)

                 {:ok, {writer, closer}}
               end)
             end)

    assert {:ok, _} = Task.await(writer, 15_000)
    assert {:ok, _} = Task.await(closer, 15_000)
    assert {:ok, %{records: [_]}} = Ankole.Pod.Bases.query(actor, table.id, %{})
    assert {:error, %{"code" => "run_closed"}} = RPCBroker.handle_write(ctx.ref, request, ctx.ctx)
    assert {:ok, %{records: [_]}} = Ankole.Pod.Bases.query(actor, table.id, %{})
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
