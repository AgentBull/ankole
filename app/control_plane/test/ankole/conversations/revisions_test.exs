defmodule Ankole.Conversations.RevisionsTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.SignalsGateway.ActorRuntimeCase
  alias Ankole.Conversations.{Admission, Model, Revisions, Run}
  alias Ankole.SignalsGateway.InputRevisions

  setup do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    assert {:ok, %{actor_event: event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: "Keep this request", explicit: true}),
               now: @base_time
             )

    {:ok, agent: agent, event: event, key: %{agent_uid: agent.uid, session_id: event.session_id}}
  end

  for kind <- ["edit", "supplement"] do
    @kind kind
    test "#{kind} before any call replaces the request in the same attempt", %{
      event: event,
      key: key
    } do
      {:ok, run} = Admission.admit(key, event)
      {:ok, model} = response(run, [])
      entry = Map.put(event.payload["data"]["entry"], "text", "Updated request")
      revision = revision(run, event.id, @kind, entry)
      assert Revisions.immediate?(run, revision)
      assert {:ok, revised} = Revisions.apply(run, revision)
      assert revised.epoch == run.epoch
      assert revised.event.attempt_count == run.event.attempt_count
      assert Repo.get!(Message, model.id).status == "retracted"
      assert {:ok, {:preparing, prepared}} = Model.prepare(revised)
      assert Ankole.JSON.encode!(prepared.input) =~ "Updated request"
      refute Ankole.JSON.encode!(prepared.input) =~ "Keep this request"
    end

    test "#{kind} after a call stays ordinary input and preserves its tool history", %{
      event: event,
      key: key
    } do
      {:ok, run} = Admission.admit(key, event)
      {:ok, _} = response(run, [call()])
      {:ok, {:executing_tools, run}} = Run.restore(run)
      entry = Map.put(event.payload["data"]["entry"], "text", "Updated request")
      revision = revision(run, event.id, @kind, entry)
      refute Revisions.immediate?(run, revision)
      assert Repo.get!(Message, run.model_response.id).status == "complete"
      assert Repo.get!(ActorEvent, revision.id).completed_at == nil

      {:ok, _} =
        Run.record_round(%{
          run
          | results: %{"effect" => %Ankole.Conversations.ToolResult{output: "Committed once"}}
        })

      {:ok, {:boundary, run}} = Run.restore(run)
      {:ok, [revision]} = Run.inject(run, [revision])
      run = %{run | steer_event_ids: [revision.id]}
      {:ok, final} = response(run, [answer()])
      assert {:ok, result} = Run.finalize(%{run | anchor: final.id})
      assert [box] = result.outboxes.finals
      assert box.source_actor_event_id == event.id
      assert Repo.reload!(revision).completed_at
    end

    test "#{kind} with a pending attachment still records a later capacity failure", %{
      event: event,
      key: key
    } do
      {:ok, run} = Admission.admit(key, event)
      {:ok, _} = response(run, [])

      entry =
        event.payload["data"]["entry"]
        |> Map.put("metadata", %{"attachment_materialization" => %{"state" => "pending"}})

      revision = revision(run, event.id, @kind, entry)
      assert {:ok, revised} = Revisions.apply(run, revision)
      now = DateTime.utc_now(:microsecond)
      assert DateTime.compare(revised.event.available_at, now) == :gt
      error = %{"code" => "rate_limit_exceeded", "retryable" => true}
      assert {:ok, retried} = Run.defer_retry(revised, error, now)
      assert retried.provider_capacity_attempt_count == 1
      assert DateTime.diff(retried.available_at, now) == 30
      assert {:ok, ^retried} = Run.defer_retry(revised, error, now)

      assert {:ok, ^retried} =
               Run.defer_retry(revised, error, DateTime.add(retried.available_at, 1))
    end
  end

  test "a partially withdrawn request keeps recorded effects through Driver loss", %{
    event: event,
    key: key
  } do
    extra =
      event.payload["data"]["entry"]
      |> Map.put("source_entry_id", "withdrawn-part")
      |> Map.put("text", "Withdraw this part")

    assert {:ok, event} =
             Repo.transact(fn repo ->
               InputRevisions.revise_event_in_tx(repo, event, "supplement", extra, @base_time)
             end)

    {:ok, run} = Admission.admit(key, event)
    {:ok, model} = response(run, [call()])
    {:ok, {:executing_tools, run}} = Run.restore(run)

    {:ok, journal} =
      Run.record_round(%{
        run
        | results: %{"effect" => %Ankole.Conversations.ToolResult{output: "Committed once"}}
      })

    {:ok, {:boundary, run}} = Run.restore(run)
    revision = revision(run, event.id, "remove", extra)
    assert Revisions.immediate?(run, revision)
    assert {:ok, revised} = Revisions.apply(run, revision)
    assert {:ok, {:boundary, restored}} = Model.prepare(revised)
    assert restored.calls == []
    assert restored.anchor == journal.message.id
    assert revision.id in restored.pending_event_ids
    assert Repo.get!(Message, model.id).status == "complete"
    assert Repo.get!(Message, journal.message.id).status == "complete"
    assert revised.event.payload["data"]["entry"]["text"] == "Keep this request"

    assert {:ok, replacement} = Admission.admit(key, Repo.reload!(event))
    assert {:ok, {:boundary, restored}} = Model.prepare(replacement)
    assert restored.calls == []
    assert revision.id in restored.pending_event_ids
    assert {:ok, [revision]} = Run.inject(restored, [revision])
    {:ok, final} = response(%{restored | steer_event_ids: [revision.id]}, [answer()])
    assert {:ok, result} = Run.finalize(%{restored | anchor: final.id}, :loop_finished)
    assert result.final_text == "The remaining request is complete."
    assert Repo.reload!(revision).completed_at
    assert Repo.reload!(event).completed_at
    assert [box] = result.outboxes.finals
    assert box.source_actor_event_id == event.id
  end

  test "partial withdrawal restores one failure and retains the attempt cache and span", %{
    event: event,
    key: key
  } do
    extra =
      event.payload["data"]["entry"]
      |> Map.put("source_entry_id", "withdrawn-failed-part")
      |> Map.put("text", "Withdraw this part")

    {:ok, event} =
      Repo.transact(fn repo ->
        InputRevisions.revise_event_in_tx(repo, event, "supplement", extra, @base_time)
      end)

    {:ok, run} = Admission.admit(key, event)
    {:ok, _} = response(run, [call()])
    {:ok, {:executing_tools, run}} = Run.restore(run)

    failure = %Ankole.Conversations.ToolResult{
      output: "Provider failed",
      is_error: true,
      failure_kind: "provider_failed"
    }

    {:ok, _} = Run.record_round(%{run | results: %{"effect" => failure}})
    {:ok, {:boundary, run}} = Run.restore(run)
    assert {_, 1} = run.repeated_failure

    run = %{
      run
      | web_cache: %{"https://example.test/page" => %{text: "Cached page"}},
        span: %{id: "attempt-span"}
    }

    revision = revision(run, event.id, "remove", extra)
    assert Revisions.immediate?(run, revision)
    assert {:ok, revised} = Revisions.apply(run, revision)
    assert {:ok, {:boundary, restored}} = Model.prepare(revised)
    assert {_, 1} = restored.repeated_failure
    assert restored.web_cache == run.web_cache
    assert restored.span == run.span
    assert restored.epoch == run.epoch
    assert restored.event.attempt_count == run.event.attempt_count
    assert restored.event.last_attempt_at == run.event.last_attempt_at
    assert restored.event.payload["data"]["entry"]["text"] == "Keep this request"
  end

  test "withdrawal of an injected steer preserves effects and does not poison terminal input", %{
    event: event,
    key: key
  } do
    {:ok, run} = Admission.admit(key, event)

    {:ok, steer} =
      append_runtime_actor_event(key.agent_uid, key.session_id, "command.steer", now: @base_time)

    steer = Repo.update!(Ecto.Changeset.change(steer, source_entry_id: "withdrawn-steer"))
    {:ok, [steer]} = Run.inject(run, [steer])
    run = %{run | steer_event_ids: [steer.id]}
    {:ok, _} = response(run, [call()])
    {:ok, {:executing_tools, run}} = Run.restore(run)

    {:ok, _} =
      Run.record_round(%{
        run
        | results: %{"effect" => %Ankole.Conversations.ToolResult{output: "Committed once"}}
      })

    {:ok, {:boundary, run}} = Run.restore(run)
    revision = revision(run, steer.id, "remove", %{"source_entry_id" => "withdrawn-steer"})
    assert {:ok, _} = Revisions.apply(run, revision)
    refute Repo.get(ActorEvent, steer.id)
    {:ok, replacement} = Admission.admit(key, Repo.reload!(event))
    assert {:ok, {:boundary, restored}} = Model.prepare(replacement)
    refute steer.id in restored.steer_event_ids
    assert revision.id in restored.pending_event_ids
    {:ok, final} = response(%{restored | steer_event_ids: [revision.id]}, [answer()])
    assert {:ok, _} = Run.finalize(%{restored | anchor: final.id}, :loop_finished)
    assert Repo.reload!(event).completed_at
    assert Repo.reload!(revision).completed_at
  end

  test "recovery after retraction retains the full revised steer input", %{event: event, key: key} do
    {:ok, run} = Admission.admit(key, event)

    {:ok, steer} =
      append_runtime_actor_event(key.agent_uid, key.session_id, "command.steer", now: @base_time)

    steer =
      Repo.update!(
        Ecto.Changeset.change(steer,
          payload: %{
            "data" => %{"command" => %{"name" => "steer", "argsText" => "Original steer"}}
          },
          source_entry_id: "steer-source"
        )
      )

    {:ok, [steer]} = Run.inject(run, [steer])
    run = %{run | steer_event_ids: [steer.id]}
    {:ok, _} = response(run, [])
    entry = %{"source_entry_id" => "steer-source", "text" => "Revised steer"}
    revision = revision(run, steer.id, "edit", entry)
    assert {:ok, _} = Revisions.apply(run, revision)
    {:ok, replacement} = Admission.admit(key, Repo.reload!(event))
    assert {:ok, {:preparing, restored}} = Model.prepare(replacement)
    assert steer.id in restored.steer_event_ids
    assert Ankole.JSON.encode!(restored.input) =~ "Revised steer"
    refute Ankole.JSON.encode!(restored.input) =~ "Original steer"
  end

  defp response(run, items) do
    {:ok, response} =
      start_response_run(%{
        subject_uid: run.agent_uid,
        conversation_id: run.conversation.id,
        round_state: run,
        metadata: %{"request_metadata" => Ankole.Conversations.Run.metadata(run)}
      })

    ResponseCommit.commit_complete(response, items)
  end

  defp revision(run, id, kind, entry) do
    {:ok, revision} =
      Repo.transact(fn repo ->
        SignalsGateway.append_actor_event_in_tx(repo, %{
          source_work: run.event,
          agent_uid: run.agent_uid,
          session_id: run.session_id,
          binding_name: run.event.binding_name,
          source_event_id: Ecto.UUID.generate(),
          type: "input.revised",
          available_at: DateTime.utc_now(:microsecond),
          signal_channel_id: run.event.signal_channel_id,
          source_entry_id: entry["source_entry_id"],
          payload: %{
            "data" => %{
              "revision" => %{
                "actor_event_id" => id,
                "kind" => kind,
                "source_entry_id" => entry["source_entry_id"],
                "entry" => entry
              },
              "entry" => entry
            }
          }
        })
      end)

    revision
  end

  defp call,
    do: %{
      "type" => "function_call",
      "name" => "command",
      "call_id" => "effect",
      "arguments" => "{}",
      "status" => "completed"
    }

  defp answer,
    do: %{
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => "The remaining request is complete."}]
    }
end
