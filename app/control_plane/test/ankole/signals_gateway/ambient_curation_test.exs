defmodule Ankole.SignalsGateway.AmbientCurationTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.SignalsGateway.AmbientCuration
  alias Ankole.SignalsGateway.AmbientJudgment
  alias Ankole.SignalsGateway.Channel

  @channel_id "lark:chat:group-a"

  defp ambient_event!(agent_uid, overrides, opts) do
    assert {:ok, %{actor_event: event}} =
             emit_entry(agent_uid, "bot", group_entry(overrides), opts)

    assert event.type == "im.message.may_intervene"
    event
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

    assert {:ok, %{decision: "silent", asked_by_state: nil, judged_until: judged_until}} =
             AmbientCuration.record_judgment(agent.uid, event.id, %{
               decision: "silent",
               reason: "small talk between colleagues"
             })

    assert DateTime.compare(judged_until, @base_time) == :eq

    judgment = Repo.get!(AmbientJudgment, event.id)
    assert judgment.decision == "silent"
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
             AmbientCuration.record_judgment(agent.uid, event.id, %{
               decision: "intervene",
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
             AmbientCuration.record_judgment(agent.uid, event.id, %{
               decision: "intervene",
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
             AmbientCuration.record_judgment(agent.uid, event.id, %{
               decision: "intervene",
               reason: "asker is no longer the latest speaker",
               asked_by_source_entry_id: "msg-stale",
               asked_by_degraded: true
             })

    assert is_nil(Repo.get!(ActorEvent, event.id).ambient_asked_source_entry_id)
  end

  test "a retried judgment replaces the stored row and keeps the cursor monotonic" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-retry", text: "retry me"},
        now: @base_time
      )

    assert {:ok, _result} =
             AmbientCuration.record_judgment(agent.uid, event.id, %{
               decision: "silent",
               reason: "first attempt"
             })

    assert {:ok, _result} =
             AmbientCuration.record_judgment(agent.uid, event.id, %{
               decision: "intervene",
               reason: "second attempt"
             })

    judgment = Repo.get!(AmbientJudgment, event.id)
    assert judgment.decision == "intervene"
    assert judgment.reason == "second attempt"

    channel = Repo.get!(Channel, @channel_id)
    assert DateTime.compare(channel.ambient_judged_until, @base_time) == :eq
  end

  test "record_judgment rejects unknown events, foreign agents, and bad decisions" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)

    event =
      ambient_event!(
        agent.uid,
        %{source_entry_id: "msg-guard", text: "guard case"},
        now: @base_time
      )

    assert {:error, {:invalid_ambient_decision, "maybe"}} =
             AmbientCuration.record_judgment(agent.uid, event.id, %{decision: "maybe"})

    assert {:error, :actor_event_not_found} =
             AmbientCuration.record_judgment(agent.uid, Ecto.UUID.generate(), %{
               decision: "silent"
             })

    assert {:error, :actor_event_agent_mismatch} =
             AmbientCuration.record_judgment(other_agent.uid, event.id, %{decision: "silent"})
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
             AmbientCuration.record_judgment(agent.uid, first.id, %{
               decision: "silent",
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
