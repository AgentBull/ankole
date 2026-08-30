defmodule Ankole.Workflow.ProgramTest do
  use ExUnit.Case, async: true

  alias Ankole.Workflow.Program
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  test "assembles the stable Workflow wrapper byte for byte" do
    run = %Run{
      args: %{"topic" => "replay"},
      script: "return await agent(args.topic);"
    }

    assert {:ok, source} = Program.source(run)

    assert source ==
             """
             "use strict";
             const args = {"topic":"replay"};
             const agent = (prompt, opts = {}) => {
               if (typeof prompt !== "string" || prompt.trim() === "") {
                 throw new Error("agent(prompt, opts) needs a non-empty prompt string");
               }
               return tools.agent({ prompt, ...opts }).then((r) => (r && r.ok ? r.value : null));
             };
             const __wf_value = await (async () => {
             return await agent(args.topic);
             })();
             if (__wf_value !== undefined) {
               text(typeof __wf_value === "string" ? __wf_value : JSON.stringify(__wf_value));
             }
             """
  end

  test "memo is only the longest terminal prefix" do
    calls = [
      call(0, "succeeded", %{"prompt" => "first"}, %{"ok" => true, "value" => false}),
      call(1, "queued", %{"prompt" => "second"}, nil),
      call(2, "failed", %{"prompt" => "third"}, %{
        "ok" => false,
        "code" => "failed",
        "summary" => "Failed."
      })
    ]

    assert {memo, 1} = Program.memo_prefix(Enum.reverse(calls))

    assert memo == [
             %{
               "namespace" => nil,
               "name" => "agent",
               "arguments" => %{"prompt" => "first"},
               "output" => %{"ok" => true, "value" => false}
             }
           ]
  end

  test "stall diff keeps matching stored calls and returns only the new suffix" do
    calls = [
      call(0, "succeeded", %{"prompt" => "first"}, %{"ok" => true, "value" => "one"}),
      call(1, "queued", %{"prompt" => "second"}, nil),
      call(2, "succeeded", %{"prompt" => "third"}, %{"ok" => true, "value" => "three"})
    ]

    pending = [
      pending(%{"prompt" => "second"}),
      pending(%{"prompt" => "third"}),
      pending(%{"prompt" => "fourth"})
    ]

    assert {:ok, %{memo_length: 1, new_calls: [new_call]}} =
             Program.stall_diff(calls, pending, 8)

    assert new_call == %{call_seq: 3, arguments: %{"prompt" => "fourth"}}
  end

  test "stall diff rejects changed identity and a missing stored tail" do
    calls = [
      call(0, "succeeded", %{"prompt" => "first"}, %{"ok" => true, "value" => "one"}),
      call(1, "queued", %{"prompt" => "second"}, nil),
      call(2, "running", %{"prompt" => "third"}, nil)
    ]

    assert {:error, {:workflow_replay_diverged, %{call_seq: 1}}} =
             Program.stall_diff(calls, [pending(%{"prompt" => "changed"})], 8)

    assert {:error, {:workflow_replay_diverged, %{call_seq: 2, replayed: :missing_pending_call}}} =
             Program.stall_diff(calls, [pending(%{"prompt" => "second"})], 8)
  end

  test "stall diff rejects another tool identity and the Agent-call limit" do
    invalid = [%{namespace: "collaboration", name: "spawn_agent", arguments: %{}}]

    assert {:error, {:workflow_replay_diverged, %{call_seq: 0, replayed: :invalid_pending_call}}} =
             Program.stall_diff([], invalid, 8)

    assert {:error, {:workflow_agent_limit_exceeded, %{used: 2, max: 1}}} =
             Program.stall_diff(
               [],
               [pending(%{"prompt" => "one"}), pending(%{"prompt" => "two"})],
               1
             )
  end

  defp call(call_seq, status, arguments, result) do
    %AgentCall{call_seq: call_seq, status: status, arguments: arguments, result: result}
  end

  defp pending(arguments), do: %{namespace: nil, name: "agent", arguments: arguments}
end
