defmodule Ankole.WorkerProviderTransactionsTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.Providers.Provider
  alias Ankole.AgentWorkers.Providers.Seed
  alias Ankole.AgentWorkers.AgentWorker

  setup %{tenant: tenant} do
    suffix = System.unique_integer([:positive])
    first = "provider-tx-first-#{suffix}"
    second = "provider-tx-second-#{suffix}"
    uid = "provider-tx-legacy-#{suffix}"
    seed = Path.join(System.tmp_dir!(), "worker-provider-transactions-#{suffix}.yaml")

    on_exit(fn ->
      Repo.put_tenant_id(tenant.id)
      File.rm(seed)

      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from w in AgentWorker, where: w.agent_uid == ^uid)
        Repo.delete_all(from p in Provider, where: p.provider_id in ^[first, second])
        Repo.delete!(tenant)
      end)
    end)

    %{first: first, second: second, uid: uid, seed: seed}
  end

  test "independent non-default creates can commit at the same time", context do
    first = hold(fn -> Providers.create(attrs(context.first)) end)
    second = start(fn -> Providers.create(attrs(context.second)) end)
    assert {:ok, %{provider_id: id}} = finish(second)
    assert id == context.second
    assert Repo.get_by(Provider, provider_id: context.first) == nil
    release(first)
    assert {:ok, %{provider_id: id}} = finish(first)
    assert id == context.first
  end

  test "seed import waits for a pending Console create and then keeps that registry", context do
    refute Repo.exists?(Provider)
    legacy!(context.uid)
    seed!(context.seed, context.second)

    first = hold(fn -> Providers.create(attrs(context.first)) end)
    seed = start(fn -> Seed.import_file(context.seed) end)
    assert_blocked_by(seed, first)
    release(first)
    assert {:ok, _} = finish(first)
    assert :ok = finish(seed)
    assert Repo.get_by(Provider, provider_id: context.second) == nil
    assert Repo.get!(AgentWorker, context.uid).provider_id == nil
  end

  test "a Console create waits for seed insertion and legacy assignment to commit", context do
    refute Repo.exists?(Provider)
    legacy!(context.uid)
    seed!(context.seed, context.first)

    seed =
      hold(fn ->
        :ok = Seed.import_file(context.seed)
        {:ok, :imported}
      end)

    second = start(fn -> Providers.create(attrs(context.second)) end)
    assert_blocked_by(second, seed)
    assert Repo.get_by(Provider, provider_id: context.first) == nil
    assert Repo.get!(AgentWorker, context.uid).provider_id == nil
    release(seed)
    assert {:ok, :imported} = finish(seed)
    assert {:ok, _} = finish(second)
    assert Repo.get!(AgentWorker, context.uid).provider_id == context.first
    assert Repo.get_by!(Provider, provider_id: context.first).is_default
  end

  test "concurrent default creates serialize and leave one default", context do
    refute Repo.exists?(Provider)
    first = hold(fn -> Providers.create(Map.put(attrs(context.first), :is_default, true)) end)
    second = start(fn -> Providers.create(Map.put(attrs(context.second), :is_default, true)) end)
    assert_blocked_by(second, first)
    release(first)
    assert {:ok, _} = finish(first)
    assert {:ok, _} = finish(second)

    assert Repo.all(from p in Provider, where: p.is_default, select: p.provider_id) == [
             context.second
           ]
  end

  defp attrs(id),
    do: %{provider_id: id, kind: "docker", display_name: id, config: "network: bridge\n"}

  defp legacy!(uid) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.insert!(%AgentWorker{
        agent_uid: uid,
        state: "absent",
        state_changed_at: DateTime.utc_now(:microsecond)
      })
    end)
  end

  defp seed!(path, id) do
    File.write!(
      path,
      Ankole.JSON.encode!(%{
        providers: [Map.merge(attrs(id), %{is_default: true, legacy_agents: true})]
      })
    )
  end

  defp start(fun) do
    parent = self()
    tenant_id = Repo.tenant_id!()

    task =
      Task.async(fn ->
        Repo.put_tenant_id(tenant_id)

        Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:database_task, self(), backend_pid})
          fun.()
        end)
      end)

    pid = task.pid
    assert_receive {:database_task, ^pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid}
  end

  defp hold(fun) do
    parent = self()

    operation =
      start(fn ->
        Repo.transact(fn _repo ->
          result = fun.()
          send(parent, {:transaction_held, self()})

          receive do
            :commit -> result
          after
            10_000 -> raise "test did not release its transaction"
          end
        end)
      end)

    pid = operation.task.pid
    assert_receive {:transaction_held, ^pid}, 5_000
    operation
  end

  defp assert_blocked_by(waiter, holder) do
    assert {:ok, true} =
             wait_until(deadline(5_000), fn ->
               %{rows: [[blocked]]} =
                 Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [
                   holder.backend_pid,
                   waiter.backend_pid
                 ])

               blocked
             end)
  end

  defp release(operation), do: send(operation.task.pid, :commit)
  defp finish(operation), do: Task.await(operation.task, 5_000)
end
