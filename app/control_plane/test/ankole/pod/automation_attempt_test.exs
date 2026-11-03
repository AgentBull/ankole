defmodule Ankole.Pod.AutomationAttemptTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures
  alias Ankole.AutomationJobs
  alias Ankole.Pod.{Bases, Pages}
  alias Ankole.Principals.WorkAccess
  alias Ankole.RuntimeFabric.V1, as: Proto
  alias Ankole.SessionsCase

  test "service and Human attempts cross the real RPC codec with their current page permissions" do
    owner = human_fixture().principal
    human = human_fixture().principal
    agent = Ankole.SessionsCase.agent_fixture().principal
    owner_actor = actor_fixture(owner)
    route = "automation-pod-#{agent.uid}"
    {:ok, _} = SessionsCase.admit_worker(route, %{worker_id: agent.uid})
    {:ok, page} = Pages.create(owner_actor, %{type: "base", private_owner_uid: owner.uid})
    {:ok, %{tables: [table]}} = Bases.list_tables(owner_actor, page.id)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [
          %{principal_uid: agent.uid, role: "edit"},
          %{principal_uid: human.uid, role: "contribute"}
        ]
      })

    for kind <- [:service, :human] do
      {job, run} = attempt(agent, human, kind)

      proof = %Proto.AutomationAttemptRef{
        job_id: to_string(job.id),
        run_id: to_string(run.id),
        attempt_id: run.attempt_id
      }

      ctx = %{route: route, agent: agent, proof: proof}

      assert {:ok, %{"records" => [_]}} =
               rpc(ctx, "pod.write", "base.write", %{
                 id: table.id,
                 creates: [%{data: %{}}]
               })

      result =
        rpc(ctx, "pod.write", "base.create_field", %{
          id: table.id,
          name: to_string(kind),
          type: "text"
        })

      assert {:ok, _} = result

      assert {:ok, _} = rpc(ctx, "pod.read", "base.schema", %{id: table.id})

      stale = %{ctx | proof: %{proof | attempt_id: Ecto.UUID.generate()}}

      assert {:error, "automation_job_attempt_not_active"} =
               rpc(stale, "pod.read", "base.schema", %{id: table.id})

      assert {:error, "automation_job_attempt_not_active"} =
               rpc(stale, "pod.write", "base.write", %{
                 id: table.id,
                 creates: [%{data: %{}}]
               })

      assert {:ok, _} =
               AutomationJobs.finish_attempt(run.id, run.attempt_id, %{
                 status: "succeeded",
                 exit_code: 0
               })

      assert {:error, "automation_job_attempt_not_active"} =
               rpc(ctx, "pod.read", "base.schema", %{id: table.id})
    end
  end

  test "an admitted Agent attempt keeps its fence after Human revocation, while new admission fails" do
    owner = human_fixture().principal
    human = human_fixture().principal
    agent = Ankole.SessionsCase.agent_fixture().principal
    other = Ankole.SessionsCase.agent_fixture().principal

    {:ok, page} =
      Pages.create(actor_fixture(owner), %{type: "base", private_owner_uid: owner.uid})

    {:ok, %{tables: [table]}} = Bases.list_tables(actor_fixture(owner), page.id)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [
          %{principal_uid: agent.uid, role: "edit"},
          %{principal_uid: human.uid, role: "view"}
        ]
      })

    {job, run} = attempt(agent, human, :human)

    proof = %Proto.AutomationAttemptRef{
      job_id: to_string(job.id),
      run_id: to_string(run.id),
      attempt_id: run.attempt_id
    }

    assert {:error, :automation_job_attempt_not_active} =
             AutomationJobs.authorize_attempt_actor(proof, %{worker_id: other.uid})

    {:ok, reviewed_job} =
      Repo.transact(fn -> Ankole.Ash.update(job, :reauthorize, WorkAccess.fields(nil)) end)

    assert {:ok, admitted_actor} =
             AutomationJobs.authorize_attempt_actor(proof, %{worker_id: agent.uid})

    assert {:ok, %{records: [_]}} =
             Bases.write_records(admitted_actor, table.id, %{creates: [%{data: %{}}]})

    {:ok, _} =
      Repo.transact(fn ->
        Ankole.Ash.update(reviewed_job, :reauthorize, WorkAccess.from_sender(human.uid))
      end)

    Ankole.PrincipalsFixtures.disable_principal_fixture(human.uid)

    assert {:ok, admitted_actor} =
             AutomationJobs.authorize_attempt_actor(proof, %{worker_id: agent.uid})

    assert {:ok, %{records: [_]}} =
             Bases.write_records(admitted_actor, table.id, %{creates: [%{data: %{}}]})

    assert {:ok, _} =
             AutomationJobs.finish_attempt(run.id, run.attempt_id, %{status: "succeeded"})

    assert {:ok, %{status: :skipped}} =
             Repo.transact(fn ->
               Ankole.WorkFixtures.dispatch_job_in_tx(job, %{
                 "id" => Ecto.UUID.generate(),
                 "source" => "test://revoked",
                 "type" => "test.triggered",
                 "data" => %{}
               })
             end)
  end

  test "Pod file RPCs use the executing Agent permissions and reject missing proof" do
    owner = human_fixture().principal
    human = human_fixture().principal
    agent = Ankole.SessionsCase.agent_fixture().principal
    route = "automation-files-#{agent.uid}"
    {:ok, _} = SessionsCase.admit_worker(route, %{worker_id: agent.uid})
    fake = Ankole.WorkerFilesFake.start!(route)

    {:ok, page} =
      Pages.create(actor_fixture(owner), %{type: "applet", private_owner_uid: owner.uid})

    manifest =
      Enum.map(
        %{
          "src/main.tsx" => "private source",
          "dist/main.js" => "export {}",
          "dist/index.html" => "<head></head>"
        },
        fn {path, bytes} ->
          {:ok, stored} = Ankole.Files.store(bytes)

          {:ok, _} =
            Ankole.Files.commit(owner.uid, [
              Map.merge(stored, %{path: "project/" <> path, source: "agent"})
            ])

          %{path: path, object_id: stored.object_id, source_path: "project/" <> path}
        end
      )

    {:ok, _} = Ankole.Pod.Files.publish(actor_fixture(owner), page.id, 0, manifest)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [
          %{principal_uid: agent.uid, role: "edit"},
          %{principal_uid: human.uid, role: "contribute"}
        ]
      })

    for kind <- [:service, :human] do
      {job, run} = attempt(agent, human, kind)

      proof = %Proto.AutomationAttemptRef{
        job_id: to_string(job.id),
        run_id: to_string(run.id),
        attempt_id: run.attempt_id
      }

      for {path, bytes} <- [{"dist/main.js", "export {}"}, {"src/main.tsx", "private source"}] do
        target = "#{kind}/" <> path

        assert {:ok, response} =
                 rpc(%{route: route, agent: agent, proof: proof}, "pod.read", "files.download", %{
                   id: page.id,
                   path: path,
                   home_relative_path: target
                 })

        assert response["path"] == path
        assert response["sha256"] == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        assert Ankole.WorkerFilesFake.files(fake)[target] == bytes
      end

      {:ok, _} = AutomationJobs.finish_attempt(run.id, run.attempt_id, %{status: "succeeded"})
    end

    missing =
      SessionsCase.rpc_request("missing-proof", "pod.read", %Proto.PodRequest{
        operation: "files.download",
        params_json:
          Torque.encode!(%{
            id: page.id,
            path: "src/main.tsx",
            home_relative_path: "missing.tsx"
          })
      })

    {:ok, envelope} = SessionsCase.handle_rpc(missing, route, agent.uid)

    assert SessionsCase.rpc_error_payload!(envelope)["code"] ==
             "work_authorization_review_required"

    refute Map.has_key?(Ankole.WorkerFilesFake.files(fake), "missing.tsx")
  end

  test "an Agent attempt publishes existing Action policies and rolls them back when its fence closes" do
    human = human_fixture().principal
    agent = SessionsCase.agent_fixture(%{owner_principal_uid: human.uid}).principal
    actor = actor_fixture(agent)
    {:ok, page} = Pages.create(actor, %{type: "applet", private_owner_uid: agent.uid})
    source = "export default {actions:{work:{idempotent:false,handler:()=>1}}}"
    publish_applet_fixture(%{actor: actor, page: page}, source)

    {:ok, action_job} =
      AutomationJobs.create_applet_job(actor, page.id, "work", %{authorization_kind: "service"})

    {job, run} = attempt(agent, human, :human)

    proof = %Proto.AutomationAttemptRef{
      job_id: to_string(job.id),
      run_id: to_string(run.id),
      attempt_id: run.attempt_id
    }

    {:ok, attempt_actor} = AutomationJobs.authorize_attempt_actor(proof, %{worker_id: agent.uid})
    updated_source = String.replace(source, "false", "true")
    manifest = applet_manifest_fixture(agent.uid, page.id, updated_source)

    assert {:ok, %{revision: 2}} = Ankole.Pod.Files.publish(attempt_actor, page.id, 1, manifest)
    assert {:ok, %{idempotent: true}} = AutomationJobs.get_automation_job(action_job.id)

    assert {:ok, _} =
             AutomationJobs.finish_attempt(run.id, run.attempt_id, %{status: "succeeded"})

    manifest = applet_manifest_fixture(agent.uid, page.id, source)

    assert {:error, :automation_job_attempt_not_active} =
             Ankole.Pod.Files.publish(attempt_actor, page.id, 2, manifest)

    assert {:ok, %{idempotent: true}} = AutomationJobs.get_automation_job(action_job.id)
    assert {:ok, %{revision: 2}} = Ankole.Pod.Files.manifest(actor, page.id)
    assert {:ok, _, ^updated_source} = Ankole.Pod.Files.read(actor, page.id, "server/main.js")
  end

  defp attempt(agent, human, kind) do
    source = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)

    if kind == :human do
      {:ok, _} =
        Repo.transact(fn ->
          Ankole.Ash.update(source, :reauthorize, WorkAccess.from_sender(human.uid))
        end)
    end

    drive_file_fixture(agent.uid, "automation/test/main.ts")

    {:ok, job} =
      AutomationJobs.create_job(%{
        agent_uid: agent.uid,
        owner_session_id: source.session_id,
        source_signal_id: source.id,
        drive_prefix: "automation/test",
        label: "Pod attempt",
        reply_route: %{},
        source_provenance: %{}
      })

    {:ok, %{automation_job_run: run}} =
      Repo.transact(fn ->
        Ankole.WorkFixtures.dispatch_job_in_tx(job, %{
          "specversion" => "1.0",
          "id" => Ecto.UUID.generate(),
          "source" => "test://pod",
          "type" => "test.triggered",
          "data" => %{}
        })
      end)

    # The real Worker admission path must accept the attempt.
    case Ankole.AgentWorkers.ready_worker(agent.uid) do
      {:ok, _} -> :ok
      _ -> {:ok, _} = SessionsCase.admit_worker("attempt-#{agent.uid}", %{worker_id: agent.uid})
    end

    {:ok, %{run: run}} = AutomationJobs.start_attempt(run.id)
    {job, run}
  end

  defp rpc(ctx, method, operation, params) do
    request =
      SessionsCase.rpc_request("automation-pod-request", method, %Proto.PodRequest{
        operation: operation,
        params_json: Torque.encode!(params),
        automation_attempt: ctx.proof
      })

    {:ok, envelope} = SessionsCase.handle_rpc(request, ctx.route, ctx.agent.uid)

    case envelope.body do
      {:rpc_response, _} ->
        body = SessionsCase.rpc_response_payload!(envelope, Proto.JSONPassthroughResponse)
        {:ok, Torque.decode!(body.body_json)["result"]}

      {:rpc_error, _} ->
        {:error, SessionsCase.rpc_error_payload!(envelope)["code"]}
    end
  end
end
