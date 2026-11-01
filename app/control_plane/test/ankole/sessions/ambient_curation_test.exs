defmodule Ankole.Sessions.AmbientCurationTest do
  use Ankole.SessionsCase

  import Ecto.Query

  alias Ankole.BackgroundAgentJobs
  alias Ankole.Sessions.AmbientCuration
  alias Ankole.Sessions.AmbientJudgment
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Conversation, as: Channel

  @channel_id "lark:chat:group-a"

  setup do
    {:ok, now: DateTime.utc_now(:microsecond)}
  end

  defp ambient_event!(agent_uid, overrides, opts) do
    assert {:ok, %{signal: event}} =
             emit_entry(
               agent_uid,
               "bot",
               group_entry(Map.put_new(overrides, :provider_time, Keyword.fetch!(opts, :now))),
               opts
             )

    assert event.type == "im.message.may_intervene"
    event
  end

  defp record_judgment(agent_uid, signal_id, attrs) do
    event = Repo.get(Signal, signal_id)

    key = %{
      agent_uid: agent_uid,
      session_id: if(event, do: event.session_id, else: "missing-session")
    }

    attrs =
      attrs
      |> Map.put_new(:handoff_job_id, nil)
      |> Map.put_new(:asked_by_state, if(attrs[:asked_by_message_id], do: "accepted"))

    AmbientCuration.record_judgment(key, signal_id, attrs)
  end

  test "the judgment resource rejects contradictory routes and attribution before storage", %{
    now: now
  } do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)
    event = ambient_event!(agent.uid, %{provider_message_id: "invalid-judgment"}, now: now)

    base = %{
      signal_id: event.id,
      agent_uid: agent.uid,
      conversation_id: event.conversation_id,
      action: "NOOP",
      authority: "NONE"
    }

    for {changes, field} <- [
          {%{action: "unknown"}, "action"},
          {%{authority: "EXPLICIT_REQUEST"}, "authority"},
          {%{action: "HANDOFF"}, "handoff_job_id"},
          {%{handoff_job_id: 1}, "handoff_job_id"},
          {%{asked_by_state: "accepted"}, "asked_by_message_id"},
          {%{asked_by_state: "degraded", asked_by_message_id: Ecto.UUID.generate()},
           "asked_by_message_id"},
          {%{asked_by_message_id: Ecto.UUID.generate()}, "asked_by_message_id"},
          {%{asked_by_state: "unknown"}, "asked_by_state"}
        ] do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.create(AmbientJudgment, :record, Map.merge(base, changes))
               end)

      assert Enum.any?(Ankole.Ash.validation_details(error), &(&1.path == field))
      refute Repo.get(AmbientJudgment, event.id)
    end
  end

  test "a silent judgment persists the reason and advances the channel cursor", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-silent", text: "morning chatter"},
        now: now
      )

    assert {:ok, %{action: "NOOP", asked_by_state: nil, judged_until: judged_until}} =
             record_judgment(agent.uid, event.id, %{
               action: "NOOP",
               authority: "NONE",
               reason: "small talk between colleagues"
             })

    assert DateTime.compare(judged_until, now) == :eq

    judgment = Repo.get!(AmbientJudgment, event.id)
    assert judgment.action == "NOOP"
    assert judgment.authority == "NONE"
    assert judgment.reason == "small talk between colleagues"
    assert judgment.conversation_id == conversation_id()
    assert is_nil(judgment.asked_by_message_id)

    assert DateTime.compare(
             AmbientCuration.judged_until(agent.uid, event.conversation_id),
             now
           ) == :eq

    assert is_nil(Repo.get!(Signal, event.id).ambient_asked_message_id)
  end

  test "an accepted asked_by becomes the reply anchor", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-ask", text: "Bot, which benchmark should we use?"},
        now: now
      )

    assert {:ok, %{asked_by_state: "accepted"}} =
             record_judgment(agent.uid, event.id, %{
               action: "FOREGROUND_REPLY",
               authority: "NONE",
               reason: "Alice is asking the agent directly",
               asked_by_message_id: message_id("msg-ask")
             })

    reloaded = Repo.get!(Signal, event.id)
    assert reloaded.ambient_asked_message_id == message_id("msg-ask")
    assert Ankole.Signals.reply_anchor_provider_message_id(reloaded) == "msg-ask"

    assert Repo.get!(AmbientJudgment, event.id).asked_by_state == "accepted"
  end

  test "host deletion of an accepted asked_by preserves the judgment progress", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-removed-ask", text: "Bot, which benchmark should we use?"},
        now: now
      )

    assert {:ok, %{asked_by_state: "accepted"}} =
             record_judgment(agent.uid, event.id, %{
               action: "FOREGROUND_REPLY",
               authority: "NONE",
               reason: "Alice is asking the agent directly",
               asked_by_message_id: message_id("msg-removed-ask")
             })

    assert {:ok, %Ankole.Sessions.Run{}} =
             Ankole.Sessions.Admission.admit(
               %{agent_uid: agent.uid, session_id: event.session_id},
               event,
               now: now
             )

    judgment = Repo.get!(AmbientJudgment, event.id)
    cursor = AmbientCuration.judged_until(agent.uid, event.conversation_id)
    asked_id = judgment.asked_by_message_id

    authorization =
      Repo.get!(Signal, event.id)
      |> Map.take([:authorization_kind, :human_uid, :human_access_version])

    assert {:ok, _removed} =
             Ankole.Conversations.Observe.emit_entry_removed(
               Ankole.Signals.get_agent_binding!(agent.uid, "bot").id,
               lifecycle_entry(%{provider_message_id: "msg-removed-ask"}),
               now: DateTime.add(now, 1, :second)
             )

    refute Repo.get_by(Ankole.Conversations.Message, id: asked_id)
    updated = Repo.reload!(judgment)
    assert updated.asked_by_state == "degraded"
    assert updated.asked_by_message_id == nil
    assert updated.judged_until == judgment.judged_until
    assert updated.action == judgment.action
    assert updated.reason == judgment.reason
    assert AmbientCuration.judged_until(agent.uid, event.conversation_id) == cursor

    assert Repo.get!(Signal, event.id)
           |> Map.take([:authorization_kind, :human_uid, :human_access_version]) == authorization
  end

  test "asked_by degrades when the entry is not mirrored in the channel", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-real", text: "anyone?"},
        now: now
      )

    assert {:ok, %{asked_by_state: "degraded"}} =
             record_judgment(agent.uid, event.id, %{
               action: "FOREGROUND_REPLY",
               authority: "NONE",
               reason: "looks addressed",
               asked_by_message_id: message_id("msg-not-mirrored")
             })

    reloaded = Repo.get!(Signal, event.id)
    assert is_nil(reloaded.ambient_asked_message_id)
    assert Ankole.Signals.reply_anchor_provider_message_id(reloaded) == "msg-real"

    judgment = Repo.get!(AmbientJudgment, event.id)
    assert is_nil(judgment.asked_by_message_id)
    assert judgment.asked_by_state == "degraded"
  end

  test "a recognizer-degraded asked_by stays degraded even when the entry exists", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-stale", text: "old question"},
        now: now
      )

    assert {:ok, %{asked_by_state: "degraded"}} =
             record_judgment(agent.uid, event.id, %{
               action: "FOREGROUND_REPLY",
               authority: "NONE",
               reason: "asker is no longer the latest speaker",
               asked_by_message_id: message_id("msg-stale"),
               asked_by_state: "degraded"
             })

    assert is_nil(Repo.get!(Signal, event.id).ambient_asked_message_id)
  end

  test "a retried judgment returns the first canonical route and keeps the cursor monotonic", %{
    now: now
  } do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-retry", text: "retry me"},
        now: now
      )

    assert {:ok, _result} =
             record_judgment(agent.uid, event.id, %{
               action: "NOOP",
               authority: "NONE",
               reason: "first attempt"
             })

    assert {:ok, _result} =
             record_judgment(agent.uid, event.id, %{
               action: "FOREGROUND_REPLY",
               authority: "NONE",
               reason: "second attempt"
             })

    judgment = Repo.get!(AmbientJudgment, event.id)
    assert judgment.action == "NOOP"
    assert judgment.reason == "first attempt"

    assert DateTime.compare(
             AmbientCuration.judged_until(agent.uid, event.conversation_id),
             now
           ) == :eq
  end

  test "record_judgment rejects unknown events and foreign agents", %{now: now} do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-guard", text: "guard case"},
        now: now
      )

    assert {:error, :signal_not_found} =
             record_judgment(agent.uid, Ecto.UUID.generate(), %{
               action: "NOOP",
               authority: "NONE"
             })

    assert {:error, :signal_agent_mismatch} =
             record_judgment(other_agent.uid, event.id, %{action: "NOOP", authority: "NONE"})
  end

  test "judgment cannot lock an event from another Session", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)
    event = ambient_event!(agent.uid, %{text: "Which benchmark?"}, now: now)

    assert {:error, :ambient_event_unavailable} =
             AmbientCuration.record_judgment(
               %{agent_uid: agent.uid, session_id: "another-session"},
               event.id,
               %{action: "NOOP", authority: "NONE", handoff_job_id: nil}
             )

    assert is_nil(Repo.get(AmbientJudgment, event.id))
    assert is_nil(AmbientCuration.judged_until(agent.uid, event.conversation_id))
  end

  test "new routes persist action and authority without starting work", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-new-work", text: "This investigation may be useful."},
        now: now
      )

    assert {:ok, %{action: "NEW_WORK", authority: "NONE", handoff_job_id: nil}} =
             record_judgment(agent.uid, event.id, %{
               action: "NEW_WORK",
               authority: "NONE",
               reason: "A concrete task exists but no one assigned it."
             })

    judgment = Repo.get!(AmbientJudgment, event.id)
    assert judgment.action == "NEW_WORK"
    assert judgment.authority == "NONE"

    refute Repo.exists?(from row in Signal, where: row.type == "background_agent_job.dispatch")
  end

  test "explicit-request authority requires an accepted human row from this batch", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    current =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-current-request", text: "Please investigate this failure."},
        now: now
      )

    assert {:ok,
            %{
              action: "NEW_WORK",
              authority: "EXPLICIT_REQUEST",
              asked_by_state: "accepted"
            }} =
             record_judgment(agent.uid, current.id, %{
               action: "NEW_WORK",
               authority: "EXPLICIT_REQUEST",
               asked_by_message_id: message_id("msg-current-request"),
               reason: "The current human message assigns the work."
             })

    later = DateTime.add(now, 30, :second)

    next =
      ambient_event!(
        agent.uid,
        %{
          provider_message_id: "msg-next-request",
          text: "A later unrelated message.",
          provider_time: later
        },
        now: later
      )

    assert {:ok, %{action: "NEW_WORK", authority: "NONE", asked_by_state: "degraded"}} =
             record_judgment(
               agent.uid,
               next.id,
               %{
                 action: "NEW_WORK",
                 authority: "EXPLICIT_REQUEST",
                 asked_by_message_id: message_id("msg-current-request"),
                 reason: "The proposed requester is only in channel history."
               }
             )

    assert Repo.get!(AmbientJudgment, next.id).authority == "NONE"
  end

  test "standing-order authority requires the current channel text to match the event snapshot",
       %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    ambient_event!(
      agent.uid,
      %{provider_message_id: "msg-orders-seed", text: "seed the channel"},
      now: now
    )

    assert {:ok, %{orders: "Investigate every failed deploy."}} =
             AmbientCuration.put_conversation_standing_orders(
               conversation_id(),
               "Investigate every failed deploy.",
               "operator"
             )

    unchanged_at = DateTime.add(now, 30, :second)

    unchanged =
      ambient_event!(
        agent.uid,
        %{
          provider_message_id: "msg-orders-current",
          text: "The deploy failed.",
          provider_time: unchanged_at
        },
        now: unchanged_at
      )

    assert {:ok, %{action: "NEW_WORK", authority: "STANDING_ORDER"}} =
             record_judgment(
               agent.uid,
               unchanged.id,
               %{
                 action: "NEW_WORK",
                 authority: "STANDING_ORDER",
                 reason: "The unchanged order authorizes this investigation."
               }
             )

    changed_at = DateTime.add(now, 60, :second)

    changed =
      ambient_event!(
        agent.uid,
        %{
          provider_message_id: "msg-orders-stale",
          text: "A second deploy failed.",
          provider_time: changed_at
        },
        now: changed_at
      )

    assert changed.data["channel"]["standing_orders"] ==
             "Investigate every failed deploy."

    assert {:ok, %{orders: "Only report failed deploys."}} =
             AmbientCuration.put_conversation_standing_orders(
               conversation_id(),
               "Only report failed deploys.",
               "operator"
             )

    assert {:ok, %{action: "NEW_WORK", authority: "NONE"}} =
             record_judgment(
               agent.uid,
               changed.id,
               %{
                 action: "NEW_WORK",
                 authority: "STANDING_ORDER",
                 reason: "The model saw the superseded standing order."
               }
             )

    assert Repo.get!(AmbientJudgment, changed.id).authority == "NONE"
  end

  test "HANDOFF prelocks one target, appends one steer, and keeps the canonical target", %{
    now: now
  } do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-handoff", text: "The failed pod reports a database timeout."},
        now: now
      )

    job = create_job!(agent.uid, event, "handoff")

    Ankole.SessionsCase.stub_driver(%{
      agent_uid: agent.uid,
      session_id: BackgroundAgentJobs.job_session_id(job.id)
    })

    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:ankole, :repo, :query],
        fn _event, _measurements, metadata, target ->
          if self() == target and is_binary(metadata.query) do
            send(target, {handler_id, metadata.query})
          end
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{action: "HANDOFF", authority: "NONE", handoff_job_id: handoff_job_id}} =
             record_judgment(agent.uid, event.id, %{
               action: "HANDOFF",
               authority: "NONE",
               handoff_job_id: job.id,
               reason: "The message updates the active deploy investigation."
             })

    :ok = :telemetry.detach(handler_id)
    queries = collect_queries(handler_id)

    assert [job_lock_index] =
             queries
             |> Enum.with_index()
             |> Enum.flat_map(fn {query, index} ->
               if String.contains?(query, ~s(FROM "background_agent_jobs")) and
                    String.contains?(query, "FOR UPDATE"),
                  do: [index],
                  else: []
             end)

    owner_session_lock_index =
      Enum.find_index(queries, &String.contains?(&1, "pg_advisory_xact_lock"))

    assert is_integer(owner_session_lock_index)
    assert job_lock_index < owner_session_lock_index

    assert handoff_job_id == job.id
    assert Repo.get!(AmbientJudgment, event.id).handoff_job_id == job.id

    assert [steer] =
             Repo.all(
               from row in Signal,
                 where:
                   row.type == "command.steer" and
                     row.session_id == ^BackgroundAgentJobs.job_session_id(job.id)
             )

    handoff_text = get_in(steer.data, ["command", "argsText"])

    assert :ok =
             Ankole.Sessions.Jobs.EnsureDriver.run(%Oban.Job{
               args: %{"agent_uid" => agent.uid, "session_id" => steer.session_id}
             })

    assert_receive :reconcile_inbox
    assert handoff_text =~ "database timeout"
    refute handoff_text =~ "updates the active deploy investigation"

    other_job = create_job!(agent.uid, event, "other-handoff")

    assert {:ok, %{action: "HANDOFF", handoff_job_id: ^handoff_job_id}} =
             record_judgment(agent.uid, event.id, %{
               action: "HANDOFF",
               authority: "NONE",
               handoff_job_id: other_job.id,
               reason: "A retry selected another target."
             })

    missing_job_id = 2_147_483_647
    assert is_nil(BackgroundAgentJobs.get_job(missing_job_id))

    assert {:ok, %{action: "HANDOFF", handoff_job_id: ^handoff_job_id}} =
             record_judgment(agent.uid, event.id, %{
               action: "HANDOFF",
               authority: "NONE",
               handoff_job_id: missing_job_id,
               reason: "A retry selected a missing target."
             })

    refute_receive {:inbox, _}, 20

    assert 1 ==
             Repo.aggregate(
               from(row in Signal, where: row.type == "command.steer"),
               :count
             )
  end

  test "the next ambient batch shows judged rows as backdrop, not delta", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    first =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-old", text: "old question"},
        now: now
      )

    assert {:ok, _result} =
             record_judgment(agent.uid, first.id, %{
               action: "NOOP",
               authority: "NONE",
               reason: "nothing owed"
             })

    later = DateTime.add(now, 60, :second)

    second =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-new", text: "new question", provider_time: later},
        now: later
      )

    delta_ids =
      second.data["observed_messages"] |> Enum.map(& &1["provider_message_id"])

    backdrop_ids =
      second.data["backdrop_messages"] |> Enum.map(& &1["provider_message_id"])

    assert "msg-new" in delta_ids
    refute "msg-old" in delta_ids
    assert "msg-old" in backdrop_ids
  end

  defp create_job!(agent_uid, event, suffix) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
               "agent_uid" => agent_uid,
               "owner_session_id" => event.session_id,
               "source_tool_call_id" => "ambient-job-#{suffix}",
               "title" => "Investigate deploy failure",
               "task" => "Find the cause of the failed production deploy.",
               "reply_route" => %{
                 "binding_name" => event.reply_binding_name,
                 "conversation_id" => event.conversation_id,
                 "provider_thread_id" => event.provider_thread_id,
                 "provider_message_id" => event.provider_message_id
               }
             })

    job
  end

  defp collect_queries(handler_id, queries \\ []) do
    receive do
      {^handler_id, query} -> collect_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  test "standing orders set from a turn record the asking author and activation", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-orders", text: "only speak when CI turns red"},
        now: now
      )

    assert {:ok, %{orders: "Only speak when CI turns red.", set_by: "Alice", active: true}} =
             AmbientCuration.set_standing_orders(
               agent.uid,
               event.id,
               "Only speak when CI turns red."
             )

    channel = Repo.get_by!(Channel, id: conversation_id())
    assert channel.ambient_standing_orders == "Only speak when CI turns red."
    assert channel.ambient_standing_orders_set_by == "Alice"

    assert {:ok, %{orders: nil, active: false}} =
             AmbientCuration.set_standing_orders(agent.uid, event.id, "   ")

    assert is_nil(Repo.get_by!(Channel, id: conversation_id()).ambient_standing_orders)

    too_long = String.duplicate("a", 4_001)

    assert {:error, :standing_orders_too_long} =
             AmbientCuration.set_standing_orders(agent.uid, event.id, too_long)
  end

  test "active standing orders travel in may_intervene envelope payloads", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    ambient_event!(
      agent.uid,
      %{provider_message_id: "msg-seed", text: "seed the channel"},
      now: now
    )

    assert {:ok, %{orders: "Post a daily summary at 18:00."}} =
             AmbientCuration.put_conversation_standing_orders(
               conversation_id(),
               "Post a daily summary at 18:00.",
               "operator"
             )

    later = DateTime.add(now, 30, :second)

    event =
      ambient_event!(
        agent.uid,
        %{provider_message_id: "msg-after-orders", text: "another message", provider_time: later},
        now: later
      )

    assert event.data["channel"]["standing_orders"] ==
             "Post a daily summary at 18:00."
  end

  test "console standing orders round-trip by channel id", %{now: now} do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    ambient_event!(
      agent.uid,
      %{provider_message_id: "msg-console", text: "seed"},
      now: now
    )

    assert {:error, :channel_not_found} =
             AmbientCuration.conversation_standing_orders("lark:chat:missing")

    assert {:ok, %{orders: nil}} = AmbientCuration.conversation_standing_orders(conversation_id())

    assert {:ok, %{orders: "Escalate incidents only.", set_by: "operator"}} =
             AmbientCuration.put_conversation_standing_orders(
               conversation_id(),
               "Escalate incidents only.",
               "operator"
             )

    id = conversation_id()

    assert {:ok, %{orders: "Escalate incidents only.", conversation_id: ^id}} =
             AmbientCuration.conversation_standing_orders(conversation_id())
  end

  defp conversation_id do
    Ankole.Conversations.External.get_conversation(@channel_id).id
  end

  defp message_id(provider_id) do
    case Ankole.Conversations.External.get_message(conversation_id(), provider_id) do
      %{message: message} ->
        message.id

      nil ->
        key = {:ambient_message, provider_id}

        Process.get(key) ||
          (
            id = Ecto.UUID.generate()
            Process.put(key, id)
            id
          )
    end
  end
end
