defmodule Ankole.Signals.TargetTest do
  use ExUnit.Case, async: true
  alias Ankole.Signals.Target, as: ExecutionTarget
  alias Ankole.Sessions.Key

  test "parses atom and JSON destinations with the same key contract" do
    id = "019a2b00-0000-7000-8000-000000000001"
    assert ExecutionTarget.parse(%{conversation_id: id}) == {:conversation, id}
    assert ExecutionTarget.parse(%{"session_id" => Key.conversation(id)}) == {:conversation, id}
    assert ExecutionTarget.parse(%{session_id: "custom:triage"}) == {:session, "custom:triage"}
    assert ExecutionTarget.parse({:conversation, id}) == {:conversation, id}
    assert ExecutionTarget.parse(%{session_id: Key.job(1000)}) == {:session, Key.job(1000)}
  end

  test "rejects missing, ambiguous and invalid destinations" do
    for target <- [
          nil,
          %{},
          %{session_id: ""},
          %{session_id: <<255>>},
          %{conversation_id: "invalid"},
          %{session_id: "custom", conversation_id: "invalid"}
        ] do
      assert ExecutionTarget.parse(target) == :error
    end
  end
end
