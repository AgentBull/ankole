defmodule Ankole.Wave234HardeningTest do
  use Ankole.DataCase, async: false
  require Ash.Query

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.{AgentWorker, ReconcileJob}
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.SourceLearning
  alias Ankole.Conversations.Observe
  alias Ankole.Files, as: Drive
  alias Ankole.Pod.{Applets, Files, Pages}
  alias Ankole.Principals
  alias Ankole.Principals.{HumanAccess, ServiceAccounts}
  alias Ankole.Repo
  alias Ankole.SiteConsole.Aggregates

  describe "SiteConsole cross-tenant aggregates (F-114a,c)" do
    test "paginates across active tenants and toggles service accounts" do
      owner_a = human_fixture()

      %{agent: agent_a} =
        agent_fixture(%{uid: "agg_agent_a", owner_principal_uid: owner_a.principal.uid})

      {:ok, tenant_b} =
        Ankole.Tenants.create(%{
          slug: "agg-tenant-#{System.unique_integer([:positive])}",
          display_name: "Aggregate Tenant B"
        })

      %{agent: agent_b} =
        Repo.with_tenant(tenant_b.id, fn ->
          owner_b = human_fixture()
          agent_fixture(%{uid: "agg_agent_b", owner_principal_uid: owner_b.principal.uid})
        end)

      {:ok, overview} = Ankole.Ash.run_action(Aggregates, :overview, %{})
      assert overview.active_tenants >= 2
      assert overview.active_agents >= 2

      for action <- [:workers, :signal_bindings, :schedules, :background_agent_jobs] do
        assert {:ok, %{items: items}} = Ankole.Ash.run_action(Aggregates, action, %{limit: 10})
        assert is_list(items)
      end

      assert {:ok, %{by_tenant: by_tenant}} =
               Ankole.Ash.run_action(Aggregates, :ai_usage, %{days: 7})

      assert length(by_tenant) >= 2

      {:ok, page1} = Ankole.Ash.run_action(Aggregates, :agents, %{limit: 1, q: "agg_agent_"})
      assert length(page1.items) == 1
      assert is_binary(page1.next_cursor)

      {:ok, page2} =
        Ankole.Ash.run_action(Aggregates, :agents, %{
          limit: 10,
          q: "agg_agent_",
          cursor: page1.next_cursor
        })

      uids = Enum.map(page1.items ++ page2.items, & &1.uid)
      assert agent_a.uid in uids
      assert agent_b.uid in uids

      {:ok, principals_no_sys} =
        Ankole.Ash.run_action(Aggregates, :principals, %{include_system: false, limit: 100})

      refute Enum.any?(principals_no_sys.items, &(&1.type == "system"))

      {:ok, principals_with_sys} =
        Ankole.Ash.run_action(Aggregates, :principals, %{include_system: true, limit: 100})

      assert Enum.any?(principals_with_sys.items, &(&1.type == "system"))
    end
  end

  describe "AgentWorker force_reset_generation (G1-05)" do
    test "rejects active healthy ready workers and settles wedged generations to absent" do
      owner = human_fixture()

      %{agent: agent} =
        agent_fixture(%{uid: "wedge_agent", owner_principal_uid: owner.principal.uid})

      now = DateTime.utc_now()

      {:ok, ready_worker} =
        Repo.transact_top_level(fn ->
          locked =
            case AgentWorkers.lock_in_tx(agent.uid) do
              nil ->
                {:ok, created} =
                  Ankole.Ash.create(AgentWorker, :register_unassigned, %{agent_uid: agent.uid})

                created

              existing ->
                existing
            end

          {:ok, starting} =
            Ankole.Ash.update(locked, :begin_generation, %{
              generation: "gen-healthy",
              create_sent_at: now,
              token_digest: "digest-healthy",
              token_ciphertext: "cipher-healthy",
              image: "test:1",
              protocol_version: 1,
              settings_digest: "settings-1",
              instance_settings: %{}
            })

          Ankole.Ash.update(starting, :admit, %{
            incarnation: "inc-healthy",
            transport_route: "route-healthy",
            capacity: %{"max_slots" => 2, "available_slots" => 2}
          })
        end)

      assert ready_worker.state == :ready

      assert {:error, %Ankole.Errors.Invalid.Rejected{reason: :worker_generation_still_active}} =
               ReconcileJob.force_reset_generation(agent.uid)

      {:ok, stale_worker} =
        Repo.transact_top_level(fn ->
          locked = AgentWorkers.lock_in_tx(agent.uid)
          {:ok, disconnected} = Ankole.Ash.update(locked, :disconnect, %{})

          Ankole.Ash.update(disconnected, :record_error, %{
            last_error: "heartbeat_timeout",
            last_error_kind: :transient
          })
        end)

      assert stale_worker.state == :stale

      assert {:ok, settled} = ReconcileJob.force_reset_generation(agent.uid)
      assert settled.state == :absent
      assert is_nil(settled.generation)
      assert is_nil(settled.last_error)
    end
  end

  describe "Applet service account continuity and two-layer idempotency (F-10, F-137a)" do
    test "keeps Applet routes live after creator offboarding, supports ownership claim, and deduplicates Idempotency-Key" do
      creator = human_fixture()
      successor = human_fixture()
      creator_uid = creator.principal.uid
      successor_uid = successor.principal.uid
      creator_actor = actor_fixture(creator_uid)
      successor_actor = actor_fixture(successor_uid)

      {:ok, page} =
        Pages.create(creator_actor, %{
          type: "applet",
          title: "Expense Applet",
          private_owner_uid: creator_uid
        })

      service_uid = ServiceAccounts.applet_uid(page.id)
      assert {:ok, %{type: :system, status: :active}} = Principals.get_principal(service_uid)

      # Share manage access with successor before creator offboards.
      Ankole.Pod.PagesFixtures.set_sharing(creator_uid, page.id, %{
        grants: [%{principal_uid: successor_uid, role: "manage"}]
      })

      source = """
      let counter = 0;
      export default {
        'GET /ping': () => ({ ok: true, count: counter }),
        'POST /charge': async (req) => {
          return await AnkoleRuntime.idempotent(req.body.orderId, async () => {
            counter += 1;
            return { charged: counter, orderId: req.body.orderId };
          });
        }
      }
      """

      manifest =
        Enum.map(
          [
            {"src/main.tsx", "frontend source"},
            {"dist/index.html", "<!doctype html><title>App</title>"},
            {"server/main.js", source}
          ],
          fn {path, bytes} ->
            {:ok, blob} = Drive.store(bytes)

            {:ok, _} =
              Drive.commit(creator_uid, [
                Map.merge(blob, %{path: "publish/#{page.id}/#{path}", source: "agent"})
              ])

            %{path: path, object_id: blob.object_id, source_path: "publish/#{page.id}/#{path}"}
          end
        )

      assert {:ok, %{revision: 1}} = Files.publish(creator_actor, page.id, 0, manifest)

      # Offboard creator: Applet seamlessly falls back to its dedicated service account!
      assert {:ok, _} =
               HumanAccess.disable(
                 creator_uid,
                 "departed",
                 nil,
                 "op-offboard-#{System.unique_integer([:positive])}",
                 :offboarded
               )

      {:ok, refreshed} = Pages.fetch(page.id)

      status =
        Applets.owner_status(successor_actor, Map.put(refreshed, :actions, ["node_manage"]))

      assert status.continuity_active == true
      assert status.effective_uid == service_uid
      assert status.can_claim == true

      # Successor can still call routes while creator is disabled, and Idempotency-Key replays cleanly.
      req1 = %{
        "method" => "POST",
        "path" => "/charge",
        "query" => %{},
        "body" => %{"orderId" => "ord-1", "amount" => 50}
      }

      run1 = fn -> Applets.call(successor_actor, page.id, req1, revision: 1) end

      assert {:ok, %{"status" => 200, "body" => %{"charged" => 1, "orderId" => "ord-1"}}} =
               Applets.Idempotency.execute_route(
                 successor_actor,
                 page.id,
                 req1,
                 "idem-http-1",
                 run1
               )

      # Same HTTP Idempotency-Key + same body returns cached outcome without re-running handler.
      assert {:ok, %{"status" => 200, "body" => %{"charged" => 1, "orderId" => "ord-1"}}} =
               Applets.Idempotency.execute_route(
                 successor_actor,
                 page.id,
                 req1,
                 "idem-http-1",
                 fn ->
                   flunk("handler should not execute on HTTP idempotency replay")
                 end
               )

      # Same HTTP Idempotency-Key + different body fails with :idempotency_key_mismatch.
      req_mismatch = put_in(req1, ["body", "amount"], 99)

      assert {:error, :idempotency_key_mismatch} =
               Applets.Idempotency.execute_route(
                 successor_actor,
                 page.id,
                 req_mismatch,
                 "idem-http-1",
                 run1
               )

      # Different HTTP Idempotency-Key with same business orderId hits SDK AnkoleRuntime.idempotent!
      assert {:ok, %{"status" => 200, "body" => %{"charged" => 1, "orderId" => "ord-1"}}} =
               Applets.Idempotency.execute_route(
                 successor_actor,
                 page.id,
                 req1,
                 "idem-http-2",
                 run1
               )

      # Successor claims ownership cleanly.
      assert {:ok, claimed} = Applets.transfer_owner(successor_actor, page.id, successor_uid)
      assert claimed.owner_uid == successor_uid
    end
  end

  describe "Brain Source default scope trashing, restore, and physical purge (N-02)" do
    test "warns on soft-trash, preserves binding across undo, and detaches without falling back to world on purge" do
      owner = human_fixture()
      actor = actor_fixture(owner.principal.uid)
      {:ok, scope_page} = Pages.create(actor, %{title: "Private Brain Scope"})

      upstream_path =
        Path.join(System.tmp_dir!(), "brain-n02-#{System.unique_integer([:positive])}.md")

      File.write!(upstream_path, "# Confidential\n\nSecret roadmap item.\n")
      on_exit(fn -> File.rm(upstream_path) end)

      {:ok, source} =
        SourceLearning.register_source(%{
          upstream_id: upstream_path,
          kind: "file",
          name: "Confidential Sync",
          default_source_node_id: scope_page.id
        })

      # Soft-delete without force returns :brain_source_scope_in_use warning.
      assert {:error, {:brain_source_scope_in_use, [%{id: id, name: "Confidential Sync"}]}} =
               Pages.delete(actor, scope_page.id)

      assert id == source.id

      # Force soft-delete succeeds while preserving default_source_node_id for Undo, and pauses sync.
      assert {:ok, _trashed} = Pages.delete(actor, scope_page.id, nil, force: true)
      still_bound = Source |> Ash.Query.filter(id == ^source.id) |> Ankole.Ash.read_one!()
      assert still_bound.default_source_node_id == scope_page.id
      assert {:error, :source_scope_trashed} = SourceLearning.learn(source.id)

      # Undo restore keeps the binding intact without operator reconfiguration.
      assert {:ok, _restored} = Pages.restore(actor, scope_page.id)
      after_restore = Source |> Ash.Query.filter(id == ^source.id) |> Ankole.Ash.read_one!()
      assert after_restore.default_source_node_id == scope_page.id
      assert is_nil(after_restore.attention_reason)

      # Physical purge detaches FK, marks attention_reason = "default_scope_purged",
      # and blocks sync from leaking to world.
      assert {:ok, _} = Pages.delete(actor, scope_page.id, nil, force: true)
      assert {:ok, _} = Pages.purge(actor, scope_page.id)
      assert :ok = Ankole.Pod.Jobs.PurgeTree.run(%Oban.Job{args: %{"node_id" => scope_page.id}})

      purged_source = Source |> Ash.Query.filter(id == ^source.id) |> Ankole.Ash.read_one!()
      assert is_nil(purged_source.default_source_node_id)
      assert purged_source.attention_reason == "default_scope_purged"
      assert {:error, :source_attention_required} = SourceLearning.learn(source.id)
    end
  end

  describe "External Bot admission policy (F-08) & Applet service account hardening (M5)" do
    test "ignores external bots by default and registers external_bot service accounts under record_only" do
      owner = human_fixture()

      %{agent: agent} =
        agent_fixture(%{uid: "policy_gate_agent", owner_principal_uid: owner.principal.uid})

      {:ok, binding} =
        raw_binding_fixture(%{
          agent_uid: agent.uid,
          name: "lark-bot-gate",
          adapter: "lark",
          config_ref: "app-config://lark-bot-gate",
          filters: %{},
          unaddressed_group_message_policy: :may_intervene,
          unmatched_sender_policy: :create_standalone,
          external_bot_policy: :ignore
        })

      bot_entry =
        group_entry(%{
          source_event_id: "evt-bot-1",
          provider_message_id: "msg-bot-1",
          text: "Build #42 failed",
          author: %{
            provider: "lark-main",
            platform_subject: "cli_github_actions",
            id: "cli_github_actions",
            display_name: "GitHub Actions",
            is_bot: true
          }
        })

      assert {:ok, %{status: :ignored_external_bot}} =
               Observe.emit_entry(binding.id, bot_entry, now: base_time())

      {:ok, record_binding} =
        raw_binding_fixture(binding, %{external_bot_policy: :record_only})

      assert {:ok, _observed} =
               Observe.emit_entry(record_binding.id, bot_entry, now: base_time())

      bot_uid = ServiceAccounts.bot_uid("lark", "cli_github_actions")

      assert {:ok, %{type: :system, status: :active, display_name: "GitHub Actions [Bot]"}} =
               Principals.get_principal(bot_uid)
    end

    test "blocks non-system svc_applet_* UIDs, hardens Access, and seeds Access.Graph on private Applets" do
      worker_provider_fixture(%{is_default: true})
      owner = human_fixture()
      owner_uid = owner.principal.uid
      owner_actor = actor_fixture(owner_uid)

      {:ok, doc_page} =
        Pages.create(owner_actor, %{
          type: "doc",
          title: "Private Sibling Doc",
          private_owner_uid: owner_uid
        })

      spoof_uid = ServiceAccounts.applet_uid(doc_page.id)

      # (a) Neither :agent nor :human can create or rename into svc_applet_<32hex>
      refute Principals.Agent.valid_uid?(spoof_uid)

      assert {:error, _} =
               Principals.create_agent(%{
                 uid: spoof_uid,
                 display_name: "Spoof Agent",
                 role: "Spoofer",
                 owner_principal_uid: owner_uid
               })

      assert {:error, _} =
               Principals.create_human(%{
                 uid: spoof_uid,
                 display_name: "Spoof Human",
                 email: "spoof@example.com"
               })

      assert {:error, :invalid_uid} = Principals.Rename.rename(owner_uid, spoof_uid)

      # Email local-parts starting with svc_ / bot_ / system allocate safe non-reserved handles
      assert {:ok, %{principal: safe_human}} =
               Principals.create_human(%{
                 display_name: "Service Ops",
                 email: "svc_ops@example.com"
               })

      assert safe_human.uid == "member.svc_ops"
      refute ServiceAccounts.reserved_non_system_uid?(safe_human.uid)

      # (b) applet_service_subtree?/2 rejects non-:system actors and non-:applet host pages
      fake_human_actor =
        Ankole.AuthZ.Actor.new(%{owner.principal | uid: spoof_uid, type: :human, status: :active})

      assert {:error, :forbidden} =
               Ankole.Pod.Access.authorize(fake_human_actor, doc_page, "node_view")

      fake_system_on_doc =
        Ankole.AuthZ.Actor.new(%Principals.Principal{
          tenant_id: Repo.tenant_id!(),
          uid: spoof_uid,
          type: :system,
          status: :active
        })

      assert {:error, :forbidden} =
               Ankole.Pod.Access.authorize(fake_system_on_doc, doc_page, "node_view")

      # (c) Real svc_applet_<page_id> can list_children and reconcile_versions
      # on a private Applet subtree via Access.Graph
      {:ok, applet_page} =
        Pages.create(owner_actor, %{
          type: "applet",
          title: "Private Continuity Applet",
          private_owner_uid: owner_uid
        })

      {:ok, child_page} =
        Pages.create(owner_actor, %{
          type: "doc",
          title: "Applet Child Doc",
          parent_id: applet_page.id
        })

      svc_uid = ServiceAccounts.applet_uid(applet_page.id)
      {:ok, svc_principal} = Principals.get_principal(svc_uid)
      svc_actor = Ankole.AuthZ.Actor.new(svc_principal)

      assert {:ok, %{pages: children}} = Pages.list_children(svc_actor, applet_page.id)
      assert Enum.map(children, & &1.id) == [child_page.id]

      assert {:ok, %{pages: reconciled}} =
               Pages.reconcile_versions(
                 svc_actor,
                 [applet_page.id, child_page.id, doc_page.id],
                 []
               )

      assert MapSet.new(reconciled, & &1.id) == MapSet.new([applet_page.id, child_page.id])

      assert {:error, :not_found} = Pages.list_children(svc_actor, doc_page.id)
    end
  end
end
