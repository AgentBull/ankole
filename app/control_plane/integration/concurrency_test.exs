defmodule Ankole.ConcurrencyIntegrationTest do
  use Ankole.DataCase, async: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.Brain.LibraryKnowledge
  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Schemas.SchemaCalibrationDomain
  alias Ankole.Brain.Schemas.SchemaLinkType
  alias Ankole.Brain.Schemas.SchemaPack
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Sources
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime
  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor
  alias Ankole.SignalsGateway.ActorRuntime.RPCLane
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntimeCase, as: RuntimeCase
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.IdentityProviders
  alias Ankole.IdentityProviders.Config, as: ProviderConfig

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

    on_exit(fn ->
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

  test "channel creation merges the persisted winner after an insert conflict" do
    alias Ankole.SignalsGateway.{Channel, Projection}
    id = "test:concurrent-channel-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:microsecond)

    first = %{
      signal_channel_id: id,
      channel_kind: :im_group,
      reply_mode: :entry,
      channel_name: "Original name",
      channel_visibility: nil,
      channel_metadata: %{"first" => true},
      channel_raw_payload: %{}
    }

    second = %{first | channel_name: nil, channel_metadata: %{"second" => true}}

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn -> Repo.delete_all(from(c in Channel, where: c.id == ^id)) end)
    end)

    winner = hold_transaction(fn -> Projection.upsert_channel(Repo, first, now) end)

    loser =
      start_unboxed(fn ->
        Repo.transact(fn repo -> Projection.upsert_channel(repo, second, now) end)
      end)

    assert_blocked_by(loser, winner)
    release(winner)
    assert {:ok, _} = finish(winner)
    assert {:ok, channel} = finish(loser)
    assert channel.name == "Original name"
    assert channel.metadata == %{"first" => true, "second" => true}
    assert Repo.get!(Channel, id).metadata == channel.metadata
  end

  describe "runtime placement and automation lock order" do
    setup do
      %{principal: agent} = Sandbox.unboxed_run(Repo, &RuntimeCase.agent_fixture/0)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, profile} = Ankole.AIAgent.ModelProfiles.get_model_profile(agent.uid, "heavy")

          Repo.delete_all(
            from(a in ActorSessionWorkerAssignment, where: a.agent_uid == ^agent.uid)
          )

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

    test "one placement does not lock the other ready worker", %{agent: agent} do
      alias Ankole.SignalsGateway.ActorRuntime.WorkerPool
      routes = [RuntimeCase.unique_route(), RuntimeCase.unique_route()]

      workers =
        Sandbox.unboxed_run(Repo, fn ->
          for route <- routes do
            assert {:ok, worker} =
                     RuntimeCase.admit_worker(route, %{
                       capacity: %{"available_turn_slots" => 1_000_000}
                     })

            worker
          end
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(
            from(a in ActorSessionWorkerAssignment, where: a.agent_uid == ^agent.uid)
          )

          Repo.delete_all(from(w in AgentComputerWorker, where: w.transport_route in ^routes))
        end)
      end)

      first =
        hold_transaction(fn ->
          WorkerPool.assign_worker(%{agent_uid: agent.uid, session_id: "first"})
        end)

      second =
        start_unboxed(fn ->
          WorkerPool.assign_worker(%{agent_uid: agent.uid, session_id: "second"})
        end)

      assert {:ok, second_assignment} = finish(second)
      release(first)
      assert {:ok, first_assignment} = finish(first)
      refute first_assignment.worker_id == second_assignment.worker_id

      assert Enum.sort([first_assignment.worker_id, second_assignment.worker_id]) ==
               Enum.sort(Enum.map(workers, & &1.worker_id))
    end

    test "starting a run waits for cancellation without holding its Run lock", %{agent: agent} do
      alias Ankole.AutomationJobs

      {job, run} =
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, job} =
                   AutomationJobs.create_job(%{
                     agent_uid: agent.uid,
                     owner_session_id: "cancel-race",
                     directory_path: "/agents/#{agent.uid}/automation/test",
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
        start_unboxed(fn ->
          pause_after_query(fn metadata ->
            metadata.source == "automation_jobs" and
              String.contains?(metadata.query, "FOR UPDATE")
          end)

          AutomationJobs.cancel_job(agent.uid, job.owner_session_id, job.id)
        end)

      assert_receive {:query_paused, cancel_pid}, 5_000
      assert cancel_pid == cancel.task.pid
      start = start_unboxed(fn -> AutomationJobs.start_attempt(run.id) end)
      assert_blocked_by(start, cancel)
      send(cancel.task.pid, :continue_query)
      assert {:ok, %{status: :cancelled}} = finish(cancel)
      assert {:ok, :noop} = finish(start)
      assert Repo.get!(Ankole.AutomationJobs.Schemas.Run, run.id).status == "cancelled"
    end
  end

  describe "Library ownership during concurrent operator actions" do
    setup do
      suffix = System.unique_integer([:positive])
      slug = "concepts/concurrent-library-#{suffix}"
      dir = Path.join(System.tmp_dir!(), "ankole-library-concurrency-#{suffix}")
      File.mkdir_p!(dir)
      set = %{kind: :knowledge, set_id: "concurrent-library-#{suffix}", name: "Library", dir: dir}

      schema_rows =
        Sandbox.unboxed_run(Repo, fn ->
          for schema <- [SchemaType, SchemaLinkType, SchemaCalibrationDomain, SchemaPack] do
            {schema, Repo.all(schema)}
          end
        end)

      on_exit(fn ->
        File.rm_rf!(dir)

        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from(object in Object, where: object.slug == ^slug))
          Repo.delete_all(from(source in Source, where: source.upstream_id == ^set.set_id))

          for {schema, rows} <- schema_rows do
            original_ids = Enum.map(rows, & &1.id)
            Repo.delete_all(from(row in schema, where: row.id not in ^original_ids))

            restored = Enum.map(rows, &(Map.from_struct(&1) |> Map.delete(:__meta__)))

            Repo.insert_all(schema, restored,
              on_conflict: {:replace_all_except, [:id]},
              conflict_target: [:id]
            )
          end
        end)
      end)

      write_library_page(dir, slug, "Original shipped body.")

      source =
        Sandbox.unboxed_run(Repo, fn ->
          assert {:ok, _packs} = SchemaPacks.install_packs([])
          assert {:ok, _report} = LibraryKnowledge.sync(sets: [set])
          Repo.get_by!(Source, kind: "library", upstream_id: set.set_id)
        end)

      %{dir: dir, set: set, source: source, slug: slug}
    end

    test "rebuilding chunks waits for a content edit and uses its committed body", ctx do
      old = Repo.get_by!(Object, slug: ctx.slug)

      edit =
        hold_transaction(fn ->
          assert {:ok, object} = Objects.fork_library_page(ctx.slug)

          Objects.update_object(
            ctx.slug,
            %{body: "Committed replacement.", expected_content_hash: object.content_hash},
            :system
          )
        end)

      rebuild = start_unboxed(fn -> Objects.reconcile_chunks(old) end)
      assert_blocked_by(rebuild, edit)
      release(edit)
      assert {:ok, _} = finish(edit)
      assert {:ok, current} = finish(rebuild)
      assert current.body == "Committed replacement."
      assert chunk_texts(current) == ["Committed replacement."]
    end

    test "sync waits for Fork and preserves the instance body and its retrieval chunks", ctx do
      write_library_page(ctx.dir, ctx.slug, "New shipped body.")

      fork =
        hold_transaction(fn ->
          assert {:ok, object} = Objects.fork_library_page(ctx.slug)
          assert {:ok, _alias} = Links.add_alias(ctx.slug, "Instance alias")

          Objects.update_object(
            ctx.slug,
            %{body: "My instance content.", expected_content_hash: object.content_hash},
            :system
          )
        end)

      sync = start_unboxed(fn -> LibraryKnowledge.sync(sets: [ctx.set]) end)
      assert_blocked_by(sync, fork)
      release(fork)

      assert {:ok, _object} = finish(fork)
      assert {:ok, %{reports: [%{shadowed: 1, projected: 0}]}} = finish(sync)

      object = Repo.get_by!(Object, slug: ctx.slug)
      assert object.managed_by_source_id == nil
      assert object.body == "My instance content."
      assert object.content_hash == Objects.content_hash(object.title, object.body, object.meta)
      assert ["My instance content."] == chunk_texts(object)
      assert Repo.get_by(ObjectAlias, object_slug: ctx.slug, alias_norm: "instance alias")

      assert Repo.aggregate(
               from(version in ObjectVersion, where: version.object_id == ^object.id),
               :count
             ) == 1
    end

    test "a sync that read the Source before archive cannot restore its pages", ctx do
      write_library_page(ctx.dir, ctx.slug, "New shipped body.")

      sync =
        start_unboxed(fn ->
          pause_after_query(fn metadata ->
            metadata.source == "brain_sources" and
              String.starts_with?(metadata.query, "SELECT") and
              not String.contains?(metadata.query, "FOR UPDATE")
          end)

          LibraryKnowledge.sync(sets: [ctx.set])
        end)

      assert_receive {:query_paused, sync_pid}, 5_000
      assert sync_pid == sync.task.pid

      archived = Sandbox.unboxed_run(Repo, fn -> Sources.archive(ctx.source.id) end)
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
      write_library_page(ctx.dir, ctx.slug, "New shipped body.")
      sync = hold_transaction(fn -> LibraryKnowledge.sync(sets: [ctx.set]) end)
      archive = start_unboxed(fn -> Sources.archive(ctx.source.id) end)
      assert_blocked_by(archive, sync)
      release(sync)

      assert {:ok, %{reports: [%{projected: 1}]}} = finish(sync)
      assert {:ok, %Source{archived_at: %DateTime{}}} = finish(archive)

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

  describe "a user steer races with the Worker's terminal Job RPC" do
    setup context do
      RuntimeCase.use_mock_signal_provider_plugin(context)
      route = RuntimeCase.unique_route()
      :ok = Broker.register_local_worker(route, self())
      previews = RuntimeCase.preview_handler_pids()

      %{principal: agent} = Sandbox.unboxed_run(Repo, &RuntimeCase.agent_fixture/0)

      on_exit(fn ->
        RuntimeCase.stop_new_preview_handlers(previews)
        Broker.unregister_local_worker(route)

        Sandbox.unboxed_run(Repo, fn ->
          {:ok, profile} = Ankole.AIAgent.ModelProfiles.get_model_profile(agent.uid, "heavy")

          for schema <- [ActorEventDelivery, ActorSessionActivation, ActorSessionWorkerAssignment] do
            Repo.delete_all(from(row in schema, where: row.agent_uid == ^agent.uid))
          end

          Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)

          Repo.delete_all(
            from(worker in AgentComputerWorker, where: worker.transport_route == ^route)
          )

          Repo.delete_all(
            from(provider in Ankole.AIGateway.ProviderConfigs.Provider,
              where: provider.provider_id == ^profile["provider_id"]
            )
          )
        end)
      end)

      Sandbox.unboxed_run(Repo, fn ->
        RuntimeCase.binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
        assert {:ok, _worker} = RuntimeCase.admit_worker(route)

        assert {:ok, %{job: job}} =
                 BackgroundAgentJobs.create_with_dispatch(%{
                   "agent_uid" => agent.uid,
                   "owner_session_id" => "owner-#{agent.uid}",
                   "source_tool_call_id" => "tool-#{agent.uid}",
                   "title" => "Concurrent Job",
                   "task" => "Finish the report.",
                   "reply_route" => %{"binding_name" => "bot", "signal_channel_id" => route}
                 })

        actor_key = %{
          agent_uid: agent.uid,
          session_id: BackgroundAgentJobs.job_session_id(job.id)
        }

        assert {:ok, %{send_outcome: "sent_or_queued"}} =
                 ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                   now: DateTime.add(job.queued_at, 1, :second),
                   lease_seconds: 31_536_000
                 )

        assert_receive {:actor_lane, envelope}, 1_000
        turn = RuntimeCase.turn_start_payload!(envelope).turn
        turn_ref = RuntimeCase.domain_turn_ref(turn)

        assert {:ok, [_delivery]} =
                 ActorRuntime.handle_turn_accepted(RuntimeCase.turn_accepted_payload(turn))

        assert {:ok, _result} =
                 BackgroundAgentJobs.commit_status_with_wakeup(
                   job.id,
                   agent.uid,
                   %{"status" => "running", "runtime_thread_id" => "thread-#{job.id}"},
                   turn_ref: turn_ref,
                   worker_route: route
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
                   route
                 )

        assert {:ok, %{command_event: steer}} =
                 BackgroundAgentJobs.send_message(job.id, %{
                   "agent_uid" => agent.uid,
                   "message" => "Include the operator runbook.",
                   "request_id" => "steer-#{job.id}"
                 })

        %{agent: agent, actor_key: actor_key, job: job, turn: turn, route: route, steer: steer}
      end)
    end

    test "terminal RPC takes the Worker lock before a waiting steer takes its event", ctx do
      terminal =
        start_unboxed(fn ->
          pause_after_query(fn metadata ->
            metadata.source == "agent_computer_workers" and
              String.contains?(metadata.query, "FOR UPDATE")
          end)

          terminal_job_rpc(ctx)
        end)

      assert_receive {:query_paused, terminal_pid}, 5_000
      assert terminal_pid == terminal.task.pid

      steer =
        start_unboxed(fn -> ReadyEventProcessor.process_ready_event_for_actor(ctx.actor_key) end)

      assert_blocked_by(steer, terminal)

      Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, %ActorEvent{}} =
                 Repo.transact(fn repo ->
                   {:ok,
                    repo.one!(
                      from(event in ActorEvent,
                        where: event.id == ^ctx.steer.id,
                        lock: "FOR UPDATE NOWAIT"
                      )
                    )}
                 end)
      end)

      send(terminal.task.pid, :continue_query)
      assert_terminal_rpc(finish(terminal))
      assert {:ok, %{status: :idle}} = finish(steer)
      assert_successor(ctx)
    end

    test "a delivered but unaccepted steer survives a terminal RPC waiting on the Worker", ctx do
      steer =
        hold_transaction(fn ->
          ReadyEventProcessor.process_ready_event_for_actor(ctx.actor_key)
        end)

      terminal = start_unboxed(fn -> terminal_job_rpc(ctx) end)
      assert_blocked_by(terminal, steer)
      release(steer)

      assert {:ok, %{status: :active_steer_nudged}} = finish(steer)
      assert_terminal_rpc(finish(terminal))
      assert_successor(ctx)
    end
  end

  describe "concurrent operator saves of identity providers" do
    setup do
      suffix = System.unique_integer([:positive])
      provider_ids = ["concurrent-a-#{suffix}", "concurrent-b-#{suffix}"]
      definition = ProviderConfig.active_definition()
      Cache.clear_for_test()

      original =
        Sandbox.unboxed_run(Repo, fn ->
          Repo.get_by(AppConfig, scope: "global", key: definition.key)
        end)

      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(
            from(row in AppConfig, where: row.scope == "global" and row.key == ^definition.key)
          )

          if original, do: Repo.insert!(original)

          for adapter <- ["lark", "local"], provider_id <- provider_ids do
            AppConfigure.delete_global_by_key(
              "principals.identity_providers.#{adapter}.#{provider_id}"
            )
          end
        end)

        Cache.clear_for_test()
      end)

      assert {:ok, []} = ProviderConfig.active_providers()
      %{provider_ids: provider_ids, definition: definition}
    end

    test "both saves merge with the committed activation list and retain their own configuration",
         ctx do
      [first_id, second_id] = ctx.provider_ids

      first =
        paused_provider_save(
          first_id,
          "lark",
          %{"appID" => "cli_first", "appSecret" => "first-secret"},
          false
        )

      second =
        start_unboxed(fn ->
          IdentityProviders.save_provider(
            second_id,
            "lark",
            %{"appID" => "cli_second", "appSecret" => "second-secret"},
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

      for {provider_id, app_id} <- [{first_id, "cli_first"}, {second_id, "cli_second"}] do
        key = "principals.identity_providers.lark.#{provider_id}"
        assert {:ok, %{"appID" => ^app_id}} = AppConfigure.get_by_key(key)

        assert %AppConfig{value: %{"type" => "cipher"}} =
                 Repo.get_by!(AppConfig, scope: "global", key: key)
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
               scope: "global",
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
    operation =
      start_unboxed(fn ->
        pause_after_query(fn metadata ->
          String.contains?(metadata.query, "pg_advisory_xact_lock")
        end)

        IdentityProviders.save_provider(provider_id, adapter_id, config, enabled)
      end)

    operation_pid = operation.task.pid
    assert_receive {:query_paused, ^operation_pid}, 5_000
    operation
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
        turn: ctx.turn
      )

    RPCLane.handle_request(request, ctx.route)
  end

  defp assert_terminal_rpc({:ok, envelope}) do
    response = RuntimeCase.rpc_response_payload!(envelope, FabricProto.BackgroundAgentJobResponse)
    assert response.status == "succeeded"
  end

  defp assert_successor(ctx) do
    assert [%Job{} = successor] =
             Repo.all(from(job in Job, where: job.continued_from_job_id == ^ctx.job.id))

    assert successor.status == "queued"
    assert successor.task == "Include the operator runbook."
    assert successor.runtime_thread_id == "thread-#{ctx.job.id}"
    assert successor.source_actor_event_id == ctx.steer.id
    source = Repo.get!(Job, ctx.job.id)
    assert source.status == "succeeded"
    assert is_binary(successor.metadata["owner_conversation_id"])
    assert successor.metadata["owner_conversation_id"] == source.metadata["owner_conversation_id"]
    assert Repo.get!(ActorEvent, ctx.steer.id).completed_at != nil

    wakeup =
      Repo.one!(
        from(event in ActorEvent,
          where:
            event.agent_uid == ^ctx.agent.uid and event.session_id == ^source.owner_session_id
        )
      )

    assert get_in(wakeup.payload, ["data", "successor_job_id"]) == successor.id
  end

  defp write_library_page(dir, slug, body) do
    File.write!(Path.join(dir, "page.md"), """
    ---
    slug: #{slug}
    type: concept
    title: Library concurrency
    aliases:
      - Shipped alias
    ---

    #{body}
    """)
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

  defp start_unboxed(fun) do
    parent = self()

    task =
      Task.async(fn ->
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

  defp pause_after_query(predicate) do
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
  end
end
