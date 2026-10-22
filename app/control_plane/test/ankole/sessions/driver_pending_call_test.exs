defmodule Ankole.Sessions.DriverPendingCallTest do
  use ExUnit.Case, async: true
  alias Ankole.Sessions.PendingCall

  test "dispatch keeps call order and counts every active state toward four slots" do
    calls = Enum.map(1..6, &call/1)
    pending = PendingCall.new_round(calls, false)
    assert {:ok, first, 0} = PendingCall.next(pending, calls)
    assert first == call(1)
    assert {:ok, second, 0} = PendingCall.next(Map.delete(pending, "1"), calls)
    assert second == call(2)

    pending =
      Enum.reduce(1..4, pending, fn id, p -> PendingCall.wait_worker(p, to_string(id)) end)

    assert PendingCall.next(pending, calls) == :none
  end

  test "a sequential call blocks later calls and waits for other active calls" do
    pending = PendingCall.new_round([call(1)], false)
    refute PendingCall.blocked?(pending, false, 0)
    assert PendingCall.blocked?(pending, true, 1)
    pending = PendingCall.start(pending, "1", call(1), %{retry_safe: false}, %{}, true)
    assert PendingCall.blocked?(pending, false, 1)
  end

  test "worker dispatch probes attempted unsafe calls and executes retry-safe calls" do
    pending = PendingCall.new_round([call(1), call(2)], true)
    pending = PendingCall.start(pending, "1", call(1), %{retry_safe: false}, %{}, false)
    pending = PendingCall.start(pending, "2", call(2), %{retry_safe: true}, %{}, false)
    {pending, first} = PendingCall.to_worker(pending, "1")
    assert first.mode == "probe"
    {_, second} = PendingCall.to_worker(pending, "2")
    assert second.mode == "execute"
  end

  test "worker replacement keeps local calls and preserves whether a wait was attempted" do
    pending = %{
      "worker" => entry(:worker),
      "fresh" => entry(:worker_wait),
      "attempted" => entry(:worker_wait, true),
      "local" => entry(:running),
      "wait" => entry(:waiting)
    }

    changed = PendingCall.worker_changed(pending)
    assert changed["worker"].status == :queued and changed["worker"].probe?
    assert changed["fresh"].status == :queued and not changed["fresh"].probe?
    assert changed["attempted"].probe?
    assert changed["local"] == pending["local"]
    assert changed["wait"] == pending["wait"]
  end

  test "observation, send failure, unknown and workspace readiness retain probe semantics" do
    pending = %{"worker" => entry(:worker), "wait" => entry(:worker_wait, true)}
    same = PendingCall.worker_same(pending)
    assert same["worker"].status == :queued and same["worker"].probe?
    assert same["wait"] == pending["wait"]
    assert PendingCall.send_failed(pending, "missing") == pending
    failed = PendingCall.send_failed(pending, "worker")
    assert failed["worker"].status == :queued and failed["worker"].probe?
    unknown = PendingCall.unknown(failed, "worker")
    refute unknown["worker"].probe?
    ready = PendingCall.ready(pending)
    assert ready["wait"].status == :queued and ready["wait"].probe?
    assert ready["worker"] == pending["worker"]
  end

  test "selectors return only the intended calls and waiting values" do
    pending = %{
      "fresh" => entry(:worker_wait),
      "attempted" => entry(:worker_wait, true),
      "queued" => entry(:queued),
      "worker" => entry(:worker),
      "waiting" => %{entry(:waiting) | wait: :deadline}
    }

    assert Enum.sort(PendingCall.waiting_worker(pending)) == ["attempted", "fresh"]
    assert PendingCall.queued(pending) == ["queued"]
    assert PendingCall.on_worker(pending) == ["worker"]
    assert PendingCall.waits(pending) == [{"waiting", :deadline}]
  end

  test "a route observation does not probe a call whose transport send is still pending" do
    pending = %{"sending" => entry(:worker), "sent" => entry(:worker)}
    observed = PendingCall.worker_same(pending, ["sending"])
    assert observed["sending"] == pending["sending"]
    assert observed["sent"].status == :queued
    assert observed["sent"].probe?
  end

  test "delegation and waiting retain the call identity and continuation" do
    pending = PendingCall.new_round([call(1)], false)
    pending = PendingCall.start(pending, "1", call(1), %{retry_safe: false}, %{}, false)
    continue = fn _run, result -> result end
    pending = PendingCall.delegate(pending, "1", "worker-tool", %{key: "value"}, continue)
    assert pending["1"].tool.retry_safe
    assert pending["1"].call == call(1)
    assert pending["1"].continue == continue
    assert PendingCall.await(pending, "1", :deadline)["1"].wait == :deadline
  end

  defp call(id), do: %{"call_id" => to_string(id), "name" => "command"}

  defp entry(status, probe? \\ false),
    do: %PendingCall{call: call(1), status: status, probe?: probe?}
end
