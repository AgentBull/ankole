defmodule Ankole.JobTest do
  use Ankole.DataCase, async: true

  alias Ankole.Tenants.Tenant

  defmodule TenantWorker do
    use Ankole.Job, tenancy: :tenant, queue: :default
    @impl Ankole.Job
    def run(_job), do: {:ok, Ankole.Repo.tenant_id!()}
  end

  defmodule SiteWorker do
    use Ankole.Job, tenancy: :site, queue: :default
    @impl Ankole.Job
    def run(_job), do: {:ok, Ankole.Repo.tenant_id()}
  end

  test "every application job has an enabled production queue" do
    queues =
      Path.expand("../../config/config.exs", __DIR__)
      |> Config.Reader.read!(env: :prod)
      |> Keyword.fetch!(:ankole)
      |> Keyword.fetch!(Oban)
      |> Keyword.fetch!(:queues)

    workers =
      Enum.filter(Ankole.TestModules.all(), fn module ->
        Code.ensure_loaded?(module) and function_exported?(module, :__opts__, 0)
      end)

    assert workers != []

    for worker <- workers do
      queue = Keyword.fetch!(worker.__opts__(), :queue)

      assert is_integer(queues[queue]) and queues[queue] > 0,
             "#{inspect(worker)} has no consumer for queue #{inspect(queue)}"
    end
  end

  test "new/1 captures the submitting tenant in the durable args", %{tenant: tenant} do
    job = TenantWorker.new(%{work: "resume"}) |> Ecto.Changeset.apply_changes()
    assert job.args["tenant_id"] == tenant.id
    assert TenantWorker.__tenancy__() == :tenant
  end

  test "tenant jobs deduplicate and cancel only within their submitting tenant", %{tenant: tenant} do
    other = create_tenant()

    args = %{
      agent_uid: "shared-agent",
      session_id: "main",
      binding_name: "bot",
      outbound_key: "reply"
    }

    dispatch = Ankole.Conversations.Delivery.Jobs.Dispatch

    Oban.Testing.with_testing_mode(:manual, fn ->
      for worker <- [
            Ankole.AgentWorkers.ReconcileJob,
            Ankole.Sessions.Jobs.EnsureDriver,
            dispatch
          ] do
        first = Oban.insert!(worker.new(args))
        duplicate = Oban.insert!(worker.new(args))
        assert duplicate.id == first.id
        assert duplicate.conflict?
        second = Repo.with_tenant(other.id, fn -> Oban.insert!(worker.new(args)) end)
        refute second.id == first.id
        assert first.args["tenant_id"] == tenant.id
        assert second.args["tenant_id"] == other.id

        if worker == dispatch do
          assert :ok = dispatch.schedule_in_tx(args, nil)
          assert Repo.get!(Oban.Job, first.id).state == "cancelled"
          assert Repo.get!(Oban.Job, second.id).state == "available"
        end
      end
    end)
  end

  test "runtime unique options retain tenant scope" do
    job =
      TenantWorker.new(%{key: "same"}, unique: [keys: [:key]]) |> Ecto.Changeset.apply_changes()

    assert :tenant_id in job.unique.keys
    assert :key in job.unique.keys
    assert :args in job.unique.fields

    assert TenantWorker.new(%{}, unique: false)
           |> Ecto.Changeset.apply_changes()
           |> Map.fetch!(:unique) == nil
  end

  test "same-named Session Drivers and reply previews have distinct tenant identities", %{
    tenant: tenant
  } do
    other = create_tenant()
    key = %{agent_uid: "shared-agent", session_id: "main"}
    first = Ankole.SessionsCase.stub_driver(key)
    second = Repo.with_tenant(other.id, fn -> Ankole.SessionsCase.stub_driver(key) end)
    assert Ankole.Sessions.driver_pid(key) == first
    assert Repo.with_tenant(other.id, fn -> Ankole.Sessions.driver_pid(key) end) == second
    event = struct!(Ankole.Signals.Signal, Map.put(key, :tenant_id, tenant.id))

    refute Ankole.Conversations.Delivery.Preview.via_tuple(event) ==
             Ankole.Conversations.Delivery.Preview.via_tuple(%{event | tenant_id: other.id})
  end

  test "a job restores its tenant even when execution inherits another tenant", %{tenant: tenant} do
    other = create_tenant()
    job = TenantWorker.new(%{}) |> Ecto.Changeset.apply_changes()

    Repo.with_tenant(other.id, fn ->
      assert {:ok, id} = TenantWorker.perform(job)
      assert id == tenant.id
      assert Repo.tenant_id!() == other.id
    end)
  end

  test "a suspended tenant can finish previously admitted work", %{tenant: tenant} do
    tenant |> Ecto.Changeset.change(suspended_at: DateTime.utc_now()) |> Repo.update!()
    job = TenantWorker.new(%{}) |> Ecto.Changeset.apply_changes()
    assert TenantWorker.perform(job) == {:ok, tenant.id}
  end

  test "deleted and missing tenant jobs never reach the worker" do
    deleted_id = Ankole.Ecto.UUIDv7.autogenerate()
    refute Repo.get(Tenant, deleted_id)

    assert TenantWorker.perform(%Oban.Job{args: %{"tenant_id" => deleted_id}}) ==
             {:cancel, :tenant_deleted}

    assert_raise FunctionClauseError, fn ->
      TenantWorker.perform(%Oban.Job{args: %{}})
    end
  end

  test "site work clears the inherited context and restores it afterwards", %{tenant: tenant} do
    assert SiteWorker.perform(%Oban.Job{args: %{}}) == {:ok, nil}
    assert Repo.tenant_id!() == tenant.id
  end

  test "unscoped submission fails before enqueue" do
    Repo.without_tenant(fn ->
      assert_raise Ankole.TenantContextMissing, fn -> TenantWorker.new(%{}) end
    end)
  end
end
