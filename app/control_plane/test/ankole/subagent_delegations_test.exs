defmodule Ankole.SubagentDelegationsTest do
  use Ankole.AIGatewayCase

  import Ecto.Query, warn: false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SubagentDelegations
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.Repo

  test "create_with_dispatch durably creates one queued work item and one isolated dispatch event" do
    %{principal: agent} = agent_fixture()

    attrs = %{
      "agent_uid" => agent.uid,
      "session_id" => "parent-session",
      "tool_call_id" => "tool-subagent-1",
      "title" => "Prepare the launch brief",
      "prompt" =>
        "Read the source material, write the brief, and verify every acceptance criterion.",
      "workdir" => "/workspace/user-files/subagent/019f",
      "reply_route" => %{
        "binding_name" => "lark",
        "signal_channel_id" => "chat-1",
        "provider_thread_id" => "thread-1",
        "source_entry_id" => "message-1"
      }
    }

    assert {:ok, %{delegation: %Delegation{} = delegation, dispatch_event: %ActorEvent{} = event}} =
             SubagentDelegations.create_with_dispatch(attrs)

    assert delegation.runtime == "codex"
    assert delegation.status == "queued"
    assert delegation.attempts == 0
    assert delegation.title == attrs["title"]
    assert delegation.prompt == attrs["prompt"]
    assert delegation.reply_route == attrs["reply_route"]

    assert event.agent_uid == agent.uid
    assert event.binding_name == "lark"
    assert event.session_id == "subagent:#{delegation.id}"
    assert event.signal_channel_id == "chat-1"
    assert event.provider_thread_id == "thread-1"
    assert event.source_entry_id == "message-1"
    assert event.type == "subagent.delegation.dispatch"
    assert event.source_event_id == "subagent_delegation:#{delegation.id}:dispatch:0"

    assert get_in(event.payload, ["data", "delegation_id"]) == delegation.id
    assert get_in(event.payload, ["data", "parent_session_id"]) == "parent-session"
    assert get_in(event.payload, ["data", "workdir"]) == attrs["workdir"]
    assert get_in(event.payload, ["data", "attempts"]) == 0
    refute inspect(event.payload) =~ attrs["prompt"]

    assert {:ok, %{delegation: same_delegation, dispatch_event: same_event}} =
             SubagentDelegations.create_with_dispatch(attrs)

    assert same_delegation.id == delegation.id
    assert same_event.id == event.id
    assert Repo.aggregate(Delegation, :count) == 1
    assert Repo.aggregate(ActorEvent, :count) == 1
  end

  test "creation rejects workdirs outside the delegated workspace before journaling work" do
    %{principal: agent} = agent_fixture()

    assert {:error, changeset} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent.uid,
               "session_id" => "parent-session-invalid-workdir",
               "tool_call_id" => "tool-subagent-invalid-workdir",
               "title" => "Invalid workdir",
               "prompt" => "This must never be dispatched.",
               "workdir" => "/workspace/user-files/../../etc",
               "reply_route" => %{"binding_name" => "lark"}
             })

    assert %{workdir: ["must stay under /workspace"]} = errors_on(changeset)
    assert Repo.aggregate(Delegation, :count) == 0
    assert Repo.aggregate(ActorEvent, :count) == 0
  end

  test "status commits wake the parent only for waiting and result-bearing terminal states" do
    %{principal: agent} = agent_fixture()
    waiting = create_delegation!(agent.uid, "waiting")

    assert {:ok, %{delegation: running, wakeup_event: nil}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "running",
               "runtime_thread_id" => "thread-waiting"
             })

    assert running.status == "running"

    pending_user_input = %{
      "questions" => [
        %{
          "id" => "audience",
          "header" => "Audience",
          "question" => "Who should this brief target?",
          "isOther" => true,
          "options" => [%{"label" => "Operators", "description" => "Console operators"}]
        }
      ]
    }

    assert {:ok, %{delegation: paused, wakeup_event: %ActorEvent{} = waiting_event}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => pending_user_input}
             })

    assert paused.status == "waiting_on_user"
    assert waiting_event.session_id == "parent-session-waiting"
    assert waiting_event.type == "subagent.delegation.waiting"
    assert waiting_event.source_event_id == "subagent_delegation:#{waiting.id}:waiting:0"
    assert get_in(waiting_event.payload, ["data", "pending_user_input"]) == pending_user_input

    assert {:ok, %{delegation: resumed, wakeup_event: nil}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "running"
             })

    assert resumed.status == "running"

    assert {:ok, %{delegation: succeeded, wakeup_event: %ActorEvent{} = completed_event}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "Launch brief written and verified."}
             })

    assert succeeded.status == "succeeded"
    assert completed_event.type == "subagent.delegation.completed"
    assert completed_event.source_event_id == "subagent_delegation:#{waiting.id}:succeeded"

    assert get_in(completed_event.payload, ["data", "result_summary"]) ==
             "Launch brief written and verified."

    stopped = create_delegation!(agent.uid, "stopped")

    assert {:ok, %{delegation: stopped, wakeup_event: nil}} =
             SubagentDelegations.commit_status_with_wakeup(stopped.id, agent.uid, %{
               "status" => "stopped",
               "metadata" => %{"cancel_requested_by" => "operator:ding"}
             })

    assert stopped.status == "stopped"

    parent_wakeups =
      Repo.all(
        from event in ActorEvent,
          where: event.session_id in ["parent-session-waiting", "parent-session-stopped"],
          where:
            event.type in ^~w(subagent.delegation.waiting subagent.delegation.completed subagent.delegation.failed)
      )

    assert Enum.map(parent_wakeups, & &1.type) |> Enum.sort() ==
             ["subagent.delegation.completed", "subagent.delegation.waiting"]
  end

  test "status and parent wakeup roll back together when the frozen reply route is invalid" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "invalid-route")

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "running"
             })

    from(row in Delegation, where: row.id == ^delegation.id)
    |> Repo.update_all(set: [reply_route: %{}])

    assert {:error, :subagent_reply_route_binding_missing} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => "must not commit"}
             })

    persisted = Repo.get!(Delegation, delegation.id)
    assert persisted.status == running.status
    assert persisted.completed_at == nil

    refute Repo.exists?(
             from event in ActorEvent,
               where: event.session_id == ^delegation.session_id,
               where: event.type == "subagent.delegation.completed"
           )
  end

  test "stop is durable and idempotent while running work also receives an interrupt command" do
    %{principal: agent} = agent_fixture()
    queued = create_delegation!(agent.uid, "queued-stop")

    assert {:ok, %{delegation: stopped, command_event: nil}} =
             SubagentDelegations.request_stop(queued.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:ding",
               "reason" => "No longer needed"
             })

    assert stopped.status == "stopped"
    assert stopped.metadata["cancel_requested_by"] == "operator:ding"

    dispatch =
      Repo.one!(
        from event in ActorEvent,
          where: event.session_id == ^"subagent:#{queued.id}",
          where: event.type == "subagent.delegation.dispatch"
      )

    assert %DateTime{} = dispatch.completed_at

    assert {:ok, %{delegation: same_stopped, command_event: nil}} =
             SubagentDelegations.request_stop(queued.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:ding"
             })

    assert same_stopped.id == stopped.id

    running = create_delegation!(agent.uid, "running-stop")

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(running.id, agent.uid, %{
               "status" => "running"
             })

    assert {:ok, %{delegation: running_stopped, command_event: %ActorEvent{} = stop_event}} =
             SubagentDelegations.request_stop(running.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "agent:#{agent.uid}",
               "reason" => "Changed priorities",
               "request_id" => "stop-running-once"
             })

    assert running_stopped.status == "stopped"
    assert %DateTime{} = running_stopped.completed_at
    assert running_stopped.metadata["cancel_requested_by"] == "agent:#{agent.uid}"
    assert running_stopped.metadata["cancel_reason"] == "Changed priorities"
    assert stop_event.type == "command.stop"
    assert stop_event.session_id == "subagent:#{running.id}"
    assert get_in(stop_event.payload, ["data", "command", "argsText"]) == "Changed priorities"

    waiting = create_delegation!(agent.uid, "waiting-stop")

    assert {:ok, %{delegation: running_before_wait}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "running"
             })

    assert running_before_wait.status == "running"

    assert {:ok, %{delegation: waiting}} =
             SubagentDelegations.commit_status_with_wakeup(waiting.id, agent.uid, %{
               "status" => "waiting_on_user",
               "metadata" => %{"pending_user_input" => %{"questions" => []}}
             })

    assert {:ok, %{delegation: waiting_stopped, command_event: nil}} =
             SubagentDelegations.request_stop(waiting.id, %{
               "agent_uid" => agent.uid,
               "cancel_requested_by" => "operator:ding"
             })

    assert waiting_stopped.status == "stopped"

    refute Repo.exists?(
             from event in ActorEvent,
               where: event.session_id == ^"subagent:#{waiting.id}",
               where: event.type == "command.stop"
           )
  end

  test "steer journals text and answers and list visibility is bounded by parent session or channel" do
    %{principal: agent} = agent_fixture()
    same_session = create_delegation!(agent.uid, "same-session")
    same_channel = create_delegation!(agent.uid, "same-channel")
    other_channel = create_delegation!(agent.uid, "other-channel")

    from(row in Delegation, where: row.id == ^same_channel.id)
    |> Repo.update_all(
      set: [
        session_id: "historical-session",
        reply_route: %{"binding_name" => "lark", "signal_channel_id" => "chat-same-session"}
      ]
    )

    assert {:ok, %{delegation: ^same_session, command_event: %ActorEvent{} = steer_event}} =
             SubagentDelegations.request_steer(same_session.id, %{
               "agent_uid" => agent.uid,
               "text" => "Use the operator audience.",
               "answers" => %{"audience" => "Operators"},
               "request_id" => "steer-same-session"
             })

    assert steer_event.type == "command.steer"

    assert get_in(steer_event.payload, ["data", "command", "argsText"]) ==
             "Use the operator audience."

    assert get_in(steer_event.payload, ["data", "command", "answers"]) == %{
             "audience" => "Operators"
           }

    listed =
      SubagentDelegations.list_for_channel(
        agent.uid,
        same_session.session_id,
        "chat-same-session"
      )

    assert Enum.map(listed, & &1.id) |> MapSet.new() ==
             MapSet.new([same_session.id, same_channel.id])

    refute Enum.any?(listed, &(&1.id == other_channel.id))
  end

  test "status commits reject missing status and lifecycle regression" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "status-transition")

    assert {:ok, %{delegation: running}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "running"
             })

    assert {:error, :subagent_delegation_status_missing} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "metadata" => %{"ignored" => true}
             })

    assert {:error, {:invalid_subagent_status_transition, "running", "queued"}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "queued"
             })

    assert Repo.get!(Delegation, delegation.id).status == running.status
  end

  test "parent wakeup summaries are bounded to 16KB of valid UTF-8" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "bounded-wakeup")

    assert {:ok, %{delegation: _running}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "running"
             })

    assert {:ok, %{wakeup_event: wakeup}} =
             SubagentDelegations.commit_status_with_wakeup(delegation.id, agent.uid, %{
               "status" => "succeeded",
               "result" => %{"summary" => String.duplicate("大", 20_000)}
             })

    summary = get_in(wakeup.payload, ["data", "result_summary"])
    assert String.valid?(summary)
    assert byte_size(summary) <= 16_384
    assert String.ends_with?(summary, "...[truncated]")
  end

  test "trajectory payloads are redacted before the durable 16KB bound is applied" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "bounded-audit")
    secret = "sk-secret-that-must-never-reappear"

    assert {:ok, event} =
             SubagentDelegations.append_event(%{
               "agent_uid" => agent.uid,
               "delegation_id" => delegation.id,
               "seq" => 0,
               "direction" => "server_to_client",
               "event_type" => "large_json_rpc",
               "payload" => %{
                 "authorization" => secret,
                 "message" => %{"delta" => String.duplicate("大", 20_000)}
               }
             })

    assert event.payload["truncated"] == true
    assert event.payload["original_bytes"] > 16_384
    assert byte_size(Ankole.JSON.encode!(event.payload)) <= 16_384
    refute inspect(event.payload, limit: :infinity, printable_limit: :infinity) =~ secret
    assert event.payload["preview_json"] =~ "[REDACTED:sha256="
    assert event.redaction["payload_truncated"] == true
    assert event.redaction["redacted_paths"] == ["$.authorization"]
  end

  test "trajectory batches reject more than twenty events at the durable boundary" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "bounded-batch")

    events =
      for seq <- 0..20 do
        %{
          "seq" => seq,
          "direction" => "process",
          "event_type" => "batch-test",
          "payload" => %{"seq" => seq}
        }
      end

    assert {:error, :subagent_event_batch_too_large} =
             SubagentDelegations.append_events(delegation.id, agent.uid, events)

    assert SubagentDelegations.list_events(delegation.id) == []
  end

  test "trajectory sequence retries are idempotent but divergent payloads are rejected" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "audit-sequence")

    attrs = %{
      "agent_uid" => agent.uid,
      "delegation_id" => delegation.id,
      "seq" => 0,
      "direction" => "process",
      "event_type" => "thread_started",
      "payload" => %{"thread_id" => "thread-1"}
    }

    assert {:ok, first} = SubagentDelegations.append_event(attrs)
    assert {:ok, retried} = SubagentDelegations.append_event(attrs)
    assert retried.id == first.id

    assert {:error, :subagent_event_sequence_conflict} =
             SubagentDelegations.append_event(
               put_in(attrs, ["payload", "thread_id"], "different-thread")
             )

    assert [%{id: id}] = SubagentDelegations.list_events(delegation.id)
    assert id == first.id
  end

  test "delegation summary derives bounded prior-attempt context from the audit journal" do
    %{principal: agent} = agent_fixture()
    delegation = create_delegation!(agent.uid, "attempt-history")

    from(row in Delegation, where: row.id == ^delegation.id)
    |> Repo.update_all(set: [attempts: 4])

    for {seq, attempt, event_type, summary} <- [
          {0, 1, "status_failed", "First attempt failed."},
          {1, 2, "thread_started", nil},
          {2, 2, "status_failed", "Second attempt failed."},
          {3, 3, "status_failed", "Third attempt failed."}
        ] do
      payload =
        %{"attempt" => attempt}
        |> then(fn payload ->
          if summary, do: Map.put(payload, "error", %{"summary" => summary}), else: payload
        end)

      assert {:ok, _event} =
               SubagentDelegations.append_event(%{
                 "agent_uid" => agent.uid,
                 "delegation_id" => delegation.id,
                 "seq" => seq,
                 "direction" => "process",
                 "event_type" => event_type,
                 "payload" => payload
               })
    end

    assert {:ok, %{last_event_seq: 3, attempt_history: history}} =
             SubagentDelegations.get_delegation_summary_for_agent(delegation.id, agent.uid)

    assert Enum.map(history, & &1.attempt) == [1, 2, 3]
    assert Enum.at(history, 1).event_types == ["status_failed", "thread_started"]
    assert Enum.at(history, 2).summary == "Third attempt failed."
  end

  defp create_delegation!(agent_uid, suffix) do
    assert {:ok, %{delegation: delegation}} =
             SubagentDelegations.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "session_id" => "parent-session-#{suffix}",
               "tool_call_id" => "tool-subagent-#{suffix}",
               "title" => "Delegation #{suffix}",
               "prompt" => "Complete the #{suffix} delegation.",
               "workdir" => "/workspace/user-files/subagent/#{suffix}",
               "reply_route" => %{
                 "binding_name" => "lark",
                 "signal_channel_id" => "chat-#{suffix}",
                 "provider_thread_id" => "thread-#{suffix}",
                 "source_entry_id" => "message-#{suffix}"
               }
             })

    delegation
  end
end
