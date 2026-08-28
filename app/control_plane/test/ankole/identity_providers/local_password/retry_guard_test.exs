defmodule Ankole.IdentityProviders.LocalPassword.RetryGuardTest do
  use ExUnit.Case, async: false

  alias Ankole.IdentityProviders.LocalPassword.RetryGuard

  @max_account_keys 10_000

  setup do
    RetryGuard.reset_for_test()
    on_exit(&RetryGuard.reset_for_test/0)
    :ok
  end

  test "reserves five attempts and then locks" do
    for _attempt <- 1..5 do
      assert :ok = RetryGuard.register_attempt("user@example.com")
    end

    assert {:locked, retry_after} = RetryGuard.register_attempt("user@example.com")
    assert retry_after in 1..(30 * 60)
  end

  test "locks per account key" do
    for _attempt <- 1..5, do: RetryGuard.register_attempt("locked@example.com")

    assert {:locked, _seconds} = RetryGuard.register_attempt("locked@example.com")
    assert :ok = RetryGuard.register_attempt("free@example.com")
  end

  test "concurrent attempts cannot exceed the limit" do
    results =
      1..20
      |> Task.async_stream(
        fn _index -> RetryGuard.register_attempt("user@example.com") end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 5
    assert Enum.count(results, &match?({:locked, _seconds}, &1)) == 15
  end

  test "clear/1 removes the attempt history" do
    for _attempt <- 1..5, do: RetryGuard.register_attempt("user@example.com")
    assert {:locked, _seconds} = RetryGuard.register_attempt("user@example.com")

    RetryGuard.clear("user@example.com")
    assert :ok = RetryGuard.register_attempt("user@example.com")
  end

  test "attempts at or before :not_before_ms do not count" do
    for _attempt <- 1..5, do: RetryGuard.register_attempt("user@example.com")
    assert {:locked, _seconds} = RetryGuard.register_attempt("user@example.com")

    assert :ok =
             RetryGuard.register_attempt("user@example.com",
               not_before_ms: System.system_time(:millisecond)
             )
  end

  test "the sweep keeps in-window attempts and survives idle keys" do
    assert :ok = RetryGuard.register_attempt("user@example.com")

    send(Process.whereis(RetryGuard), :sweep)

    # The attempt is still inside the window, so the key survives the sweep
    # and the remaining budget is unchanged.
    for _attempt <- 1..4 do
      assert :ok = RetryGuard.register_attempt("user@example.com")
    end

    assert {:locked, _seconds} = RetryGuard.register_attempt("user@example.com")
  end

  test "saturation bounds state and locks every account key the same way" do
    for index <- 1..@max_account_keys do
      assert :ok = RetryGuard.register_attempt("user-#{index}@example.com")
    end

    assert {:locked, overflow_retry_after} =
             RetryGuard.register_attempt("overflow@example.com")

    assert {:locked, admitted_retry_after} =
             RetryGuard.register_attempt("user-1@example.com")

    assert abs(overflow_retry_after - admitted_retry_after) <= 1

    assert %{attempts_by_account: attempts_by_account, saturated_until_ms: saturated_until_ms} =
             :sys.get_state(RetryGuard)

    assert map_size(attempts_by_account) == @max_account_keys
    assert is_integer(saturated_until_ms)
  end
end
