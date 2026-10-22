defmodule Ankole.IdentityProviders.LocalPassword.RetryGuardIntegrationTest do
  use ExUnit.Case, async: false

  alias Ankole.IdentityProviders.LocalPassword.RetryGuard

  @tenant_a "00000000-0000-7000-8000-000000000001"
  @tenant_b "00000000-0000-7000-8000-000000000002"
  @hash "$argon2id$v=19$m=8,t=1,p=1$lN2XWliZcQl4gHsXITedAg$DDmr4D0bb5laGYLf46hR2ubMwUfsd5HD1Oz71V/yDAo"
  @slow_hash String.replace(@hash, "m=8,t=1", "m=19456,t=300")

  setup do
    start_supervised!({Task.Supervisor, name: :b16_callers})
    :ok
  end

  defp start_guard(concurrency) do
    start_supervised!(
      {RetryGuard.Supervisor,
       name: :b16_supervisor,
       guard: :b16_guard,
       task_supervisor: :b16_verifiers,
       max_concurrency: concurrency}
    )
  end

  defp verify(tenant \\ @tenant_a, key \\ "user@example.com", hash \\ @hash, opts \\ []) do
    RetryGuard.verify_password(tenant, key, "wrong", hash, Keyword.put(opts, :server, :b16_guard))
  end

  defp launch(label, tenant, key, hash \\ @hash) do
    owner = self()

    {:ok, pid} =
      Task.Supervisor.start_child(:b16_callers, fn ->
        result =
          try do
            verify(tenant, key, hash)
          catch
            :exit, reason -> {:exit, reason}
          end

        send(owner, {label, result})
      end)

    pid
  end

  defp await_state(predicate, remaining \\ 200) do
    state = :sys.get_state(:b16_guard)

    if predicate.(state) do
      state
    else
      assert remaining > 0
      receive after: (5 -> :ok)
      await_state(predicate, remaining - 1)
    end
  end

  test "the actual native verifier retains its permit after the caller exits" do
    start_guard(1)
    caller = launch(:slow, @tenant_a, "slow@example.com", @slow_hash)
    await_state(&(map_size(&1.running) == 1))
    [verifier] = Task.Supervisor.children(:b16_verifiers)
    caller_ref = Process.monitor(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}
    assert Process.alive?(verifier)

    launch(:queued_a1, @tenant_a, "queue-a1@example.com")
    launch(:queued_a2, @tenant_a, "queue-a2@example.com")
    await_state(&(length(Map.get(&1.waiting, @tenant_a, [])) == 2))
    assert {:busy, 1} = verify(@tenant_a, "overflow@example.com")
    state = :sys.get_state(:b16_guard)
    refute Map.has_key?(state.tenants[@tenant_a], :crypto.hash(:sha256, "overflow@example.com"))
    assert Task.Supervisor.children(:b16_verifiers) == [verifier]
    assert_receive {:queued_a1, {:busy, 1}}, 1_500
    assert_receive {:queued_a2, {:busy, 1}}, 1_500
    await_state(&(map_size(&1.running) == 0), 1_000)
    assert {:ok, false} = verify(@tenant_a, "overflow@example.com")
  end

  test "waiting callers that exit leave no attempts or queue slots" do
    start_guard(1)
    launch(:slow, @tenant_a, "slow@example.com", @slow_hash)
    await_state(&(map_size(&1.running) == 1))
    queued = launch(:queued, @tenant_b, "waiting@example.com")
    await_state(&(length(Map.get(&1.waiting, @tenant_b, [])) == 1))
    Process.exit(queued, :kill)
    state = await_state(&(not Map.has_key?(&1.waiting, @tenant_b)))
    refute Map.has_key?(state.tenants, @tenant_b)
    assert state.order == []
    assert_receive {:slow, {:ok, false}}, 5_000
  end

  test "queued tenants rotate and cannot take each other's two slots" do
    start_guard(1)
    slow_hash = String.replace(@hash, "m=8,t=1", "m=19456,t=35")
    launch(:slow, @tenant_a, "slow@example.com", slow_hash)
    await_state(&(map_size(&1.running) == 1))
    queued_hash = String.replace(@hash, "m=8,t=1", "m=19456,t=5")
    launch(:a1, @tenant_a, "a1@example.com", queued_hash)
    launch(:a2, @tenant_a, "a2@example.com", queued_hash)
    await_state(&(length(Map.get(&1.waiting, @tenant_a, [])) == 2))
    launch(:b1, @tenant_b, "b1@example.com", queued_hash)
    launch(:b2, @tenant_b, "b2@example.com", queued_hash)
    state = await_state(&(length(Map.get(&1.waiting, @tenant_b, [])) == 2))
    assert state.order == [@tenant_a, @tenant_b]
    assert {:busy, 1} = verify(@tenant_a, "a3@example.com")
    assert_receive {:slow, {:ok, false}}, 1_000

    for expected <- [:a1, :b1, :a2, :b2] do
      assert_receive {actual, {:ok, false}}, 1_000
      assert actual == expected
    end
  end

  test "a guard restart waits for the native verifier before admitting new work" do
    start_guard(1)
    launch(:slow, @tenant_a, "slow@example.com", @slow_hash)
    await_state(&(map_size(&1.running) == 1))
    [verifier] = Task.Supervisor.children(:b16_verifiers)
    await_state(fn _state -> Process.info(verifier, :trap_exit) == {:trap_exit, true} end)
    verifier_ref = Process.monitor(verifier)
    guard = Process.whereis(:b16_guard)
    Process.exit(guard, :kill)
    assert_receive {:slow, {:exit, _}}, 1_000
    refute_receive {:DOWN, ^verifier_ref, :process, ^verifier, _}, 100
    assert_receive {:DOWN, ^verifier_ref, :process, ^verifier, _}, 5_000

    # The supervised restart happens only after the trapped shutdown returns.
    pid = await_guard_restart(guard)
    refute pid == guard
    refute Process.alive?(verifier)
    assert {:ok, false} = verify()
    assert map_size(:sys.get_state(:b16_guard).tenants[@tenant_a]) == 1
  end

  defp await_guard_restart(old, remaining \\ 200) do
    case Process.whereis(:b16_guard) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ ->
        assert remaining > 0
        receive after: (5 -> :ok)
        await_guard_restart(old, remaining - 1)
    end
  end
