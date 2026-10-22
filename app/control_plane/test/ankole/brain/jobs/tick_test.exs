defmodule Ankole.Brain.Jobs.TickTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Brain.Jobs.Dreaming
  alias Ankole.Brain.Jobs.SelfHealing
  alias Ankole.Brain.Jobs.Tick

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    on_exit(fn ->
      Registry.clear_for_test()
      Cache.clear_for_test()
    end)

    :ok
  end

  test "mechanical maintenance is enqueued without a maintainer", %{tenant: tenant} do
    assert {:ok, "Etc/UTC"} = Ankole.AppConfigure.put_tenant_by_key("system.timezone", "UTC")
    assert :ok = Tick.perform(%Oban.Job{inserted_at: ~U[2026-08-27 05:00:00Z]})
    assert_enqueued(worker: SelfHealing, args: %{tenant_id: tenant.id})
    assert_enqueued(worker: Dreaming, args: %{tenant_id: tenant.id})
  end

  test "a delayed tick evaluates the immutable insertion minute", %{tenant: tenant} do
    %{principal: maintainer} = Ankole.PrincipalsFixtures.agent_fixture()

    assert {:ok, _} =
             Ankole.AppConfigure.put_tenant_by_key("brain.maintainer_agent_uid", maintainer.uid)

    assert {:ok, "Etc/UTC"} = Ankole.AppConfigure.put_tenant_by_key("system.timezone", "UTC")

    assert :ok =
             Tick.perform(%Oban.Job{
               attempt: 2,
               inserted_at: ~U[2026-08-27 05:00:00Z],
               scheduled_at: ~U[2026-08-27 05:01:00Z]
             })

    assert_enqueued(worker: SelfHealing, args: %{tenant_id: tenant.id})
    assert_enqueued(worker: Dreaming, args: %{tenant_id: tenant.id})
  end
end
