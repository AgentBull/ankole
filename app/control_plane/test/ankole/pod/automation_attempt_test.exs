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

    for {kind, expected_schema} <- [{:service, :allowed}, {:human, :denied}] do
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

      if expected_schema == :allowed,
        do: assert(match?({:ok, _}, result)),
        else: assert(result == {:error, "forbidden"})

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

  test "an attempt requires its assigned Worker, current Human access and review clearance" do
    owner = human_fixture().principal
    human = human_fixture().principal
    agent = Ankole.SessionsCase.agent_fixture().principal
    other = Ankole.SessionsCase.agent_fixture().principal
    {:ok, page} = Pages.create(actor_fixture(owner), %{private_owner_uid: owner.uid})

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

    assert {:error, :work_authorization_review_required} =
             AutomationJobs.authorize_attempt_actor(proof, %{worker_id: agent.uid})

    {:ok, _} =
      Repo.transact(fn ->
        Ankole.Ash.update(reviewed_job, :reauthorize, WorkAccess.from_sender(human.uid))
      end)

    Ankole.PrincipalsFixtures.disable_principal_fixture(human.uid)

    assert {:error, :human_access_revoked} =
             AutomationJobs.authorize_attempt_actor(proof, %{worker_id: agent.uid})
  end

  test "Pod file RPCs keep the attempt Human intersection and reject missing proof" do
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
              %{path: "project/" <> path, sha256: stored.sha256, source: "agent"}
            ])

          %{path: path, sha256: stored.sha256}
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

        request =
          SessionsCase.rpc_request("automation-file", "files.get", %Proto.FilesGetRequest{
            pod_drive: true,
            path: "pages/#{page.id}/" <> path,
            home_relative_path: target,
            automation_attempt: proof
          })

        {:ok, envelope} = SessionsCase.handle_rpc(request, route, agent.uid)

        if kind == :human and path == "src/main.tsx" do
          assert SessionsCase.rpc_error_payload!(envelope)["code"] == "forbidden"
          refute Map.has_key?(Ankole.WorkerFilesFake.files(fake), target)
        else
          response = SessionsCase.rpc_response_payload!(envelope, Proto.FilesGetResponse)
          assert response.file.path == "pages/#{page.id}/" <> path
          assert response.file.sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
          assert Ankole.WorkerFilesFake.files(fake)[target] == bytes
        end
      end

      {:ok, _} = AutomationJobs.finish_attempt(run.id, run.attempt_id, %{status: "succeeded"})
    end

    missing =
      SessionsCase.rpc_request("missing-proof", "files.get", %Proto.FilesGetRequest{
        pod_drive: true,
        path: "pages/#{page.id}/src/main.tsx",
        home_relative_path: "missing.tsx"
      })

    {:ok, envelope} = SessionsCase.handle_rpc(missing, route, agent.uid)

    assert SessionsCase.rpc_error_payload!(envelope)["code"] ==
             "work_authorization_review_required"

    refute Map.has_key?(Ankole.WorkerFilesFake.files(fake), "missing.tsx")
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
        AutomationJobs.enqueue_run_in_tx(job.id, agent.uid, %{
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
