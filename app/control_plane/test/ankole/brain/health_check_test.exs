defmodule Ankole.Brain.HealthCheckTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.Brain
  alias Ankole.Brain.Config
  alias Ankole.Brain.HealthCheck
  alias Ankole.Brain.Jobs.CuratePrincipal
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Sources
  alias Ankole.Brain.Schemas.BlockCitation
  alias Ankole.Brain.Schemas.Cursor
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Schemas.Episode
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AppConfigure
  alias Ankole.AuthZ.Group
  alias Ankole.Repo
  alias Ankole.SignalsGateway.{AdapterContext, BindingMembership, Channel}

  test "orphan detection ignores self-mentions and accepts mentions from another entry" do
    %{principal: agent} = agent_fixture()
    {:ok, scope} = Scope.for_store(agent.uid, "shared")

    alpha = create_entry(scope, agent.uid, "Alpha Subject", "Alpha Subject describes itself")

    assert {:ok, first_health} = HealthCheck.diagnostics(scope)

    assert Enum.any?(
             first_health["orphan_entries"],
             &(&1["entry_id"] == alpha.id)
           )

    beta = create_entry(scope, agent.uid, "Beta Notes", "Evidence points to Alpha Subject")

    assert {:ok, second_health} = HealthCheck.diagnostics(scope)

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
    {:ok, scope} = Scope.for_store(agent.uid, "shared")
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
          mentions: [%{kind: "agent", structured: true, agent_uid: agent.uid}],
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

    assert {:ok, health} = HealthCheck.diagnostics(scope)

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
    {:ok, scope} = Scope.for_store(agent.uid, "self")
    memo = String.duplicate("projection evidence ", 100)

    assert {:ok, %{results: [%{entry_id: entry_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "create_entry",
                 name: "Agent Memo",
                 type: "agent_system_pinned_memo",
                 initial_body: memo
               },
               %{kind: :agent, uid: agent.uid}
             )

    assert {:ok, %{blocks: [%{body: stored_memo}]}} =
             Knowledge.open(scope, entry_id, block_limit: :all)

    exact_tokens = Ankole.Kernel.estimate_o200k_base_tokens(stored_memo)
    assert exact_tokens > 80

    assert {:ok, health} = Brain.health_check(scope)

    assert [
             %{
               "entry_id" => ^entry_id,
               "estimated_tokens" => ^exact_tokens,
               "budget" => 80,
               "over_budget" => true,
               "snapshot_truncated" => true
             }
           ] = health["memo"]

    assert "memo_over_budget" in health["alerts"]
  end

  test "source lint distinguishes integration gaps, broken citations, and weak generated claims" do
    %{principal: agent} = agent_fixture()
    {:ok, scope} = Scope.for_store(agent.uid, "shared")

    assert {:ok, source} =
             Sources.capture(
               scope,
               %{
                 kind: "file",
                 title: "Evidence",
                 original_name: "evidence.txt",
                 media_type: "application/octet-stream",
                 content: "The supported fact."
               },
               agent.uid
             )

    weak_entry = create_entry(scope, agent.uid, "Uncited generated claim", "A generated claim")

    assert {:ok, first_health} = HealthCheck.diagnostics(scope)

    assert Enum.any?(
             first_health["unintegrated_sources"],
             &(&1["document_id"] == source.document_id)
           )

    assert Enum.any?(
             first_health["uncited_generated_blocks"],
             &(&1["entry_id"] == weak_entry.id)
           )

    assert {:ok, %{results: [%{entry_id: cited_entry_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "create_entry",
                 name: "Supported claim",
                 type: "topic",
                 initial_body: "The supported fact. src:#{source.document_id}"
               },
               %{kind: :agent, uid: agent.uid}
             )

    block = Repo.get_by!(EntryBlock, entry_id: weak_entry.id)
    now = DateTime.utc_now(:microsecond)

    Repo.insert_all(BlockCitation, [
      %{
        block_id: block.id,
        document_id: "brain-source:removed",
        inserted_at: now
      }
    ])

    assert {:ok, second_health} = HealthCheck.diagnostics(scope)

    refute Enum.any?(
             second_health["unintegrated_sources"],
             &(&1["document_id"] == source.document_id)
           )

    assert Enum.any?(second_health["broken_citations"], fn item ->
             item["entry_id"] == weak_entry.id and
               item["document_id"] == "brain-source:removed"
           end)

    refute Enum.any?(
             second_health["uncited_generated_blocks"],
             &(&1["entry_id"] == cited_entry_id)
           )
  end

  test "the shared status surface reports all four curation lints" do
    %{principal: agent} = agent_fixture()
    {:ok, shared_scope} = Scope.for_store(agent.uid, "shared")

    _dated = create_entry(shared_scope, agent.uid, "Policy 2026-07", "Current policy fact")
    _first = create_entry(shared_scope, agent.uid, "Customer Alpha", "Current customer fact")

    _duplicate =
      create_entry(shared_scope, agent.uid, "Customer Alpha Notes", "Duplicate subject fact")

    _long =
      create_entry(
        shared_scope,
        agent.uid,
        "Long Subject",
        Enum.map_join(1..201, "\n", &"line #{&1}")
      )

    assert {:ok, %{results: [%{entry_id: zero_body_id}]}} =
             Knowledge.apply_operations(
               shared_scope,
               %{operation: "create_entry", name: "Empty Subject", type: "topic"},
               %{kind: :agent, uid: agent.uid}
             )

    {:ok, console_scope} = Scope.for_console(agent.uid, :all)
    assert {:ok, status} = Brain.health_check(console_scope)

    assert status["lints"]["dated_names"]["count"] == 1
    assert status["lints"]["near_duplicate_names"]["count"] >= 1
    assert status["lints"]["long_entries"]["count"] == 1
    assert status["lints"]["zero_body_entries"]["count"] == 1
    assert status["lints"]["long_entries"]["items"] == status["diagnostics"]["long_entries"]

    assert Enum.any?(
             status["lints"]["zero_body_entries"]["items"],
             &(&1["entry_id"] == zero_body_id)
           )

    assert "curation_lints" in status["alerts"]
  end

  test "status marks Stage B as not applicable for a human owner" do
    %{principal: human} = human_fixture()
    {:ok, console_scope} = Scope.for_console(human.uid, :all)

    assert {:ok, status} = Brain.health_check(console_scope)
    assert status["stage_b"]["model"]["status"] == "not_applicable"
    assert status["stage_b"]["unavailable_reason"] == nil
    refute "stage_b_unavailable" in status["alerts"]
  end

  test "status lists retryable Stage B jobs and alerts only on the last attempt" do
    %{principal: agent} = agent_fixture()
    attempted_at = ~U[2026-07-24 01:00:00.000000Z]
    scheduled_at = DateTime.add(attempted_at, 5, :minute)

    assert {:ok, job} =
             agent.uid
             |> then(&%{"principal_uid" => &1})
             |> CuratePrincipal.new()
             |> Oban.insert()

    set_retryable_attempt = fn attempt ->
      assert {1, nil} =
               Repo.update_all(
                 from(row in Oban.Job, where: row.id == ^job.id),
                 set: [
                   state: "retryable",
                   attempt: attempt,
                   attempted_at: attempted_at,
                   scheduled_at: scheduled_at
                 ]
               )
    end

    set_retryable_attempt.(2)
    assert {:ok, status} = Brain.status(agent.uid)

    assert [
             %{
               "job_id" => job_id,
               "principal_uid" => principal_uid,
               "attempt" => 2,
               "max_attempts" => 5,
               "attempted_at" => "2026-07-24T01:00:00.000000Z",
               "scheduled_at" => "2026-07-24T01:05:00.000000Z"
             }
           ] = status["stage_b"]["retryable_jobs"]

    assert job_id == job.id
    assert principal_uid == agent.uid
    refute "curation_jobs_failing" in status["alerts"]

    set_retryable_attempt.(4)
    assert {:ok, status} = Brain.status(agent.uid)
    assert [%{"attempt" => 4}] = status["stage_b"]["retryable_jobs"]
    assert "curation_jobs_failing" in status["alerts"]
  end

  test "status reports each visible channel cursor and episode embedding counts" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "brain-status-channel", :record_only)
    now = DateTime.utc_now(:microsecond)

    assert {:ok, %{signal_entry: source}} =
             Ankole.SignalsGateway.Ingress.emit_entry(
               agent.uid,
               "brain-status-channel",
               group_entry(%{
                 source_event_id: "brain-status-event",
                 signal_channel_id: "lark:chat:brain-status-channel",
                 source_entry_id: "brain-status-message",
                 text: "status source",
                 provider_time: now
               }),
               now: now
             )

    channel = Repo.get!(Channel, source.signal_channel_id)

    group =
      %Group{}
      |> Group.changeset(%{
        name: "brain-status-channel-group",
        display_name: "Brain status channel group",
        domain: :im_group,
        metadata:
          BindingMembership.project(
            %{},
            AdapterContext.new(
              agent_uid: agent.uid,
              binding_name: "brain-status-channel",
              adapter: "lark",
              user_name: "Lark"
            ),
            :joined,
            now
          )
      })
      |> Repo.insert!()

    channel
    |> Channel.changeset(%{principal_group_id: group.id})
    |> Repo.update!()

    %Cursor{}
    |> Cursor.changeset(%{
      scope_kind: :channel,
      scope_key: source.signal_channel_id,
      cursor_provider_time: now,
      cursor_source_entry_id: source.source_entry_id,
      cursor_entry_observed_at: now,
      unavailable_reason: "light profile unavailable",
      metadata: %{}
    })
    |> Repo.insert!()

    %Episode{}
    |> Episode.changeset(%{
      signal_channel_id: source.signal_channel_id,
      topic: "Status topic",
      summary: "Pending navigation summary",
      source_entry_ids: [source.source_entry_id],
      started_at: now,
      ended_at: now,
      metadata: %{"version" => 2}
    })
    |> Repo.insert!()

    assert {:ok, status} = Brain.status(agent.uid)

    assert %{
             "unavailable_reason" => "light profile unavailable",
             "cursor_observed_at" => cursor_observed_at,
             "episodes" => %{"total" => 1, "pending" => 1, "synced" => 0, "failed" => 0}
           } =
             Enum.find(
               status["stage_a"]["channels"],
               &(&1["channel_id"] == source.signal_channel_id)
             )

    assert is_binary(cursor_observed_at)
    assert status["stage_a"]["episodes"]["pending"] == 1
    assert "stage_a_unavailable" in status["alerts"]
  end

  test "status reports vectors from a replaced global embedding space" do
    %{principal: owner} = agent_fixture()
    %{principal: old_model} = agent_fixture()
    %{principal: current_model} = agent_fixture()
    :ok = Brain.ensure_registered()
    configure_embedding_profile!(old_model)
    configure_embedding_profile!(current_model)

    assert {:ok, _stored} =
             AppConfigure.put_global(Config.embedding_definition(), %{
               "enabled" => true,
               "model_agent_uid" => current_model.uid,
               "dimensions" => 3
             })

    on_exit(fn -> AppConfigure.delete_global(Config.embedding_definition()) end)

    {:ok, scope} = Scope.for_store(owner.uid, "shared")
    entry = create_entry(scope, owner.uid, "Old vector space", "Semantic source text")

    EntryBlock
    |> where([block], block.entry_id == ^entry.id)
    |> Repo.update_all(
      set: [
        embedding: Ankole.Brain.Embedding.storage_vector([1.0, 0.0]),
        embedding_dimensions: 2,
        embedding_model_agent_uid: old_model.uid,
        embedding_state: :synced,
        embedding_error: nil
      ]
    )

    assert {:ok, status} = Brain.status(owner.uid)

    assert status["embedding"] == %{
             "status" => "error",
             "configuration_status" => "ok",
             "model_agent_uid" => current_model.uid,
             "dimensions" => 3,
             "reason" => "stored vectors use a different embedding space",
             "stale_vectors" => %{
               "total" => 1,
               "entry_blocks" => 1,
               "episodes" => 0
             }
           }

    assert "embedding_space_stale" in status["alerts"]
    refute "embedding_unavailable" in status["alerts"]
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

  defp configure_embedding_profile!(agent) do
    provider_id = "brain-health-embedding-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "https://brain-health.invalid/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-brain-health-test"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "embedding", %{
               provider_id: provider_id,
               model: "openai/brain-health-test"
             })
  end
end
