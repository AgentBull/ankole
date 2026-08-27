defmodule Ankole.SignalsGateway.AmbientCurationTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  import Ecto.Query

  alias Ankole.BackgroundAgentJobs
  alias Ankole.SignalsGateway.AmbientCuration
  alias Ankole.SignalsGateway.AmbientJudgment
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Channel

  @channel_id "lark:chat:group-a"

  defp ambient_event!(agent_uid, overrides, opts) do
    assert {:ok, %{actor_event: event}} =
             emit_entry(agent_uid, "bot", group_entry(overrides), opts)

    assert event.type == "im.message.may_intervene"
    event
  end

  defp record_judgment(agent_uid, actor_event_id, attrs, now \\ @base_time) do
    AmbientCuration.record_judgment(agent_uid, actor_event_id, attrs, now: now)
  end

  test "a silent judgment persists the reason and advances the channel cursor" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-silent", text: "morning chatter"},
        now: @base_time
      )

    assert {:ok, %{action: "NOOP", asked_by_state: nil, judged_until: judged_until}} =
             record_judgment(agent.uid, event.id, %{
               action: "NOOP",
               authority: "NONE",
               reason: "small talk between colleagues"
             })

    assert DateTime.compare(judged_until, @base_time) == :eq

    judgment = Repo.get!(AmbientJudgment, event.id)
    assert judgment.action == "NOOP"
    assert judgment.authority == "NONE"
    assert judgment.reason == "small talk between colleagues"
    assert judgment.signal_channel_id == @channel_id
    assert is_nil(judgment.asked_by_source_entry_id)

    channel = Repo.get!(Channel, @channel_id)
    assert DateTime.compare(channel.ambient_judged_until, @base_time) == :eq

    assert is_nil(Repo.get!(ActorEvent, event.id).ambient_asked_source_entry_id)
  end

  test "an accepted asked_by becomes the reply anchor" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-ask", text: "Bot, which benchmark should we use?"},
        now: @base_time
      )

    assert {:ok, %{asked_by_state: "accepted"}} =
             record_judgment(agent.uid, event.id, %{
               action: "FOREGROUND_REPLY",
               authority: "NONE",
               reason: "Alice is asking the agent directly",
               asked_by_source_entry_id: "msg-ask"
             })

    reloaded = Repo.get!(ActorEvent, event.id)
    assert reloaded.ambient_asked_source_entry_id == "msg-ask"
    assert ActorEvent.reply_anchor_source_entry_id(reloaded) == "msg-ask"

    assert Repo.get!(AmbientJudgment, event.id).asked_by_state == "accepted"
  end

  test "asked_by degrades when the entry is not mirrored in the channel" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-real", text: "anyone?"},
        now: @base_time
      )

    assert {:ok, %{asked_by_state: "degraded"}} =
             record_judgment(agent.uid, event.id, %{
               action: "FOREGROUND_REPLY",
               authority: "NONE",
               reason: "looks addressed",
               asked_by_source_entry_id: "msg-not-mirrored"
             })

    reloaded = Repo.get!(ActorEvent, event.id)
    assert is_nil(reloaded.ambient_asked_source_entry_id)
    assert ActorEvent.reply_anchor_source_entry_id(reloaded) == "msg-real"

    judgment = Repo.get!(AmbientJudgment, event.id)
    assert judgment.asked_by_source_entry_id == "msg-not-mirrored"
    assert judgment.asked_by_state == "degraded"
  end

  test "a worker-degraded asked_by stays degraded even when the entry exists" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-stale", text: "old question"},
        now: @base_time
      )

    assert {:ok, %{asked_by_state: "degraded"}} =
             record_judgment(agent.uid, event.id, %{
               action: "FOREGROUND_REPLY",
               authority: "NONE",
               reason: "asker is no longer the latest speaker",
               asked_by_source_entry_id: "msg-stale",
               asked_by_degraded: true
             })

    assert is_nil(Repo.get!(ActorEvent, event.id).ambient_asked_source_entry_id)
  end

  test "a retried judgment returns the first canonical route and keeps the cursor monotonic" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-retry", text: "retry me"},
        now: @base_time
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

    channel = Repo.get!(Channel, @channel_id)
    assert DateTime.compare(channel.ambient_judged_until, @base_time) == :eq
  end

  test "record_judgment rejects unknown events, foreign agents, and bad routes" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-guard", text: "guard case"},
        now: @base_time
      )

    assert {:error, {:invalid_ambient_action, nil}} =
             record_judgment(agent.uid, event.id, %{reason: "no route"})

    assert {:error, :actor_event_not_found} =
             record_judgment(agent.uid, Ecto.UUID.generate(), %{
               action: "NOOP",
               authority: "NONE"
             })

    assert {:error, :actor_event_agent_mismatch} =
             record_judgment(other_agent.uid, event.id, %{action: "NOOP", authority: "NONE"})
  end

  test "new routes persist action and authority without starting work" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-new-work", text: "This investigation may be useful."},
        now: @base_time
      )

    assert {:error, {:invalid_ambient_action, "MAYBE"}} =
             record_judgment(agent.uid, event.id, %{
               action: "MAYBE",
               authority: "NONE"
             })

    assert {:error, {:invalid_ambient_authority, "EXPLICIT_REQUEST"}} =
             record_judgment(agent.uid, event.id, %{
               action: "FOREGROUND_REPLY",
               authority: "EXPLICIT_REQUEST"
             })

    assert {:ok, %{action: "NEW_WORK", authority: "NONE", handoff_job_id: nil}} =
             record_judgment(agent.uid, event.id, %{
               action: "NEW_WORK",
               authority: "NONE",
               reason: "A concrete task exists but no one assigned it."
             })

    judgment = Repo.get!(AmbientJudgment, event.id)
    assert judgment.action == "NEW_WORK"
    assert judgment.authority == "NONE"

    refute Repo.exists?(
             from row in ActorEvent, where: row.type == "background_agent_job.dispatch"
           )
  end

  test "explicit-request authority requires an accepted human row from this batch" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    current =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-current-request", text: "Please investigate this failure."},
        now: @base_time
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
               asked_by_source_entry_id: "msg-current-request",
               reason: "The current human message assigns the work."
             })

    later = DateTime.add(@base_time, 30, :second)

    next =
      ambient_event!(
        agent.uid,
        %{
          source_entry_id: "msg-next-request",
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
                 asked_by_source_entry_id: "msg-current-request",
                 reason: "The proposed requester is only in channel history."
               },
               later
             )

    assert Repo.get!(AmbientJudgment, next.id).authority == "NONE"
  end

  test "standing-order authority requires the current channel text to match the event snapshot" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    ambient_event!(
      agent.uid,
      %{source_entry_id: "msg-orders-seed", text: "seed the channel"},
      now: @base_time
    )

    assert {:ok, %{orders: "Investigate every failed deploy."}} =
             AmbientCuration.put_channel_standing_orders(
               @channel_id,
               "Investigate every failed deploy.",
               "operator"
             )

    unchanged_at = DateTime.add(@base_time, 30, :second)

    unchanged =
      ambient_event!(
        agent.uid,
        %{
          source_entry_id: "msg-orders-current",
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
               },
               unchanged_at
             )

    changed_at = DateTime.add(@base_time, 60, :second)

    changed =
      ambient_event!(
        agent.uid,
        %{
          source_entry_id: "msg-orders-stale",
          text: "A second deploy failed.",
          provider_time: changed_at
        },
        now: changed_at
      )

    assert changed.payload["data"]["channel"]["standing_orders"] ==
             "Investigate every failed deploy."

    assert {:ok, %{orders: "Only report failed deploys."}} =
             AmbientCuration.put_channel_standing_orders(
               @channel_id,
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
               },
               changed_at
             )

    assert Repo.get!(AmbientJudgment, changed.id).authority == "NONE"
  end

  test "HANDOFF prelocks one target, appends one steer, and keeps the canonical target" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-handoff", text: "The failed pod reports a database timeout."},
        now: @base_time
      )

    job = create_job!(agent.uid, event, "handoff")
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
               handoff_job_id: Integer.to_string(job.id),
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
               from row in ActorEvent,
                 where:
                   row.type == "command.steer" and
                     row.session_id == ^BackgroundAgentJobs.job_session_id(job.id)
             )

    handoff_text = get_in(steer.payload, ["data", "command", "argsText"])
    assert handoff_text =~ "database timeout"
    refute handoff_text =~ "updates the active deploy investigation"

    other_job = create_job!(agent.uid, event, "other-handoff")

    assert {:ok, %{action: "HANDOFF", handoff_job_id: ^handoff_job_id}} =
             record_judgment(agent.uid, event.id, %{
               action: "HANDOFF",
               authority: "NONE",
               handoff_job_id: Integer.to_string(other_job.id),
               reason: "A retry selected another target."
             })

    missing_job_id = 2_147_483_647
    assert is_nil(BackgroundAgentJobs.get_job(missing_job_id))

    assert {:ok, %{action: "HANDOFF", handoff_job_id: ^handoff_job_id}} =
             record_judgment(agent.uid, event.id, %{
               action: "HANDOFF",
               authority: "NONE",
               handoff_job_id: Integer.to_string(missing_job_id),
               reason: "A retry selected a missing target."
             })

    assert 1 ==
             Repo.aggregate(
               from(row in ActorEvent, where: row.type == "command.steer"),
               :count
             )
  end

  test "the next ambient batch shows judged rows as backdrop, not delta" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    first =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-old", text: "old question"},
        now: @base_time
      )

    assert {:ok, _result} =
             record_judgment(agent.uid, first.id, %{
               action: "NOOP",
               authority: "NONE",
               reason: "nothing owed"
             })

    later = DateTime.add(@base_time, 60, :second)

    second =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-new", text: "new question", provider_time: later},
        now: later
      )

    delta_ids =
      second.payload["data"]["observed_messages"] |> Enum.map(& &1["source_entry_id"])

    backdrop_ids =
      second.payload["data"]["backdrop_messages"] |> Enum.map(& &1["source_entry_id"])

    assert "msg-new" in delta_ids
    refute "msg-old" in delta_ids
    assert "msg-old" in backdrop_ids
  end

  defp create_job!(agent_uid, event, suffix) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "owner_session_id" => event.session_id,
               "source_tool_call_id" => "ambient-job-#{suffix}",
               "title" => "Investigate deploy failure",
               "task" => "Find the cause of the failed production deploy.",
               "reply_route" => %{
                 "binding_name" => event.binding_name,
                 "signal_channel_id" => event.signal_channel_id,
                 "provider_thread_id" => event.provider_thread_id,
                 "source_entry_id" => event.source_entry_id
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

  test "standing orders set from a turn record the asking author and activation" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-orders", text: "only speak when CI turns red"},
        now: @base_time
      )

    assert {:ok, %{orders: "Only speak when CI turns red.", set_by: "Alice", active: true}} =
             AmbientCuration.set_standing_orders(
               agent.uid,
               event.id,
               "Only speak when CI turns red."
             )

    channel = Repo.get!(Channel, @channel_id)
    assert channel.ambient_standing_orders == "Only speak when CI turns red."
    assert channel.ambient_standing_orders_set_by == "Alice"

    assert {:ok, %{orders: nil, active: false}} =
             AmbientCuration.set_standing_orders(agent.uid, event.id, "   ")

    assert is_nil(Repo.get!(Channel, @channel_id).ambient_standing_orders)

    too_long = String.duplicate("a", 4_001)

    assert {:error, :standing_orders_too_long} =
             AmbientCuration.set_standing_orders(agent.uid, event.id, too_long)
  end

  test "active standing orders travel in may_intervene envelope payloads" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    ambient_event!(
      agent.uid,
      %{source_entry_id: "msg-seed", text: "seed the channel"},
      now: @base_time
    )

    assert {:ok, %{orders: "Post a daily summary at 18:00."}} =
             AmbientCuration.put_channel_standing_orders(
               @channel_id,
               "Post a daily summary at 18:00.",
               "operator"
             )

    later = DateTime.add(@base_time, 30, :second)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-after-orders", text: "another message", provider_time: later},
        now: later
      )

    assert event.payload["data"]["channel"]["standing_orders"] ==
             "Post a daily summary at 18:00."
  end

  test "console standing orders round-trip by channel id" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    ambient_event!(
      agent.uid,
      %{source_entry_id: "msg-console", text: "seed"},
      now: @base_time
    )

    assert {:error, :channel_not_found} =
             AmbientCuration.channel_standing_orders("lark:chat:missing")

    assert {:ok, %{orders: nil}} = AmbientCuration.channel_standing_orders(@channel_id)

    assert {:ok, %{orders: "Escalate incidents only.", set_by: "operator"}} =
             AmbientCuration.put_channel_standing_orders(
               @channel_id,
               "Escalate incidents only.",
               "operator"
             )

    assert {:ok, %{orders: "Escalate incidents only.", channel_id: @channel_id}} =
             AmbientCuration.channel_standing_orders(@channel_id)
  end
end
