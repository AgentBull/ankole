defmodule Ankole.LambdaWorkerTransactionsTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AgentWorkers

  alias Ankole.AgentWorkers.Config
  alias Ankole.AgentWorkers.Lambda
  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.ReconcileJob
  alias Ankole.AgentWorkers.SweepJob

  alias Ankole.AgentWorkers.Lambda.Client
  alias Ankole.AgentWorkers.AgentWorker

  @fixtures Path.expand("../test/fixtures/worker_providers/lambda/responses.json", __DIR__)
  @api "/2025-09-09"

  setup do
    Ankole.E2E.Harness.cleanup_committed_fixtures_on_exit!()
    {:ok, runtime} = Config.fetch()
    previous = Application.get_env(:ankole, :lambda_api_req_options)
    Application.put_env(:ankole, :lambda_api_req_options, plug: {Req.Test, __MODULE__})
    :ok = Config.put(runtime |> Map.to_list() |> Keyword.merge(installation: "prod"))

    on_exit(fn ->
      Config.put(Map.to_list(runtime))

      if previous,
        do: Application.put_env(:ankole, :lambda_api_req_options, previous),
        else: Application.delete_env(:ankole, :lambda_api_req_options)
    end)

    row =
      worker_provider_fixture(%{
        provider_id: "lambda-test",
        kind: "lambda",
        config: Lambda.definition().example,
        credentials: %{"accessKeyId" => "AKIAEXAMPLE", "secretAccessKey" => "test-secret"}
      })

    {:ok, provider} = Providers.load(row)
    %{principal: agent} = agent_fixture(%{worker_provider_id: provider.provider_id})
    assert :ok = AgentWorkers.request(agent.uid)
    %{provider: provider, uid: agent.uid}
  end

  # PostgreSQL, reconciliation, and sweep are real. Only AWS HTTP is a fixture;
  # this proves the database and timing contract, not the AWS service contract.
  test "a sweep neither waits for nor deletes a pending create's VM, and removes an old orphan",
       %{
         provider: provider,
         uid: uid
       } do
    parent = self()

    platform =
      start_supervised!(
        {Agent, fn -> %{visible: false, deleted: false, started: System.system_time(:second)} end}
      )

    fixtures = @fixtures |> File.read!() |> Ankole.JSON.decode!()

    image =
      fixtures["image"]
      |> put_in(["tags", "ankole-settings"], provider.settings_digest)
      |> put_in(["tags", "ankole-source"], ProviderKind.hash16(provider.runtime.image))

    image_path = @api <> "/microvm-images/" <> Client.path(image["imageArn"])
    instance_path = @api <> "/microvms/" <> fixtures["microvm"]["microvmId"]

    microvm = fn ->
      Map.put(fixtures["microvm"], "startedAt", Agent.get(platform, & &1.started))
    end

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", @api <> "/microvm-images"} ->
          Req.Test.json(conn, %{"items" => [image]})

        {"GET", ^image_path} ->
          Req.Test.json(conn, image)

        {"GET", @api <> "/microvms"} ->
          items = if Agent.get(platform, & &1.visible), do: [microvm.()], else: []
          Req.Test.json(conn, %{"items" => items})

        {"POST", @api <> "/microvms"} ->
          Agent.update(platform, &%{&1 | visible: true})
          send(parent, {:create_pending, self()})

          receive do
            :finish_create -> Req.Test.json(conn, microvm.())
          after
            10_000 -> raise "test did not release RunMicrovm"
          end

        {"GET", ^instance_path} ->
          Req.Test.json(conn, microvm.())

        {"DELETE", ^instance_path} ->
          Agent.update(platform, &%{&1 | deleted: true})
          Req.Test.json(conn, %{})

        {"GET", path} ->
          cond do
            path == image_path <> "/versions/1.0" ->
              Req.Test.json(conn, fixtures["version"])

            String.contains?(path, "/managed-microvm-images/") ->
              Req.Test.json(conn, fixtures["managed_versions"])

            true ->
              flunk("Unexpected AWS request: #{path}")
          end
      end
    end)

    args = Ankole.Job.arguments(:tenant, %{"agent_uid" => uid})
    create = start_database_task(fn -> ReconcileJob.perform(%Oban.Job{args: args}) end)

    assert_receive {:create_pending, pending}, 5_000
    assert Repo.get!(AgentWorker, uid).generation != nil
    assert Repo.get!(AgentWorker, uid).instance_ref == nil
    assert %DateTime{} = Repo.get!(AgentWorker, uid).create_sent_at

    # The create holds no database lock while RunMicrovm is pending. The sweep
    # finishes at once and leaves the young, still unattributed VM alone.
    assert :ok = SweepJob.perform(%Oban.Job{args: %{"objects" => true}})
    refute Agent.get(platform, & &1.deleted)

    send(pending, :finish_create)
    assert :ok = Task.await(create.task, 5_000)
    assert Repo.get!(AgentWorker, uid).instance_ref == fixtures["microvm"]["microvmId"]
    assert :ok = SweepJob.perform(%Oban.Job{args: %{"objects" => true}})
    refute Agent.get(platform, & &1.deleted)

    # A VM that nobody owns and that started more than one sweep ago is an
    # orphan.
    Repo.delete!(Repo.get!(AgentWorker, uid))
    Agent.update(platform, &%{&1 | started: System.system_time(:second) - 600})
    assert :ok = SweepJob.perform(%Oban.Job{args: %{"objects" => true}})
    assert Agent.get(platform, & &1.deleted)
  end

  test "another Agent's young unattributed VM cannot block a first create", %{
    provider: provider,
    uid: uid
  } do
    api = install_platform(provider, [unowned_vm("young-orphan", System.system_time(:second))])
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).instance_ref != nil
    assert length(Agent.get(api, & &1.calls)) == 1
  end

  test "only possible VMs after the committed send time block a same-generation retry", %{
    provider: provider,
    uid: uid
  } do
    api = install_platform(provider, [])
    Agent.update(api, &%{&1 | mode: :error})
    assert {:error, {:lambda_api, 500, _}} = reconcile(uid)
    worker = Repo.get!(AgentWorker, uid)
    assert worker.instance_ref == nil
    assert %DateTime{} = worker.create_sent_at
    generation = worker.generation

    for started <- [
          nil,
          DateTime.to_unix(worker.create_sent_at) + 1,
          DateTime.to_unix(worker.create_sent_at) - 59
        ] do
      Agent.update(api, &%{&1 | mode: :success, instances: [unowned_vm("possible", started)]})
      assert {:error, :lambda_waiting_for_provider_orphans} = reconcile(uid)
      assert Repo.get!(AgentWorker, uid).generation == generation
      assert Repo.get!(AgentWorker, uid).create_sent_at == worker.create_sent_at
      assert length(Agent.get(api, & &1.calls)) == 1
    end

    old = unowned_vm("old-orphan", DateTime.to_unix(worker.create_sent_at) - 600)
    terminated = unowned_vm("terminated", nil) |> Map.put("state", "TERMINATED")
    Agent.update(api, &%{&1 | instances: [old, terminated]})
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation == generation
    [retry, first] = Agent.get(api, & &1.calls)
    assert retry["clientToken"] == first["clientToken"]
  end

  test "another tenant's owned VM never blocks a retry and remains attributed", %{
    provider: provider,
    uid: uid
  } do
    api = install_platform(provider, [])
    other_tenant = create_tenant()

    other_uid =
      Repo.with_tenant(other_tenant.id, fn ->
        Ankole.E2E.Harness.cleanup_committed_fixtures_on_exit!()
        %{principal: agent} = agent_fixture(%{worker_provider_id: provider.provider_id})
        assert :ok = AgentWorkers.request(agent.uid)
        assert :ok = reconcile(agent.uid)
        agent.uid
      end)

    assert {:ok, [%{agent_uid: ^other_uid}]} = Lambda.list_instances(provider, :all)
    Agent.update(api, &%{&1 | mode: :error})
    assert {:error, {:lambda_api, 500, _}} = reconcile(uid)
    generation = Repo.get!(AgentWorker, uid).generation
    Agent.update(api, &%{&1 | mode: :success})
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation == generation
    assert {:ok, objects} = Lambda.list_instances(provider, :all)
    assert MapSet.new(objects, & &1.agent_uid) == MapSet.new([uid, other_uid])
  end

  test "two cold starts reach RunMicrovm together with send intent committed", %{
    provider: provider,
    uid: uid
  } do
    api = install_platform(provider, [])
    Agent.update(api, &%{&1 | mode: :hold})
    %{principal: other} = agent_fixture(%{worker_provider_id: provider.provider_id})
    assert :ok = AgentWorkers.request(other.uid)
    first_args = Ankole.Job.arguments(:tenant, %{agent_uid: uid})
    second_args = Ankole.Job.arguments(:tenant, %{agent_uid: other.uid})
    first = start_database_task(fn -> ReconcileJob.perform(%Oban.Job{args: first_args}) end)
    assert_receive {:run_pending, ^uid, first_request}, 5_000
    intent = Repo.get!(AgentWorker, uid)
    assert %DateTime{} = intent.create_sent_at
    assert intent.instance_ref == nil

    second = start_database_task(fn -> ReconcileJob.perform(%Oban.Job{args: second_args}) end)
    assert_receive {:run_pending, other_uid, second_request}, 5_000
    assert other_uid == other.uid
    assert Repo.get!(AgentWorker, other.uid).create_sent_at != nil
    assert Repo.get!(AgentWorker, other.uid).instance_ref == nil

    send(first_request, :finish_run)
    send(second_request, :finish_run)
    assert :ok = Task.await(first.task, 5_000)
    assert :ok = Task.await(second.task, 5_000)

    assert Repo.get!(AgentWorker, uid).instance_ref !=
             Repo.get!(AgentWorker, other.uid).instance_ref
  end

  test "a ready storage helper is deleted once before its committed Worker row", %{
    provider: provider,
    uid: uid
  } do
    api = install_storage_platform(provider)

    assert {:ok, :ok} =
             Repo.transact(fn -> {:ok, AgentWorkers.mark_deleting_in_tx(uid)} end)

    assert :ok = reconcile(uid)
    ref = Repo.get!(AgentWorker, uid).storage_ref
    assert %{"microvmId" => _} = ref
    Agent.update(api, &%{&1 | delete_mode: :hold})

    args = Ankole.Job.arguments(:tenant, %{"agent_uid" => uid})
    deletion = start_database_task(fn -> ReconcileJob.perform(%Oban.Job{args: args}) end)
    assert_receive {:storage_delete_pending, pending}, 5_000
    assert %{state: :deleting, storage_ref: ^ref} = Repo.get!(AgentWorker, uid)
    assert Agent.get(api, & &1.deletes) == [ref["microvmId"]]

    send(pending, :accept_delete)
    assert :ok = Task.await(deletion.task, 5_000)
    assert Repo.get(AgentWorker, uid) == nil
    assert :ok = reconcile(uid)
    assert Agent.get(api, & &1.deletes) == [ref["microvmId"]]
    assert length(Agent.get(api, & &1.calls)) == 1
  end

  test "a storage-helper DELETE failure retains its ref for the coordinator retry", %{
    provider: provider,
    uid: uid
  } do
    api = install_storage_platform(provider)

    assert {:ok, :ok} =
             Repo.transact(fn -> {:ok, AgentWorkers.mark_deleting_in_tx(uid)} end)

    assert :ok = reconcile(uid)
    ref = Repo.get!(AgentWorker, uid).storage_ref
    Agent.update(api, &%{&1 | delete_mode: :error})

    assert {:error, {:lambda_api, 503, "InternalServerException"}} = reconcile(uid)

    assert %{state: :deleting, storage_ref: ^ref, last_error_kind: "transient"} =
             Repo.get!(AgentWorker, uid)

    Agent.update(api, &%{&1 | delete_mode: :success})
    assert :ok = reconcile(uid)
    assert Repo.get(AgentWorker, uid) == nil
    assert Agent.get(api, & &1.deletes) == [ref["microvmId"], ref["microvmId"]]
    assert length(Agent.get(api, & &1.calls)) == 1
  end

  test "terminated helpers start anew and a lost response retries that launch only", %{
    provider: provider,
    uid: uid
  } do
    api = install_storage_platform(provider)

    assert {:ok, :ok} =
             Repo.transact(fn -> {:ok, AgentWorkers.mark_deleting_in_tx(uid)} end)

    assert :ok = reconcile(uid)
    first_ref = Repo.get!(AgentWorker, uid).storage_ref
    [first] = Agent.get(api, & &1.calls)

    Agent.update(api, &put_in(&1.instances[first_ref["microvmId"]]["state"], "TERMINATED"))
    assert :ok = reconcile(uid)
    assert %{"previousMicrovmId" => previous_id} = Repo.get!(AgentWorker, uid).storage_ref
    assert previous_id == first_ref["microvmId"]

    Agent.update(api, &%{&1 | run_mode: :lost_response})
    assert {:error, {:lambda_unreachable, _}} = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).storage_ref == %{"previousMicrovmId" => previous_id}
    [second, ^first] = Agent.get(api, & &1.calls)
    refute second["clientToken"] == first["clientToken"]

    Agent.update(api, &%{&1 | run_mode: :success})
    assert :ok = reconcile(uid)
    second_ref = Repo.get!(AgentWorker, uid).storage_ref
    refute second_ref == first_ref
    [retry, ^second, ^first] = Agent.get(api, & &1.calls)
    assert retry == second
    assert map_size(Agent.get(api, & &1.instances)) == 2

    Agent.update(api, &put_in(&1.instances[second_ref["microvmId"]]["state"], "TERMINATED"))
    assert :ok = reconcile(uid)
    assert :ok = reconcile(uid)
    third_ref = Repo.get!(AgentWorker, uid).storage_ref
    refute third_ref in [first_ref, second_ref]
    [third, ^retry, ^second, ^first] = Agent.get(api, & &1.calls)
    refute third["clientToken"] in [first["clientToken"], second["clientToken"]]
    assert map_size(Agent.get(api, & &1.instances)) == 3
  end

  defp reconcile(uid), do: perform_job(ReconcileJob, %{agent_uid: uid})

  defp unowned_vm(ref, started) do
    @fixtures
    |> File.read!()
    |> Ankole.JSON.decode!()
    |> Map.fetch!("microvm")
    |> Map.merge(%{"microvmId" => ref, "startedAt" => started})
  end

  defp install_platform(provider, instances) do
    parent = self()

    api =
      start_supervised!(
        {Agent, fn -> %{instances: instances, calls: [], next: 0, mode: :success} end}
      )

    fixtures = @fixtures |> File.read!() |> Ankole.JSON.decode!()

    image =
      fixtures["image"]
      |> put_in(["tags", "ankole-settings"], provider.settings_digest)
      |> put_in(["tags", "ankole-source"], ProviderKind.hash16(provider.runtime.image))

    image_path = @api <> "/microvm-images/" <> Client.path(image["imageArn"])

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", @api <> "/microvm-images"} ->
          Req.Test.json(conn, %{"items" => [image]})

        {"GET", ^image_path} ->
          Req.Test.json(conn, image)

        {"GET", @api <> "/microvms"} ->
          Req.Test.json(conn, %{"items" => Agent.get(api, & &1.instances)})

        {"POST", @api <> "/microvms"} ->
          {:ok, bytes, conn} = Plug.Conn.read_body(conn)
          body = Ankole.JSON.decode!(bytes)

          {mode, instance} =
            Agent.get_and_update(api, fn state ->
              instance = unowned_vm("mvm-test-#{state.next}", System.system_time(:second))

              items =
                if state.mode == :error, do: state.instances, else: [instance | state.instances]

              {{state.mode, instance},
               %{state | next: state.next + 1, calls: [body | state.calls], instances: items}}
            end)

          if mode == :hold do
            uid = Ankole.JSON.decode!(body["runHookPayload"])["WORKER_ID"]
            send(parent, {:run_pending, uid, self()})

            receive do
              :finish_run -> :ok
            after
              10_000 -> raise "test did not release RunMicrovm"
            end
          end

          if mode == :error,
            do:
              conn
              |> Plug.Conn.put_status(500)
              |> Req.Test.json(%{
                "__type" => "InternalServerException",
                "message" => "temporary outage"
              }),
            else: Req.Test.json(conn, instance)

        {"GET", path} ->
          cond do
            path == image_path <> "/versions/1.0" ->
              Req.Test.json(conn, fixtures["version"])

            String.contains?(path, "/managed-microvm-images/") ->
              Req.Test.json(conn, fixtures["managed_versions"])

            true ->
              flunk("Unexpected AWS request: #{path}")
          end
      end
    end)

    api
  end

  defp install_storage_platform(provider) do
    parent = self()

    api =
      start_supervised!(
        {Agent,
         fn ->
           %{
             instances: %{},
             tokens: %{},
             calls: [],
             deletes: [],
             run_mode: :success,
             delete_mode: :success
           }
         end}
      )

    fixtures = @fixtures |> File.read!() |> Ankole.JSON.decode!()

    images =
      for role <- ~w(worker storage) do
        fixtures["image"]
        |> Map.update!("imageArn", &(&1 <> "-" <> role))
        |> put_in(["tags", "ankole-role"], role)
        |> put_in(["tags", "ankole-settings"], provider.settings_digest)
        |> put_in(["tags", "ankole-source"], ProviderKind.hash16(provider.runtime.image))
      end

    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", @api <> "/microvm-images"} ->
          Req.Test.json(conn, %{"items" => images})

        {"GET", @api <> "/microvms"} ->
          # Worker listings exclude the storage image, as the real API does.
          Req.Test.json(conn, %{"items" => []})

        {"POST", @api <> "/microvms"} ->
          {:ok, bytes, conn} = Plug.Conn.read_body(conn)
          body = Ankole.JSON.decode!(bytes)

          {mode, instance} =
            Agent.get_and_update(api, fn state ->
              id = state.tokens[body["clientToken"]] || "storage-#{map_size(state.tokens)}"
              instance = Map.merge(fixtures["microvm"], %{"microvmId" => id})

              {{state.run_mode, instance},
               %{
                 state
                 | tokens: Map.put(state.tokens, body["clientToken"], id),
                   instances: Map.put_new(state.instances, id, instance),
                   calls: [body | state.calls]
               }}
            end)

          if mode == :lost_response,
            do: Req.Test.transport_error(conn, :timeout),
            else: Req.Test.json(conn, instance)

        {method, @api <> "/microvms/" <> id} ->
          if method == "GET" do
            Req.Test.json(conn, Agent.get(api, &Map.fetch!(&1.instances, id)))
          else
            assert method == "DELETE"

            mode =
              Agent.get_and_update(api, &{&1.delete_mode, %{&1 | deletes: [id | &1.deletes]}})

            if mode == :hold do
              send(parent, {:storage_delete_pending, self()})

              receive do
                :accept_delete -> :ok
              after
                10_000 -> raise "test did not release storage DELETE"
              end
            end

            if mode == :error do
              conn
              |> Plug.Conn.put_resp_header("x-amzn-errortype", "InternalServerException")
              |> Plug.Conn.put_status(503)
              |> Req.Test.json(%{"message" => "temporary outage"})
            else
              Agent.update(api, &put_in(&1.instances[id]["state"], "TERMINATING"))
              Req.Test.json(conn, %{})
            end
          end

        {"GET", path} ->
          image =
            Enum.find(
              images,
              &(path == @api <> "/microvm-images/" <> Client.path(&1["imageArn"]))
            )

          version_image =
            Enum.find(
              images,
              &(path ==
                  @api <> "/microvm-images/" <> Client.path(&1["imageArn"]) <> "/versions/1.0")
            )

          cond do
            image ->
              Req.Test.json(conn, image)

            version_image ->
              Req.Test.json(
                conn,
                Map.put(fixtures["version"], "imageArn", version_image["imageArn"])
              )

            String.contains?(path, "/managed-microvm-images/") ->
              Req.Test.json(conn, fixtures["managed_versions"])

            true ->
              flunk("Unexpected AWS request: #{path}")
          end
      end
    end)

    api
  end

  defp start_database_task(fun) do
    parent = self()

    task =
      Task.async(fn ->
        Repo.checkout(fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:database_task, self(), backend_pid})
          fun.()
        end)
      end)

    pid = task.pid
    assert_receive {:database_task, ^pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid}
  end
end
