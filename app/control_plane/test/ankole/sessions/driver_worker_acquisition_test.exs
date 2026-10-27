defmodule Ankole.Sessions.WorkerAcquisitionTest do
  use ExUnit.Case, async: true
  alias Ankole.Sessions.WorkerAcquisition, as: Acquisition

  test "streamed demand leaves the deadline for tool execution" do
    {state, [:request]} = Acquisition.next(:idle, :request, 0)
    assert {^state, []} = Acquisition.next(state, :request, 60_000)
    {state, effects} = Acquisition.next(state, :acquire, 120_000)
    assert :resolve in effects
    assert {{:opening, 120_000, nil}, []} = Acquisition.next(state, :expired, 120_001)
  end

  for phase <- [:starting, :resuming, :retrying, :replacing, :preparing, :capacity] do
    test "#{phase} keeps the deadline through repeated attempts" do
      phase = unquote(phase)
      {state, _} = Acquisition.next(:idle, :acquire, 100)
      {state, effects} = Acquisition.next(state, {:resolved, {:wait, phase}}, 200)
      assert {:phase, phase} in effects
      assert :request in effects
      {state, [:resolve]} = Acquisition.next(state, :acquire, 20_000)
      {state, _} = Acquisition.next(state, {:resolved, {:wait, phase}}, 30_000)
      assert {^state, []} = Acquisition.next(state, :expired, 60_099)

      assert {{:unavailable, {:timeout, ^phase}}, [{:unavailable, {:timeout, ^phase}}]} =
               Acquisition.next(state, :expired, 60_100)
    end
  end

  test "workspace replies can precede the send result" do
    row = %{transport_route: "route"}
    {state, _} = Acquisition.next(:idle, :acquire, 0)

    {state, [{:send_open, ^row, :envelope}]} =
      Acquisition.next(state, {:resolved, {:ok, row, :envelope}}, 1)

    {state, [:ready]} = Acquisition.next(state, :ready, 2)
    assert state == {:ready, row}
    assert {^state, []} = Acquisition.next(state, {:sent, {:ok, row}}, 3)
  end

  test "a ready workspace serves later rounds without another open" do
    row = %{transport_route: "route"}
    state = {:ready, row}

    for now <- [0, 60_000, 180_000] do
      assert {^state, [:ready]} = Acquisition.next(state, :acquire, now)
      assert {^state, []} = Acquisition.next(state, :expired, now)
    end

    assert {^state, [{:check, ^row}]} = Acquisition.next(state, :check, 1)
    assert {^state, [:probe]} = Acquisition.next(state, {:checked, {:ok, :same}}, 2)

    assert {{:opening, 3, nil}, [:retry_calls, :resolve]} =
             Acquisition.next(state, {:checked, {:ok, :changed}}, 3)
  end

  test "capacity feedback retains the original start time" do
    row = %{transport_route: "route"}
    {state, _} = Acquisition.next(:idle, :acquire, 10)
    {state, _} = Acquisition.next(state, {:resolved, {:ok, row, :envelope}}, 11)

    assert {{:waiting, :capacity, 10}, [{:phase, :capacity}]} =
             Acquisition.next(state, {:waiting, :CAPACITY}, 12)

    assert {{:waiting, :replacing, 10}, [{:phase, :replacing}]} =
             Acquisition.next(state, {:waiting, :DRAINING}, 12)
  end

  test "a connection change during opening resolves again without extending the deadline" do
    row = %{transport_route: "old"}
    state = {:opening, 10, row}
    assert {^state, [{:check, ^row}]} = Acquisition.next(state, :check, 20)
    assert {^state, []} = Acquisition.next(state, {:checked, {:ok, :same}}, 30)

    assert {{:opening, 10, nil} = retry, [:resolve]} =
             Acquisition.next(state, {:checked, {:ok, :changed}}, 40)

    assert {^retry, [:resolve]} = Acquisition.next(retry, :check, 50)
    assert {{:unavailable, {:timeout, :starting}}, _} = Acquisition.next(retry, :expired, 60_010)
  end

  test "unavailability lasts until the run ends and ignores late replies" do
    state = {:unavailable, {:timeout, :capacity}}

    for event <- [
          :ready,
          :acquire,
          :check,
          :send_failed,
          :request,
          :expired,
          :round_committed,
          {:waiting, :DRAINING},
          {:unavailable, :late_error},
          {:sent, {:ok, %{}}},
          {:resolved, {:ok, %{}, :envelope}},
          {:checked, {:ok, :changed}}
        ] do
      assert {^state, []} = Acquisition.next(state, event, 120_000)
    end

    assert Acquisition.error_text(elem(state, 1)) =~ "busy with other tasks"
    refute Acquisition.error_text({:rejected, "secret"}) =~ "secret"
  end

  test "a committed round abandons only unfinished acquisition and cancels its timers" do
    row = %{transport_route: "route"}

    for state <- [{:opening, 10, nil}, {:opening, 10, row}, {:waiting, :capacity, 10}] do
      assert {{:idle, :requested} = idle, []} = Acquisition.next(state, :round_committed, 30_000)
      assert [{:acquire, :cancel}, {:check, :cancel}] = Acquisition.timers(idle, 30_000)

      assert {{:opening, 70_000, nil}, [{:phase, :starting}, :resolve]} =
               Acquisition.next(idle, :acquire, 70_000)
    end

    assert {{:ready, ^row}, []} = Acquisition.next({:ready, row}, :round_committed, 70_000)
  end

  test "broadcasts and late workspace replies do not open or poison non-opening states" do
    row = %{transport_route: "route"}

    for state <- [
          :idle,
          {:idle, :requested},
          {:opening, 10, nil},
          {:waiting, :capacity, 10},
          {:ready, row}
        ],
        reply <- [
          :ready,
          {:waiting, :CAPACITY},
          {:waiting, :DRAINING},
          {:unavailable, :late_reply}
        ] do
      assert {^state, []} = Acquisition.next(state, reply, 20)
    end

    assert {:idle, []} = Acquisition.next(:idle, :check, 0)
    assert {{:idle, :requested}, []} = Acquisition.next({:idle, :requested}, :check, 0)
  end
end
