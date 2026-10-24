defmodule Ankole.E2E.RuntimeFabricE2ETest do
  @moduledoc "Production Worker routing and message effects through the real Docker Worker."

  use Ankole.DataCase, async: false

  import Ankole.E2E.Harness
  import Ankole.E2E.WaitHelpers

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.E2E.DockerWorker
  alias Ankole.E2E.FakeOpenAIState
  alias Ankole.RuntimeFabric.V1, as: Proto
  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.WorkerRoute
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.Signals.Signal
  alias Ankole.Signals.WebhookEndpoint

  @moduletag :q03_production
  @moduletag sandbox: false
  @moduletag timeout: 240_000

  setup do
    cleanup_committed_fixtures_on_exit!()
    :ok
  end

  test "the route fence, reconnect, duplicate tool call and image result use the production Channel" do
    ctx = start_worker_e2e_stack!()
    uid = ctx.agent.uid

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai",
               provider_kind: "openai_compatible",
               base_url: "http://127.0.0.1:#{ctx.fake_llm_port}",
               credential_pool: %{entries: [%{label: "Q03 fake model", api_key: "q03-test-only"}]}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(uid, "primary", %{
               provider_id: "openai",
               model: "gpt-4.1",
               provider_options: %{}
             })

    assert {:ok, %{"input_modalities" => modalities}} =
             ModelProfiles.resolve_runtime_model_ref(uid, "primary")

    assert "image" in modalities
    worker = Repo.get!(AgentWorker, uid)
    target = AgentWorkers.target(worker)
    assert {:ok, channel} = WorkerRoute.connection_pid(target)

    # Keep the directory alive while PostgreSQL withdraws its route. A send
    # must consult the current fence, not the cached directory entry.
    try do
      Repo.update_all(from(w in AgentWorker, where: w.agent_uid == ^uid),
        set: [transport_route: Ecto.UUID.generate()]
      )

      assert {:error, :stale_route} =
               WorkerRoute.request_rpc(target, "worker.no_such_method", <<>>, timeout_ms: 1_000)

      assert Process.alive?(channel)
    after
      Repo.update_all(from(w in AgentWorker, where: w.agent_uid == ^uid),
        set: [transport_route: worker.transport_route]
      )
    end

    restart_control_plane_http_server!(ctx.server_port)

    assert {:ok, rejoined} =
             wait_until(deadline(60_000), fn ->
               current = Repo.get!(AgentWorker, uid)

               (current.state == :ready and current.transport_route != worker.transport_route) &&
                 current
             end)

    assert rejoined.generation == worker.generation
    assert rejoined.incarnation_id == worker.incarnation_id
    assert {:error, reason} = WorkerRoute.connection_pid(target)
    assert reason in [:stale_route, :unknown_route]
    target = AgentWorkers.target(rejoined)

    assert {:error, %{"code" => "unknown_rpc_method"}} =
             WorkerRoute.request_rpc(target, "worker.no_such_method", <<>>, timeout_ms: 10_000)

    png =
      File.read!(
        Path.expand("../../../app/control_plane/test/fixtures/sessions/rgba.png", __DIR__)
      )

    DockerWorker.exec!(ctx.container, [
      "sh",
      "-ec",
      "printf '%s' '#{Base.encode64(png)}' | base64 -d > /workspace/q03-image.png"
    ])

    assert {:ok, channel} = WorkerRoute.connection_pid(target)
    :erlang.trace(channel, true, [:receive, {:tracer, self()}])
    on_exit(fn -> if Process.alive?(channel), do: :erlang.trace(channel, false, [:receive]) end)

    input = send!(ctx, "transport", "CHAOS_Q03_TRANSPORT")

    assert_receive {:trace, ^channel, :receive,
                    {:"$gen_call", _from,
                     {:deliver, %Proto.Envelope{body: {:workspace_open, open}}}}},
                   30_000

    assert open.run.signal_id == input.id

    assert_receive {:trace, ^channel, :receive,
                    {:"$gen_call", _from,
                     {:deliver, %Proto.Envelope{body: {:tool_call, call}} = envelope}}},
                   30_000

    assert call.call_id == "call_q03_command"

    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               DockerWorker.exec!(ctx.container, [
                 "sh",
                 "-ec",
                 "test -f /workspace/q03-call-count && echo started || true"
               ]) == "started\n"
             end)

    duplicate = %{envelope | message_id: "q03-duplicate-#{Ecto.UUID.generate()}"}
    assert {:ok, :sent_or_queued} = WorkerRoute.send_mandatory(target, duplicate)
    assert DockerWorker.exec!(ctx.container, ["cat", "/workspace/q03-call-count"]) == "x"
    DockerWorker.exec!(ctx.container, ["touch", "/workspace/q03-call-release"])

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(ctx.container, input.id, deadline(90_000))

    assert reply.message.text =~ "CHAOS_Q03_TRANSPORT_OK"
    assert DockerWorker.exec!(ctx.container, ["cat", "/workspace/q03-call-count"]) == "x"

    assert_receive {:trace, ^channel, :receive,
                    {:"$gen_call", _from,
                     {:deliver, %Proto.Envelope{body: {:workspace_close, closed}}}}},
                   30_000

    assert closed.run == open.run

    # A completed workspace rejects a late execution request. Its transport
    # acknowledgement does not claim a second business execution.
    assert {:ok, :sent_or_queued} =
             WorkerRoute.send_mandatory(target, %{duplicate | message_id: Ecto.UUID.generate()})

    assert {:error, %{"code" => "unknown_rpc_method"}} =
             WorkerRoute.request_rpc(target, "worker.no_such_method", <<>>, timeout_ms: 10_000)

    assert DockerWorker.exec!(ctx.container, ["cat", "/workspace/q03-call-count"]) == "x"

    requests = Enum.filter(FakeOpenAIState.requests(), &(&1.kind == :q03_transport))
    assert Enum.map(requests, & &1.count) == [1, 2, 3]
    final_request = List.last(requests).request

    assert Enum.any?(final_request["messages"], fn message ->
             is_list(message["content"]) and
               Enum.any?(message["content"], fn part ->
                 part["type"] == "image_url" and
                   String.starts_with?(
                     get_in(part, ["image_url", "url"]) || "",
                     "data:image/webp;base64,"
                   )
               end)
           end),
           inspect(final_request)

    assert_lark_final_reply(
      ctx.fake_feishu,
      reply,
      "CHAOS_Q03_TRANSPORT_OK",
      :reply,
      input.provider_message_id
    )
  end

  test "stopping a live Codex Job sends TurnControl through the admitted route" do
    ctx = start_worker_e2e_stack!()
    uid = ctx.agent.uid
    assert {:ok, profile} = ModelProfiles.get_model_profile(uid, "primary")
    assert {:ok, _} = ModelProfiles.put_model_profile(uid, "coding", profile)
    input = send!(ctx, "control", "CHAOS_JOB_CREATE_RECONNECT")
    assert {:ok, _, _} = wait_for_completed_final_reply(ctx.container, input.id, deadline(60_000))
    job = Repo.one!(from(j in Job, where: j.source_signal_id == ^input.id))

    assert {:ok, true} =
             wait_until(deadline(60_000), fn ->
               DockerWorker.exec!(ctx.container, [
                 "sh",
                 "-ec",
                 "test -f /workspace/jobs/#{job.id}/old-command.pid && echo started || true"
               ]) == "started\n"
             end)

    target = AgentWorkers.target(Repo.get!(AgentWorker, uid))
    assert {:ok, channel} = WorkerRoute.connection_pid(target)
    :erlang.trace(channel, true, [:receive, {:tracer, self()}])
    on_exit(fn -> if Process.alive?(channel), do: :erlang.trace(channel, false, [:receive]) end)

    assert {:ok, %{job: %{status: :stopped} = stopped, turn: turn}} =
             BackgroundAgentJobs.request_stop(job.id, %{
               agent_uid: uid,
               cancel_requested_by: "agent:#{uid}",
               reason: "Q03 production TurnControl validation",
               request_id: "q03-stop"
             })

    assert turn.job_id == job.id
    assert turn.attempt == job.attempts
    assert :ok = Ankole.Sessions.stop_job_turn(stopped, turn)

    refute Repo.exists?(
             from(event in Signal,
               where: event.session_id == ^BackgroundAgentJobs.job_session_id(job.id),
               where: event.type == "command.stop"
             )
           )

    assert_receive {:trace, ^channel, :receive,
                    {:"$gen_call", _from,
                     {:deliver, %Proto.Envelope{body: {:turn_control, control}}}}},
                   30_000

    assert control.command == "stop"
    assert control.turn.job_id == job.id

    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               DockerWorker.logs(ctx.container) =~ "worker.turn_controlled_stop"
             end)

    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               DockerWorker.exec!(ctx.container, [
                 "sh",
                 "-ec",
                 "pid=$(cat /workspace/jobs/#{job.id}/old-command.pid); " <>
                   "if kill -0 \"$pid\" 2>/dev/null; then printf alive; else printf gone; fi"
               ]) == "gone"
             end)

    refute DockerWorker.exec!(ctx.container, [
             "sh",
             "-ec",
             "test -f /workspace/jobs/#{job.id}/late-write.txt && echo repeated || true"
           ]) =~ "repeated"
  end

  for boundary <- [:acceptance, :read] do
    @tag :b02_b03_reconnect
    test "same-attempt Job survives a lost #{boundary} connection without repeating its command" do
      boundary = unquote(boundary)
      ctx = start_worker_e2e_stack!()
      uid = ctx.agent.uid
      assert {:ok, profile} = ModelProfiles.get_model_profile(uid, "primary")
      assert {:ok, _} = ModelProfiles.put_model_profile(uid, "coding", profile)
      worker = Repo.get!(AgentWorker, uid)
      assert {:ok, channel} = WorkerRoute.connection_pid(AgentWorkers.target(worker))
      ref = pause_worker_boundary!(channel, boundary)
      input = send!(ctx, "b02-b03-#{boundary}", "CHAOS_JOB_CREATE_RECONNECT B02_B03_ONCE")

      assert_receive {:worker_boundary_paused, ^ref, turn}, 60_000
      job = Repo.get!(Job, turn.job_id)
      assert job.agent_uid == uid
      assert job.attempts == turn.attempt
      assert job.status == :running
      fault_at = System.monotonic_time(:millisecond)
      monitor = Process.monitor(channel)
      Process.exit(channel, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^channel, :killed}, 10_000

      assert {:ok, rejoined} =
               wait_until(deadline(30_000), fn ->
                 current = Repo.get!(AgentWorker, uid)

                 (current.state == :ready and current.transport_route != worker.transport_route) &&
                   current
               end)

      assert rejoined.generation == worker.generation
      assert rejoined.incarnation_id == worker.incarnation_id
      resumed_at = System.monotonic_time(:millisecond)

      assert {:ok, true} =
               wait_until(deadline(15_000), fn ->
                 DockerWorker.exec!(ctx.container, [
                   "sh",
                   "-ec",
                   "test -f /workspace/jobs/#{job.id}/effect-count && echo started || true"
                 ]) == "started\n"
               end)

      assert System.monotonic_time(:millisecond) - resumed_at < 15_000
      started_at = System.monotonic_time(:millisecond)

      IO.puts(
        "[b02-b03-latency] " <>
          Ankole.JSON.encode!(%{
            boundary: boundary,
            fault_to_rejoin_ms: resumed_at - fault_at,
            rejoin_to_effect_ms: started_at - resumed_at,
            fault_to_effect_ms: started_at - fault_at,
            attempt: turn.attempt
          })
      )

      assert DockerWorker.exec!(ctx.container, ["cat", "/workspace/jobs/#{job.id}/effect-count"]) ==
               "x"

      assert Repo.get!(Job, job.id).attempts == 1
      assert Repo.get!(Job, job.id).execution_failures == 0

      assert {:ok, _, _} =
               wait_for_completed_final_reply(ctx.container, input.id, deadline(60_000))

      DockerWorker.exec!(ctx.container, ["touch", "/workspace/jobs/#{job.id}/allow-write"])

      assert {:ok, completed} =
               wait_until(deadline(90_000), fn ->
                 case Repo.get!(Job, job.id) do
                   %Job{status: :succeeded} = completed -> completed
                   _ -> nil
                 end
               end)

      assert completed.attempts == 1
      assert completed.execution_failures == 0
      assert completed.result["output_text"] =~ "CHAOS_JOB_RECONNECTED"

      assert DockerWorker.exec!(ctx.container, ["cat", "/workspace/jobs/#{job.id}/state.txt"]) ==
               "JOB_FILE_BEFOREJOB_FILE_AFTER"

      assert DockerWorker.exec!(ctx.container, ["cat", "/workspace/jobs/#{job.id}/effect-count"]) ==
               "x"

      assert DockerWorker.logs(ctx.container) |> String.split("worker.turn_started") |> length() ==
               2

      requests = Enum.filter(FakeOpenAIState.requests(), &(&1.kind == :job_reconnect))
      assert Enum.map(requests, & &1.count) == [1, 2, 3]
    end
  end

  @tag :b02_b03_reconnect
  test "a late acceptance for a stopped Job releases the slot without crashing or executing" do
    ctx = start_worker_e2e_stack!()
    uid = ctx.agent.uid
    assert {:ok, profile} = ModelProfiles.get_model_profile(uid, "primary")
    assert {:ok, _} = ModelProfiles.put_model_profile(uid, "coding", profile)
    worker = Repo.get!(AgentWorker, uid)
    target = AgentWorkers.target(worker)
    assert {:ok, channel} = WorkerRoute.connection_pid(target)
    ref = pause_worker_boundary!(channel, :stop)
    input = send!(ctx, "b02-stop", "CHAOS_JOB_CREATE_RECONNECT B02_B03_ONCE")
    assert_receive {:worker_boundary_paused, ^ref, turn}, 60_000

    assert {:ok, %{job: stopped, turn: stopped_turn}} =
             BackgroundAgentJobs.request_stop(turn.job_id, %{
               agent_uid: uid,
               cancel_requested_by: "agent:#{uid}",
               reason: "B02 fresh acceptance raced durable stop",
               request_id: "b02-stop"
             })

    assert stopped.status == :stopped
    send(channel, {:resume_worker_boundary, ref})

    assert {:ok, true} =
             wait_until(deadline(15_000), fn ->
               DockerWorker.logs(ctx.container) =~ "worker.turn_acceptance_rejected"
             end)

    assert {:ok, true} =
             wait_until(deadline(15_000), fn ->
               AgentWorker.available_slots(Repo.get!(AgentWorker, uid)) ==
                 worker.capacity["max_slots"]
             end)

    assert :ok = Ankole.Sessions.stop_job_turn(stopped, stopped_turn)
    assert {:ok, _, _} = wait_for_completed_final_reply(ctx.container, input.id, deadline(60_000))
    assert Process.alive?(channel)

    assert {:error, %{"code" => "unknown_rpc_method"}} =
             WorkerRoute.request_rpc(target, "worker.no_such_method", <<>>, timeout_ms: 10_000)

    refute DockerWorker.logs(ctx.container) =~ "worker.turn_started"

    refute DockerWorker.exec!(ctx.container, [
             "sh",
             "-ec",
             "test -f /workspace/jobs/#{turn.job_id}/effect-count && echo executed || true"
           ]) =~ "executed"

    assert Repo.get!(Job, turn.job_id).attempts == 1
    assert Repo.get!(Job, turn.job_id).execution_failures == 0
  end

  # The official OTP debug callback pauses the real Channel at one precise
  # boundary. It changes no broker, adapter, message or durable decision.
  defp pause_worker_boundary!(channel, boundary) do
    ref = make_ref()
    caller = self()

    callback = fn state, event, _process_state ->
      {state, pause?} = worker_boundary_event(state, event, boundary)

      if pause? do
        send(caller, {:worker_boundary_paused, ref, state.turn})

        receive do
          {:resume_worker_boundary, ^ref} -> :done
        after
          30_000 -> :done
        end
      else
        state
      end
    end

    assert :ok = :sys.install(channel, {ref, callback, %{turn: nil, seq: nil, request_id: nil}})

    on_exit(fn ->
      if Process.alive?(channel) do
        send(channel, {:resume_worker_boundary, ref})

        try do
          :sys.remove(channel, ref)
        catch
          :exit, {:noproc, _} -> :ok
          :exit, {:shutdown, _} -> :ok
        end
      end
    end)

    ref
  end

  defp worker_boundary_event(
         state,
         {:in, %Phoenix.Socket.Message{event: "durable", payload: {:binary, bytes}}},
         boundary
       ) do
    case Ankole.RuntimeFabric.decode_and_validate(bytes) do
      {:ok, %Proto.Envelope{body: {:turn_accepted, accepted}, transport_seq: seq}} ->
        {%{state | turn: accepted.turn, seq: seq}, boundary == :stop}

      {:ok,
       %Proto.Envelope{body: {:rpc_request, %{method: "files.list", request_id: request_id}}}}
      when boundary == :read and not is_nil(state.turn) ->
        {%{state | request_id: request_id}, false}

      _ ->
        {state, false}
    end
  end

  defp worker_boundary_event(
         %{seq: seq} = state,
         {:in, {:reply_done, _ref, :durable, seq, _bytes, _result}},
         :acceptance
       )
       when not is_nil(seq),
       do: {state, true}

  defp worker_boundary_event(
         %{request_id: id} = state,
         {:in,
          {:"$gen_call", _from,
           {:push, %Proto.Envelope{body: {:rpc_response, %{request_id: id}}}}}},
         :read
       )
       when not is_nil(id),
       do: {state, true}

  defp worker_boundary_event(state, _event, _boundary), do: {state, false}

  @tag :q23_quota
  test "a real Codex usage-limit rejection ends the Job at the control-plane quota owner" do
    ctx = start_worker_e2e_stack!()
    uid = ctx.agent.uid
    assert {:ok, profile} = ModelProfiles.get_model_profile(uid, "primary")
    assert {:ok, _} = ModelProfiles.put_model_profile(uid, "coding", profile)
    input = send!(ctx, "quota-parent", "Q23_PARENT_READY")
    assert {:ok, _, _} = wait_for_completed_final_reply(ctx.container, input.id, deadline(60_000))
    before_requests = length(FakeOpenAIState.requests())

    now = DateTime.utc_now(:microsecond)

    assert {:ok, _} =
             Ankole.AIAgent.TokenQuota.put(uid, %{
               "period_days" => 7,
               "period_start_at" => now |> DateTime.add(-3_600, :second) |> DateTime.to_iso8601(),
               "limit_tokens" => 1
             })

    assert {:ok, _record} =
             Ankole.Ash.create(Ankole.AIGateway.Schemas.UsageRecord, :record_round, %{
               subject_uid: uid,
               origin: :agent,
               model: "quota-e2e/fixture",
               input_tokens: 1,
               output_tokens: 0
             })

    assert {:ok, %{job: job, dispatch_event: dispatch}} =
             Repo.transact(fn ->
               BackgroundAgentJobs.Dispatch.create_with_dispatch_in_tx(%{
                 source_signal_id: input.id,
                 agent_uid: uid,
                 owner_session_id: input.session_id,
                 source_tool_call_id: "q23-create",
                 title: "Quota boundary",
                 task: "Q23_QUOTA_JOB Reply once.",
                 reply_route:
                   Ankole.Conversations.Route.snapshot(%{
                     signal_id: input.id
                   })
               })
             end)

    retry_until_sent!(dispatch, DateTime.add(dispatch.available_at, 1, :second))

    assert {:ok, failed} =
             wait_until(deadline(90_000), fn ->
               case Repo.get!(Job, job.id) do
                 %Job{status: :failed} = failed -> failed
                 _ -> nil
               end
             end)

    assert failed.attempts == 1
    assert failed.execution_failures == 0
    assert failed.error["code"] == "agent_token_quota_exceeded"
    assert failed.error["summary"] == "The Agent has used its token quota for the current period."
    assert failed.error["details"]["error_code"] == "agent_token_quota_exceeded"
    assert Repo.get!(Ankole.Signals.Signal, dispatch.id).status == :dead_letter

    assert Repo.get_by!(Ankole.Signals.Signal,
             agent_uid: uid,
             session_id: input.session_id,
             type: "background_agent_job.failed"
           )

    assert length(FakeOpenAIState.requests()) == before_requests
  end

  @tag :b18_ingress
  test "ignored Lark context survives without identity writes and reaches a later Docker turn" do
    ctx = start_worker_e2e_stack!()
    identities = Repo.all(Ankole.Principals.ExternalIdentity)
    memberships = Repo.all(Ankole.AuthZ.Membership)
    principal_count = Repo.aggregate(Ankole.Principals.Principal, :count)
    before_requests = length(FakeOpenAIState.requests())

    Ankole.E2E.Scenarios.Observe.run_unaddressed_ignore_guardrail(ctx)
    assert Repo.all(Ankole.Principals.ExternalIdentity) == identities
    assert Repo.all(Ankole.AuthZ.Membership) == memberships
    assert Repo.aggregate(Ankole.Principals.Principal, :count) == principal_count
    assert length(FakeOpenAIState.requests()) == before_requests

    conversation = Ankole.Conversations.External.get_conversation("lark:oc_chaos_ignore")
    assert conversation

    [batch] =
      Repo.all(
        from(batch in Ankole.Conversations.InboundBatch,
          where:
            batch.agent_uid == ^ctx.agent.uid and
              batch.conversation_id == ^conversation.id
        )
      )

    assert {:ok, %{status: :ignored, inbound_batch: batch}} =
             Ankole.Conversations.InboundBatches.finalize_inbound_batch_by_id(batch.id,
               now: batch.available_at
             )

    assert batch.batch_state == :finalized
    assert [stored] = batch.entries
    assert stored["text"] == "This unaddressed group line must not wake the agent."
    assert Ankole.JSON.encode!(stored["raw_payload"]) =~ stored["text"]

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_b18_addressed_reference",
               message_id: "om_b18_addressed_reference",
               parent_id: "om_ignored_unaddressed_1",
               chat_id: "oc_chaos_ignore",
               chat_type: "group",
               text: "@_user_1 Reply exactly CHAOS_DIRECT_OK. Do not call tools.",
               mentions: [lark_bot_mention()]
             )

    input = signal_by_provider_message_id!(ctx.agent.uid, "om_b18_addressed_reference")
    retry_until_sent!(input, DateTime.add(input.available_at, 1, :second))
    parent = message_observation("lark:oc_chaos_ignore", "om_ignored_unaddressed_1")
    current = message_observation("lark:oc_chaos_ignore", "om_b18_addressed_reference")
    assert parent.message.text == stored["text"]
    assert current.message.reply_to_message_id == parent.message.id
    assert input.message_id == current.message.id

    assert {:ok, reply, _} =
             wait_for_completed_final_reply(
               %{agent_uid: ctx.agent.uid},
               input.id,
               deadline(90_000)
             )

    assert reply.message.text =~ "CHAOS_DIRECT_OK"
    assert Ankole.JSON.encode!(FakeOpenAIState.requests()) =~ stored["text"]
    assert Repo.get!(Ankole.Conversations.InboundBatch, batch.id).entries == batch.entries
    assert Repo.aggregate(Ankole.Principals.Principal, :count) > principal_count
    assert_signal_completed!(input.id)
  end

  @tag :webhook_cli
  test "the Docker CLI creates control-plane capabilities and HTTP consumes them once in their tenant" do
    ctx = start_worker_e2e_stack!()
    endpoint_config = Application.fetch_env!(:ankole, AnkoleWeb.Endpoint)

    AnkoleWeb.Endpoint.config_change(
      [
        {AnkoleWeb.Endpoint,
         Keyword.put(endpoint_config, :url,
           scheme: "http",
           host: "host.docker.internal",
           port: ctx.server_port
         )}
      ],
      []
    )

    on_exit(fn ->
      AnkoleWeb.Endpoint.config_change([{AnkoleWeb.Endpoint, endpoint_config}], [])
    end)

    input = send!(ctx, "webhook-cli", "CHAOS_WEBHOOK_CLI")

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(
               %{agent_uid: ctx.agent.uid},
               input.id,
               deadline(90_000)
             )

    assert reply.message.text =~ "CHAOS_WEBHOOK_CLI_OK"
    messages = ai_messages_for_signal(input.id)
    assert command_tool_succeeded?(messages)
    assert [%{"raw" => output}] = successful_tool_results(messages, "command")
    assert [_, result] = Regex.run(~r/^R22_WEBHOOK_RESULT=(.+)$/m, output)

    assert %{"results" => [first, second], "listed" => 2, "remaining" => 0} =
             Ankole.JSON.decode!(result)

    assert first["statuses"] == [204, 204]
    assert second["statuses"] == [204, 204, 204]
    refute Regex.match?(~r/wh_[A-Za-z0-9_-]{43}/, output)
    refute first["id"] == second["id"]
    refute first["digest"] == second["digest"]

    endpoints = Enum.map([first, second], &Repo.get!(WebhookEndpoint, &1["id"]))
    worker = Repo.get!(AgentWorker, ctx.agent.uid)

    for {endpoint, result} <- Enum.zip(endpoints, [first, second]) do
      assert endpoint.token_digest == result["digest"]
      assert byte_size(endpoint.token_digest) == 43
      assert endpoint.tenant_id == Repo.tenant_id!()
      assert endpoint.agent_uid == ctx.agent.uid
      assert endpoint.source_signal_id == input.id
      assert endpoint.session_id == input.session_id
      assert endpoint.binding_name == input.reply_binding_name
      assert endpoint.expires_at == hd(endpoints).expires_at
      assert endpoint.mode == "one_shot"
      assert endpoint.status == :fired
      assert endpoint.fired_at
      assert is_binary(endpoint.source_provenance["rpc_request_id"])
      assert endpoint.source_provenance["transport_route"] == worker.transport_route
    end

    refute hd(endpoints).source_provenance["rpc_request_id"] ==
             List.last(endpoints).source_provenance["rpc_request_id"]

    receipts =
      Repo.all(
        from(event in Signal,
          where: event.agent_uid == ^ctx.agent.uid and event.type == "webhook.received"
        )
      )

    assert length(receipts) == 2

    for {endpoint, index} <- Enum.with_index(endpoints) do
      assert [receipt] =
               Enum.filter(
                 receipts,
                 &(&1.data["webhook_endpoint"]["id"] == endpoint.id)
               )

      assert receipt.tenant_id == endpoint.tenant_id
      assert receipt.session_id == input.session_id
      assert receipt.data["source_signal_id"] == input.id

      assert Ankole.JSON.decode!(receipt.data["body"]) == %{
               "marker" => "r22-http-#{index}"
             }
    end

    other_tenant = create_committed_tenant()

    on_exit(fn ->
      Repo.with_tenant(other_tenant.id, fn -> cleanup_tenant!(other_tenant) end)
    end)

    Repo.with_tenant(other_tenant.id, fn ->
      for endpoint <- endpoints, do: assert(is_nil(Repo.get(WebhookEndpoint, endpoint.id)))
      for receipt <- receipts, do: assert(is_nil(Repo.get(Signal, receipt.id)))
    end)

    assert_signal_completed!(input.id)
  end

  @tag :b07_long_lived_owner
  test "a real Codex Job creates long-lived resources and their HTTP and script callbacks wake its origin" do
    ctx = start_worker_e2e_stack!()
    uid = ctx.agent.uid
    assert {:ok, profile} = ModelProfiles.get_model_profile(uid, "primary")
    assert {:ok, _} = ModelProfiles.put_model_profile(uid, "coding", profile)
    endpoint_config = Application.fetch_env!(:ankole, AnkoleWeb.Endpoint)

    AnkoleWeb.Endpoint.config_change(
      [
        {AnkoleWeb.Endpoint,
         Keyword.put(endpoint_config, :url,
           scheme: "http",
           host: "host.docker.internal",
           port: ctx.server_port
         )}
      ],
      []
    )

    on_exit(fn ->
      AnkoleWeb.Endpoint.config_change([{AnkoleWeb.Endpoint, endpoint_config}], [])
    end)

    input = send!(ctx, "b07-owner", "CHAOS_B07_CREATE")
    assert {:ok, _, _} = wait_for_completed_final_reply(ctx.container, input.id, deadline(90_000))
    job = Repo.one!(from(j in Job, where: j.source_signal_id == ^input.id))

    assert {:ok, completed} =
             wait_until(deadline(90_000), fn ->
               current = Repo.get!(Job, job.id)
               current.status == :succeeded && current
             end)

    assert completed.result["summary"] == "B07_JOB_DONE" or
             Ankole.JSON.encode!(completed.result) =~ "B07_JOB_DONE"

    endpoint =
      Repo.one!(
        from(e in WebhookEndpoint,
          where: e.agent_uid == ^uid and e.label == "B07 callback" and e.status == :armed
        )
      )

    automation =
      Repo.one!(
        from(j in Ankole.AutomationJobs.Schemas.Job,
          where: j.agent_uid == ^uid and j.label == "B07 automation" and j.status == :active
        )
      )

    dispatch = Repo.get!(Signal, endpoint.source_signal_id)
    assert dispatch.session_id == BackgroundAgentJobs.job_session_id(job.id)
    assert endpoint.session_id == input.session_id
    assert automation.owner_session_id == input.session_id
    assert automation.source_signal_id == dispatch.id
    assert endpoint.conversation_id == input.conversation_id
    assert automation.authorization_kind == dispatch.authorization_kind
    assert automation.human_uid == dispatch.human_uid
    assert automation.human_access_version == dispatch.human_access_version

    assert Repo.one!(
             from(e in WebhookEndpoint,
               where: e.agent_uid == ^uid and e.label == "B07 callback" and e.status == :cancelled
             )
           )

    assert Repo.one!(
             from(j in Ankole.AutomationJobs.Schemas.Job,
               where:
                 j.agent_uid == ^uid and j.label == "B07 automation" and j.status == :cancelled
             )
           )

    # The capability stays inside the fixture container until this local HTTP
    # request. It must not appear in model tool output or test diagnostics.
    capability =
      DockerWorker.exec!(ctx.container, ["cat", "/workspace/jobs/#{job.id}/b07-webhook-url"])

    uri = URI.parse(String.trim(capability))
    assert uri.host == "host.docker.internal"

    assert {:ok, %{status: 204}} =
             Req.post("http://127.0.0.1:#{ctx.server_port}#{uri.path}",
               json: %{marker: "CHAOS_B07_WAKE", path: "webhook"},
               retry: false
             )

    receipt =
      Repo.one!(
        from(e in Signal,
          where: e.agent_uid == ^uid and e.type == "webhook.received"
        )
      )

    assert receipt.session_id == input.session_id
    assert receipt.data["source_signal_id"] == dispatch.id

    assert {:ok, webhook_reply, _} =
             wait_for_completed_final_reply(ctx.container, receipt.id, deadline(90_000))

    assert webhook_reply.message.text =~ "B07_OWNER_RECEIVED"

    assert {:ok, %{status: 204}} =
             Req.post("http://127.0.0.1:#{ctx.server_port}#{uri.path}",
               json: %{marker: "replay"},
               retry: false
             )

    assert Repo.aggregate(
             from(e in Signal,
               where: e.agent_uid == ^uid and e.type == "webhook.received"
             ),
             :count
           ) == 1

    due_at = DateTime.add(DateTime.utc_now(:microsecond), 2, :second)

    assert {:ok, %{scheduled_event: scheduled}} =
             Ankole.Schedule.create_check_back_later(%{
               "source_signal_id" => dispatch.id,
               "agent_uid" => uid,
               "session_id" => input.session_id,
               "binding_name" => input.reply_binding_name,
               "tool_call_id" => "b07-script-trigger",
               "idempotency_key" => "b07-script-trigger",
               "schedule" => %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"},
               "reason" => "Exercise the registered script after its Job ends.",
               "check" => "Run the deterministic fixture.",
               "context_summary" => "B07 long-lived owner",
               "reply_route" => %{
                 "conversation_id" => input.conversation_id,
                 "provider_thread_id" => input.provider_thread_id,
                 "provider_message_id" => input.provider_message_id
               },
               "source_provenance" => %{"kind" => "b07-e2e-fixture"},
               "automation_job_id" => automation.id
             })

    assert {:ok, %{automation_job_run: queued}} =
             Ankole.Schedule.fire_due_event(scheduled.id, now: due_at)

    assert :ok =
             perform_job(
               Ankole.AutomationJobs.Jobs.ExecuteRun,
               %{"automation_job_run_id" => queued.id}
             )

    assert %Ankole.AutomationJobs.Schemas.Run{status: :succeeded, exit_code: 0} =
             Repo.reload!(queued)

    emitted =
      Repo.one!(
        from(e in Signal,
          where: e.agent_uid == ^uid and e.type == "automation_job.emitted"
        )
      )

    assert emitted.session_id == input.session_id
    assert emitted.data["payload"]["path"] == "automation"

    assert {:ok, script_reply, _} =
             wait_for_completed_final_reply(ctx.container, emitted.id, deadline(90_000))

    assert script_reply.message.text =~ "B07_OWNER_RECEIVED"
    assert Repo.reload!(job).status == :succeeded
    assert_signal_completed!(receipt.id)
    assert_signal_completed!(emitted.id)
  end

  defp send!(ctx, suffix, text) do
    source_id = "om_q03_#{suffix}"

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_q03_#{suffix}",
               message_id: source_id,
               chat_id: "oc_q03_#{suffix}",
               chat_type: "p2p",
               text: "@_user_1 #{text}",
               mentions: [lark_bot_mention()]
             )

    input = signal_by_provider_message_id!(ctx.agent.uid, source_id)
    retry_until_sent!(input, DateTime.add(input.available_at, 1, :second))
    input
  end
end
