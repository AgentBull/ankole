defmodule Ankole.ActorRuntimeCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import Ecto.Query, warn: false

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Entry

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  using do
    quote do
      use Ankole.DataCase, async: false

      import Ecto.Query, warn: false

      import Ankole.ActorRuntimeCase,
        except: [
          use_mock_signal_provider_plugin: 1,
          wait_for_final_mirror: 1,
          wait_for_final_mirror: 2
        ]

      alias Ankole.AIGateway.ProviderConfigs, warn: false
      alias Ankole.AIGateway.StatefulResponses, warn: false
      alias Ankole.AIGateway.ModelProfiles, warn: false
      alias Ankole.AIGateway.Schemas.Conversation, warn: false
      alias Ankole.AIGateway.Schemas.Message, warn: false
      alias Ankole.Actors, warn: false
      alias Ankole.Actors.ActorEvent, warn: false
      alias Ankole.ActorRuntime, warn: false
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
      alias Ankole.SignalsGateway.Entry, warn: false
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

  def binding_fixture(agent_uid, name, policy, opts \\ []) do
    {:ok, binding} =
      SignalsGateway.upsert_binding(%{
        agent_uid: agent_uid,
        name: name,
        adapter: Keyword.get(opts, :adapter, "lark"),
        config_ref: "app-config://#{name}",
        filters: %{},
        unaddressed_group_message_policy: policy
      })

    binding
  end

  def use_mock_signal_provider_plugin(_context) do
    original_state = :sys.get_state(Ankole.Plugins.Registry)
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        disabled_ids: MapSet.new()
      }
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    :ok
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

  def append_runtime_actor_event(agent_uid, session_id, type, opts) do
    now = Keyword.fetch!(opts, :now)
    source_event_id = "#{type}-#{System.unique_integer([:positive])}"

    Actors.append_actor_event(%{
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

  def process_ready_events_once(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    limit = Keyword.get(opts, :limit, 1)

    results =
      Ankole.ActorRuntime.runtime_event_snapshot()
      |> Enum.filter(&actor_session_ready_due?(&1, now))
      |> Enum.take(limit)
      |> Enum.map(fn {_channel, payload} ->
        Ankole.ActorRuntime.process_ready_event_for_actor(
          %{
            agent_uid: payload["agent_uid"],
            session_id: payload["session_id"]
          },
          opts
        )
      end)

    case results do
      [] -> {:ok, %{status: :idle}}
      [result | _rest] -> result
    end
  end

  defp actor_session_ready_due?(
         {channel, %{"agent_uid" => agent_uid, "session_id" => session_id} = payload},
         now
       )
       when is_binary(agent_uid) and is_binary(session_id) do
    channel == Ankole.RuntimeEvents.actor_session_ready_channel() and
      due_at?(payload["due_at"], now)
  end

  defp actor_session_ready_due?(_event, _now), do: false

  defp due_at?(nil, _now), do: true

  defp due_at?(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, due_at, _offset} -> DateTime.compare(due_at, now) != :gt
      {:error, _reason} -> false
    end
  end

  defp due_at?(_value, _now), do: false

  def complete_actor_event(agent_uid, binding_name, source_event_id, opts \\ []) do
    completed_at = Keyword.get(opts, :completed_at, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      query =
        from(event in ActorEvent,
          where:
            event.agent_uid == ^agent_uid and event.binding_name == ^binding_name and
              event.source_event_id == ^source_event_id,
          lock: "FOR UPDATE"
        )

      case repo.one(query) do
        %ActorEvent{} = actor_event ->
          Actors.complete_actor_event_in_tx(
            repo,
            actor_event,
            Keyword.put(opts, :completed_at, completed_at)
          )

        nil ->
          {:error, :actor_event_not_found}
      end
    end)
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

  def wait_for_attachment_outbox(actor_event_id, attempts \\ 100)

  def wait_for_attachment_outbox(actor_event_id, attempts) when attempts > 0 do
    case Repo.get_by(OutboxEntry, source_actor_event_id: actor_event_id) do
      %OutboxEntry{payload: %{"attachments" => [_ | _]}} = outbox ->
        outbox

      _value ->
        Process.sleep(10)
        wait_for_attachment_outbox(actor_event_id, attempts - 1)
    end
  end

  def wait_for_attachment_outbox(actor_event_id, 0) do
    flunk("attachment outbox for actor event #{actor_event_id} was not committed")
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

  def insert_generating_ai_message_for_actor_event!(%ActorEvent{} = actor_event, opts \\ []) do
    now = Keyword.get(opts, :now, @base_time)
    conversation = active_conversation_for_actor_event!(actor_event)

    Repo.insert!(%Message{
      agent_uid: actor_event.agent_uid,
      conversation_id: conversation.id,
      type: "message",
      status: "generating",
      content: Keyword.get(opts, :content, []),
      metadata:
        %{"actor_event_id" => actor_event.id}
        |> Map.merge(Keyword.get(opts, :metadata, %{})),
      inserted_at: now,
      updated_at: now
    })
  end

  def start_aigateway_run_for_turn!(turn_ref, opts \\ []) do
    agent_uid = get_in(turn_ref, ["actor", "agent_uid"])
    session_id = get_in(turn_ref, ["actor", "session_id"])
    actor_event_id = Map.fetch!(turn_ref, "actor_event_id")
    request_items = Keyword.get(opts, :request_items, [])

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent_uid, session_id)

    {:ok, run} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent_uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event_id,
        request_items: request_items
      })

    run
  end

  def complete_aigateway_turn!(turn_ref, text, opts \\ []) do
    run =
      case Keyword.get(opts, :run) do
        %Message{} = run -> run
        nil -> start_aigateway_run_for_turn!(turn_ref, opts)
      end

    output_items =
      Keyword.get(opts, :output_items, [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ])

    {:ok, committed} = StatefulResponses.commit_complete(run, output_items)

    if Keyword.get(opts, :wait_for_mirror, false) do
      dispatch_final_reply_outbox!(committed.id)
      wait_for_final_mirror(committed.id)
    end

    committed
  end

  def dispatch_final_reply_outbox!(ai_message_id) do
    case Repo.get_by(OutboxEntry, outbound_key: "ai-reply:#{ai_message_id}") do
      %OutboxEntry{} = outbox ->
        assert {:ok, %OutboxEntry{status: :succeeded}} =
                 SignalsGateway.dispatch_outbox(
                   outbox.agent_uid,
                   outbox.binding_name,
                   outbox.outbound_key,
                   %{
                     capabilities: [:post_entry, :reply_entry, :edit_entry],
                     send: fn outbox ->
                       {:ok,
                        %{
                          created_source_entry_id:
                            outbox.target_source_entry_id || "test-final-#{ai_message_id}",
                          raw_payload: %{"provider" => "test"}
                        }}
                     end
                   }
                 )

        :ok

      nil ->
        :ok
    end
  end

  def wait_for_final_mirror(ai_message_id, attempts \\ 20)

  def wait_for_final_mirror(ai_message_id, attempts) when attempts > 0 do
    case Repo.get_by(Entry, ai_message_id: ai_message_id) do
      %Entry{} = entry ->
        entry

      nil ->
        Process.sleep(50)
        wait_for_final_mirror(ai_message_id, attempts - 1)
    end
  end

  def wait_for_final_mirror(ai_message_id, 0) do
    flunk("expected final mirror for ai_message_id=#{ai_message_id}")
  end

  defp active_conversation_for_actor_event!(%ActorEvent{} = actor_event) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^actor_event.agent_uid)
    |> where([conversation], conversation.conversation_key == ^actor_event.session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> Repo.one!()
  end

  def ai_message_for_actor_event!(actor_event_id) do
    Message
    |> where([message], fragment("?->>'actor_event_id'", message.metadata) == ^actor_event_id)
    |> Repo.one!()
  end

  def wait_for_ai_message_status(actor_event_id, status, attempts \\ 100)

  def wait_for_ai_message_status(actor_event_id, status, attempts) when attempts > 0 do
    case ai_message_for_actor_event(actor_event_id) do
      %Message{status: ^status} = message ->
        message

      %Message{} ->
        Process.sleep(10)
        wait_for_ai_message_status(actor_event_id, status, attempts - 1)

      nil ->
        Process.sleep(10)
        wait_for_ai_message_status(actor_event_id, status, attempts - 1)
    end
  end

  def wait_for_ai_message_status(actor_event_id, status, 0) do
    flunk("ai message for actor event #{actor_event_id} did not reach #{status}")
  end

  defp ai_message_for_actor_event(actor_event_id) do
    Message
    |> where([message], fragment("?->>'actor_event_id'", message.metadata) == ^actor_event_id)
    |> Repo.one()
  end

  defp maybe_finalize_test_inbound_batch(%{inbound_batch: %InboundBatch{} = batch} = result) do
    finalize_result =
      Ankole.SignalsGatewayFixtures.finalize_due_inbound_batch_events(
        now: DateTime.add(batch.available_at, 1, :microsecond)
      )

    with {:ok, finalized_results} <- finalize_result,
         %ActorEvent{} = actor_event <- finalized_actor_event(finalized_results, batch.id) do
      Map.put(result, :actor_event, actor_event)
    else
      _no_actor_event ->
        attach_existing_actor_event_from_batch(batch, result)
    end
  end

  defp maybe_finalize_test_inbound_batch(result), do: result

  defp attach_existing_actor_event_from_batch(%InboundBatch{} = batch, result) do
    case Repo.get(InboundBatch, batch.id) do
      %InboundBatch{actor_event_id: id} when is_binary(id) and byte_size(id) > 0 ->
        case Repo.get(ActorEvent, id) do
          %ActorEvent{} = ae -> Map.put(result, :actor_event, ae)
          nil -> result
        end

      _ ->
        result
    end
  end

  defp finalized_actor_event(finalized_results, batch_id) do
    Enum.find_value(finalized_results, fn
      %{inbound_batch: %InboundBatch{id: ^batch_id}, actor_event: %ActorEvent{} = input} ->
        input

      _result ->
        nil
    end)
  end
end
