defmodule Ankole.IdentityProviders.LocalPassword.RetryGuardTest do
  use ExUnit.Case, async: true

  alias Ankole.IdentityProviders.LocalPassword.RetryGuard

  @tenant_a "00000000-0000-7000-8000-000000000001"
  @tenant_b "00000000-0000-7000-8000-000000000002"
  @hash "$argon2id$v=19$m=8,t=1,p=1$lN2XWliZcQl4gHsXITedAg$DDmr4D0bb5laGYLf46hR2ubMwUfsd5HD1Oz71V/yDAo"

  setup do
    start_supervised!({Task.Supervisor, name: :b16_callers})
    :ok
  end

  defp start_guard(concurrency \\ 2) do
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

  defp launch(label) do
    owner = self()
    Task.Supervisor.start_child(:b16_callers, fn -> send(owner, {label, verify()}) end)
  end

  test "five attempts are reserved per tenant and account" do
    start_guard()
    credential_written_at = DateTime.utc_now() |> DateTime.to_unix(:microsecond)

    assert {:ok, false} =
             verify(@tenant_a, "user@example.com", @hash, not_before_us: credential_written_at)

    [first_attempt] =
      :sys.get_state(:b16_guard).tenants[@tenant_a][:crypto.hash(:sha256, "user@example.com")]

    assert first_attempt >= credential_written_at
    opts = [not_before_us: first_attempt]

    for _ <- 2..5, do: assert({:ok, false} = verify(@tenant_a, "user@example.com", @hash, opts))
    assert {:locked, seconds} = verify(@tenant_a, "user@example.com", @hash, opts)
    assert seconds in 1..1_800
    assert {:ok, false} = verify(@tenant_a, "another@example.com")
    assert {:ok, false} = verify(@tenant_b)
  end

  test "a matching dummy hash does not clear unknown-account attempts" do
    start_guard()
    hash = Ankole.Kernel.argon2id_hash("wrong")

    for _ <- 1..5,
        do:
          assert(
            {:ok, true} = verify(@tenant_a, "missing@example.com", hash, clear_on_match?: false)
          )

    assert {:locked, _} = verify(@tenant_a, "missing@example.com", hash, clear_on_match?: false)
  end

  test "concurrent verification cannot reserve more than five guesses" do
    start_guard(20)
    for index <- 1..20, do: launch(index)

    results =
      for index <- 1..20 do
        assert_receive {^index, result}, 1_000
        result
      end

    assert Enum.count(results, &(&1 == {:ok, false})) == 5
    assert Enum.count(results, &match?({:locked, _}, &1)) == 15
  end

  test "new credentials remove old attempts and sweep retains in-window history" do
    start_guard()
    for _ <- 1..5, do: assert({:ok, false} = verify())
    send(Process.whereis(:b16_guard), :sweep)
    assert {:locked, _} = verify()

    assert {:ok, false} =
             verify(@tenant_a, "user@example.com", @hash,
               not_before_us: System.os_time(:microsecond)
             )
  end

  test "a tenant with 10,000 keys cannot lock another tenant" do
    start_guard()

    for index <- 1..10_000 do
      assert {:ok, false} = verify(@tenant_a, "user-#{index}@example.com")
    end

    assert {:locked, _} = verify(@tenant_a, "overflow@example.com")
    assert {:locked, _} = verify(@tenant_a, "user-1@example.com")
    assert {:ok, false} = verify(@tenant_b)
    state = :sys.get_state(:b16_guard)
    assert map_size(state.tenants[@tenant_a]) == 10_000
    assert map_size(state.tenants[@tenant_b]) == 1
  end
end
