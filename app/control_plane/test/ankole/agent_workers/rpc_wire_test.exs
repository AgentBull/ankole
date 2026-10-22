defmodule Ankole.AgentWorkers.RPCWireTest do
  use ExUnit.Case, async: true

  alias Ankole.AgentWorkers.RPCWire

  test "unexpected Ash errors retain broker details without exposing private failure data" do
    secret = "private-rpc-token-/srv/private/action"

    log =
      ExUnit.CaptureLog.capture_log([format: "$metadata $message\n", metadata: :all], fn ->
        for module <- [Ash.Error.Framework, Ash.Error.Unknown],
            style <- [:default, :tuple_reason, :inspect_tuple_reason, :tuple_inspect] do
          error = module.exception(errors: [RuntimeError.exception(secret)], path: [secret])

          payload =
            RPCWire.error_payload("request-1", error,
              fallback_code: "job_failed",
              message_style: style,
              details_json: %{"agent_uid" => "agent-1"}
            )

          assert payload["request_id"] == "request-1"
          assert payload["code"] == "job_failed"
          assert payload["details_json"] == %{"agent_uid" => "agent-1"}

          assert payload["message"] ==
                   "The request failed for an unexpected reason; check the server log"

          refute Ankole.JSON.encode!(payload) =~ secret
        end
      end)

    assert log =~ "runtime_fabric.rpc_action_error"
    assert log =~ "Ash.Error.Framework"
    assert log =~ "Ash.Error.Unknown"
    refute log =~ secret
  end

  test "Ash authorization failures use the shared access denial contract" do
    secret = "private-forbidden-token"

    for style <- [:default, :tuple_reason, :inspect_tuple_reason, :tuple_inspect] do
      error = Ash.Error.Forbidden.exception(errors: [RuntimeError.exception(secret)])

      assert RPCWire.error_payload("request-1", error,
               fallback_code: "job_failed",
               message_style: style
             ) == %{
               "request_id" => "request-1",
               "code" => "forbidden",
               "message" => "access denied",
               "details_json" => %{}
             }
    end
  end

  test "validation errors preserve field limits and the broker code without private input" do
    secret = "private-token-/srv/private/session"

    changeset =
      Ankole.Schedule.Schemas.ScheduledEvent
      |> Ash.Changeset.new()
      |> Ash.Changeset.add_error(
        Ash.Error.Changes.InvalidAttribute.exception(
          field: :name,
          message: "must have at least %{count} characters",
          vars: [count: 3, token: secret],
          private_vars: [constraint: secret],
          value: %{token: secret},
          path: [secret]
        )
      )

    for error <- [changeset, Ash.Error.to_error_class(changeset)] do
      payload =
        RPCWire.error_payload("request-1", error,
          fallback_code: "job_failed",
          validation_code: "invalid_job",
          details_json: %{"agent_uid" => "agent-1"}
        )

      assert payload["request_id"] == "request-1"
      assert payload["code"] == "invalid_job"
      assert payload["details_json"] == %{"agent_uid" => "agent-1"}

      assert Ankole.JSON.decode!(payload["message"]) == [
               %{"path" => "name", "message" => "must have at least 3 characters"}
             ]

      assert RPCWire.error_code(error, "job_failed") == "job_failed"
      refute Ankole.JSON.encode!(payload) =~ secret
    end
  end

  test "projects one library Skill into the shared RuntimeFabric summary" do
    summary =
      RPCWire.runtime_skill_summary(%{
        "skill_name" => "bullx-financial-data",
        "description" => "Use BullX financial data.",
        "source_kind" => "builtin",
        "relative_path" => "bullx-financial-data",
        "skill_root" => "internal",
        "metadata" => %{"ankole-runtime" => "any", "brain_recall_only" => true},
        "category" => "data"
      })

    assert summary.skill_name == "bullx-financial-data"
    assert summary.description == "Use BullX financial data."
    assert summary.source_kind == "builtin"
    assert summary.relative_path == "bullx-financial-data"
    assert summary.skill_root == "internal"

    assert Torque.decode!(summary.metadata_json) == %{
             "ankole-runtime" => "any",
             "brain_recall_only" => true
           }

    assert summary.category == "data"
  end
end