end

defmodule AnkoleWeb.LocalPasswordBusyIntegrationTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.IdentityProviders.LocalPassword.RetryGuard
  alias AnkoleWeb.Session, as: WebSession

  setup %{tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    Ankole.AppConfigure.Registry.clear_for_test()
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok = RetryGuard.reset_for_test()
    on_exit(&RetryGuard.reset_for_test/0)
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    {:ok, _} = IdentityProviders.save_provider("local-main", "local", %{}, true)
    :ok
  end

  test "verification saturation returns a short busy delay without an account attempt", %{
    conn: conn,
    tenant: tenant
  } do
    %{email: email} = local_admin_user("correct-horse")
    supervisor = start_supervised!({Task.Supervisor, []})
    owner = self()

    slow_hash =
      "$argon2id$v=19$m=19456,t=300,p=1$lN2XWliZcQl4gHsXITedAg$DDmr4D0bb5laGYLf46hR2ubMwUfsd5HD1Oz71V/yDAo"

    for index <- 1..2 do
      Task.Supervisor.start_child(supervisor, fn ->
        result =
          RetryGuard.verify_password(tenant.id, "busy-#{index}@example.com", "wrong", slow_hash)

        send(owner, {:verification_complete, result})
      end)
    end

    await_retry_guard(fn state -> map_size(state.running) == 2 end)

    response_conn =
      conn
      |> init_test_session(%{})
      |> post_password(%{"email" => email, "password" => "correct-horse"})

    assert json_response(response_conn, 429) == %{
             "error" => "retry_busy",
             "retryAfterSeconds" => 1
           }

    assert get_resp_header(response_conn, "retry-after") == ["1"]
    state = :sys.get_state(RetryGuard)
    refute Map.has_key?(state.tenants[tenant.id], :crypto.hash(:sha256, email))
    for _ <- 1..2, do: assert_receive({:verification_complete, {:ok, false}}, 10_000)
    await_retry_guard(fn state -> map_size(state.running) == 0 end)
    Ankole.Repo.put_tenant_id(tenant.id)
    assert {:ok, _} = LocalPassword.authenticate(email, "correct-horse")
  end

  defp await_retry_guard(predicate, remaining \\ 200) do
    if predicate.(:sys.get_state(RetryGuard)) do
      :ok
    else
      assert remaining > 0
      receive after: (5 -> :ok)
      await_retry_guard(predicate, remaining - 1)
    end
  end

  defp local_admin_user(password) do
    %{principal: principal, human_user: human} = Ankole.PrincipalsFixtures.human_fixture()
    {:ok, _} = LocalPassword.set_local_password(principal.uid, password, false)
    {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(principal.uid)
    %{email: human.email}
  end

  defp post_password(conn, params) do
    {:ok, conn, transaction} = WebSession.begin_login(conn, :console, %{})
    post(conn, "/.internal-apis/sessions/local-password", Map.put(params, "flow", transaction.id))
  end
end
