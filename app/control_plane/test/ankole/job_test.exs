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

  test "new/1 captures the submitting tenant in the durable args", %{tenant: tenant} do
    job = TenantWorker.new(%{work: "resume"}) |> Ecto.Changeset.apply_changes()
    assert job.args["tenant_id"] == tenant.id
    assert TenantWorker.__tenancy__() == :tenant
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
