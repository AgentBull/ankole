defmodule Ankole.Conversations.RetryCommandTest do
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.ResponseChain
  use Ankole.SignalsGateway.ActorRuntimeCase
  alias Ankole.Conversations.{Admission, Commands, Model, Receipts, Run}

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  setup do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    %{agent: agent}
  end

  test "reply retry replays its cron dead letter instead of a channel completion", %{agent: agent} do
    unrelated = input(agent, "Unrelated channel work")
    session_id = "cron:#{Ecto.UUID.generate()}"

    {:ok, source} =
      Repo.transact(fn repo ->
        SignalsGateway.append_actor_event_in_tx(repo, %{
          agent_uid: agent.uid,
          binding_name: "bot",
          session_id: session_id,
          source_event_id: "cron-fire-#{Ecto.UUID.generate()}",
          signal_channel_id: unrelated.signal_channel_id,
          provider_thread_id: "scheduled-thread",
          ambient_asked_source_entry_id: "scheduled-anchor",
          type: "cron.fire",
          available_at: @base_time,
          sender_key: "system:cron",
          payload: %{
            "id" => "cron-payload",
            "type" => "cron.fire",
            "time" => DateTime.to_iso8601(@base_time),
            "data" => %{"wake_payload" => %{"delivery" => %{"targets" => []}}}
          }
        })
      end)

    {:ok, notice} =
      Repo.transact(fn repo ->
        {:ok, source} =
          Actors.mark_event_dead_letter_in_tx(repo, source, @base_time, "cron_failed")

        Ankole.SignalsGateway.Outbox.commit_dead_letter_notice_outbox_in_tx(
          repo,
          source,
          "Cron failed"
        )
      end)

    complete_input(unrelated)
    dispatch(notice, "provider-cron-failure")

    {:ok, %{actor_event: command}} =
      emit_entry(
        agent.uid,
        "bot",
        group_entry(%{
          source_entry_id: "retry-command-entry",
          provider_thread_id: "command-thread",
          reply_to_source_entry_id: "provider-cron-failure",
          text: "/retry",
          explicit: true
        }),
        now: DateTime.add(@base_time, 4)
      )

    assert command.session_id == session_id
    assert get_in(command.payload, ["data", "command", "targetActorEventId"]) == source.id
    assert {:ok, %ActorEvent{} = retry} = Commands.process(key(command), command)

    for field <-
          ~w(agent_uid binding_name session_id signal_channel_id provider_thread_id source_entry_id ambient_asked_source_entry_id type)a do
      assert Map.fetch!(retry, field) == Map.fetch!(source, field)
    end

    assert retry.input_state == "open"
    refute retry.completed_at
    refute retry.dead_letter_at
    refute retry.final_response_id
    assert retry.sender_key == command.sender_key
    assert retry.payload["time"] == DateTime.to_iso8601(retry.available_at)
    assert retry.payload["data"]["wake_payload"] == source.payload["data"]["wake_payload"]
    assert Repo.reload!(source).input_state == "dead_letter"
    assert Repo.reload!(unrelated).completed_at
    assert_delete(command, "provider-cron-failure")
  end

  test "retry replays a request and its attachment after pre-conversation failure", %{
    agent: _agent
  } do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)

    source =
      input(agent, "Inspect this", %{
        attachments: [%{provider_ref: "lark:file:1", name: "evidence.pdf"}]
      })

    assert {:ok, %{status: :model_profile_unavailable, notice_outbox: notice}} =
             Admission.admit(key(source), source, now: DateTime.add(@base_time, 20))

    dispatch(notice, "profile-failure")
    command = targeted_retry(agent, source.id)
    assert {:ok, retry} = Commands.process(key(command), command)
    assert retry.payload["data"]["entry"]["text"] == "Inspect this"

    assert [%{"name" => "evidence.pdf", "provider_ref" => "lark:file:1", "attachment_id" => id}] =
             retry.payload["data"]["entry"]["attachments"]

    assert id >= 10_000
    assert_delete(command, "profile-failure")
  end

  test "reply retry retains an addressed request that quotes an unmirrored group entry", %{
    agent: agent
  } do
    quoted_source_id = "unaddressed-quote"
    quoted_text = "The delivery code is QUOTE-630213."

    assert {:ok, %{status: :ignored}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_entry_id: quoted_source_id,
                 text: quoted_text,
                 explicit: false
               }),
               now: @base_time
             )

    source =
      input(agent, "Use the code in the quoted message", %{
        reply_to_source_entry_id: quoted_source_id
      })

    refute Repo.get_by(Entry,
             signal_channel_id: source.signal_channel_id,
             source_entry_id: quoted_source_id
           )

    assert %{
             "resolution" => "resolved",
             "source_entry_id" => ^quoted_source_id,
             "text" => ^quoted_text
           } = get_in(source.payload, ["data", "entry", "reply_to"])

    {:ok, run} = Admission.admit(key(source), source, now: DateTime.add(@base_time, 31))
    assert {:ok, {:preparing, prepared}} = Model.prepare(run)
    assert Ankole.JSON.encode!(Model.request(prepared)["input"]) =~ quoted_text

    {:ok, response} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: prepared.conversation.id,
        round_state: prepared,
        metadata: %{"request_metadata" => Ankole.Conversations.Run.metadata(prepared)},
        request_items: prepared.input
      })

    completed = finish(prepared, response)

    visible_refs =
      Ankole.SignalsGateway.AIGatewayLink.visible_channel_context_refs(
        agent.uid,
        source.session_id
      )

    outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{completed.id}")
    dispatch(outbox, "quoted-request-reply")

    {:ok, %{actor_event: command}} =
      emit_entry(
        agent.uid,
        "bot",
        group_entry(%{
          source_entry_id: "quoted-request-retry",
          text: "/retry",
          reply_to_source_entry_id: "quoted-request-reply",
          explicit: true
        }),
        now: DateTime.add(@base_time, 40)
      )

    assert get_in(command.payload, ["data", "command", "targetActorEventId"]) == source.id
    assert {:ok, %ActorEvent{} = retry} = Commands.process(key(command), command)

    assert retry.payload["data"]["entry"]["reply_to"] ==
             source.payload["data"]["entry"]["reply_to"]

    assert_delete(command, "quoted-request-reply")
    assert Repo.reload!(completed).status == "retracted"
    assert MapSet.member?(visible_refs, {source.signal_channel_id, source.source_entry_id})
    refute MapSet.member?(visible_refs, {source.signal_channel_id, quoted_source_id})

    assert {:ok, replacement} = Admission.admit(key(retry), retry)
    assert {:ok, {:preparing, restored}} = Model.prepare(replacement)
    assert Ankole.JSON.encode!(Model.request(restored)["input"]) =~ quoted_text

    refute Repo.get_by(Entry,
             signal_channel_id: source.signal_channel_id,
             source_entry_id: quoted_source_id
           )
  end

  for {title, items, allowed?} <- [
        {"provider failure before output", [%{"role" => "user", "content" => "Original request"}],
         true},
        {"provider failure with a tool fragment",
         [
           %{
             "type" => "function_call",
             "call_id" => "send-1",
             "name" => "send_report",
             "arguments" => "{}"
           }
         ], false}
      ] do
    @items items
    @allowed allowed?
    test "targeted retry handles #{title} without losing the error response", %{agent: agent} do
      {source, run, response} = started(agent)

      {:ok, failed} =
        ResponseCommit.commit_error(response, @items, %{
          "code" => "upstream_response_failed",
          "retryable" => false
        })

      assert {:ok, _} = Run.finalize(run, :dead_letter, "provider_response")
      command = targeted_retry(agent, source.id)
      result = Commands.process(key(command), command)

      if @allowed do
        assert {:ok, %ActorEvent{} = retry} = result
        assert retry.id != source.id
        assert retry.payload["data"]["entry"]["retry_of_actor_event_id"] == source.id
      else
        assert {:ok, %{feedback: text}} = result
        assert text == Ankole.I18n.t("signals_gateway.reply.retry_target_unavailable")
        refute retry_for(command)
      end

      assert Repo.reload!(failed).status == "error"
      assert Repo.reload!(source).input_state == "dead_letter"
    end
  end

  test "retry deletes the dead-letter card and preserves its failed Response", %{agent: agent} do
    {source, run, response} = started(agent)

    source =
      Repo.update!(
        ActorEvent.changeset(source, %{reply_preview_source_entry_id: "dead-letter-preview"})
      )

    {:ok, failed} =
      ResponseCommit.commit_error(
        response,
        [
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "Partial"}]
          }
        ],
        %{"code" => "provider_failed"}
      )

    assert {:ok, _} = Run.finalize(%{run | event: source}, :dead_letter, "provider_failed")
    command = targeted_retry(agent, source.id)
    assert {:ok, %ActorEvent{}} = Commands.process(key(command), command)
    assert_delete(command, "dead-letter-preview")
    assert Repo.reload!(failed).status == "error"
    assert Repo.reload!(source).input_state == "dead_letter"
    assert {:ok, :already_consumed} = Commands.process(key(command), command)

    assert Repo.aggregate(
             from(e in ActorEvent, where: e.source_event_id == ^"retry:#{command.id}"),
             :count
           ) == 1
  end

  test "a completed applied steer cannot be replayed without a Response anchor", %{agent: agent} do
    source = input(agent, "/steer Use the correction")
    complete_input(source)
    assert_unavailable(agent, source)
  end

  test "a standalone dead-letter steer can be retried", %{agent: agent} do
    source = input(agent, "/steer Use the correction")

    {:ok, source} =
      Repo.transact(fn repo ->
        Actors.mark_event_dead_letter_in_tx(repo, source, @base_time, "steer_failed")
      end)

    command = targeted_retry(agent, source.id)
    assert {:ok, retry} = Commands.process(key(command), command)
    assert retry.type == "command.steer"
    assert retry.sender_key == command.sender_key
  end

  test "retry does not revive a withdrawn dead-letter request", %{agent: agent} do
    {source, run, _response} = started(agent)
    assert {:ok, _} = Run.finalize(run, :dead_letter, "provider_failed")

    assert {:ok, _} =
             Repo.transact(fn _repo ->
               Ingress.emit_entry_removed(
                 agent.uid,
                 "bot",
                 lifecycle_entry(%{
                   source_event_id: "removed",
                   source_entry_id: source.source_entry_id,
                   signal_channel_id: source.signal_channel_id
                 }),
                 now: DateTime.add(@base_time, 3)
               )
             end)

    refute Repo.get_by(Entry,
             signal_channel_id: source.signal_channel_id,
             source_entry_id: source.source_entry_id
           )

    assert_unavailable(agent, source)
  end

  test "idle bare retry is consumed with visible feedback", %{agent: agent} do
    command = input(agent, "/retry")
    assert {:ok, %{feedback: text}} = Commands.process(key(command), command)
    assert text == Ankole.I18n.t("signals_gateway.reply.retry_target_required")
    assert Repo.reload!(command).completed_at
    assert Repo.get_by!(OutboxEntry, source_actor_event_id: command.id).payload["text"] == text
    refute retry_for(command)
  end

  test "a failed bare retry does not stale a later exact retry", %{agent: agent} do
    source = input(agent, "Retry this exact request")
    complete_input(source)
    bare = input(agent, "/retry")
    assert {:ok, %{feedback: text}} = Commands.process(key(bare), bare)
    assert text == Ankole.I18n.t("signals_gateway.reply.retry_target_required")
    command = targeted_retry(agent, source.id)
    assert {:ok, retry} = Commands.process(key(command), command)
    assert retry.session_id == source.session_id
    assert retry.payload["data"]["entry"]["retry_of_actor_event_id"] == source.id
  end

  test "retry does not cross an empty new-conversation boundary", %{agent: agent} do
    {source, run, response} = started(agent)
    finish(run, response)
    new = input(agent, "/new")
    assert {:ok, %{status: :command_consumed}} = Commands.process(key(new), new)
    assert_unavailable(agent, source)
  end

  test "an exact retry never substitutes a newer terminal input", %{agent: agent} do
    {source, run, response} = started(agent)
    finish(run, response)
    latest = input(agent, "Latest request")
    complete_input(latest)
    assert_unavailable(agent, source)
    assert Repo.reload!(latest).completed_at
  end

  test "bare retry without calls retracts generation and restarts the original input", %{
    agent: agent
  } do
    {source, run, response} = started(agent)
    source = Repo.reload!(source)

    {:ok, source} =
      Repo.update(
        ActorEvent.changeset(source, %{
          provider_capacity_attempt_count: source.attempt_count,
          available_at: DateTime.add(DateTime.utc_now(:microsecond), 600)
        })
      )

    command = input(agent, "/retry")
    assert {:ok, :interrupt} = Commands.retry_action(run, command)
    assert {:ok, :retry} = Commands.interrupt(run, command)
    assert Repo.reload!(response).status == "retracted"
    assert Repo.reload!(command).completed_at
    assert Repo.reload!(source).attempt_count == 0
    assert Repo.reload!(source).provider_capacity_attempt_count == 0

    assert DateTime.compare(Repo.reload!(source).available_at, DateTime.utc_now(:microsecond)) ==
             :lt

    refute Repo.reload!(source).last_attempt_at
    refute Repo.reload!(source).completed_at
    refute retry_for(command)
  end

  test "bare retry sees committed calls before the Driver sees the model terminal message", %{
    agent: agent
  } do
    {source, run, response} = started(agent)

    calls =
      for id <- ["committed", "interrupted"],
          do: %{
            "type" => "function_call",
            "call_id" => id,
            "name" => "command",
            "arguments" => "{}"
          }

    {:ok, called} = ResponseCommit.commit_complete(response, calls)

    # The unit receipt boundary supplies the durable result of a domain effect.
    assert {:ok, _} =
             Receipts.execute(run, "resp_#{called.id}", "committed", fn _repo ->
               {:ok, %Ankole.Conversations.ToolResult{output: "Committed once"}, []}
             end)

    command = input(agent, "/retry")
    assert {:ok, %Run{}} = Commands.interrupt(run, command)
    assert Repo.reload!(called).status == "complete"
    assert Repo.reload!(command).last_attempt_at
    refute Repo.reload!(command).completed_at
    assert Repo.reload!(source).attempt_count == 1

    {:ok, replacement} = Admission.admit(key(source), Repo.reload!(source))
    assert {:ok, {:boundary, restored}} = Model.prepare(replacement)
    assert restored.calls == []
    assert command.id in restored.pending_event_ids
    assert Commands.injectable?(Repo.reload!(command))
    assert {:ok, :continue} = Commands.retry_action(restored, Repo.reload!(command))
    journal = Repo.get!(Message, restored.anchor)
    text = Ankole.JSON.encode!(journal.content)
    assert text =~ "Committed once"
    assert text =~ "Tool execution was interrupted"
    assert {:ok, [command]} = Run.inject(restored, [command])
    restored = %{restored | steer_event_ids: [command.id]}

    {:ok, final} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: restored.conversation.id,
        round_state: restored,
        metadata: %{"request_metadata" => Ankole.Conversations.Run.metadata(restored)}
      })

    finish(restored, final)
    assert Repo.reload!(command).completed_at
    assert Repo.reload!(source).completed_at
    assert Repo.reload!(called).status == "complete"

    assert Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{final.id}").source_actor_event_id ==
             source.id
  end

  test "bare retry restores one failure and retains the attempt cache and span", %{agent: agent} do
    {source, run, response} = started(agent)

    call = %{
      "type" => "function_call",
      "call_id" => "failed",
      "name" => "command",
      "arguments" => "{}"
    }

    {:ok, _} = ResponseCommit.commit_complete(response, [call])
    {:ok, {:executing_tools, run}} = Run.restore(run)

    failure = %Ankole.Conversations.ToolResult{
      output: "Provider failed",
      is_error: true,
      failure_kind: "provider_failed"
    }

    {:ok, _} = Run.record_round(%{run | results: %{"failed" => failure}})
    {:ok, {:boundary, run}} = Run.restore(run)
    assert {_, 1} = run.repeated_failure

    run = %{
      run
      | web_cache: %{"https://example.test/page" => %{text: "Cached page"}},
        span: %{id: "attempt-span"}
    }

    command = input(agent, "/retry")
    assert {:ok, %Run{} = reset} = Commands.interrupt(run, command)
    assert {:ok, {:boundary, restored}} = Model.prepare(reset)
    assert {_, 1} = restored.repeated_failure
    assert restored.web_cache == run.web_cache
    assert restored.span == run.span
    assert restored.epoch == run.epoch
    assert restored.event.attempt_count == run.event.attempt_count
    assert Repo.reload!(source).attempt_count == run.event.attempt_count
    assert command.id in restored.pending_event_ids
  end

  test "targeted retry keeps committed tool results and deletes the old reply", %{agent: agent} do
    {source, run, response} = started(agent)

    call = %{
      "type" => "function_call",
      "call_id" => "committed",
      "name" => "command",
      "arguments" => "{}"
    }

    {:ok, called} = ResponseCommit.commit_complete(response, [call])
    assert {:ok, {:executing_tools, run}} = Model.prepare(run)

    # This unit receipt boundary supplies the result of a committed domain effect.
    result = %Ankole.Conversations.ToolResult{output: "Committed once"}

    assert {:ok, _} =
             Receipts.execute(run, "resp_#{called.id}", "committed", fn _repo ->
               {:ok, result, []}
             end)

    assert {:ok, journal} = Run.record_round(%{run | results: %{"committed" => result}})

    {:ok, answer} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: run.conversation.id,
        expected_previous_response_id: Run.response_id(journal.message),
        round_state: run,
        metadata: %{"request_metadata" => Ankole.Conversations.Run.metadata(run)}
      })

    completed = finish(%{run | calls: [], model_response: nil}, answer)
    outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{completed.id}")
    dispatch(outbox, "completed-tool-reply")

    command = targeted_retry(agent, source.id)
    assert {:ok, %ActorEvent{} = retry} = Commands.process(key(command), command)
    box = assert_delete(command, "completed-tool-reply")
    assert box.ai_message_id == completed.id

    assert {:ok, _} =
             SignalsGateway.dispatch_outbox(
               box.agent_uid,
               box.binding_name,
               box.outbound_key,
               outbox_adapter([:delete_entry], fn _ -> {:ok, %{}} end)
             )

    refute Repo.get_by(Entry,
             signal_channel_id: source.signal_channel_id,
             source_entry_id: "completed-tool-reply"
           )

    for row <- [called, journal.message, completed],
        do: assert(Repo.reload!(row).status == "complete")

    assert ResponseChain.latest_visible_leaf(run.conversation.id) == completed.id
    {:ok, replacement} = Admission.admit(key(retry), retry)
    assert {:ok, {:preparing, restored}} = Model.prepare(replacement)
    assert restored.anchor == completed.id
    assert restored.calls == []
    assert Ankole.JSON.encode!(journal.message.content) =~ "Committed once"
    prompt = Ankole.JSON.encode!(Model.request(restored)["input"])
    assert prompt =~ "another answer"
    assert prompt =~ "Original request"
    assert prompt =~ "Do not repeat committed effects"

    {:ok, final} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: restored.conversation.id,
        expected_previous_response_id: Run.response_id(completed),
        round_state: restored,
        metadata: %{"request_metadata" => Ankole.Conversations.Run.metadata(restored)},
        request_items: restored.input
      })

    finish(restored, final)
    reply = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{final.id}")
    assert reply.source_actor_event_id == retry.id
    assert reply.operation == outbox.operation
    assert reply.target_source_entry_id == outbox.target_source_entry_id
    assert reply.provider_thread_id == outbox.provider_thread_id
    assert Repo.reload!(called).status == "complete"
    assert Repo.reload!(journal.message).status == "complete"
    assert {:ok, :already_consumed} = Commands.process(key(command), command)
  end

  test "retry retracts a completed answer and deletes its mirror before regeneration", %{
    agent: agent
  } do
    {source, run, response} = started(agent)
    completed = finish(run, response)

    outbox =
      Repo.get_by!(OutboxEntry,
        source_actor_event_id: source.id,
        delivery_class: :durable_ai_reply
      )

    dispatch(outbox, "completed-reply")
    command = targeted_retry(agent, source.id)
    assert {:ok, retry} = Commands.process(key(command), command)
    assert retry.payload["data"]["entry"]["text"] == "Original request"
    assert Repo.reload!(completed).status == "retracted"
    assert Repo.reload!(completed).metadata["retraction"]["reason"] == "command.retry"
    box = assert_delete(command, "completed-reply")
    assert box.ai_message_id == completed.id

    assert {:ok, _} =
             SignalsGateway.dispatch_outbox(
               box.agent_uid,
               box.binding_name,
               box.outbound_key,
               outbox_adapter([:delete_entry], fn _ -> {:ok, %{}} end)
             )

    refute Repo.get_by(Entry,
             signal_channel_id: source.signal_channel_id,
             source_entry_id: "completed-reply"
           )

    assert ResponseChain.latest_visible_leaf(run.conversation.id) == nil
  end

  defp input(agent, text, overrides \\ %{}) do
    id = Ecto.UUID.generate()

    {:ok, %{actor_event: event}} =
      emit_entry(
        agent.uid,
        "bot",
        group_entry(
          Map.merge(
            %{
              source_event_id: id,
              source_entry_id: id,
              text: text,
              explicit: true
            },
            overrides
          )
        ),
        now: DateTime.add(@base_time, 30)
      )

    event
  end

  defp started(agent) do
    event = input(agent, "Original request")
    {:ok, run} = Admission.admit(key(event), event, now: DateTime.add(@base_time, 31))

    {:ok, response} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: run.conversation.id,
        round_state: run,
        metadata: %{"request_metadata" => Ankole.Conversations.Run.metadata(run)},
        request_items: [%{"type" => "message", "role" => "user", "content" => "Original request"}]
      })

    {event, run, response}
  end

  defp finish(run, response) do
    {:ok, completed} =
      ResponseCommit.commit_complete(response, [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "Original answer"}]
        }
      ])

    assert {:ok, _} = Run.finalize(%{run | anchor: completed.id})
    completed
  end

  defp complete_input(input),
    do:
      Repo.transact(fn repo ->
        Actors.complete_actor_event_in_tx(repo, input, completed_at: @base_time)
      end)

  defp key(event), do: %{agent_uid: event.agent_uid, session_id: event.session_id}

  # This unit boundary supplies the target that Ingress resolves from a sent reply.
  defp targeted_retry(agent, target) do
    command = input(agent, "/retry")
    payload = put_in(command.payload, ["data", "command", "targetActorEventId"], target)
    Repo.update!(ActorEvent.changeset(command, %{payload: payload}))
  end

  defp assert_unavailable(agent, source) do
    command = targeted_retry(agent, source.id)
    assert {:ok, %{feedback: text}} = Commands.process(key(command), command)
    assert text == Ankole.I18n.t("signals_gateway.reply.retry_target_unavailable")
    refute retry_for(command)
  end

  defp retry_for(command), do: Repo.get_by(ActorEvent, source_event_id: "retry:#{command.id}")

  defp dispatch(box, source_id) do
    assert {:ok, %OutboxEntry{status: :succeeded}} =
             SignalsGateway.dispatch_outbox(
               box.agent_uid,
               box.binding_name,
               box.outbound_key,
               outbox_adapter([:post_entry, :reply_entry, :edit_entry, :card, :divider], fn _ ->
                 {:ok, %{created_source_entry_id: source_id}}
               end)
             )
  end

  defp assert_delete(command, source_id) do
    box = Repo.get_by!(OutboxEntry, source_actor_event_id: command.id, operation: :delete)
    assert box.target_source_entry_id == source_id
    box
  end
end
