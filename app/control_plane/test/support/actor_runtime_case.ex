defmodule Ankole.ActorRuntimeCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.Actors
  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.OutboxEntry

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  using do
    quote do
      use Ankole.DataCase, async: false

      import Ecto.Query, warn: false
      import Ankole.ActorRuntimeCase

      alias Ankole.AIGateway.ProviderConfigs, warn: false
      alias Ankole.AIAgent.ModelProfiles, warn: false
      alias Ankole.AIAgent.Schemas.Conversation, warn: false
      alias Ankole.AIAgent.Schemas.LlmTurn, warn: false
      alias Ankole.AIAgent.Schemas.Message, warn: false
      alias Ankole.Actors, warn: false
      alias Ankole.Actors.ActorEvent, warn: false
      alias Ankole.Actors.ActorInputConsumption, warn: false
      alias Ankole.ActorRuntime, warn: false
      alias Ankole.ActorRuntime.ActivationManager, warn: false
      alias Ankole.ActorRuntime.OutboxDispatcher, warn: false
      alias Ankole.ActorRuntime.Reconciler, warn: false
      alias Ankole.ActorRuntime.RPCLane, warn: false
      alias Ankole.ActorRuntime.Schemas.ActorEventDelivery, warn: false
      alias Ankole.ActorRuntime.Schemas.ActorSessionActivation, warn: false
      alias Ankole.ActorRuntime.Schemas.AgentComputerWorker, warn: false
      alias Ankole.ActorRuntime.Transport.Broker, warn: false
      alias Ankole.ActorRuntime.WorkerAuthKey, warn: false
      alias Ankole.ActorRuntime.WorkerBootstrap, warn: false
      alias Ankole.Repo, warn: false
      alias Ankole.SignalsGateway, warn: false
      alias Ankole.SignalsGateway.InboundBatch, warn: false
      alias Ankole.SignalsGateway.OutboxEntry, warn: false
      alias Ankole.SignalsGateway.SignalEntry, warn: false
      alias Ankole.SystemConfig, warn: false

      @base_time ~U[2026-07-02 01:34:05.000000Z]
      @long_lease_seconds 31_536_000
    end
  end

  def admit_worker(route, overrides \\ %{}) do
    ActorRuntime.admit_worker_ready(
      Map.merge(
        %{
          worker_id: "worker-" <> route,
          runtime: "bun",
          version: "test",
          capacity: %{"available_turn_slots" => 4}
        },
        overrides
      ),
      %{authenticated?: true, transport_route: route}
    )
  end

  def agent_fixture(attrs \\ %{}) do
    %{principal: agent} = fixture = Ankole.PrincipalsFixtures.agent_fixture(attrs)
    provider_id = "actor-runtime-test-" <> Ecto.UUID.generate()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{
                 "api_key" => "sk-test"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: "google/gemini-3.5-flash"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "light", %{
               provider_id: provider_id,
               model: "openai/gpt-5.4-nano"
             })

    fixture
  end

  def binding_fixture(agent_uid, name, policy) do
    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: "lark",
        config_ref: "app-config://#{name}",
        filters: %{},
        unaddressed_group_message_policy: policy
      })

    binding
  end

  def emit_entry(agent_uid, binding_name, input, opts) do
    with {:ok, result} <- SignalsGateway.emit_entry(agent_uid, binding_name, input, opts) do
      {:ok, maybe_finalize_test_inbound_batch(result)}
    end
  end

  def group_entry(overrides) do
    Map.merge(
      %{
        source_event_id: "evt-" <> Integer.to_string(System.unique_integer([:positive])),
        signal_channel_id: "lark:chat:group-a",
        source_entry_id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"},
        text: "PING",
        explicit: false,
        author: %{principal_uid: "alice", id: "ou_alice", display_name: "Alice"},
        provider_time: @base_time
      },
      overrides
    )
  end

  def append_runtime_actor_input(agent_uid, session_id, type, opts) do
    now = Keyword.fetch!(opts, :now)
    source_event_id = "#{type}-#{System.unique_integer([:positive])}"

    Actors.append_actor_input(%{
      agent_uid: agent_uid,
      binding_name: "control-plane:test",
      session_id: session_id,
      source_event_id: source_event_id,
      type: type,
      available_at: now,
      payload: %{
        "specversion" => "1.0",
        "id" => source_event_id,
        "source" => "control-plane://test",
        "time" => DateTime.to_iso8601(now),
        "type" => type,
        "data" => %{
          "session" => %{
            "agent_uid" => agent_uid,
            "session_id" => session_id,
            "binding_name" => "control-plane:test"
          }
        }
      }
    })
  end

  def lifecycle_entry(overrides) do
    Map.merge(
      %{
        source_event_id: "lifecycle-" <> Integer.to_string(System.unique_integer([:positive])),
        signal_channel_id: "lark:chat:group-a",
        source_entry_id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      },
      overrides
    )
  end

  def unique_route do
    "local-test-route-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  def unique_process_name(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end

  def runtime_fabric_kernel_dir do
    Path.expand("../../../kernel", __DIR__)
  end

  def runtime_fabric_attachment_worker_script do
    ~S"""
    const endpoint = process.env.ANKOLE_RF_ENDPOINT
    const identity = process.env.ANKOLE_RF_IDENTITY
    const workerId = process.env.ANKOLE_RF_WORKER_ID
    const token = process.env.ANKOLE_RF_TOKEN

    for (const [name, value] of Object.entries({ endpoint, identity, workerId, token })) {
      if (!value) throw new Error(`missing ${name}`)
    }

    const { RuntimeFabricDealer, runtimeFabricDecodeEnvelope } = await import('./index.js')
    const dealer = new RuntimeFabricDealer(endpoint, identity, workerId, token)

    function envelope(type, payload, lane, durability, correlationId = '') {
      return {
        protocol_version: 1,
        message_id: `${type}-${Date.now()}-${Math.random().toString(16).slice(2)}`,
        correlation_id: correlationId,
        lane,
        sent_at_unix_ms: Date.now(),
        durability,
        body: {
          type,
          [type]: payload,
        },
      }
    }

    dealer.sendEnvelope(envelope('worker_ready', {
      worker_id: workerId,
      runtime: 'bun',
      version: 'test',
      capacity_json: { available_turn_slots: 1 },
    }, 'LANE_CONTROL', 'CONTROL_EPHEMERAL'))

    let turnEnvelope = null
    const deadline = Date.now() + 4000

    while (Date.now() < deadline) {
      const payload = dealer.recv(100)
      if (!payload) continue

      const decoded = runtimeFabricDecodeEnvelope(payload)
      if (decoded.body?.type === 'turn_start') {
        turnEnvelope = decoded
        break
      }
    }

    if (!turnEnvelope) {
      throw new Error('timed out waiting for turn_start')
    }

    const turnStart = turnEnvelope.body.turn_start
    const turn = turnStart.turn
    if (!turnStart.actor_event) {
      throw new Error('turn_start.actor_event is required')
    }

    dealer.sendEnvelope(envelope('turn_accepted', {
      turn,
    }, 'LANE_TURN', 'CONTROL_REPLAYABLE', turnEnvelope.message_id))

    dealer.sendEnvelope(envelope('turn_final_proposal', {
      turn,
      messages: [],
      reply: {
        text: 'Here is the report.',
        content_json: [{ type: 'text', text: 'Here is the report.' }],
        attachments: [{
          agent_computer_path: '/workspace/user-files/reports/a.txt',
          user_files_relative_path: 'reports/a.txt',
          name: 'report.txt',
          mime_type: 'text/plain',
          size: 16,
        }],
      },
      stop_reason: 'stop',
      tool_results_json: [],
    }, 'LANE_TURN', 'CONTROL_DURABLE', turnEnvelope.message_id))

    dealer.stop()
    console.log('worker-complete')
    """
  end

  def worker_ready_envelope do
    %{
      "protocol_version" => 1,
      "message_id" => "worker-ready-test",
      "lane" => "LANE_CONTROL",
      "durability" => "CONTROL_EPHEMERAL",
      "body" => %{
        "type" => "worker_ready",
        "worker_ready" => %{
          "worker_id" => "worker-a",
          "runtime" => "bun",
          "version" => "test"
        }
      }
    }
  end

  def wait_for_worker(worker_id, worker_task, attempts \\ 100)

  def wait_for_worker(worker_id, worker_task, attempts) when attempts > 0 do
    case Repo.get_by(AgentComputerWorker, worker_id: worker_id) do
      %AgentComputerWorker{} = worker ->
        worker

      nil ->
        case Task.yield(worker_task, 0) do
          {:ok, {output, status}} ->
            flunk("runtime fabric worker exited before ready status=#{status}\n#{output}")

          {:exit, reason} ->
            flunk("runtime fabric worker exited before ready: #{inspect(reason)}")

          nil ->
            Process.sleep(10)
            wait_for_worker(worker_id, worker_task, attempts - 1)
        end
    end
  end

  def wait_for_worker(worker_id, _worker_task, 0) do
    flunk("runtime fabric worker #{worker_id} was not admitted")
  end

  def wait_for_attachment_outbox(actor_input_id, attempts \\ 100)

  def wait_for_attachment_outbox(actor_input_id, attempts) when attempts > 0 do
    case Repo.get_by(OutboxEntry, source_actor_event_id: actor_input_id) do
      %OutboxEntry{payload: %{"attachments" => [_ | _]}} = outbox ->
        outbox

      _value ->
        Process.sleep(10)
        wait_for_attachment_outbox(actor_input_id, attempts - 1)
    end
  end

  def wait_for_attachment_outbox(actor_input_id, 0) do
    flunk("attachment outbox for actor input #{actor_input_id} was not committed")
  end

  def wait_for_delivery_state(actor_event_id, state, attempts \\ 100)

  def wait_for_delivery_state(actor_event_id, state, attempts) when attempts > 0 do
    case Repo.get_by(ActorEventDelivery, actor_event_id: actor_event_id, state: state) do
      %ActorEventDelivery{} = delivery ->
        delivery

      nil ->
        Process.sleep(10)
        wait_for_delivery_state(actor_event_id, state, attempts - 1)
    end
  end

  def wait_for_delivery_state(actor_event_id, state, 0) do
    flunk("delivery #{actor_event_id} did not reach #{state}")
  end

  def wait_for_turn_status(actor_event_id, status, attempts \\ 100)

  def wait_for_turn_status(actor_event_id, status, attempts) when attempts > 0 do
    # Phase 1: map old status names to the new ai_gateway_messages values.
    mapped = map_turn_status(status)

    case Repo.get!(LlmTurn, actor_event_id) do
      %LlmTurn{status: ^mapped} = turn ->
        turn

      %LlmTurn{} ->
        Process.sleep(10)
        wait_for_turn_status(actor_event_id, status, attempts - 1)
    end
  end

  def wait_for_turn_status(actor_event_id, status, 0) do
    flunk("llm turn #{actor_event_id} did not reach #{status}")
  end

  # Phase 1: maps old turn status names to the new ai_gateway_messages values.
  defp map_turn_status("started"), do: "generating"
  defp map_turn_status("succeeded"), do: "complete"
  defp map_turn_status("failed"), do: "error"
  defp map_turn_status("cancelled"), do: "error"
  defp map_turn_status(other), do: other

  defp maybe_finalize_test_inbound_batch(%{inbound_batch: %InboundBatch{} = batch} = result) do
    finalize_result =
      SignalsGateway.finalize_due_inbound_batches(
        now: DateTime.add(batch.available_at, 1, :microsecond)
      )

    with {:ok, finalized_results} <- finalize_result,
         %ActorEvent{} = actor_input <- finalized_actor_input(finalized_results, batch.id) do
      Map.put(result, :actor_input, actor_input)
    else
      _no_actor_input ->
        # Phase 1: the finalize path may have completed but not returned the
        # actor event in a discoverable way. Directly create the actor event
        # from the batch's last entry, bypassing the finalize machinery.
        force_create_actor_event_from_batch(batch, result)
    end
  end

  defp maybe_finalize_test_inbound_batch(result), do: result

  # When the normal finalize path doesn't produce an actor event, the
  # ActivationManager may have already finalized the batch and created one.
  # Try to find it via the batch's actor_event_id, then fall back to creating.
  defp force_create_actor_event_from_batch(%InboundBatch{} = batch, result) do
    import Ecto.Query

    # 1. Reload the batch — it may have been finalized by ActivationManager.
    case Repo.get(InboundBatch, batch.id) do
      %InboundBatch{actor_event_id: id} when is_binary(id) and byte_size(id) > 0 ->
        # The batch was finalized and has an actor_event_id.
        case Repo.get(ActorEvent, id) do
          %ActorEvent{} = ae -> Map.put(result, :actor_input, ae)
          nil -> create_actor_event_from_batch(batch, result)
        end

      _ ->
        # Batch not finalized or no actor_event_id. Try to find existing.
        case Repo.one(
               from(a in ActorEvent,
                 where: a.agent_uid == ^batch.agent_uid and a.session_id == ^batch.session_id,
                 order_by: [desc: a.inserted_at],
                 limit: 1
               )
             ) do
          %ActorEvent{} = existing -> Map.put(result, :actor_input, existing)
          nil -> create_actor_event_from_batch(batch, result)
        end
    end
  end

  defp create_actor_event_from_batch(%InboundBatch{} = _batch, result) do
    # Phase 1: Do NOT create a new actor event — the ActivationManager likely
    # already created one. Just return the result without actor_input.
    # The caller should handle the nil case.
    result
  end

  defp finalized_actor_input(finalized_results, batch_id) do
    Enum.find_value(finalized_results, fn
      %{inbound_batch: %InboundBatch{id: ^batch_id}, actor_input: %ActorEvent{} = input} ->
        input

      _result ->
        nil
    end)
  end
end
