defmodule Ankole.Sessions.KeyTest do
  use ExUnit.Case, async: true
  alias Ankole.Sessions.Key

  test "constructors and parsers preserve each persisted key format" do
    id = "019a2b00-0000-7000-8000-000000000001"
    assert Key.parse(Key.conversation(id)) == {:conversation, id}
    assert Key.parse(Key.cron(id)) == {:cron, id}
    assert Key.parse(Key.job(1000)) == {:job, "1000"}
    assert Key.parse(Key.workflow_task(2000)) == {:workflow_task, "2000"}
    assert Key.parse("triage:incident") == {:named, "triage:incident"}
  end

  test "invalid strings are rejected and private work cannot be routed" do
    for key <- [
          nil,
          1,
          "",
          " \n",
          <<255>>,
          "a\0b",
          "conversation:no",
          "job:",
          "wf_task: ",
          "cron:"
        ] do
      assert Key.parse(key) == :error
      refute Key.routable?(key)
    end

    refute Key.routable?(Key.job(1000))
    refute Key.routable?(Key.workflow_task(1000))
    assert Key.routable?(Key.cron("report"))
    assert Key.routable?("triage")
  end
end
