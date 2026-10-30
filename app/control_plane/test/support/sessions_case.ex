defmodule Ankole.SessionsCase do
  alias Ankole.AIGateway.ResponseCommit
  @moduledoc false

  use ExUnit.CaseTemplate

  import ExUnit.Assertions
  import Ecto.Query, warn: false
  import Ankole.SignalsFixtures, only: [delivery_adapter: 2]

  alias Ankole.AIGatewayCase
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Sessions.Queue
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.Config, as: AgentWorkersConfig
  alias Ankole.Sessions.RPCLane
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.Run
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.Repo

  alias Ankole.Conversations.Observe
  alias Ankole.Conversations.InboundBatch
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Message, as: ConversationMessage
  alias Ankole.Conversations.ExternalMessageRef

  def ensure_workspace(agent_uid, session_id) do
    Repo.transact(fn ->
      Ankole.Sessions.Workspaces.ensure_in_tx(agent_uid, session_id)
    end)
  end

  def effective_worker_env(agent_uid, opts \\ []) do
    with {:ok, %{operator: operator, binding: binding}} <-
           Ankole.AgentWorkers.WorkerEnv.effective_env_parts(agent_uid, opts),
         do: {:ok, Map.merge(operator, binding)}
  end

  using do
    quote do
      use Ankole.DataCase, async: false

      import Ecto.Query, warn: false
      import Ankole.SignalsFixtures, only: [delivery_adapter: 2, delivery_adapter: 3]

      import Ankole.SessionsCase,
        except: [use_mock_signal_provider_plugin: 1]

      import Ankole.AIGatewayCase, only: [start_response_run: 1]

      alias Ankole.AIGateway.ProviderConfigs, warn: false
      alias Ankole.AIGateway.StatefulResponses, warn: false
      alias Ankole.RuntimeFabric.V1, as: FabricProto, warn: false
      alias Ankole.AIAgent.ModelProfiles, warn: false
      alias Ankole.AIGateway.Schemas.Conversation, warn: false
      alias Ankole.AIGateway.Schemas.Message, warn: false
      alias Ankole.Sessions.Queue, warn: false
      alias Ankole.Signals.Signal, warn: false
      alias Ankole.AgentWorkers, warn: false
      alias Ankole.Sessions.RPCLane, warn: false
      alias Ankole.AgentWorkers.AgentWorker, warn: false
      alias Ankole.AgentWorkers.WorkerRoute, warn: false
      alias Ankole.AgentWorkers.WorkerAuthKey, warn: false
      alias Ankole.AgentWorkers.WorkerBootstrap, warn: false
      alias Ankole.Repo, warn: false

      alias Ankole.Conversations.Observe, warn: false
      alias Ankole.Conversations.InboundBatch, warn: false
      alias Ankole.Conversations.Delivery.Intent, warn: false
      alias Ankole.Conversations.Message, as: ConversationMessage, warn: false
      alias Ankole.Conversations.ExternalMessageRef, warn: false
      alias Ankole.SystemConfig, warn: false

      @base_time ~U[2026-07-02 01:34:05.000000Z]
      @long_lease_seconds 31_536_000
    end
  end

  def driver_pids do
    Ankole.Sessions.Drivers
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_id, pid, _type, _modules} -> if is_pid(pid), do: [pid], else: [] end)
    |> MapSet.new()
  end

  @doc "Registers a passive Driver boundary fake for a domain unit test."
  def stub_driver(key, owner \\ self()) do
    caller = self()
    ready = make_ref()

    pid =
      spawn(
        Ankole.Repo.bind_tenant(fn ->
          :ok = Ankole.Sessions.Events.subscribe_input(key.agent_uid, key.session_id)
          send(caller, ready)
          stub_driver_loop(owner, Process.monitor(owner))
        end)
      )

    receive do
      ^ready -> :ok
    after
      5_000 -> raise "Driver boundary fake did not subscribe"
    end

    :yes = :global.register_name(Ankole.Sessions.driver_name(key), pid)
    pid
  end

  defp stub_driver_loop(owner, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        :ok

      message ->
        send(owner, message)
        stub_driver_loop(owner, monitor)
    end
  end

  @doc "Installs passive task Drivers before a Workflow unit fixture dispatches."
  def stub_workflow_drivers(run) do
    handler = {__MODULE__, :workflow_drivers, run.id}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if String.starts_with?(metadata.query, ~s(INSERT INTO "workflow_agent_calls")) and
               run.id in metadata.params do
            {:ok, %{columns: columns, rows: rows}} = metadata.result
            id_column = Enum.find_index(columns, &(&1 == "id"))

            Enum.each(rows, fn row ->
              stub_driver(
                %{
                  agent_uid: run.agent_uid,
                  session_id: Ankole.Workflow.task_session_id(Enum.at(row, id_column))
                },
                owner
              )
            end)
          end
        end,
        nil
      )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(handler) end)
    run
  end

  def stop_new_drivers(existing_pids) do
    MapSet.difference(driver_pids(), existing_pids)
    |> Enum.each(&DynamicSupervisor.terminate_child(Ankole.Sessions.Drivers, &1))
  end

  def preview_handler_pids do
    Ankole.Conversations.Delivery.Previews
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_id, pid, :worker, _modules} when is_pid(pid) -> [pid]
      _child -> []
    end)
    |> MapSet.new()
  end

  def stop_new_preview_handlers(existing_pids) do
    existing_pids = MapSet.new(existing_pids)

    handlers =
      existing_pids
      |> then(fn existing -> MapSet.difference(preview_handler_pids(), existing) end)
      |> Enum.map(fn pid -> {pid, Process.monitor(pid)} end)

    Enum.each(handlers, fn {pid, _monitor} -> GenServer.cast(pid, :stop) end)

    Enum.each(handlers, fn {pid, monitor} ->
      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        6_000 ->
          Process.demonitor(monitor, [:flush])
          _ = DynamicSupervisor.terminate_child(Ankole.Conversations.Delivery.Previews, pid)
      end
    end)

    :ok
  end

  @doc """
  Admits the Worker of one Agent on `route`, the way a real Worker does: the
  row is provisioned as the reconcile job creates it (a generation, its
  credential digest, this node's image, protocol, and template) and the
  process joins. `worker_id:` names the Agent; without it the test must have
  exactly one Agent.
  """
  def admit_worker(route, overrides \\ %{}) do
    agent_uid = Map.get(overrides, :worker_id) || sole_agent_uid!()
    capacity = Map.get(overrides, :capacity, %{"available_slots" => 4})
    load = Map.get(overrides, :load)
    available_slots = Map.get(capacity, "available_slots", 0)
    active_slots = if is_map(load), do: Map.get(load, "active_slots", 0), else: 0
    max_slots = Map.get(capacity, "max_slots", available_slots + active_slots)
    incarnation_id = Map.get(overrides, :incarnation_id, "incarnation-" <> route)

    :ok = provision_worker(agent_uid)

    auth = %{
      transport_route: route,
      worker_id: agent_uid,
      generation: Repo.get!(AgentWorker, agent_uid).generation
    }

    admitted =
      AgentWorkers.admit_join(
        %{
          incarnation_id: incarnation_id,
          max_slots: max_slots,
          available_slots: available_slots
        },
        auth
      )

    # The join carries no load; a Worker reports it in its next heartbeat.
    with {:ok, worker} when load != nil <- admitted do
      AgentWorkers.handle_worker_heartbeat(
        %FabricProto.WorkerHeartbeat{
          incarnation_id: worker.incarnation_id,
          max_slots: max_slots,
          active_slots: active_slots,
          available_slots: available_slots,
          active_tasks: Map.get(load, "active_tasks", active_slots),
          idle_for_ms: Map.get(load, "idle_for_ms", 0)
        },
        auth
      )
    end
  end

  @doc """
  Gives an Agent's row a generation as `ReconcileJob` creates one, unless the
  row can already accept a process. Returns the credential of a new
  generation in the process dictionary of the test as `{:worker_token, uid}`.
  """
  def provision_worker(agent_uid) do
    {:ok, config} = AgentWorkersConfig.fetch()

    case Repo.get(AgentWorker, agent_uid) do
      %AgentWorker{state: state} when state in [:starting, :stale, :ready] ->
        :ok

      %AgentWorker{} = worker ->
        {:ok, provider} =
          Ankole.AgentWorkers.Providers.load(worker.provider_id)

        generation =
          "test" <>
            String.slice(Base.encode16(:crypto.hash(:sha256, agent_uid), case: :lower), 0, 6)

        {:ok, credential} =
          Ankole.AgentWorkers.issue_credential(agent_uid, generation)

        {:ok, token} =
          Ankole.AgentWorkers.credential(%AgentWorker{
            agent_uid: agent_uid,
            generation: generation,
            token_ciphertext: credential.token_ciphertext
          })

        Process.put({:worker_token, agent_uid}, token)

        {1, _rows} =
          Repo.update_all(
            from(worker in AgentWorker, where: worker.agent_uid == ^agent_uid),
            set: [
              state: :starting,
              generation: generation,
              token_digest: credential.token_digest,
              token_ciphertext: credential.token_ciphertext,
              image: config.image,
              protocol_version: config.protocol_version,
              settings_digest: provider.settings_digest,
              transport_route: nil,
              drain_reason: nil
            ]
          )

        :ok

      nil ->
        raise ArgumentError,
              "Agent #{agent_uid} has no Worker row; create it with agent_fixture/1"
    end
  end

  defp sole_agent_uid! do
    case Repo.all(
           from principal in Ankole.Principals.Principal,
             where: principal.type == :agent,
             select: principal.uid
         ) do
      [agent_uid] ->
        agent_uid

      agents ->
        raise ArgumentError,
              "admit_worker/2 needs worker_id: when the test has #{length(agents)} Agents"
    end
  end

  def turn_proto_ref(%JobTurnRef{} = ref), do: JobTurnRef.to_proto(ref)
  def turn_proto_ref(%FabricProto.JobTurnRef{} = ref), do: ref
  def turn_proto_ref(%FabricProto.RunRef{} = ref), do: ref

  def commit_turn_completion(%Run{} = run, final_response_id, outcome \\ :loop_finished) do
    Ankole.Sessions.Run.finalize(
      %{run | anchor: String.replace_prefix(final_response_id, "resp_", "")},
      outcome
    )
  end

  def complete_turn_silent(%Run{} = run, _final_response_id \\ nil),
    do: Ankole.Sessions.Run.finalize(run, :silent)

  @doc """
  Unwraps one expected body payload from a captured envelope struct.
  """
  def envelope_body!(%FabricProto.Envelope{body: {type, payload}}, type), do: payload

  def envelope_body_type(%FabricProto.Envelope{body: {type, _payload}}), do: type

  def turn_start_payload!(envelope), do: envelope_body!(envelope, :turn_start)

  def decoded_request_context(%FabricProto.TurnStart{request_context_json: bytes}),
    do: decoded_json_bytes(bytes)

  def decoded_json_bytes(bytes) when bytes in [nil, ""], do: nil
  def decoded_json_bytes(bytes) when is_binary(bytes), do: Torque.decode!(bytes)

  @doc """
  Encodes an envelope struct into the protobuf bytes the router delivers.
  """
  def encode_fabric_envelope(%FabricProto.Envelope{} = envelope),
    do: Ankole.RuntimeFabric.encode_envelope(envelope)

  @doc """
  Builds a worker-originated RPC request frame carrying an encoded payload
  message. `turn:` (domain or generated fence) is the frame fact of
  turn-scoped methods.
  """
  def rpc_request(request_id, method, payload, opts \\ [])

  def rpc_request(request_id, method, %_{} = payload, opts) do
    %FabricProto.RPCRequest{
      request_id: request_id,
      method: method,
      payload: encode_proto!(payload),
      run: Keyword.get(opts, :run),
      job_turn:
        case Keyword.get(opts, :job_turn) do
          nil -> nil
          ref -> turn_proto_ref(ref)
        end
    }
  end

  @doc """
  Handles one RPC as if it arrived on `route` from the Worker of `worker_id`.
  A test with one Agent may omit `worker_id`.
  """
  def handle_rpc(%FabricProto.RPCRequest{} = request, route, worker_id \\ nil) do
    worker_id = worker_id || sole_agent_uid!()
    RPCLane.handle_request(request, %{transport_route: route, worker_id: worker_id})
  end

  @doc """
  Encodes one generated message struct into its binary payload bytes.
  """
  def encode_proto!(%_{} = message) do
    {iodata, _size} = message.__struct__.encode!(message)
    IO.iodata_to_binary(iodata)
  end

  @doc """
  Decodes an `rpc_response` payload with the method's response module.
  """
  def rpc_response_payload!(envelope, module) do
    {:ok, decoded} = module.decode(envelope_body!(envelope, :rpc_response).payload)
    decoded
  end

  def rpc_error_payload!(envelope) do
    error = envelope_body!(envelope, :rpc_error)

    %{
      "request_id" => error.request_id,
      "code" => error.code,
      "message" => error.message,
      "details_json" => decoded_json_bytes(error.details_json) || %{}
    }
  end

  def agent_fixture(attrs \\ %{}) do
    %{principal: agent} = fixture = Ankole.PrincipalsFixtures.agent_fixture(attrs)
    provider_id = "actor-runtime-test-" <> Ecto.UUID.generate()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    :ok = cache_actor_runtime_models(provider_id)

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

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "heavy", %{
               provider_id: provider_id,
               model: "openai/gpt-5.6-sol"
             })

    fixture
  end

  @doc false
  def cache_actor_runtime_models(provider_id, image_models \\ []) do
    {:ok, provider} = ProviderConfigs.fetch_provider(provider_id)

    models =
      Enum.map(
        [
          {"google/gemini-3.5-flash", 65_536},
          {"openai/gpt-5.4-nano", 32_768},
          {"openai/gpt-5.6-sol", 128_000}
        ],
        fn {id, max_completion_tokens} ->
          %{
            "id" => id,
            "architecture" => %{
              "input_modalities" => if(id in image_models, do: ["text", "image"], else: ["text"])
            },
            "top_provider" => %{"max_completion_tokens" => max_completion_tokens}
          }
        end
      )

    # The key must stay identical to ModelMetadata's own source cache key,
    # provider revision included. A stale shape here is silent: every Turn that
    # resolves a model profile then reaches the real OpenRouter catalog over the
    # network, so the assertion below fails loudly instead.
    :ok =
      ModelMetadataCache.put(
        {:model_metadata_source, provider_id, provider.updated_at, :openrouter,
         "models?output_modalities=all"},
        models,
        :timer.hours(1)
      )

    assert {:ok, %{"top_provider" => %{"max_completion_tokens" => 65_536}}} =
             ModelMetadata.model_metadata(provider, "google/gemini-3.5-flash", capability: "llm"),
           "seeded model metadata is unreachable, so Turns will fetch the live catalog"

    :ok
  end

  def binding_fixture(agent_uid, name, policy, opts \\ []) do
    {:ok, binding} =
      Ankole.SignalsFixtures.raw_binding_fixture(%{
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
    original_state = Ankole.Plugins.Registry.snapshot_for_test()
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    Ankole.Plugins.Registry.update_for_test(fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    on_exit(fn ->
      Ankole.Plugins.Registry.update_for_test(fn _state -> original_state end)
      Ankole.AppConfigure.Registry.clear_for_test()
    end)

    :ok
  end

  def emit_entry(agent_uid, binding_name, input, opts) do
    # Observation and batch finalization are top-level actions; each owns its
    # transaction. Domain tests admit the input explicitly; Driver integration
    # tests set stub_driver: false.
    {stub_driver?, opts} = Keyword.pop(opts, :stub_driver, true)

    with {:ok, result} <-
           observe_emit_entry(agent_uid, binding_name, input, opts, stub_driver?) do
      {:ok, maybe_finalize_test_inbound_batch(result, stub_driver?)}
    end
  end

  defp observe_emit_entry(agent_uid, binding_name, input, opts, false) do
    Observe.emit_entry(agent_uid, binding_name, input, opts)
  end

  defp observe_emit_entry(agent_uid, binding_name, input, opts, true) do
    owner = self()
    spawned_ref = make_ref()
    handler = {__MODULE__, :emit_entry_drivers, spawned_ref}
    Process.put(spawned_ref, [])

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          maybe_stub_inserted_session_drivers(metadata, agent_uid, owner, spawned_ref)
        end,
        nil
      )

    try do
      case Observe.emit_entry(agent_uid, binding_name, input, opts) do
        {:ok, _result} = ok ->
          ok

        other ->
          cleanup_spawned_stub_drivers(spawned_ref)
          other
      end
    rescue
      error ->
        cleanup_spawned_stub_drivers(spawned_ref)
        reraise error, __STACKTRACE__
    after
      :telemetry.detach(handler)
      Process.delete(spawned_ref)
    end
  end

  defp maybe_stub_inserted_session_drivers(metadata, agent_uid, owner, spawned_ref) do
    query = Map.get(metadata, :query, "")
    params = Map.get(metadata, :params, [])

    if (String.starts_with?(query, ~s(INSERT INTO "signals")) or
          String.starts_with?(query, ~s(INSERT INTO "conversation_inbound_batches"))) and
         agent_uid in params do
      for {^agent_uid, session_id} <-
            extract_inserted_session_keys(query, params, metadata.result),
          is_binary(session_id) and session_id != "" do
        key = %{agent_uid: agent_uid, session_id: session_id}

        if Ankole.Sessions.driver_pid(key) == :undefined do
          pid = stub_driver(key, owner)
          Process.put(spawned_ref, [pid | Process.get(spawned_ref, [])])
        end
      end
    end
  end

  defp extract_inserted_session_keys(query, params, {:ok, %{num_rows: n} = res})
       when is_integer(n) and n > 0 do
    case res do
      %{columns: columns, rows: rows} when is_list(columns) and is_list(rows) and rows != [] ->
        agent_idx = Enum.find_index(columns, &(&1 == "agent_uid"))
        session_idx = Enum.find_index(columns, &(&1 == "session_id"))

        if is_integer(agent_idx) and is_integer(session_idx) do
          Enum.map(rows, fn row -> {Enum.at(row, agent_idx), Enum.at(row, session_idx)} end)
        else
          extract_session_keys_from_insert_sql(query, params)
        end

      _without_returning ->
        extract_session_keys_from_insert_sql(query, params)
    end
  end

  defp extract_inserted_session_keys(_query, _params, _result), do: []

  defp extract_session_keys_from_insert_sql(query, params) do
    case Regex.run(
           ~r/\AINSERT INTO "(?:signals|conversation_inbound_batches)" \(([^)]+)\) VALUES \(([^)]+)\)/,
           query
         ) do
      [_, raw_cols, raw_vals] ->
        cols = raw_cols |> String.split(",") |> Enum.map(&String.trim(&1, " \""))
        vals = raw_vals |> String.split(",") |> Enum.map(&resolve_sql_param(&1, params))
        pairs = Map.new(Enum.zip(cols, vals))
        [{Map.get(pairs, "agent_uid"), Map.get(pairs, "session_id")}]

      _other ->
        []
    end
  end

  defp resolve_sql_param(token, params) do
    case Regex.run(~r/\A\s*\$(\d+)\s*\z/, token) do
      [_, idx_str] -> Enum.at(params, String.to_integer(idx_str) - 1)
      _other -> nil
    end
  end

  defp cleanup_spawned_stub_drivers(spawned_ref) do
    spawned_ref
    |> Process.get([])
    |> Enum.each(&Process.exit(&1, :kill))
  end

  def group_entry(overrides) do
    Ankole.SignalsFixtures.group_entry(
      Map.merge(
        %{
          source_event_id: "evt-" <> Integer.to_string(System.unique_integer([:positive])),
          provider_message_id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
          text: "PING",
          explicit: false
        },
        overrides
      )
    )
  end

  def append_runtime_signal(agent_uid, session_id, type, opts) do
    now = Keyword.fetch!(opts, :now)
    source_event_id = "#{type}-#{System.unique_integer([:positive])}"

    Repo.transact(fn ->
      Ankole.Signals.accept_in_tx(%{
        producer: :kernel,
        sender: agent_uid,
        target: %{agent_uid: agent_uid, session_id: session_id},
        source: "control-plane://test",
        subject: session_id,
        id: source_event_id,
        type: type,
        time: now,
        available_at: now,
        data: %{
          "session" => %{
            "agent_uid" => agent_uid,
            "session_id" => session_id
          }
        }
      })
    end)
  end

  def complete_signal(agent_uid, binding_name, source_event_id, opts \\ []) do
    completed_at = Keyword.get(opts, :completed_at, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      query =
        from(event in Signal,
          where:
            event.agent_uid == ^agent_uid and event.reply_binding_name == ^binding_name and
              event.source_event_id == ^source_event_id,
          lock: "FOR UPDATE"
        )

      case repo.lock_all(query, "signals") do
        [%Signal{} = signal] ->
          Queue.complete_signal_in_tx(
            signal,
            Keyword.put(opts, :completed_at, completed_at)
          )

        [] ->
          {:error, :signal_not_found}
      end
    end)
  end

  def lifecycle_entry(overrides) do
    Map.merge(
      %{
        source_event_id: "lifecycle-" <> Integer.to_string(System.unique_integer([:positive])),
        provider_conversation_id: "lark:chat:group-a",
        provider_message_id: "msg-" <> Integer.to_string(System.unique_integer([:positive])),
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      },
      overrides
    )
  end

  def unique_route do
    "local-test-route-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  def wait_for_worker(worker_id, worker_task, attempts \\ 100)

  def wait_for_worker(worker_id, worker_task, attempts) when attempts > 0 do
    case Repo.get(AgentWorker, worker_id) do
      %AgentWorker{state: :ready} = worker ->
        worker

      _not_ready ->
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

  def start_aigateway_run_for_turn!(turn_ref, opts \\ [])

  def start_aigateway_run_for_turn!(%FabricProto.RunRef{} = ref, opts) do
    {:ok, run_ref} = Ankole.Sessions.RunRef.from_proto(ref, sole_agent_uid!())
    start_aigateway_run_for_turn!(run_ref, opts)
  end

  def start_aigateway_run_for_turn!(
        %{agent_uid: _, session_id: _, signal_id: _} = turn_ref,
        opts
      ) do
    agent_uid = turn_ref.agent_uid
    session_id = turn_ref.session_id
    signal_id = turn_ref.signal_id
    request_items = Keyword.get(opts, :request_items, [])

    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent_uid, session_id)

    {:ok, run} =
      AIGatewayCase.start_response_run(%{
        subject_uid: agent_uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"signal_id" => signal_id}},
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

    {:ok, committed} = ResponseCommit.commit_complete(run, output_items)

    if Keyword.get(opts, :wait_for_mirror, false) do
      assert {:ok, %{status: :turn_completed}} =
               commit_turn_completion(
                 turn_ref,
                 "resp_#{committed.id}",
                 Keyword.get(opts, :outcome, :loop_finished)
               )

      dispatch_final_reply_intent!(committed.id)
      wait_for_final_mirror(committed.id)
    end

    committed
  end

  def dispatch_final_reply_intent!(ai_message_id) do
    case Repo.get_by(Intent, outbound_key: "ai-reply:#{ai_message_id}") do
      %Intent{} = intent ->
        assert {:ok, %Intent{status: :sent}} =
                 Ankole.Conversations.Delivery.dispatch(
                   intent.agent_uid,
                   intent.binding_name,
                   intent.outbound_key,
                   delivery_adapter([:post_entry, :reply_entry, :edit_entry], fn intent ->
                     {:ok,
                      %{
                        created_provider_message_id:
                          intent.target_provider_message_id || "test-final-#{ai_message_id}",
                        raw_payload: %{"provider" => "test"}
                      }}
                   end)
                 )

        :ok

      nil ->
        :ok
    end
  end

  def final_message_observation(ai_message_id) do
    Repo.one(
      from message in ConversationMessage,
        join: ref in ExternalMessageRef,
        on: ref.message_id == message.id and ref.tenant_id == message.tenant_id,
        where: ref.ai_message_id == ^ai_message_id,
        order_by: [asc: message.seq],
        limit: 1,
        select: %{message: message, external_ref: ref}
    )
  end

  def wait_for_final_mirror(ai_message_id, attempts \\ 20)

  def wait_for_final_mirror(ai_message_id, attempts) when attempts > 0 do
    case final_message_observation(ai_message_id) do
      %{message: %ConversationMessage{}, external_ref: %ExternalMessageRef{}} = observation ->
        observation

      nil ->
        Process.sleep(50)
        wait_for_final_mirror(ai_message_id, attempts - 1)
    end
  end

  def wait_for_final_mirror(ai_message_id, 0) do
    flunk("expected final mirror for ai_message_id=#{ai_message_id}")
  end

  defp maybe_finalize_test_inbound_batch(
         %{inbound_batch: %InboundBatch{} = batch} = result,
         stub_driver?
       ) do
    key = %{agent_uid: batch.agent_uid, session_id: batch.session_id}

    if stub_driver? and Ankole.Sessions.driver_pid(key) == :undefined,
      do: stub_driver(key)

    finalize_result =
      Ankole.SignalsFixtures.finalize_due_inbound_batch_events(now: batch.available_at)

    with {:ok, finalized_results} <- finalize_result,
         %Signal{} = signal <- finalized_signal(finalized_results, batch.id) do
      Map.put(result, :signal, signal)
    else
      _no_signal ->
        attach_existing_signal_from_batch(batch, result)
    end
  end

  defp maybe_finalize_test_inbound_batch(result, _stub_driver?), do: result

  defp attach_existing_signal_from_batch(%InboundBatch{} = batch, result) do
    case Repo.get(InboundBatch, batch.id) do
      %InboundBatch{} = row ->
        case Repo.get_by(Signal,
               agent_uid: row.agent_uid,
               reply_binding_name: row.binding_name,
               source_event_id: "inbound-batch:#{row.id}:#{row.batch_revision}"
             ) do
          %Signal{} = event -> Map.put(result, :signal, event)
          nil -> result
        end

      nil ->
        result
    end
  end

  defp finalized_signal(finalized_results, batch_id) do
    Enum.find_value(finalized_results, fn
      %{inbound_batch: %InboundBatch{id: ^batch_id}, signal: %Signal{} = input} ->
        input

      _result ->
        nil
    end)
  end
end
