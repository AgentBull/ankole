defmodule BullX.Runtime.SignalRoutingTest do
  use BullX.DataCase, async: false

  import Ecto.Query

  alias BullX.Gateway.{DeliveryIntent, Signal, SourceConfig}
  alias BullX.Principals
  alias BullX.Repo
  alias BullX.Runtime.ConsumerDelivery
  alias BullX.Runtime.SignalRouting
  alias BullX.Runtime.SignalRouting.{Cache, Matcher, RouteConsumer, RouteDecision, RoutingContext}

  setup_all do
    on_exit(fn ->
      owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BullX.Repo, shared: true)
      SignalRouting.refresh_cache()
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end

  setup %{sandbox_owner: owner} do
    if cache = Process.whereis(Cache) do
      Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, owner, cache)
    end

    SignalRouting.refresh_cache()
    :ok
  end

  test "routing context projects inbound Signals and adapter-normalized routing facts" do
    signal =
      inbound_signal(%{
        "routing_facts" => %{
          "github.repo" => "agentbull/bullx",
          "github.label" => ["security", "runtime"]
        }
      })

    assert {:ok, context} = RoutingContext.from_signal(signal)
    assert context.signal_type == "com.agentbull.x.inbound.received"
    assert context.adapter == "feishu"
    assert context.channel_id == "main"
    assert context.scope_id == "chat_1"
    assert context.thread_id == "thread_1"
    assert context.event_type == "message"
    assert context.event_name == "feishu.message.posted"
    assert context.actor_external_id == "ou_alice"
    assert context.actor_bot == false
    assert context.routing_facts["github.repo"] == "agentbull/bullx"
    assert context.routing_facts["github.label"] == ["security", "runtime"]

    assert %{"content" => [_ | _], "reply_channel" => %{} = _reply} =
             RoutingContext.content_snapshot(context, :deliver_agent)

    assert RoutingContext.content_snapshot(context, :drop_signal) == nil
  end

  test "routing context rejects nested extensions and invalid routing facts" do
    assert {:error, :nested_extensions} =
             RoutingContext.from_signal(%{
               "id" => BullX.Ext.gen_uuid_v7(),
               "source" => "bullx://gateway/feishu/main",
               "type" => "com.agentbull.x.inbound.received",
               "time" => "2026-05-13T00:00:00Z",
               "data" => %{},
               "extensions" => %{"bullxoccurkey" => "bad"}
             })

    assert {:error, {:invalid_list, :routing_facts}} =
             inbound_signal(%{"routing_facts" => %{"github.repo" => true}})
             |> RoutingContext.from_signal()
  end

  test "routing context projects delivery outcome carriers without inbound event paths" do
    {:ok, signal} =
      Signal.new(%{
        "id" => BullX.Ext.gen_uuid_v7(),
        "source" => "bullx://gateway/feishu/main",
        "type" => "com.agentbull.x.delivery.succeeded",
        "time" => "2026-05-13T00:00:00Z",
        "data" => %{
          "delivery" => %{"scope_id" => "chat_1", "thread_id" => "thread_1"},
          "outcome" => %{"status" => "sent"}
        },
        "bullxoccurkey" => "gateway:delivery:1:1:outcome",
        "bullxadapter" => "feishu",
        "bullxchannel" => "main"
      })

    assert {:ok, context} = RoutingContext.from_signal(signal)
    assert context.scope_id == "chat_1"
    assert context.thread_id == "thread_1"
    assert context.event_type == nil
    assert context.event_name == nil
    assert context.actor_external_id == nil
    assert context.outcome_status == "sent"
  end

  test "writer permits default inbound Agent routes and rejects broad non-inbound routes" do
    agent = create_agent!("default")

    assert {:ok, rule} =
             SignalRouting.create_rule(
               agent_rule(agent, %{
                 key: unique_key("default"),
                 signal_type: "com.agentbull.x.inbound.received",
                 adapter: nil,
                 channel_id: nil
               })
             )

    assert rule.signal_type == "com.agentbull.x.inbound.received"
    assert {:ok, [cached_rule]} = Cache.snapshot()
    assert cached_rule.id == rule.id

    assert {:error, changeset} =
             SignalRouting.create_rule(
               agent_rule(agent, %{
                 key: unique_key("bad_broad"),
                 signal_type: "com.agentbull.x.delivery.succeeded",
                 adapter: nil,
                 channel_id: nil
               })
             )

    assert %{signal_type: [_ | _]} = errors_on(changeset)
  end

  test "writer rejects disabled Agent destinations" do
    agent = create_agent!("disabled", status: :disabled)

    assert {:error, changeset} =
             SignalRouting.create_rule(agent_rule(agent, key: unique_key("disabled")))

    assert %{agent_principal_id: [_ | _]} = errors_on(changeset)
  end

  test "matcher handles routing facts, fan-out grouping, and terminal blackhole ordering" do
    agent_a = create_agent!("match_a")
    agent_b = create_agent!("match_b")

    context =
      routing_context!(inbound_signal(%{"routing_facts" => %{"github.label" => "security"}}))

    lower_a = rule_struct(agent_rule(agent_a, key: "agent_a_lower", priority: 1))
    higher_a = rule_struct(agent_rule(agent_a, key: "agent_a_higher", priority: 2))
    agent_b_rule = rule_struct(agent_rule(agent_b, key: "agent_b", priority: 1))

    fact_rule =
      rule_struct(
        agent_rule(agent_b,
          key: "agent_b_security",
          priority: 3,
          routing_fact_key: "github.label",
          routing_fact_value: "security"
        )
      )

    assert Enum.map(
             Matcher.match(context, [lower_a, higher_a, agent_b_rule, fact_rule]),
             & &1.key
           ) ==
             ["agent_b_security", "agent_a_higher"]

    blackhole =
      rule_struct(%{
        id: BullX.Ext.gen_uuid_v7(),
        key: "drop_security",
        name: "Drop security",
        enabled: true,
        priority: 10,
        signal_type: "com.agentbull.x.inbound.received",
        adapter: "feishu",
        channel_id: "main",
        route_action: :drop_signal,
        sink_kind: :blackhole,
        reason: "blocked"
      })

    assert [%{key: "drop_security"}] =
             Matcher.match(context, [lower_a, higher_a, agent_b_rule, blackhole])
  end

  test "router emits fan-out DeliveryIntent values and terminal blackhole wins globally" do
    agent_a = create_agent!("router_a")
    agent_b = create_agent!("router_b")

    {:ok, _rule_a} =
      SignalRouting.create_rule(agent_rule(agent_a, key: unique_key("router_a")))

    {:ok, _rule_b} =
      SignalRouting.create_rule(agent_rule(agent_b, key: unique_key("router_b")))

    signal = inbound_signal()
    assert {:ok, intents} = BullX.Runtime.SignalRouting.Router.resolve(signal)
    assert length(intents) == 2
    assert Enum.all?(intents, &match?(%DeliveryIntent{}, &1))
    assert Enum.map(intents, & &1.consumer["route_action"]) == ["deliver_agent", "deliver_agent"]

    {:ok, _drop} =
      SignalRouting.create_rule(%{
        key: unique_key("drop"),
        name: "Drop all Feishu main inbound",
        priority: 50,
        signal_type: "com.agentbull.x.inbound.received",
        adapter: "feishu",
        channel_id: "main",
        route_action: :drop_signal,
        sink_kind: :blackhole,
        reason: "operator_drop",
        metadata: %{}
      })

    assert {:ok, [drop_intent]} = BullX.Runtime.SignalRouting.Router.resolve(signal)
    assert drop_intent.consumer["route_action"] == "drop_signal"
    assert drop_intent.consumer["destination_key"] == "sink:blackhole"
  end

  test "Gateway publish uses the Runtime router and enqueues one job per winning destination" do
    agent = create_agent!("gateway")
    {:ok, _rule} = SignalRouting.create_rule(agent_rule(agent, key: unique_key("gateway")))

    assert {:ok, :accepted, signal, [{:enqueued, %Oban.Job{} = job}]} =
             BullX.Gateway.publish(source(), inbound_input())

    assert job.args["signal"]["id"] == signal.id
    assert job.args["consumer"]["type"] == "signal_route_intent"
    assert job.args["consumer"]["agent_principal_id"] == agent.principal.id
  end

  test "Runtime dispatcher rejects unknown consumer types" do
    intent = test_intent(%{"type" => "unknown"})

    assert {:discard, {:unknown_consumer, "unknown"}} = ConsumerDelivery.deliver(intent)
  end

  test "route consumer persists Agent decisions idempotently with content snapshots" do
    agent = create_agent!("consumer")
    {:ok, _rule} = SignalRouting.create_rule(agent_rule(agent, key: unique_key("consumer")))
    intent = single_intent!(inbound_signal())

    assert :ok = RouteConsumer.deliver(intent)
    assert :ok = RouteConsumer.deliver(intent)

    decisions = Repo.all(from(decision in RouteDecision))
    assert length(decisions) == 1
    [decision] = decisions
    assert decision.route_action == :deliver_agent
    assert decision.agent_principal_id == agent.principal.id
    assert decision.routing_snapshot["routing_facts"] == %{}
    assert %{"content" => [_ | _], "reply_channel" => %{} = _reply} = decision.content_snapshot
  end

  test "route consumer persists blackhole decisions without content snapshots" do
    {:ok, _drop} =
      SignalRouting.create_rule(%{
        key: unique_key("sink"),
        name: "Sink inbound",
        priority: 10,
        signal_type: "com.agentbull.x.inbound.received",
        adapter: "feishu",
        channel_id: "main",
        route_action: :drop_signal,
        sink_kind: :blackhole,
        reason: "blackhole",
        metadata: %{}
      })

    intent = single_intent!(inbound_signal())

    assert :ok = RouteConsumer.deliver(intent)

    decision = Repo.one!(from(decision in RouteDecision))
    assert decision.route_action == :drop_signal
    assert decision.sink_kind == :blackhole
    assert decision.agent_principal_id == nil
    assert decision.content_snapshot == nil
    assert decision.routing_snapshot["route"]["destination_key"] == "sink:blackhole"
  end

  test "route consumer keeps rule_key and clears rule_id when a queued rule was deleted" do
    agent = create_agent!("deleted_rule")
    {:ok, rule} = SignalRouting.create_rule(agent_rule(agent, key: unique_key("deleted_rule")))
    intent = single_intent!(inbound_signal())

    assert {:ok, _deleted} = SignalRouting.delete_rule(rule)
    assert :ok = RouteConsumer.deliver(intent)

    decision = Repo.one!(from(decision in RouteDecision))
    assert decision.rule_id == nil
    assert decision.rule_key == rule.key
  end

  test "route consumer discards stale queued Agent deliveries after the Agent is disabled" do
    agent = create_agent!("disabled_after_enqueue")
    {:ok, _rule} = SignalRouting.create_rule(agent_rule(agent, key: unique_key("disable_after")))
    intent = single_intent!(inbound_signal())

    assert {:ok, _principal} = Principals.disable_principal(agent.principal)

    assert {:discard, {:agent_destination_unavailable, agent_id}} = RouteConsumer.deliver(intent)
    assert agent_id == agent.principal.id
    assert Repo.aggregate(RouteDecision, :count) == 0
  end

  defp create_agent!(suffix, opts \\ []) do
    status = Keyword.get(opts, :status, :active)

    assert {:ok, %{principal: principal, agent: agent}} =
             Principals.create_agent(%{
               principal: %{
                 uid: "signal-routing-#{suffix}-#{System.unique_integer([:positive])}",
                 display_name: "Signal Routing #{suffix}",
                 status: status
               },
               agent: %{
                 profile: %{
                   main_llm: "llm.primary",
                   goals: "Route signals",
                   soul: "Careful and concise"
                 }
               }
             })

    %{principal: principal, agent: agent}
  end

  defp agent_rule(agent, attrs) do
    %{
      key: unique_key("agent"),
      name: "Agent route",
      priority: 0,
      signal_type: "com.agentbull.x.inbound.received",
      adapter: "feishu",
      channel_id: "main",
      route_action: :deliver_agent,
      agent_principal_id: agent.principal.id,
      reason: "matched",
      metadata: %{}
    }
    |> Map.merge(Map.new(attrs))
  end

  defp rule_struct(attrs) do
    attrs
    |> Map.put_new(:id, BullX.Ext.gen_uuid_v7())
    |> then(&struct!(BullX.Runtime.SignalRouting.Rule, &1))
  end

  defp single_intent!(signal) do
    assert {:ok, [intent]} = BullX.Runtime.SignalRouting.Router.resolve(signal)
    intent
  end

  defp routing_context!(signal) do
    assert {:ok, context} = RoutingContext.from_signal(signal)
    context
  end

  defp test_intent(consumer) do
    {:ok, intent} =
      DeliveryIntent.from_signal(inbound_signal(), %{
        "route_id" => "test.route",
        "consumer_key" => "test.consumer",
        "consumer" => consumer
      })

    intent
  end

  defp inbound_signal(extra_data \\ %{}) do
    {:ok, signal} =
      Signal.new(%{
        "id" => BullX.Ext.gen_uuid_v7(),
        "source" => "bullx://gateway/feishu/main",
        "type" => "com.agentbull.x.inbound.received",
        "time" => "2026-05-13T00:00:00Z",
        "data" => Map.merge(inbound_data(), extra_data),
        "bullxoccurkey" => "feishu:event_#{System.unique_integer([:positive])}",
        "bullxadapter" => "feishu",
        "bullxchannel" => "main"
      })

    signal
  end

  defp inbound_data do
    %{
      "content" => [%{"kind" => "text", "body" => %{"text" => "hello"}}],
      "event" => %{"type" => "message", "name" => "feishu.message.posted", "version" => 1},
      "duplex" => true,
      "actor" => %{"id" => "ou_alice", "display" => "Alice", "bot" => false},
      "scope_id" => "chat_1",
      "thread_id" => "thread_1",
      "refs" => [],
      "reply_channel" => %{
        "adapter" => "feishu",
        "channel_id" => "main",
        "scope_id" => "chat_1",
        "thread_id" => "thread_1",
        "reply_to_external_id" => "message_1"
      },
      "provenance" => %{"provider_event_id" => "event_1"},
      "routing_facts" => %{}
    }
  end

  defp source do
    %SourceConfig{
      adapter: "feishu",
      channel_id: "main",
      enabled?: true,
      config: %{},
      outbound_retry: %{},
      adapter_module: nil
    }
  end

  defp inbound_input do
    %{
      "adapter" => "feishu",
      "channel_id" => "main",
      "occurrence_key" => "feishu:event_publish_#{System.unique_integer([:positive])}",
      "content" => [
        %{"kind" => "text", "body" => %{"text" => "hello"}}
      ],
      "event" => %{
        "type" => "message",
        "name" => "feishu.message.posted",
        "version" => 1,
        "data" => %{}
      },
      "actor" => %{"id" => "ou_alice", "display" => "Alice", "bot" => false},
      "scope_id" => "chat_1",
      "thread_id" => nil,
      "refs" => [],
      "reply_channel" => %{
        "adapter" => "feishu",
        "channel_id" => "main",
        "scope_id" => "chat_1",
        "thread_id" => nil,
        "reply_to_external_id" => "message_1"
      },
      "provenance" => %{"provider_event_id" => "event_1"},
      "routing_facts" => %{}
    }
  end

  defp unique_key(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end
end
