defmodule Ankole.E2E.ChaosE2ETest do
  @moduledoc """
  Worker drain, process death, instance replacement, persistent Home and
  cache, control-plane restart, and message recovery through real Docker.
  PostgreSQL owns fences, pending events, and outbox state. The supervisor
  restarts a failed process inside its instance; the control plane replaces
  a deleted instance with a new generation and the same persistent Home.
  """

  use Ankole.DataCase, async: false

  import Ecto.Query
  import Ankole.E2E.Harness

  import Ankole.E2E.Scenarios.ScheduleAndTool, only: [run_reply_attachment_tool_loop: 1]

  import Ankole.E2E.WaitHelpers,
    only: [deadline: 1, wait_until: 2, wait_for_completed_final_reply: 3]

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ReconcileJob
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRoute
  alias Ankole.SignalsGateway.Entry
  alias Ankole.E2E.DockerWorker
  alias Ankole.E2E.FakeOpenAIState
  alias Ankole.Repo
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.Workflow.RunServer, as: WorkflowRunServer
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run, as: WorkflowRun

  @tag timeout: 900_000
  @tag ownership_timeout: 900_000
  @tag :real_llm
  @tag :real_llm_chaos
  test "real DeepSeek recovers an admitted command after Driver death while the tenant is suspended",
       %{tenant: tenant} do
    ctx = start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
    command = real_command_inflight!(ctx, "driver")
    assert {:ok, suspended} = Ankole.Tenants.suspend(tenant)
    monitor = Process.monitor(command.pid)
    Process.exit(command.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 5_000
    assert Repo.reload!(command.input).completed_at == nil

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_live_suspended",
               message_id: "om_live_suspended",
               chat_id: command.attrs[:chat_id],
               chat_type: "p2p",
               text: "Reply NEW_WORK_MUST_NOT_START."
             )

    assert wait_for_event_ack!(ctx.fake_feishu, "evt_live_suspended") == 200
    refute Repo.get_by(Entry, source_entry_id: "om_live_suspended")
    refute Repo.get_by(ActorEvent, source_entry_id: "om_live_suspended")

    # The same recovery owner used by the periodic job must recover admitted work.
    assert :ok = Ankole.Conversations.Reconciler.reconcile()
    %{failure: 0} = Oban.drain_queue(queue: :conversations)
    assert_real_command_recovered!(ctx, command)

    assert {:ok, _} = Ankole.Tenants.resume(suspended)
    initial_connections = FakeFeishu.State.connection_count(ctx.fake_feishu.state)
    assert initial_connections > 0
    assert :ok = FakeFeishu.State.drop_ws_connections(ctx.fake_feishu.state)

    for _ <- 1..initial_connections do
      assert_receive {:fake_feishu, {:ws_disconnected, _}}, 15_000
    end

    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               FakeFeishu.State.connection_count(ctx.fake_feishu.state) >= initial_connections
             end)

    # Keep the provider message identity and use a fresh delivery event so its
    # acknowledgement cannot be confused with the original delivery.
    assert :ok =
             FakeFeishu.State.user_sends_message(
               ctx.fake_feishu.state,
               Keyword.put(command.attrs, :event_id, "evt_live_driver_redelivery")
             )

    assert wait_for_event_ack!(ctx.fake_feishu, "evt_live_driver_redelivery") == 200
    finalize_due_inbound_batch_events!()
    assert_one_real_reply!(command.input)
    assert DockerWorker.exec!(ctx.container, ["cat", command.path]) == command.nonce <> "\n"

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_live_resumed",
               message_id: "om_live_resumed",
               chat_id: command.attrs[:chat_id],
               chat_type: "p2p",
               text: "Reply exactly REAL_CHAOS_RESUMED. Do not call tools."
             )

    resumed_input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_live_resumed")
    assert {:ok, _} = ensure_input_driver!(resumed_input, resumed_input.available_at)

    assert {:ok, reply, _} =
             wait_for_completed_final_reply(ctx.container, resumed_input.id, deadline(180_000))

    assert_lark_final_reply(
      ctx.fake_feishu,
      reply,
      "REAL_CHAOS_RESUMED",
      :reply,
      "om_live_resumed"
    )
  end

  @tag timeout: 900_000
  @tag ownership_timeout: 900_000
  @tag :real_llm
  @tag :real_llm_chaos
  test "real DeepSeek checks a persisted file after Worker death without repeating the interrupted write" do
    ctx =
      start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!(), replaces_workers: true)

    command = real_command_inflight!(ctx, "worker")
    generation = Repo.get!(AgentWorker, ctx.agent.uid).generation
    volumes = DockerWorker.storage_volumes(ctx.agent.uid)
    assert :ok = DockerWorker.kill_docker_worker!(ctx.container)

    messages = assert_real_command_recovered!(ctx, command)

    assert %AgentWorker{state: "ready", generation: next_generation} =
             Repo.get!(AgentWorker, ctx.agent.uid)

    assert is_binary(next_generation)
    refute next_generation == generation
    assert DockerWorker.storage_volumes(ctx.agent.uid) == volumes

    assert Enum.any?(tool_results(messages, "command"), fn result ->
             tool_result_error?(result) and
               String.contains?(Ankole.JSON.encode!(result.result), "result is unknown")
           end)
  end

  @tag timeout: 900_000
  @tag ownership_timeout: 900_000
  @tag :real_llm
  @tag :real_llm_chaos
  @tag :deepseek_tenant_isolation
  @tag sandbox: false
  test "real DeepSeek keeps identical platform identities and private files separate across tenants",
       %{tenant: tenant_a} do
    assert :ok = Ankole.Tenants.ensure_scaffold(tenant_a)
    cleanup_committed_fixtures_on_exit!()
    fake_feishu = start_fake_feishu!()
    domain_a = setup_lark_real_llm_domain!(openrouter_api_key!(), fake_feishu)
    tenant_b = Ankole.DataCase.create_tenant()

    agent_b =
      Repo.with_tenant(tenant_b.id, fn ->
        assert :ok = Ankole.Tenants.ensure_scaffold(tenant_b)
        cleanup_committed_fixtures_on_exit!()

        %{principal: agent} =
          create_e2e_agent!(%{display_name: "Second tenant Agent", role: "Isolation test Agent"})

        for profile <- ["primary", "light"] do
          assert {:ok, _} =
                   Ankole.AIAgent.ModelProfiles.put_model_profile(agent.uid, profile, %{
                     provider_id: domain_a.provider_id,
                     model: "deepseek/deepseek-v4.1-flash"
                   })
        end

        upsert_lark_binding!(agent.uid, "lark-real-isolation", :ignore, fake_feishu,
          app_id: secondary_app_id(),
          group_message_mode: "addressed_only"
        )

        agent
      end)

    start_lark_connections!(fake_feishu, connections: 4)
    worker_a = start_worker!([domain_a.agent.uid])
    worker_b = Repo.with_tenant(tenant_b.id, fn -> request_worker!(agent_b.uid) end)

    subjects =
      [
        %{
          tenant: tenant_a,
          agent: domain_a.agent,
          app_id: primary_app_id(),
          binding_name: domain_a.primary_binding.name,
          container: worker_a.container,
          reference: "A#{100_000 + :rand.uniform(899_999)}"
        },
        %{
          tenant: tenant_b,
          agent: agent_b,
          app_id: secondary_app_id(),
          binding_name: "lark-real-isolation",
          container: worker_b,
          reference: "B#{100_000 + :rand.uniform(899_999)}"
        }
      ]
      |> Enum.map(fn subject ->
        Map.put(
          subject,
          :report,
          "Shipment reference: #{subject.reference}. Ready items: #{:rand.uniform(99)}."
        )
      end)

    # The platform inputs are identical. Only the app's owning tenant and its
    # private computer file differ, so the fake platform need not invent IDs.
    attrs = [
      event_id: "evt_live_same_identity",
      create_time_ms: System.system_time(:millisecond),
      message_id: "om_live_same_identity",
      chat_id: "oc_live_same_identity",
      chat_type: "p2p",
      sender_user_id: "ou_live_same_sender",
      sender_open_id: "ou_live_same_sender",
      text:
        "I placed a synthetic shipment report in /workspace/private.txt. " <>
          "It contains fictional business data, no credentials or personal data. " <>
          "Use read_file to read the report and reply with its shipment reference."
    ]

    inputs =
      Enum.map(subjects, fn subject ->
        Repo.with_tenant(subject.tenant.id, fn ->
          DockerWorker.exec!(subject.container, [
            "sh",
            "-c",
            "printf '%s' '#{subject.report}' > /workspace/private.txt"
          ])

          assert :ok =
                   FakeFeishu.State.user_sends_message(
                     fake_feishu.state,
                     Keyword.put(attrs, :to_app, subject.app_id)
                   )

          input = actor_event_by_source_entry_id!(subject.agent.uid, attrs[:message_id])
          assert {:ok, _} = ensure_input_driver!(input, input.available_at)
          Map.put(subject, :input, input)
        end)
      end)

    results =
      Enum.map(inputs, fn subject ->
        Repo.with_tenant(subject.tenant.id, fn ->
          assert {:ok, reply, _} =
                   wait_for_completed_final_reply(
                     subject.container,
                     subject.input.id,
                     deadline(240_000)
                   )

          assert_lark_final_reply(
            fake_feishu,
            reply,
            subject.reference,
            :reply,
            attrs[:message_id]
          )

          messages = Ankole.E2E.WaitHelpers.ai_messages_for_actor_event(subject.input.id)
          reads = successful_tool_results(messages, "read_file")
          assert Enum.any?(reads, &String.contains?(Ankole.JSON.encode!(&1), subject.report))
          assert_one_real_reply!(subject.input)
          entry = Repo.get_by!(Entry, source_entry_id: attrs[:message_id])
          assert entry.tenant_id == subject.tenant.id
          assert subject.input.tenant_id == subject.tenant.id
          assert reply.tenant_id == subject.tenant.id

          assert {:ok, %{config: config}} =
                   Ankole.SignalsGateway.Bindings.get_binding_configuration(
                     subject.agent.uid,
                     subject.binding_name
                   )

          namespace = Ankole.Plugins.LarkAdapter.Config.subject_namespace(config)

          assert {:ok, human} =
                   Ankole.Principals.resolve_platform_subject(namespace, "ou_live_same_sender")

          for other <- inputs, other.tenant.id != subject.tenant.id do
            refute reply.text =~ other.reference
            refute Ankole.JSON.encode!(reads) =~ other.reference
            refute Repo.get(ActorEvent, other.input.id)
            assert {:error, :not_found} = Ankole.Principals.get_agent(other.agent.uid)
          end

          %{entry: entry, human_uid: human.uid, reply: reply}
        end)
      end)

    [result_a, result_b] = results
    assert result_a.entry.document_id == result_b.entry.document_id
    refute result_a.human_uid == result_b.human_uid
    refute result_a.reply.source_entry_id == result_b.reply.source_entry_id
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :conversation_recovery
  test "Worker shutdown leaves the control-plane model turn running without replay" do
    ctx = start_worker_e2e_stack!(replaces_workers: true)

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_drain_1",
               message_id: "om_chaos_drain_1",
               chat_id: "oc_chaos_drain",
               chat_type: "p2p",
               text:
                 "@_user_1 Trigger CHAOS_FOLLOWUP_SLOW and reply exactly CHAOS_FOLLOWUP_FIRST_OK.",
               mentions: [lark_bot_mention()]
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_drain_1")

    assert {:ok, %{status: :driving}} = ensure_input_driver!(input, input.available_at)

    assert_receive {:fake_llm_request, :followup_slow, 1, _request}, 15_000
    %AgentWorker{generation: generation} = Repo.get!(AgentWorker, ctx.agent.uid)
    signalled_at = DateTime.add(DateTime.utc_now(), -1, :second)
    assert :ok = DockerWorker.signal_docker_worker!(ctx.container, "TERM")

    assert {:ok, %ActorEvent{completed_at: %DateTime{}, final_response_id: "resp_" <> _}} =
             wait_until(deadline(120_000), fn ->
               case Repo.get(ActorEvent, input.id) do
                 %ActorEvent{completed_at: %DateTime{}} = event -> event
                 _event -> nil
               end
             end)

    # The drained Worker exits 0, and its container stops.
    assert {:ok, [0]} =
             wait_until(deadline(30_000), fn ->
               case DockerWorker.exit_codes_since(ctx.container, signalled_at) do
                 [] -> nil
                 codes -> codes
               end
             end)

    assert {:ok, :idle} = Ankole.Conversations.Run.rebuild(input)

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(ctx.container, input.id, deadline(120_000))

    assert FakeOpenAIState.counters()[:followup_slow] == 1

    # A request replaces the exited instance after confirming its absence.
    request_worker!(ctx.agent.uid)
    assert %AgentWorker{generation: next_generation} = Repo.get!(AgentWorker, ctx.agent.uid)
    refute next_generation == generation

    assert_lark_final_reply(
      ctx.fake_feishu,
      reply,
      "CHAOS_FOLLOWUP_FIRST_OK",
      :reply,
      "om_chaos_drain_1"
    )
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :conversation_recovery
  test "a suspended tenant recovers accepted input after Driver death and resumes new work", %{
    tenant: tenant
  } do
    ctx = start_worker_e2e_stack!()

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_kill_1",
               message_id: "om_chaos_kill_1",
               chat_id: "oc_chaos_kill",
               chat_type: "p2p",
               text: "@_user_1 Trigger CHAOS_FOLLOWUP_SLOW.",
               mentions: [lark_bot_mention()]
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_kill_1")
    assert {:ok, %{pid: pid}} = ensure_input_driver!(input, input.available_at)
    assert_receive {:fake_llm_request, :followup_slow, 1, _request}, 15_000
    assert Repo.reload!(input).attempt_count == 1
    assert {:ok, suspended} = Ankole.Tenants.suspend(tenant)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    assert Repo.reload!(input).completed_at == nil

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_suspended",
               message_id: "om_chaos_suspended",
               chat_id: "oc_chaos_kill",
               chat_type: "p2p",
               text: "@_user_1 Trigger CHAOS_FOLLOWUP_SECOND_OK.",
               mentions: [lark_bot_mention()]
             )

    assert wait_for_event_ack!(ctx.fake_feishu, "evt_chaos_suspended") == 200
    refute Repo.get_by(Entry, source_entry_id: "om_chaos_suspended")
    refute Repo.get_by(ActorEvent, source_entry_id: "om_chaos_suspended")
    refute FakeOpenAIState.counters()[:followup_second]

    reconcile_at = DateTime.add(DateTime.utc_now(:microsecond), 61)
    assert :ok = Ankole.Conversations.Reconciler.reconcile(reconcile_at)
    Oban.drain_queue(queue: :conversations, with_scheduled: reconcile_at)

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(ctx.container, input.id, deadline(60_000))

    assert Repo.reload!(input).attempt_count == 2
    assert FakeOpenAIState.counters()[:followup_slow] == 2

    assert_lark_final_reply(
      ctx.fake_feishu,
      reply,
      "CHAOS_FOLLOWUP_FIRST_OK",
      :reply,
      "om_chaos_kill_1"
    )

    assert {:ok, _resumed} = Ankole.Tenants.resume(suspended)

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_resumed",
               message_id: "om_chaos_resumed",
               chat_id: "oc_chaos_kill",
               chat_type: "p2p",
               text: "@_user_1 Trigger CHAOS_FOLLOWUP_SECOND_OK.",
               mentions: [lark_bot_mention()]
             )

    resumed_input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_resumed")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(resumed_input, resumed_input.available_at)

    assert {:ok, resumed_reply, _message} =
             wait_for_completed_final_reply(ctx.container, resumed_input.id, deadline(60_000))

    assert_lark_final_reply(
      ctx.fake_feishu,
      resumed_reply,
      "CHAOS_FOLLOWUP_SECOND_OK",
      :reply,
      "om_chaos_resumed"
    )
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "a crashed Worker process starts again in its container and ends the processes it left" do
    ctx = start_worker_e2e_stack!(replaces_workers: true)

    %AgentWorker{generation: generation, incarnation_id: incarnation} =
      Repo.get!(AgentWorker, ctx.agent.uid)

    # A process in its own session, like a command that the Worker started.
    DockerWorker.exec!(ctx.container, ["sh", "-c", "setsid sleep 1000 >/dev/null 2>&1 &"])
    assert DockerWorker.exec!(ctx.container, ["pgrep", "-x", "sleep"]) =~ ~r/^\d+/

    crashed_at = DateTime.add(DateTime.utc_now(), -1, :second)
    DockerWorker.exec!(ctx.container, ["pkill", "-KILL", "-f", "^bun .*src/main.ts"])

    # The supervisor in the image starts the Worker again in the same
    # container: a new incarnation of the same generation joins.
    assert {:ok, %AgentWorker{generation: ^generation}} =
             wait_until(deadline(60_000), fn ->
               case Repo.get(AgentWorker, ctx.agent.uid) do
                 %AgentWorker{state: "ready", incarnation_id: id} = worker
                 when is_binary(id) and id != incarnation ->
                   worker

                 _worker ->
                   nil
               end
             end)

    assert [] = DockerWorker.exit_codes_since(ctx.container, crashed_at)
    assert DockerWorker.exec!(ctx.container, ["sh", "-c", "pgrep -x sleep || true"]) == ""
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :worker_storage_lifecycle
  @tag sandbox: false
  test "idle release deletes the instance, wake restores Home and cache, and tenant deletion removes both",
       %{tenant: tenant} do
    assert {:ok, privileged} = Ankole.Tenants.privileged()
    refute tenant.id == privileged.id
    assert :ok = Ankole.Tenants.ensure_scaffold(tenant)
    cleanup_committed_fixtures_on_exit!()
    ctx = start_worker_e2e_stack!(replaces_workers: true)
    agent_uid = ctx.agent.uid
    generation = Repo.get!(AgentWorker, agent_uid).generation
    first_container = DockerWorker.container_name(agent_uid)
    volumes = DockerWorker.storage_volumes(agent_uid)
    marker = "/agents/#{agent_uid}/persistent-marker"
    cache_marker = "/var/cache/ankole/cache-marker"

    DockerWorker.exec!(ctx.container, [
      "sh",
      "-ec",
      "echo kept > #{marker}; echo cached > #{cache_marker}"
    ])

    put_idle_release_after!(agent_uid, "1s")
    stop_idle_worker!(agent_uid)
    assert DockerWorker.container_info(first_container) == nil
    assert DockerWorker.volume_exists?(volumes.home)
    assert DockerWorker.volume_exists?(volumes.cache)

    input = send_file_message!(ctx, "om_chaos_absent_file_1", "oc_chaos_absent_file")
    [%{"path" => path}] = get_in(input.payload, ["data", "entry", "attachments"])
    assert {:ok, _file, "CHAOS_INBOUND_FILE_BYTES deck"} = Ankole.Files.read(agent_uid, path)
    assert %AgentWorker{state: "absent"} = Repo.get!(AgentWorker, agent_uid)
    retry_until_sent!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(ctx.container, input.id, deadline(120_000))

    assert reply.text =~ "CHAOS_GENERIC_OK"
    assert %AgentWorker{state: "absent"} = Repo.get!(AgentWorker, agent_uid)

    # This reply needs no computer. A separate execution demand wakes it.
    request_worker!(agent_uid)

    assert %AgentWorker{state: "ready", generation: next_generation} =
             Repo.get!(AgentWorker, agent_uid)

    assert is_binary(next_generation)
    refute next_generation == generation
    assert DockerWorker.storage_volumes(agent_uid) == volumes
    assert DockerWorker.exec!(ctx.container, ["cat", marker, cache_marker]) == "kept\ncached\n"

    assert Enum.any?(FakeOpenAIState.requests(), fn entry ->
             String.contains?(Ankole.JSON.encode!(entry.request), path)
           end)

    last_container = DockerWorker.container_name(agent_uid)
    assert {:ok, _} = Ankole.Tenants.delete(tenant)

    assert {:ok, true} =
             wait_until(deadline(60_000), fn ->
               result =
                 Oban.drain_queue(
                   queue: :default,
                   with_scheduled: DateTime.add(DateTime.utc_now(), 5, :second),
                   with_limit: 20
                 )

               assert result.failure == 0, inspect(result)
               Ankole.Tenants.get(tenant.id) == {:error, :not_found}
             end)

    refute Repo.get(AgentWorker, agent_uid)

    assert DockerWorker.container_info(last_container) == nil
    refute DockerWorker.volume_exists?(volumes.home)
    refute DockerWorker.volume_exists?(volumes.cache)
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag sandbox: false
  @tag :worker_job_recovery
  test "a waiting Codex Job resumes its thread and files after idle instance deletion" do
    Ankole.E2E.Scenarios.WorkerJobRecovery.run()
  end

  for max_slots <- [1, 9] do
    @tag timeout: 180_000
    @tag ownership_timeout: 180_000
    @tag sandbox: false
    @tag :worker_job_reconnect
    test "a running Codex Job resumes after a disconnect with #{max_slots} Worker slots" do
      Ankole.E2E.Scenarios.WorkerJobRecovery.reconnect(unquote(max_slots))
    end
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag sandbox: false
  @tag :worker_image_replacement
  test "an image change waits for an active Turn, preserves storage, and applies on the next wake" do
    cleanup_committed_fixtures_on_exit!()
    ctx = start_worker_e2e_stack!(replaces_workers: true)
    agent_uid = ctx.agent.uid
    old = Repo.get!(AgentWorker, agent_uid)
    old_container = DockerWorker.container_name(agent_uid)
    new_image = DockerWorker.tag_image!("switch")
    volumes = DockerWorker.storage_volumes(agent_uid)

    DockerWorker.exec!(ctx.container, [
      "sh",
      "-ec",
      "printf home > /workspace/image-marker; printf cache > /var/cache/ankole/image-marker"
    ])

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_switch_1",
               message_id: "om_chaos_switch_1",
               chat_id: "oc_chaos_switch",
               chat_type: "p2p",
               text: "@_user_1 Trigger CHAOS_LONG_TURN and reply exactly CHAOS_LONG_TURN_OK.",
               mentions: [lark_bot_mention()]
             )

    input = actor_event_by_source_entry_id!(agent_uid, "om_chaos_switch_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert_receive {:fake_llm_request, :long_turn, 1, _request}, 15_000

    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               DockerWorker.exec!(ctx.container, [
                 "sh",
                 "-c",
                 "test -e /workspace/image-command-started && echo started || true"
               ]) == "started\n"
             end)

    # An environment command holds a Worker slot until the workspace closes.
    DockerWorker.switch_image!(new_image)

    assert :ok =
             ReconcileJob.perform(%Oban.Job{
               args: %{"agent_uid" => agent_uid, "tenant_id" => Repo.tenant_id!()}
             })

    assert %AgentWorker{state: "ready", generation: generation, image: image} =
             Repo.get!(AgentWorker, agent_uid)

    assert {generation, image} == {old.generation, old.image}

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(ctx.container, input.id, deadline(120_000))

    assert reply.text =~ "CHAOS_LONG_TURN_OK"

    # Idle now, it is replaced by a Worker of the new image.
    assert {:ok, %AgentWorker{generation: new_generation}} =
             wait_until(deadline(120_000), fn ->
               case Repo.get!(AgentWorker, agent_uid) do
                 %AgentWorker{state: "ready", image: ^new_image} = worker -> worker
                 _worker -> nil
               end
             end)

    assert new_generation != old.generation
    assert DockerWorker.container_info(old_container) == nil
    new_container = DockerWorker.container_name(agent_uid)
    assert %{image: ^new_image, status: "running"} = DockerWorker.container_info(new_container)

    assert {:error, old_route_error} =
             WorkerRoute.connection_pid(%{
               worker_id: agent_uid,
               transport_route: old.transport_route
             })

    assert old_route_error in [:stale_route, :unknown_route]
    replacement = Repo.get!(AgentWorker, agent_uid)

    assert {:error, %{"code" => "unknown_rpc_method"}} =
             WorkerRoute.request_rpc(
               %{worker_id: agent_uid, transport_route: replacement.transport_route},
               "worker.no_such_method",
               <<>>,
               timeout_ms: 10_000
             )

    assert DockerWorker.storage_volumes(agent_uid) == volumes

    assert DockerWorker.exec!(ctx.container, [
             "cat",
             "/workspace/image-marker",
             "/var/cache/ankole/image-marker"
           ]) == "homecache"

    put_idle_release_after!(agent_uid, "1s")
    stop_idle_worker!(agent_uid)
    DockerWorker.switch_image!(old.image)

    assert {:ok, _worker} =
             wait_until(deadline(60_000), fn ->
               case Repo.get!(AgentWorker, agent_uid) do
                 %AgentWorker{state: "absent", generation: nil} = worker -> worker
                 _worker -> nil
               end
             end)

    assert DockerWorker.container_info(new_container) == nil
    request_worker!(agent_uid)
    assert Repo.get!(AgentWorker, agent_uid).image == old.image

    assert DockerWorker.exec!(ctx.container, [
             "cat",
             "/workspace/image-marker",
             "/var/cache/ankole/image-marker"
           ]) == "homecache"
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  @tag :conversation_recovery
  test "Worker death does not replay a Workflow model task or consume its call budget" do
    ctx = start_worker_e2e_stack!(replaces_workers: true)

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_wf_kill_1",
               message_id: "om_chaos_wf_kill_1",
               chat_id: "oc_chaos_wf_kill",
               chat_type: "p2p",
               text:
                 "@_user_1 Trigger CHAOS_WF_KILL_START and reply exactly CHAOS_WF_KILL_STARTED_OK.",
               mentions: [lark_bot_mention()]
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_wf_kill_1")

    assert {:ok, %{status: :driving}} = ensure_input_driver!(input, input.available_at)

    assert {:ok, start_reply, _message} =
             wait_for_completed_final_reply(ctx.container, input.id, deadline(120_000))

    assert start_reply.text =~ "CHAOS_WF_KILL_STARTED_OK"

    run =
      Repo.one!(
        from(run in WorkflowRun,
          where: run.agent_uid == ^ctx.agent.uid,
          where: run.source_actor_event_id == ^input.id
        )
      )

    assert :ok = WorkflowRunServer.poke(run.id)

    assert {:ok, %AgentCall{} = call} =
             wait_until(deadline(30_000), fn ->
               case Repo.get_by(AgentCall, run_id: run.id, call_seq: 0) do
                 %AgentCall{} = call -> {:ok, call}
                 nil -> nil
               end
             end)

    dispatch_event =
      Repo.get_by!(ActorEvent,
        agent_uid: ctx.agent.uid,
        source_event_id: "workflow:call:#{call.id}:dispatch"
      )

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(dispatch_event, dispatch_event.available_at)

    assert_receive {:fake_llm_request, :workflow_kill_task, 1, _request}, 30_000
    DockerWorker.kill_docker_worker!(ctx.container)

    assert {:ok, %AgentCall{} = call} =
             wait_until(deadline(120_000), fn ->
               case Repo.get!(AgentCall, call.id) do
                 %AgentCall{status: "succeeded"} = done -> {:ok, done}
                 %AgentCall{status: status} when status in ["failed", "cancelled"] -> {:ok, call}
                 _pending -> nil
               end
             end)

    assert call.status == "succeeded"
    assert call.result == %{"ok" => true, "value" => "killed-and-recovered"}
    assert call.attempts == 1
    assert FakeOpenAIState.counters()[:workflow_kill_task] == 1

    assert :ok = WorkflowRunServer.poke(run.id)

    assert {:ok, %ActorEvent{} = completion} =
             wait_until(deadline(30_000), fn ->
               case Repo.get_by(ActorEvent,
                      agent_uid: ctx.agent.uid,
                      source_event_id: "workflow:#{run.id}:completed"
                    ) do
                 %ActorEvent{} = event -> {:ok, event}
                 nil -> nil
               end
             end)

    assert Repo.get!(WorkflowRun, run.id).status == "completed"

    assert {:ok, %{status: :driving}} = ensure_input_driver!(completion, completion.available_at)

    assert {:ok, done_reply, _message} =
             wait_for_completed_final_reply(ctx.container, completion.id, deadline(120_000))

    assert done_reply.text =~ "CHAOS_WF_KILL_DONE_OK"

    assert_lark_final_reply(
      ctx.fake_feishu,
      done_reply,
      "CHAOS_WF_KILL_DONE_OK",
      :reply,
      "om_chaos_wf_kill_1"
    )
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "control-plane server restart re-routes the reconnected worker and it completes turns" do
    ctx = start_worker_e2e_stack!()
    before = Repo.get!(AgentWorker, ctx.agent.uid)

    restart_control_plane_http_server!(ctx.server_port)

    # The same Worker process joins again on a new connection.
    assert {:ok, %AgentWorker{} = rejoined} =
             wait_until(deadline(60_000), fn ->
               case Repo.get!(AgentWorker, ctx.agent.uid) do
                 %AgentWorker{state: "ready", transport_route: route} = worker
                 when route != before.transport_route ->
                   worker

                 _worker ->
                   nil
               end
             end)

    assert rejoined.generation == before.generation
    assert rejoined.incarnation_id == before.incarnation_id

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_router_restart_1",
               message_id: "om_chaos_router_restart_1",
               chat_id: "oc_chaos_router_restart",
               chat_type: "p2p",
               text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
               mentions: [lark_bot_mention()]
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_router_restart_1")
    retry_until_sent!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(ctx.container, input.id, deadline(120_000))

    assert reply.text =~ "CHAOS_DIRECT_OK"

    assert_lark_final_reply(
      ctx.fake_feishu,
      reply,
      "CHAOS_DIRECT_OK",
      :reply,
      "om_chaos_router_restart_1"
    )
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "an attachment whose local file is removed after the turn still delivers the pinned bytes" do
    ctx = start_worker_e2e_stack!()
    %{outbox: outbox} = run_reply_attachment_tool_loop(ctx)

    # reply_attachment pinned the file under sent/ in the drive at tool time,
    # so removing the local copy afterwards changes nothing that is delivered.
    pattern = "/agents/#{ctx.agent.uid}/sessions/*/reports/chaos-report.txt"

    assert DockerWorker.exec!(ctx.container, ["sh", "-c", "rm -v #{pattern}"]) =~
             "chaos-report.txt"

    dispatch_and_assert_lark_file_outbox(ctx.fake_feishu, outbox, "om_reply_attachment_1")
  end

  @tag timeout: 120_000
  @tag ownership_timeout: 120_000
  test "event redelivery after a WS reconnect stays deduplicated" do
    ctx = start_worker_e2e_stack!(worker: false)

    attrs = [
      event_id: "evt_chaos_redelivery_1",
      message_id: "om_chaos_redelivery_1",
      chat_id: "oc_chaos_redelivery",
      chat_type: "p2p",
      text: "@_user_1 Deduplicate me across reconnects.",
      mentions: [lark_bot_mention()]
    ]

    assert :ok = FakeFeishu.State.user_sends_message(ctx.fake_feishu.state, attrs)
    assert %ActorEvent{} = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_redelivery_1")

    initial_connection_count = FakeFeishu.State.connection_count(ctx.fake_feishu.state)
    assert initial_connection_count > 0
    assert :ok = FakeFeishu.State.drop_ws_connections(ctx.fake_feishu.state)

    for _index <- 1..initial_connection_count do
      assert_receive {:fake_feishu, {:ws_disconnected, _conn_id}}, 15_000
    end

    # Wait until every dropped consumer has a replacement. The disconnect
    # events remove the old connections before a matching count can succeed.
    assert {:ok, _count} =
             wait_until(deadline(30_000), fn ->
               count = FakeFeishu.State.connection_count(ctx.fake_feishu.state)
               count >= initial_connection_count && count
             end)

    # The provider redelivers the same event after reconnect; the gateway must
    # not create a second entry or a second actor event.
    assert :ok = FakeFeishu.State.user_sends_message(ctx.fake_feishu.state, attrs)
    wait_for_event_ack!(ctx.fake_feishu, "evt_chaos_redelivery_1")
    finalize_due_inbound_batch_events!()

    redelivered_events =
      ActorEvent
      |> where([input], input.agent_uid == ^ctx.agent.uid)
      |> where([input], input.source_entry_id == "om_chaos_redelivery_1")
      |> order_by([input], asc: input.inserted_at, asc: input.id)
      |> Repo.all()

    assert length(redelivered_events) == 1, inspect(redelivered_events, limit: :infinity)

    assert %{} = wait_for_signal_entry!("lark:oc_chaos_redelivery", "om_chaos_redelivery_1")
  end

  @tag timeout: 600_000
  @tag ownership_timeout: 600_000
  test "a rejected provider send leaves no platform message and stops for good" do
    ctx = start_worker_e2e_stack!(worker: false)

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_chaos_sendfail_1",
               message_id: "om_chaos_sendfail_1",
               chat_id: "oc_chaos_sendfail",
               chat_type: "p2p",
               text: "/new",
               mentions: []
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, "om_chaos_sendfail_1")
    assert input.type == "command.new"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert_actor_event_finished!(input.id)
    outbox = Repo.get_by!(OutboxEntry, source_actor_event_id: input.id)
    assert outbox.payload == %{"text" => "Started a new conversation."}

    # One-shot injected business rejection BEFORE any platform state change:
    # the dispatch attempt must fail without a visible message.
    FakeFeishu.State.fail_next(ctx.fake_feishu.state, :reply_message, {:code, 500_100})

    run_outbox_dispatch!()
    failed_row = Repo.reload!(outbox)
    refute failed_row.status == :succeeded

    bot_visible =
      ctx.fake_feishu.state
      |> FakeFeishu.State.visible_messages("oc_chaos_sendfail")
      |> Enum.filter(&(&1.sender == :bot))

    assert bot_visible == []

    # A non-transport business rejection of a plain send is permanent: no
    # automatic retry may fire, and the row must carry the recovery state
    # that records the stop instead of failing silently.
    assert failed_row.status == :failed
    assert failed_row.recovery_state["state"] == "permanent"
    assert failed_row.next_attempt_at == nil

    assert {:error, :outbox_manual_requeue_required} =
             Ankole.SignalsGateway.dispatch_outbox_by_key(
               failed_row.agent_uid,
               failed_row.binding_name,
               failed_row.outbound_key,
               now: DateTime.utc_now(:microsecond)
             )

    # A `:generic` delivery (command feedback) has no operator requeue
    # surface — permanent means stopped for good; only `:durable_ai_reply`
    # rows accept an explicit retry.
    assert failed_row.delivery_class == :generic

    assert {:error, :outbox_not_requeueable} =
             Ankole.SignalsGateway.requeue_outbox(
               failed_row.agent_uid,
               failed_row.binding_name,
               failed_row.outbound_key
             )

    # Stopped means stopped: nothing was partially sent then or later.
    bot_visible_after =
      ctx.fake_feishu.state
      |> FakeFeishu.State.visible_messages("oc_chaos_sendfail")
      |> Enum.filter(&(&1.sender == :bot))

    assert bot_visible_after == []
  end

  defp put_idle_release_after!(agent_uid, duration) do
    {:ok, provider} = Providers.load(Repo.get!(AgentWorker, agent_uid).provider_id)
    config = provider.settings |> Map.put("idleReleaseAfter", duration) |> Ankole.JSON.encode!()
    assert {:ok, _provider} = Providers.update(provider.provider_id, %{config: config})
  end

  defp real_command_inflight!(ctx, label) do
    nonce = "AUDIT_" <> Ecto.UUID.generate()
    path = "/workspace/real-chaos-#{label}.log"
    shell = "printf '%s\\n' '#{nonce}' >> '#{path}'; sleep 30; cat '#{path}'"

    attrs = [
      event_id: "evt_live_#{label}",
      message_id: "om_live_#{label}",
      chat_id: "oc_live_#{label}",
      chat_type: "p2p",
      text: """
      Record this operations handoff exactly once in the isolated Agent computer.
      Call command exactly once with command #{Ankole.JSON.encode!(shell)} and timeout 60.
      The append records a real effect: do not execute that command a second time.
      If execution is interrupted or its result is unknown, check the existing file instead
      of repeating the write. In either case use read_file on #{path} to verify its content.
      Only after the file proves there is exactly one record, reply with REAL_CHAOS_RECOVERED
      followed by the record. If you cannot verify that fact, report the problem honestly.
      """
    ]

    assert :ok = FakeFeishu.State.user_sends_message(ctx.fake_feishu.state, attrs)
    input = actor_event_by_source_entry_id!(ctx.agent.uid, attrs[:message_id])
    assert {:ok, %{pid: pid}} = ensure_input_driver!(input, input.available_at)

    assert {:ok, true} =
             wait_until(deadline(180_000), fn ->
               DockerWorker.exec!(ctx.container, [
                 "sh",
                 "-c",
                 "if [ -f '#{path}' ]; then cat '#{path}'; fi"
               ]) == nonce <> "\n"
             end)

    assert Repo.reload!(input).completed_at == nil
    %{input: input, pid: pid, path: path, nonce: nonce, attrs: attrs}
  end

  defp assert_real_command_recovered!(ctx, command) do
    assert {:ok, reply, _} =
             wait_for_completed_final_reply(ctx.container, command.input.id, deadline(360_000))

    assert_lark_final_reply(
      ctx.fake_feishu,
      reply,
      "REAL_CHAOS_RECOVERED",
      :reply,
      command.attrs[:message_id]
    )

    assert reply.text =~ command.nonce
    assert DockerWorker.exec!(ctx.container, ["cat", command.path]) == command.nonce <> "\n"
    messages = Ankole.E2E.WaitHelpers.ai_messages_for_actor_event(command.input.id)
    assert [_] = tool_call_items(messages, "command")
    assert tool_result_succeeded?(messages, "read_file")
    assert_actor_event_completed!(command.input.id)
    assert_one_real_reply!(command.input)
    messages
  end

  defp assert_one_real_reply!(input) do
    assert Repo.aggregate(
             from(event in ActorEvent,
               where: event.agent_uid == ^input.agent_uid,
               where: event.source_entry_id == ^input.source_entry_id
             ),
             :count
           ) == 1

    assert [%OutboxEntry{status: :succeeded}] =
             Repo.all(
               from(outbox in OutboxEntry,
                 where: outbox.source_actor_event_id == ^input.id,
                 where: outbox.delivery_class == :durable_ai_reply
               )
             )
  end

  # Let the real five-minute demand window expire before idle release.
  defp stop_idle_worker!(agent_uid) do
    case wait_until(deadline(360_000), fn ->
           case Repo.get!(AgentWorker, agent_uid) do
             %AgentWorker{state: "absent"} = worker -> worker
             _worker -> nil
           end
         end) do
      {:ok, worker} ->
        worker

      :timeout ->
        flunk(
          "the idle Worker did not release: #{inspect(Repo.get!(AgentWorker, agent_uid))}; open events: #{inspect(open_actor_events(agent_uid))}"
        )
    end
  end

  defp open_actor_events(agent_uid) do
    Repo.all(
      from(event in ActorEvent,
        where: event.agent_uid == ^agent_uid and is_nil(event.completed_at),
        select: map(event, [:id, :type, :session_id, :input_state, :available_at])
      )
    )
  end

  # Sends a rich post with one file and returns its ActorEvent once the event
  # carries the stored attachment.
  defp send_file_message!(ctx, message_id, chat_id) do
    assert :ok =
             FakeFeishu.State.put_inbound_file(
               ctx.fake_feishu.state,
               "file_1",
               "CHAOS_INBOUND_FILE_BYTES deck",
               "deck.pdf"
             )

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_" <> message_id,
               message_id: message_id,
               chat_id: chat_id,
               chat_type: "p2p",
               message_type: "post",
               content: %{
                 "title" => "",
                 "content" => [[%{"tag" => "text", "text" => "Please read the attached report."}]],
                 "files" => [%{"file_key" => "file_1", "file_name" => "deck.pdf"}]
               },
               mentions: []
             )

    input = actor_event_by_source_entry_id!(ctx.agent.uid, message_id)

    assert {:ok, %Entry{attachments: [attachment]}} =
             wait_until(deadline(10_000), fn ->
               case Repo.get_by(Entry,
                      signal_channel_id: "lark:" <> chat_id,
                      source_entry_id: message_id
                    ) do
                 %Entry{attachments: [%{"blob_ref" => blob_ref, "path" => path}]} = entry
                 when is_binary(blob_ref) and is_binary(path) ->
                   entry

                 _entry ->
                   nil
               end
             end)

    assert {:ok, %ActorEvent{} = input} =
             wait_until(deadline(10_000), fn ->
               refreshed = Repo.get!(ActorEvent, input.id)

               if get_in(refreshed.payload, ["data", "entry", "attachments"]) == [attachment],
                 do: refreshed
             end)

    input
  end

  # Re-dispatches one pending input until the Agent's Worker accepts it. Sends
  # fail while the Worker restarts, and each failed placement requests the
  # Worker again; that is the recovery path under test, so the retry loop
  # tolerates those outcomes.
end
