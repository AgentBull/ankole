defmodule Ankole.ConcurrencyIntegrationTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.Brain.Claims
  alias Ankole.Brain.LibraryKnowledge
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Schemas.SchemaCalibrationDomain
  alias Ankole.Brain.Schemas.SchemaLinkType
  alias Ankole.Brain.Schemas.SchemaPack
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.CodexJob
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.Receipts
  alias Ankole.Sessions.ToolResult
  alias Ankole.Sessions.RPCLane
  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerRoute
  alias Ankole.SessionsCase, as: RuntimeCase
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Config, as: ProviderConfig

  test "attempt admission waits for a pending tenant suspension", %{tenant: tenant} do
    suspension = hold_transaction(fn -> Ankole.Tenants.suspend(tenant) end)

    admission =
      start_unboxed(fn ->
        Repo.transact(fn repo ->
          case Ankole.Tenants.check_work_admission_in_tx(repo, tenant.id) do
            :ok -> {:ok, :admitted}
            {:error, _reason} = error -> error
          end
        end)
      end)

    assert_blocked_by(admission, suspension)
    release(suspension)
    assert {:ok, %{suspended_at: %DateTime{}}} = finish(suspension)
    assert {:error, :tenant_suspended} = finish(admission)
  end

  test "an ordinary OIDC edit preserves a secret rotated while the edit waits" do
    alias Ankole.OIDC
    alias Ankole.OIDC.Client

    {:ok, %{client: %{id: id}}} =
      Sandbox.unboxed_run(Repo, fn ->
        OIDC.create_client(%{
          name: "Concurrent OIDC edit",
          type: "confidential",
          enabled: true,
          redirect_uris: ["https://client.example.test/callback"],
          scopes: ["openid"]
        })
      end)

    on_exit_in_tenant(fn ->
      Sandbox.unboxed_run(Repo, fn -> Repo.delete_all(from(c in Client, where: c.id == ^id)) end)
    end)

    rotation = hold_transaction(fn -> OIDC.rotate_secret(id) end)
    edit = start_unboxed(fn -> OIDC.update_client(id, %{name: "Renamed client"}) end)
    assert_blocked_by(edit, rotation)
    release(rotation)
    assert {:ok, %{client_secret: secret}} = finish(rotation)
    assert {:ok, %{name: "Renamed client"}} = finish(edit)
    assert {:ok, client} = OIDC.get_client(id)
    assert OIDC.client_secret(client) == {:ok, secret}
  end

  test "a generic Agent update preserves a token quota written while the update waits" do
    alias Ankole.AIAgent.TokenQuota
    alias Ankole.Principals

    suffix = System.unique_integer([:positive])
    label = "agent-quota-race-#{suffix}"

    %{principal: agent} =
      Sandbox.unboxed_run(Repo, fn ->
        Ankole.PrincipalsFixtures.agent_fixture(%{
          handle: label,
          display_name: label,
          role: "Quota Race Agent",
          options: %{}
        })
      end)

    agent_uid = agent.uid

    on_exit_in_tenant(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        delete_agent_jobs!(agent_uid)
        Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent_uid)
      end)
    end)

    Sandbox.unboxed_run(Repo, fn ->
      {:ok, _quota} = TokenQuota.put(agent_uid, quota_attrs(100))
    end)

    quota_write = hold_transaction(fn -> TokenQuota.put(agent_uid, quota_attrs(200)) end)
    edit = start_unboxed(fn -> Principals.update_agent(agent_uid, %{options: %{}}) end)
    assert_blocked_by(edit, quota_write)
    release(quota_write)
    assert {:ok, %{"limit_tokens" => 200}} = finish(quota_write)
    assert {:ok, %{agent: _agent}} = finish(edit)
    assert {:ok, %{token_quota: %{"limit_tokens" => 200}}} = TokenQuota.status(agent_uid)
  end

  test "external conversation creation merges the persisted winner after an insert conflict" do
    alias Ankole.Conversations.{Conversation, External}
    provider_id = "test:concurrent-room-#{System.unique_integer([:positive])}"
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    binding = %{agent_uid: agent.uid}
    now = DateTime.utc_now(:microsecond)

    first = %{
      provider_conversation_id: provider_id,
      external_kind: :im_group,
      reply_mode: :entry,
      title: "Original name",
      visibility: nil,
      metadata: %{"first" => true},
      raw_payload: %{}
    }

    second = %{first | title: nil, metadata: %{"second" => true}}

    on_exit_in_tenant(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from c in Conversation, where: c.provider_conversation_id == ^provider_id)
        delete_agent_jobs!(agent.uid)
        Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)
      end)
    end)

    winner =
      hold_transaction(fn -> External.observe_conversation_in_tx(Repo, binding, first, now) end)

    loser =
      start_unboxed(fn ->
        Repo.transact(fn repo ->
          External.observe_conversation_in_tx(repo, binding, second, now)
        end)
      end)

    assert_blocked_by(loser, winner)
    release(winner)
    assert {:ok, winning} = finish(winner)
    assert {:ok, conversation} = finish(loser)
    assert conversation.id == winning.id
    assert conversation.title == "Original name"
    assert conversation.metadata == %{"first" => true, "second" => true}
    assert Repo.get_by!(Conversation, id: conversation.id).metadata == conversation.metadata
  end

  test "external receive and removal both wait for the shared Message advisory lock" do
    alias Ankole.Conversations.{Conversation, External, Observe, Message}
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    binding = Ankole.SignalsFixtures.binding_fixture(agent.uid, "lock-proof", :ignore)

    entry =
      Ankole.SignalsFixtures.group_entry(%{
        provider_conversation_id: "lark:lock-proof-#{Ecto.UUID.generate()}",
        explicit: true
      })

    now = DateTime.utc_now(:microsecond)

    {:ok, conversation} =
      Repo.transact(fn repo ->
        External.observe_conversation_in_tx(repo, binding, entry, now)
      end)

    on_exit_in_tenant(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from c in Conversation, where: c.id == ^conversation.id)
        delete_agent_jobs!(agent.uid)
        Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)
      end)
    end)

    for operation <- [&Observe.emit_entry/4, &Observe.emit_entry_removed/4] do
      holder =
        hold_transaction(fn ->
          :ok =
            Observe.lock_entry(Repo, %{
              conversation_id: conversation.id,
              provider_message_id: entry.provider_message_id
            })

          {:ok, :released}
        end)

      waiter = start_unboxed(fn -> operation.(agent.uid, binding.name, entry, now: now) end)

      refute holder.backend_pid == waiter.backend_pid
      assert_blocked_by(waiter, holder)
      release(holder)
      assert {:ok, :released} = finish(holder)
      assert {:ok, %{status: :accepted}} = finish(waiter)
    end

    refute Repo.exists?(from m in Message, where: m.conversation_id == ^conversation.id)
  end

  describe "runtime placement and automation lock order" do
    setup do
      %{principal: agent} = Sandbox.unboxed_run(Repo, &RuntimeCase.agent_fixture/0)

      on_exit_in_tenant(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, profile} = Ankole.AIAgent.ModelProfiles.get_model_profile(agent.uid, "heavy")

          delete_agent_jobs!(agent.uid)
          Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)

          Repo.delete_all(
            from(p in Ankole.AIGateway.ProviderConfigs.Provider,
              where: p.provider_id == ^profile["provider_id"]
            )
          )
        end)
      end)

      %{agent: agent}
    end

    test "a placement waits for a concurrent placement on the Agent's Worker row", %{
      agent: agent
    } do
      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, _worker} =
                 RuntimeCase.admit_worker(RuntimeCase.unique_route(), %{
                   worker_id: agent.uid,
                   capacity: %{"available_slots" => 2}
                 })
      end)

      first = hold_transaction(fn -> AgentWorkers.reserve_slot_in_tx(Repo, agent.uid) end)

      second =
        start_unboxed(fn ->
          Repo.transact(fn repo -> AgentWorkers.reserve_slot_in_tx(repo, agent.uid) end)
        end)

      # The row is the Agent's only candidate, so a locked row must make the
      # second placement wait, not report that the Agent has no Worker.
      assert_blocked_by(second, first)
      release(first)
      assert {:ok, _worker} = finish(first)
      assert {:ok, worker} = finish(second)
      assert AgentWorker.available_slots(worker) == 0
    end

    test "starting a run waits for cancellation without holding its Run lock", %{agent: agent} do
      alias Ankole.AutomationJobs

      {job, run} =
        Sandbox.unboxed_run(Repo, fn ->
          Ankole.FilesFixtures.drive_file_fixture(agent.uid, "automation/test/main.ts")

          assert {:ok, job} =
                   AutomationJobs.create_job(%{
                     agent_uid: agent.uid,
                     owner_session_id: "cancel-race",
                     source_signal_id: Ankole.WorkFixtures.service_source(agent.uid).id,
                     drive_prefix: "automation/test",
                     label: "Cancellation race"
                   })

          event = %{
            "specversion" => "1.0",
            "id" => "cancel-race",
            "source" => "test://automation",
            "type" => "test.triggered",
            "data" => %{}
          }

          assert {:ok, %{automation_job_run: run}} =
                   Repo.transact(fn repo ->
                     AutomationJobs.enqueue_run_in_tx(repo, job.id, agent.uid, event)
                   end)

          {job, run}
        end)

      cancel =
        pause_after_query(
          fn -> AutomationJobs.cancel_job(agent.uid, job.owner_session_id, job.id) end,
          fn metadata ->
            metadata.source == "automation_jobs" and
              String.contains?(metadata.query, "FOR UPDATE")
          end
        )

      start = start_unboxed(fn -> AutomationJobs.start_attempt(run.id) end)
      assert_blocked_by(start, cancel)
      send(cancel.task.pid, :continue_query)
      assert {:ok, %{status: :cancelled}} = finish(cancel)
      assert {:ok, :noop} = finish(start)
      assert Repo.get!(Ankole.AutomationJobs.Schemas.Run, run.id).status == :cancelled
    end
  end

  describe "Library ownership during concurrent operator actions" do
    setup do
      suffix = System.unique_integer([:positive])
      name = "concurrent-library-#{suffix}"
      slug = "lazyload-agent-skills/#{name}"
      set = library_skill_set(name, "Original shipped body.")

      schema_rows =
        Sandbox.unboxed_run(Repo, fn ->
          for schema <- [SchemaType, SchemaLinkType, SchemaCalibrationDomain, SchemaPack] do
            {schema, Repo.all(schema)}
          end
        end)

      on_exit_in_tenant(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from(object in Object, where: object.slug == ^slug))
          Repo.delete_all(from(source in Source, where: source.upstream_id == ^set.set_id))

          for {schema, rows} <- schema_rows do
            original_ids = Enum.map(rows, & &1.id)
            Repo.delete_all(from(row in schema, where: row.id not in ^original_ids))

            fields = schema.__schema__(:fields)
            restored = Enum.map(rows, &Map.take(&1, fields))

            Repo.insert_all(schema, restored,
              on_conflict: {:replace_all_except, [:id]},
              conflict_target: [:id]
            )
          end
        end)
      end)

      source =
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, _packs} = SchemaPacks.install_packs([])
          assert {:ok, _report} = LibraryKnowledge.sync(sets: [set])
          Repo.get_by!(Source, kind: "library", upstream_id: set.set_id)
        end)

      %{name: name, set: set, source: source, slug: slug}
    end

    test "a sync that read the Source before archive cannot restore its pages", ctx do
      set = library_skill_set(ctx.name, "New shipped body.")

      sync =
        pause_after_query(
          fn -> LibraryKnowledge.sync(sets: [set]) end,
          fn metadata ->
            metadata.source == "brain_sources" and
              String.starts_with?(metadata.query, "SELECT") and
              not String.contains?(metadata.query, "FOR UPDATE")
          end
        )

      archived = Sandbox.unboxed_run(Repo, fn -> Ankole.Brain.archive_source(ctx.source.id) end)
      assert {:ok, %Source{archived_at: %DateTime{}}} = archived
      send(sync.task.pid, :continue_query)

      assert {:ok, %{reports: [%{status: :archived}]}} = finish(sync)
      object = Repo.get_by!(Object, slug: ctx.slug)
      assert object.deleted_at != nil
      assert object.body =~ "Original shipped body."
      refute object.body =~ "New shipped body."
      assert Repo.get!(Source, ctx.source.id).upstream_revision == ctx.source.upstream_revision
    end

    test "archive waits for an in-flight projection and withdraws the committed page", ctx do
      set = library_skill_set(ctx.name, "New shipped body.")

      # The projection action pauses after its page write, in its own
      # transaction, while it holds the Source and Object locks.
      sync =
        pause_after_query(
          fn -> LibraryKnowledge.sync(sets: [set]) end,
          fn metadata ->
            metadata.source == "brain_objects" and String.starts_with?(metadata.query, "UPDATE")
          end
        )

      archive = start_unboxed(fn -> Ankole.Brain.archive_source(ctx.source.id) end)
      assert_blocked_by(archive, sync)
      send(sync.task.pid, :continue_query)

      # The page commits first. The archive waits in the Source lock queue
      # before the revision step of the sync, so the sync reports the archive.
      assert {:ok, %Source{archived_at: %DateTime{}}} = finish(archive)
      assert {:ok, %{reports: [%{status: :archived}]}} = finish(sync)

      object = Repo.get_by!(Object, slug: ctx.slug)
      assert object.deleted_at != nil
      assert object.body =~ "New shipped body."
      assert Enum.any?(chunk_texts(object), &String.contains?(&1, "New shipped body."))

      assert Repo.aggregate(
               from(version in ObjectVersion, where: version.object_id == ^object.id),
               :count
             ) == 0
    end
  end

  describe "Brain Fact dedup during a concurrent supersede" do
    setup do
      {:ok, _packs} = SchemaPacks.install_packs([])
      slug = "companies/race-#{System.unique_integer([:positive])}"

      {:ok, _object} =
        Ankole.Brain.create_object(%{slug: slug, type: "company", title: "Race"}, :system)

      embedding = {Pgvector.new([1.0 | List.duplicate(0.0, 4095)]), "race-model"}
      attrs = &race_fact_attrs(slug, &1)

      {:ok, %{claim: original, status: :inserted}} =
        Ankole.Brain.write_fact(attrs.("Acme opened its Singapore office"), :system, %{
          options: [embedding: embedding]
        })

      %{slug: slug, embedding: embedding, attrs: attrs, original: original}
    end

    # A learning slice writes its items in one transaction and keeps the
    # transaction after a rejected item. The second write reads the original
    # Fact as current, then waits for the row that the first write supersedes.
    test "a waiting Fact write supersedes the committed replacement, not the replaced row",
         ctx do
      first =
        pause_after_query(
          fn ->
            Ankole.Brain.write_fact(
              ctx.attrs.("Acme opened a Singapore office in May"),
              :system,
              %{
                options: [embedding: ctx.embedding]
              }
            )
          end,
          fn metadata ->
            metadata.source == "brain_claims" and String.starts_with?(metadata.query, "UPDATE")
          end
        )

      second =
        start_unboxed(fn ->
          Repo.transact(fn _repo ->
            result =
              Claims.write_fact_in_tx(
                ctx.attrs.("Acme opened a Singapore office in June"),
                :system,
                embedding: ctx.embedding
              )

            {:ok, result}
          end)
        end)

      assert_blocked_by(second, first)
      send(first.task.pid, :continue_query)

      assert {:ok, %{claim: replacement, status: :superseded}} = finish(first)

      assert {:ok, {:ok, %{claim: latest, status: :superseded, superseded_claim_id: replaced}}} =
               finish(second)

      assert replaced == replacement.id

      current =
        Repo.all(
          from(claim in Claim,
            where:
              claim.object_slug == ^ctx.slug and is_nil(claim.expired_at) and
                is_nil(claim.superseded_by),
            select: claim.id
          )
        )

      assert current == [latest.id]
    end
  end

  describe "conversation tool commit and takeover" do
    setup do
      %{principal: agent} = Sandbox.unboxed_run(Repo, &RuntimeCase.agent_fixture/0)
      key = %{agent_uid: agent.uid, session_id: "receipt-race:#{Ecto.UUID.generate()}"}

      {:ok, run} =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, event} =
            Repo.transact(fn repo ->
              Ankole.Signals.accept_in_tx(repo, %{
                producer: :kernel,
                source: "test://concurrency",
                id: Ecto.UUID.generate(),
                target: key,
                sender: agent.uid,
                authorization: Ankole.Principals.WorkAccess.service(),
                type: "conversation.message.addressed",
                data: %{},
                available_at: DateTime.utc_now(:microsecond)
              })
            end)

          Admission.admit(key, event)
        end)

      on_exit_in_tenant(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, profile} = Ankole.AIAgent.ModelProfiles.get_model_profile(agent.uid, "primary")
          delete_agent_jobs!(agent.uid)
          Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)
          Ankole.AIGateway.ProviderConfigs.delete_provider(profile["provider_id"])
        end)
      end)

      %{key: key, run: run}
    end

    test "takeover waits for all tool transactions and rejects a late old write (G6)", %{
      key: key,
      run: run
    } do
      first =
        hold_receipt(fn ->
          Receipts.execute(run, "resp_fence", "one", fn _ ->
            {:ok, [], fn -> {:ok, %ToolResult{output: "one", details: %{"one" => true}}, []} end}
          end)
        end)

      second =
        hold_receipt(fn ->
          Receipts.execute(run, "resp_fence", "two", fn _ ->
            {:ok, [], fn -> {:ok, %ToolResult{output: "two", details: %{"two" => true}}, []} end}
          end)
        end)

      takeover = start_unboxed(fn -> Admission.admit(key, run.event) end)
      assert_blocked_by(takeover, first)
      send(first.task.pid, :continue_query)
      assert {:ok, _} = finish(first)
      assert_blocked_by(takeover, second)
      send(second.task.pid, :continue_query)
      assert {:ok, _} = finish(second)
      assert {:ok, current} = finish(takeover)
      assert current.epoch == run.epoch + 1

      assert {:error, :stale_driver} =
               Sandbox.unboxed_run(Repo, fn ->
                 Receipts.execute(run, "resp_fence", "late", fn _ ->
                   flunk("the old writer executed")
                 end)
               end)
    end

    test "a concurrent duplicate rolls back its domain change and returns the winner's receipt (G3)",
         %{run: run} do
      operation = fn repo ->
        {1, _} =
          repo.update_all(
            from(p in Ankole.Principals.Principal,
              where: p.uid == ^run.agent_uid,
              update: [set: [display_name: fragment("? || '+tool'", p.display_name)]]
            ),
            []
          )

        {:ok, [], fn -> {:ok, %ToolResult{output: "saved", details: %{"saved" => true}}, []} end}
      end

      first =
        hold_receipt(fn -> Receipts.execute(run, "resp_duplicate", "one", operation) end)

      second = start_unboxed(fn -> Receipts.execute(run, "resp_duplicate", "one", operation) end)
      assert_blocked_by(second, first)
      send(first.task.pid, :continue_query)
      assert {:ok, receipt} = finish(first)
      assert {:ok, repeated} = finish(second)
      assert_persisted_equal(repeated, receipt)
      name = Repo.get!(Ankole.Principals.Principal, run.agent_uid).display_name
      assert length(String.split(name, "+tool")) == 2
    end
  end

  describe "a user steer races with the Worker's terminal Job RPC" do
    @describetag sandbox: false

    setup context do
      RuntimeCase.use_mock_signal_provider_plugin(context)
      route = RuntimeCase.unique_route()
      :ok = WorkerRoute.register_local_worker(route, self())
      previews = RuntimeCase.preview_handler_pids()
      drivers = RuntimeCase.driver_pids()

      %{principal: agent} = Sandbox.unboxed_run(Repo, &RuntimeCase.agent_fixture/0)

      on_exit_in_tenant(fn ->
        RuntimeCase.stop_new_drivers(drivers)
        RuntimeCase.stop_new_preview_handlers(previews)
        WorkerRoute.unregister_local_worker(route)

        Sandbox.unboxed_run(Repo, fn ->
          {:ok, profile} = Ankole.AIAgent.ModelProfiles.get_model_profile(agent.uid, "heavy")

          Repo.delete_all(
            from(j in Oban.Job, where: fragment("?->>'agent_uid'", j.args) == ^agent.uid)
          )

          delete_agent_jobs!(agent.uid)
          Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)

          Repo.delete_all(
            from(provider in Ankole.AIGateway.ProviderConfigs.Provider,
              where: provider.provider_id == ^profile["provider_id"]
            )
          )
        end)
      end)

      {:ok, context} =
        Sandbox.unboxed_run(Repo, fn ->
          binding =
            RuntimeCase.binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")

          {:ok, conversation} =
            Repo.transact(fn repo ->
              Ankole.Conversations.External.observe_conversation_in_tx(
                repo,
                binding,
                %{provider_conversation_id: "test:#{route}"},
                DateTime.utc_now(:microsecond)
              )
            end)

          assert {:ok, _worker} = RuntimeCase.admit_worker(route, %{worker_id: agent.uid})

          assert {:ok, %{job: job, dispatch_event: dispatch}} =
                   BackgroundAgentJobs.create_with_dispatch(%{
                     "agent_uid" => agent.uid,
                     "owner_session_id" => "owner-#{agent.uid}",
                     "source_tool_call_id" => "tool-#{agent.uid}",
                     "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
                     "title" => "Concurrent Job",
                     "task" => "Finish the report.",
                     "reply_route" => %{
                       "binding_name" => "bot",
                       "conversation_id" => conversation.id
                     }
                   })

          actor_key = %{
            agent_uid: agent.uid,
            session_id: BackgroundAgentJobs.job_session_id(job.id)
          }

          assert {:ok, run} = CodexJob.admit(actor_key, dispatch, [])
          turn_ref = run.job_ref
          turn = JobTurnRef.to_proto(turn_ref)

          assert {:ok, _result} =
                   BackgroundAgentJobs.commit_status_with_wakeup(
                     job.id,
                     agent.uid,
                     %{"status" => "running", "runtime_thread_id" => "thread-#{job.id}"},
                     turn_ref: turn_ref,
                     worker_id: agent.uid
                   )

          completed_at = DateTime.utc_now(:microsecond)

          assert {:ok, _turn} =
                   BackgroundAgentJobs.upsert_turn_from_worker(
                     job.id,
                     agent.uid,
                     %{
                       "attempt" => 1,
                       "runtime_thread_id" => "thread-#{job.id}",
                       "runtime_turn_id" => "turn-#{job.id}",
                       "kind" => "agent",
                       "status" => "completed",
                       "revision" => 0,
                       "trajectory" => %{"format" => "ankole_chatml", "version" => 1},
                       "turn_items" => [
                         %{
                           "position" => 0,
                           "item_key" => "answer",
                           "item" => %{
                             "type" => "agentMessage",
                             "id" => "answer",
                             "text" => "Report finished."
                           }
                         }
                       ],
                       "progress" => %{
                         "completed_items" => 0,
                         "tool_calls" => 0,
                         "tools_used" => [],
                         "files_changed" => []
                       },
                       "usage" => nil,
                       "error" => %{},
                       "started_at" => completed_at,
                       "completed_at" => completed_at
                     },
                     turn_ref,
                     agent.uid
                   )

          assert {:ok, %{command_event: steer}} =
                   BackgroundAgentJobs.send_message(job.id, %{
                     "agent_uid" => agent.uid,
                     "message" => "Include the operator runbook.",
                     "request_id" => "steer-#{job.id}"
                   })

          {:ok,
           %{
             agent: agent,
             actor_key: actor_key,
             job: job,
             turn: turn,
             route: route,
             steer: steer
           }}
        end)

      context
    end

    test "terminal RPC takes the Worker lock before a waiting steer takes its event", ctx do
      terminal =
        pause_after_query(
          fn -> terminal_job_rpc(ctx) end,
          fn metadata ->
            if metadata.source == "background_agent_jobs" and
                 String.contains?(metadata.query, "FOR UPDATE") do
              count = Process.get(:job_locks, 0) + 1
              Process.put(:job_locks, count)
              count == 2
            else
              false
            end
          end
        )

      steer =
        start_unboxed(fn -> CodexJob.admit(ctx.actor_key, ctx.steer, []) end)

      assert_blocked_by(steer, terminal)

      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, %Signal{}} =
                 Repo.transact(fn repo ->
                   {:ok,
                    repo.one!(
                      from(event in Signal,
                        where: event.id == ^ctx.steer.id,
                        lock: "FOR UPDATE NOWAIT"
                      ),
                      lock_identity: {"signals", ctx.steer.id}
                    )}
                 end)
      end)

      send(terminal.task.pid, :continue_query)
      assert_terminal_rpc(finish(terminal))
      # Admission completes a terminal Job's event without starting another attempt.
      assert {:ok, %{status: :idle, signal: %Signal{} = completed_event}} = finish(steer)
      assert completed_event.id == ctx.steer.id
      assert %DateTime{} = completed_event.completed_at
      persisted = Repo.get!(Job, ctx.job.id)
      assert persisted.status == :succeeded
      assert persisted.attempts == 1
      assert persisted.runtime_thread_id == "thread-#{ctx.job.id}"
      assert Repo.get!(Signal, ctx.steer.id).completed_at

      assert Repo.aggregate(from(j in Job, where: j.continued_from_job_id == ^ctx.job.id), :count) ==
               1
    end

    test "duplicate terminal RPCs commit once and seed one successor for unapplied input", ctx do
      first = hold_transaction(fn -> terminal_job_rpc(ctx) end)
      repeated = start_unboxed(fn -> terminal_job_rpc(ctx) end)
      assert_blocked_by(repeated, first)
      release(first)
      assert_terminal_rpc(finish(first))
      assert_terminal_rpc(finish(repeated))
      assert Repo.get!(Job, ctx.job.id).status == :succeeded
      assert Repo.get!(Signal, ctx.steer.id).completed_at

      assert Repo.aggregate(from(j in Job, where: j.continued_from_job_id == ^ctx.job.id), :count) ==
               1
    end
  end

  describe "concurrent operator saves of identity providers" do
    setup do
      suffix = System.unique_integer([:positive])
      provider_ids = ["concurrent-a-#{suffix}", "concurrent-b-#{suffix}"]
      application_suffix = String.replace(Repo.tenant_id!(), "-", "")
      app_ids = ["cli_first_#{application_suffix}", "cli_second_#{application_suffix}"]
      definition = ProviderConfig.active_definition()
      scope = "tenant:" <> Repo.tenant_id!()
      Cache.clear_for_test()

      original =
        Sandbox.unboxed_run(Repo, fn ->
          Repo.get_by(AppConfig, scope: scope, key: definition.key)
        end)

      on_exit_in_tenant(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(
            from(row in AppConfig, where: row.scope == ^scope and row.key == ^definition.key)
          )

          if original, do: Repo.insert!(original)

          for adapter <- ["lark", "local"], provider_id <- provider_ids do
            AppConfigure.delete_tenant_by_key(
              "principals.identity_providers.#{adapter}.#{provider_id}"
            )
          end
        end)

        Cache.clear_for_test()
      end)

      assert {:ok, []} = ProviderConfig.active_providers()
      %{provider_ids: provider_ids, app_ids: app_ids, definition: definition, scope: scope}
    end

    test "both saves merge with the committed activation list and retain their own configuration",
         ctx do
      [first_id, second_id] = ctx.provider_ids
      [first_app_id, second_app_id] = ctx.app_ids

      first =
        paused_provider_save(
          first_id,
          "lark",
          %{"appID" => first_app_id, "appSecret" => "first-secret"},
          false
        )

      second =
        start_unboxed(fn ->
          IdentityProviders.save_provider(
            second_id,
            "lark",
            %{"appID" => second_app_id, "appSecret" => "second-secret"},
            false
          )
        end)

      assert_blocked_by(second, first)
      send(first.task.pid, :continue_query)
      assert {:ok, %{"provider_id" => ^first_id}} = finish(first)
      assert {:ok, %{"provider_id" => ^second_id}} = finish(second)

      assert {:ok, providers} = ProviderConfig.active_providers()
      assert Enum.sort(Enum.map(providers, & &1["provider_id"])) == Enum.sort(ctx.provider_ids)
      assert Enum.all?(providers, &(&1["enabled"] == false))

      for {provider_id, app_id} <- [{first_id, first_app_id}, {second_id, second_app_id}] do
        key = "principals.identity_providers.lark.#{provider_id}"
        assert {:ok, %{"appID" => ^app_id}} = AppConfigure.get_by_key(key)

        assert %AppConfig{value: %{"type" => "cipher"}} =
                 Repo.get_by!(AppConfig, scope: ctx.scope, key: key)
      end
    end

    test "a disabled local provider still excludes a concurrent second instance without orphan config",
         ctx do
      [first_id, second_id] = ctx.provider_ids
      first = paused_provider_save(first_id, "local", %{}, false)

      second =
        start_unboxed(fn -> IdentityProviders.save_provider(second_id, "local", %{}, true) end)

      assert_blocked_by(second, first)
      send(first.task.pid, :continue_query)

      assert {:ok, %{"provider_id" => ^first_id}} = finish(first)
      assert {:error, {:local_provider_exists, ^first_id}} = finish(second)

      assert {:ok, [%{"provider_id" => ^first_id, "enabled" => false}]} =
               ProviderConfig.active_providers()

      refute Repo.get_by(AppConfig,
               scope: ctx.scope,
               key: "principals.identity_providers.local.#{second_id}"
             )

      assert :error = AppConfigure.get_by_key("principals.identity_providers.local.#{second_id}")

      assert {:ok, %{"enabled" => true}} =
               Sandbox.unboxed_run(Repo, fn ->
                 IdentityProviders.save_provider(first_id, "local", %{}, true)
               end)

      assert {:ok, [%{"provider_id" => ^first_id, "enabled" => true}]} =
               ProviderConfig.active_providers()
    end
  end

  defp paused_provider_save(provider_id, adapter_id, config, enabled) do
    activation_lock =
      "app_configure:tenant:#{Repo.tenant_id!()}:#{ProviderConfig.active_definition().key}"

    pause_after_query(
      fn -> IdentityProviders.save_provider(provider_id, adapter_id, config, enabled) end,
      fn metadata ->
        String.contains?(metadata.query, "pg_advisory_xact_lock") and
          metadata.params == [activation_lock]
      end
    )
  end

  defp terminal_job_rpc(ctx) do
    request =
      RuntimeCase.rpc_request(
        "terminal-#{ctx.job.id}",
        "background_agent_job.status.update",
        %FabricProto.BackgroundAgentJobStatusUpdateRequest{
          job_id: Integer.to_string(ctx.job.id),
          status: "succeeded",
          result_json: Ankole.JSON.encode!(%{"summary" => "Report finished."})
        },
        job_turn: ctx.turn
      )

    RPCLane.handle_request(request, %{transport_route: ctx.route, worker_id: ctx.agent.uid})
  end

  defp assert_terminal_rpc({:ok, envelope}) do
    response = RuntimeCase.rpc_response_payload!(envelope, FabricProto.BackgroundAgentJobResponse)
    assert response.status == "succeeded"
  end

  defp library_skill_set(name, description) do
    %{
      kind: :lazy_skills,
      set_id: name,
      name: "Library Skill inventory",
      skills: [
        %{
          name: name,
          description: description,
          source_hash: description,
          metadata: %{"tags" => []}
        }
      ]
    }
  end

  defp chunk_texts(object) do
    Repo.all(
      from(chunk in Chunk,
        where: chunk.object_id == ^object.id,
        order_by: chunk.chunk_index,
        select: chunk.chunk_text
      )
    )
  end

  defp race_fact_attrs(slug, text) do
    %{
      object_slug: slug,
      claim: text,
      kind: "event",
      holder: "world",
      audience_scope: "world",
      notability: "medium",
      confidence: 0.75,
      valid_from: DateTime.utc_now(:microsecond),
      provenance: "concurrency test"
    }
  end

  defp quota_attrs(limit_tokens) do
    %{
      "period_days" => 7,
      "period_start_at" => "2026-09-09T00:00:00Z",
      "limit_tokens" => limit_tokens
    }
  end

  defp start_unboxed(fun) do
    parent = self()
    tenant_id = Repo.tenant_id!()

    task =
      Task.async(fn ->
        Repo.put_tenant_id(tenant_id)

        Sandbox.unboxed_run(Repo, fn ->
          Process.put({__MODULE__, :parent}, parent)
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:database_task, self(), backend_pid})
          fun.()
        end)
      end)

    task_pid = task.pid
    assert_receive {:database_task, ^task_pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid}
  end

  defp hold_receipt(fun) do
    pause_after_query(fun, fn metadata ->
      metadata.source == "session_tool_receipts" and
        String.starts_with?(metadata.query, "INSERT")
    end)
  end

  defp hold_transaction(fun) do
    operation =
      start_unboxed(fn ->
        Repo.transact(fn _repo ->
          result = fun.()
          send(Process.get({__MODULE__, :parent}), {:transaction_held, self()})

          receive do
            :commit_transaction -> result
          after
            10_000 -> raise "test did not release its transaction"
          end
        end)
      end)

    task_pid = operation.task.pid
    assert_receive {:transaction_held, ^task_pid}, 5_000
    operation
  end

  defp assert_blocked_by(waiter, holder) do
    assert {:ok, true} =
             wait_until(deadline(5_000), fn ->
               %{rows: [[blocked]]} =
                 Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [
                   holder.backend_pid,
                   waiter.backend_pid
                 ])

               blocked
             end)
  end

  defp release(operation), do: send(operation.task.pid, :commit_transaction)
  defp finish(operation), do: Task.await(operation.task, 10_000)

  defp delete_agent_jobs!(agent_uid) do
    tenant_id = Repo.tenant_id!()

    Repo.delete_all(
      from job in Oban.Job,
        where: job.args["tenant_id"] == ^tenant_id and job.args["agent_uid"] == ^agent_uid
    )
  end

  defp on_exit_in_tenant(fun) do
    tenant_id = Repo.tenant_id!()
    on_exit(fn -> Repo.with_tenant(tenant_id, fun) end)
  end

  defp pause_after_query(fun, predicate) do
    operation =
      start_unboxed(fn ->
        handler_id = {__MODULE__, self(), make_ref()}

        :ok =
          :telemetry.attach(
            handler_id,
            [:ankole, :repo, :query],
            fn _event, _measurements, metadata, {owner, id} ->
              if self() == owner and predicate.(metadata) do
                :telemetry.detach(id)
                send(Process.get({__MODULE__, :parent}), {:query_paused, self()})

                receive do
                  :continue_query -> :ok
                after
                  10_000 -> raise "test did not release its query"
                end
              end
            end,
            {self(), handler_id}
          )

        fun.()
      end)

    task_pid = operation.task.pid
    assert_receive {:query_paused, ^task_pid}, 5_000
    operation
  end
end
