defmodule Ankole.TenantDeletionHookTest do
  use Ankole.DataCase, async: false

  alias Ankole.{AppConfigure, Repo, Tenants}
  alias Ankole.Tenants.Jobs.Delete

  setup %{tenant: tenant} do
    {:ok, _} =
      Repo.transact_top_level(fn ->
        AppConfigure.put_global_by_key_in_tx("tenants.privileged_tenant_id", tenant.id)
      end)

    :ok = Tenants.ensure_scaffold(tenant)
    original_hooks = Tenants.deletion_hooks()
    on_exit(fn -> Application.put_env(:ankole, :tenant_deletion_hooks, original_hooks) end)
    :ok
  end

  test "executes registered tenant deletion hooks as a retryable step before finishing deletion" do
    {:ok, target} =
      Tenants.create(%{
        slug: "hook-tenant-#{System.unique_integer([:positive])}",
        display_name: "Hook Tenant"
      })

    hook = build_flaky_hook(target.id, self())
    :ok = Tenants.register_deletion_hook(hook)
    assert hook in Tenants.deletion_hooks()
    assert {:ok, _} = Tenants.delete(target)

    # First run fails when the hook returns {:error, :transient_cleanup_failure}, preserving the tenant row
    assert {:error, :transient_cleanup_failure} =
             Delete.run(%Oban.Job{args: %{"tenant_id" => target.id}})

    assert_receive {:deletion_hook_called, tenant_id, 1}
    assert tenant_id == target.id
    assert {:ok, %{deleting_at: deleting_at}} = Tenants.get(target.id)
    assert not is_nil(deleting_at)

    # Retry succeeds and finishes deleting the tenant
    assert :ok = drain_delete(target.id)
    assert_received {:deletion_hook_called, ^tenant_id, _}
    assert {:error, :not_found} = Tenants.get(target.id)

    :ok = Tenants.unregister_deletion_hook(hook)
    refute hook in Tenants.deletion_hooks()
  end

  defp build_flaky_hook(target_id, test_pid) do
    attempts = :counters.new(1, [:atomics])

    fn tenant_id ->
      if tenant_id == target_id do
        :counters.add(attempts, 1, 1)
        attempt = :counters.get(attempts, 1)
        send(test_pid, {:deletion_hook_called, tenant_id, attempt})
        if attempt == 1, do: {:error, :transient_cleanup_failure}, else: :ok
      else
        :ok
      end
    end
  end

  defp drain_delete(id) do
    Enum.reduce_while(1..50, :pending, fn _, _ ->
      case Delete.run(%Oban.Job{args: %{"tenant_id" => id}}) do
        :ok -> {:halt, :ok}
        {:snooze, _} -> {:cont, :pending}
        other -> {:halt, other}
      end
    end)
  end
end
