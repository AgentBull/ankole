defmodule Ankole.Brain.HealthCheckTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.Brain
  alias Ankole.Brain.Config
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Scope
  alias Ankole.AppConfigure
  alias Ankole.AuthZ.Group
  alias Ankole.Repo
  alias Ankole.SignalsGateway.{AdapterContext, BindingMembership, Channel}

  test "orphan detection ignores self-mentions and accepts mentions from another entry" do
    %{principal: agent} = agent_fixture()
    {:ok, scope} = Scope.for_store(agent.uid, "public")

    alpha = create_entry(scope, agent.uid, "Alpha Subject", "Alpha Subject describes itself")

    assert {:ok, first_health} = Brain.health_check(scope)

    assert Enum.any?(
             first_health["orphan_entries"],
             &(&1["entry_id"] == alpha.id)
           )

    beta = create_entry(scope, agent.uid, "Beta Notes", "Evidence points to Alpha Subject")

    assert {:ok, second_health} = Brain.health_check(scope)

    refute Enum.any?(
             second_health["orphan_entries"],
             &(&1["entry_id"] == alpha.id)
           )

    assert Enum.any?(
             second_health["orphan_entries"],
             &(&1["entry_id"] == beta.id)
           )
  end

  test "stale detection normalizes PostgreSQL aggregate timestamps" do
    %{principal: agent} = agent_fixture()
    {:ok, scope} = Scope.for_store(agent.uid, "public")
    entry = create_entry(scope, agent.uid, "Timestamp Subject", "Current stored fact")
    latest = DateTime.add(DateTime.utc_now(:microsecond), 91, :day)

    binding_fixture(agent.uid, "brain-health-stale", :ignore)

    %{actor_event: actor_event} =
      emit_addressed_actor_event(
        agent.uid,
        "brain-health-stale",
        group_entry(%{
          source_event_id: "brain-health-stale-event",
          source_entry_id: "brain-health-stale-message",
          explicit: true,
          mentions: [%{kind: :agent, structured: true, agent_uid: agent.uid}],
          text: "Timestamp Subject has new evidence",
          provider_time: latest
        }),
        latest
      )

    channel = Repo.get!(Channel, actor_event.signal_channel_id)

    group =
      %Group{}
      |> Group.changeset(%{
        name: "brain-health-stale-group",
        display_name: "Brain health stale group",
        domain: :im_group,
        metadata:
          BindingMembership.project(
            %{},
            AdapterContext.new(
              agent_uid: agent.uid,
              binding_name: "brain-health-stale",
              adapter: "lark",
              user_name: "Lark"
            ),
            :joined,
            latest
          )
      })
      |> Repo.insert!()

    channel
    |> Channel.changeset(%{principal_group_id: group.id})
    |> Repo.update!()

    assert {:ok, health} = Brain.health_check(scope)

    assert Enum.any?(health["stale_entries"], fn item ->
             item["entry_id"] == entry.id and item["lag_days"] >= 90 and
               is_binary(item["latest_source_mention_at"])
           end)
  end

  test "pinned-memory budget uses the exact injected projection" do
    %{principal: agent} = agent_fixture()
    :ok = Brain.ensure_registered()
    {:ok, config} = Config.knowledge()

    assert {:ok, _stored} =
             AppConfigure.put_global(
               Config.knowledge_definition(),
               Map.put(config, "pinned_memo_max_tokens", 80)
             )

    on_exit(fn -> AppConfigure.delete_global(Config.knowledge_definition()) end)
    {:ok, scope} = Scope.for_store(agent.uid, "public")

    assert {:ok, %{results: [%{entry_id: entry_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "create_entry",
                 name: "Agent Memo",
                 type: "agent_system_pinned_memo",
                 properties: %{"large_reference" => String.duplicate("projection evidence ", 100)}
               },
               %{kind: :agent, uid: agent.uid}
             )

    assert {:ok, %{markdown: markdown}} = Knowledge.open(scope, entry_id, block_limit: :all)
    exact_tokens = Ankole.Kernel.estimate_o200k_base_tokens(markdown)
    assert exact_tokens > 80

    assert {:ok, health} = Brain.health_check(scope)

    assert [%{"entry_id" => ^entry_id, "estimated_tokens" => ^exact_tokens, "budget" => 80}] =
             health["over_budget_pinned_memos"]
  end

  defp create_entry(scope, actor_uid, name, body) do
    assert {:ok, %{results: [%{entry_id: entry_id, entry_lock_version: 1}]}} =
             Knowledge.apply_operations(
               scope,
               %{operation: "create_entry", name: name, type: "topic", summary: ""},
               %{kind: :agent, uid: actor_uid}
             )

    assert {:ok, _result} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 1,
                 body: body
               },
               %{kind: :agent, uid: actor_uid}
             )

    {:ok, %{entry: entry}} = Knowledge.open(scope, entry_id, block_limit: :all)
    entry
  end
end
