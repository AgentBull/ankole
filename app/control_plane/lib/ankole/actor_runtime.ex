defmodule Ankole.ActorRuntime do
  @moduledoc """
  Control-plane API for the Actor Runtime PING/PONG main path.

  This is the durable turn/commit/fence core. It owns the boundary between two
  layers with deliberately different guarantees:

    * AI-agent state (conversations, turns, messages) is *durable truth*.
    * Actor-runtime projections (activations, deliveries, assignments) are
      cheaper *runtime hints* that fence in-flight work and can be rebuilt.

  Every worker reply must echo a `turn_ref` whose fields are checked by equality
  against database rows (the "triple fence": activation, actor epoch, and the
  delivery rows that name a turn). This makes a late or cross-session worker
  reply fail harmlessly instead of corrupting the durable transcript, and it
  needs no in-memory session state to do so. The one intentionally weak spot —
  a durable started turn whose runtime fences were lost on a restart — is
  repaired by `reconcile_projection_lost_started_turns/1`.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.CommitCoordinator
  alias Ankole.ActorRuntime.FileTransferLane
  alias Ankole.ActorRuntime.OutboxDispatcher
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.TurnEnvelope
  alias Ankole.ActorRuntime.TurnRetry
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.ActorRuntime.WorkerAdmission
  alias Ankole.ActorRuntime.WorkerPool
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorInputTypes
  alias Ankole.SystemConfig

  # The "live" delivery set: a worker may still be acting on a turn while any of
  # its deliveries is in one of these states, so a live delivery blocks creating
  # a second delivery for the same input. `send_failed`/`superseded` are not live.
  # Mirrors the WHERE clause of the partial unique index in the migration.
  @live_delivery_states ~w(created sent accepted)
  # The "live" activation set: an activation owns its actor session while in one
  # of these statuses. `stopped`/`failed` are terminal and free the session.
  @live_activation_statuses ~w(starting active draining)
  @active_control_command_types ~w(command.new command.stop command.retry command.steer command.compress)
  @activation_progress_lease_seconds 300
  @daily_reset_time ~T[04:30:00]
  @session_lifecycle_binding_name "control-plane:session-lifecycle"

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Delegates active-conversation creation to the AI-agent context.
  """
  @spec ensure_conversation(String.t(), String.t()) :: {:ok, Conversation.t()} | {:error, term()}
  def ensure_conversation(agent_uid, session_id),
    do: AIAgent.ensure_conversation(agent_uid, session_id)

  @doc """
  Admits an authenticated worker-ready message.
  """
  @spec admit_worker_ready(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate admit_worker_ready(worker_ready, authenticated_route), to: WorkerAdmission

  @doc """
  Records a worker-ready projection.
  """
  @spec record_worker_ready(map(), String.t() | nil) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate record_worker_ready(attrs, route \\ nil), to: WorkerAdmission

  @doc """
  Records an authenticated worker heartbeat projection.
  """
  @spec handle_worker_heartbeat(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate handle_worker_heartbeat(worker_heartbeat, authenticated_route), to: WorkerAdmission

  @doc """
  Records an authenticated worker capacity projection.
  """
  @spec handle_worker_capacity(map(), String.t() | map()) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate handle_worker_capacity(worker_capacity, authenticated_route), to: WorkerAdmission

  @doc """
  Assigns a ready worker to one actor key.
  """
  @spec assign_worker(actor_key()) ::
          {:ok, ActorSessionWorkerAssignment.t()} | {:error, term()}
  defdelegate assign_worker(actor_key), to: WorkerPool

  @doc """
  Writes bytes into a worker-owned filesystem root through RuntimeFabric.

  This is for file materialization outside actor turns, for example inbound
  provider attachments. The control plane owns the request; the worker owns the
  filesystem mutation.
  """
  @spec put_worker_file(String.t(), String.t(), iodata(), keyword()) ::
          FileTransferLane.operation_result()
  def put_worker_file(root, relative_path, content, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    with {:ok, route} <- WorkerPool.file_worker_route() do
      FileTransferLane.put(route, root, relative_path, content, opts)
    end
  end

  @doc """
  Reads bytes from a worker-owned filesystem root through RuntimeFabric.

  Provider adapters use this for outbound native attachments. The control plane
  never mounts the shared filesystem; it asks a ready worker to stream the file
  over the file lane.
  """
  @spec get_worker_file(String.t(), String.t(), keyword()) :: FileTransferLane.get_result()
  def get_worker_file(root, relative_path, opts \\ [])
      when is_binary(root) and is_binary(relative_path) do
    with {:ok, route} <- WorkerPool.file_worker_route() do
      FileTransferLane.get(route, root, relative_path, opts)
    end
  end

  @doc """
  Calls one semantic RPC method on a worker route.

  This is the control-plane caller side of the bidirectional RuntimeFabric RPC
  lane. The caller chooses the worker route deliberately; worker-pool selection
  remains separate from method dispatch.
  """
  @spec request_worker_rpc(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  def request_worker_rpc(transport_route, method, payload \\ %{}, opts \\ [])
      when is_binary(transport_route) and is_binary(method) and is_map(payload) do
    Broker.request_rpc(transport_route, method, payload, opts)
  end

  @doc """
  Starts a worker-backed LLM turn for a ready actor input set.

  This is the control-plane side of the new local actor loop. It creates the
  durable AI-agent turn first, then creates delivery projections that fence the
  worker by actor epoch, activation, and LLM turn.
  """
  @spec start_llm_turn(actor_key(), [ActorInput.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_llm_turn(actor_key, actor_inputs, opts \\ [])
      when is_list(actor_inputs) do
    actor_key = normalize_actor_key(actor_key)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, assignment} <- assign_worker(actor_key) do
      Repo.transact(fn repo ->
        with {:ok, activation} <- ensure_activation(repo, actor_key, assignment, now, opts),
             {:ok, conversation} <-
               AIAgent.ensure_conversation_in_tx(repo, actor_key.agent_uid, actor_key.session_id),
             %Conversation{} = conversation <- AIAgent.lock_conversation(repo, conversation.id),
             {:ok, turn_result} <-
               start_or_reuse_llm_turn_in_tx(
                 repo,
                 conversation,
                 actor_inputs,
                 opts ++ [now: now]
               ),
             {:ok, activation} <-
               bind_activation_turn(repo, activation, turn_result.llm_turn.id, now),
             {:ok, deliveries} <-
               create_input_deliveries_in_tx(
                 repo,
                 actor_inputs,
                 activation,
                 turn_result.llm_turn,
                 assignment,
                 now
               ) do
          turn_ref = TurnEnvelope.turn_ref(repo, actor_key, activation, turn_result.llm_turn)

          envelope =
            TurnEnvelope.turn_start(turn_ref, actor_inputs, deliveries, turn_result.llm_turn)

          {:ok,
           Map.merge(turn_result, %{
             activation: activation,
             assignment: assignment,
             deliveries: deliveries,
             turn_ref: turn_ref,
             envelope: envelope
           })}
        else
          nil -> {:error, :conversation_not_found}
          {:error, _reason} = error -> error
        end
      end)
      |> send_turn_start()
    end
  end

  @doc """
  Creates a delivery attempt for one actor input.

  This public helper is used by tests and recovery paths that already know the
  turn reference. The normal runtime path creates a whole batch before sending
  one `turn_start` envelope.
  """
  @spec create_input_delivery(Ecto.UUID.t(), map(), String.t() | nil) ::
          {:ok, ActorInputDelivery.t()} | {:error, term()}
  def create_input_delivery(actor_input_id, turn_ref, route) do
    Repo.transact(fn repo ->
      with %ActorInput{} = actor_input <- lock_actor_input(repo, actor_input_id),
           %ActorSessionActivation{} = activation <-
             activation_for_turn_ref(repo, turn_ref),
           %LlmTurn{} = llm_turn <- AIAgent.lock_turn(repo, fetch_turn_id(turn_ref)),
           {:ok, delivery} <-
             create_input_delivery_in_tx(
               repo,
               actor_input,
               activation,
               llm_turn,
               route,
               %{},
               DateTime.utc_now(:microsecond)
             ) do
        {:ok, delivery}
      else
        nil -> {:error, :actor_runtime_fence_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Marks a delivery sent.
  """
  @spec mark_delivery_sent(Ecto.UUID.t(), String.t() | atom()) ::
          {:ok, ActorInputDelivery.t()} | {:error, term()}
  def mark_delivery_sent(delivery_id, send_outcome \\ "sent_or_queued") do
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      case lock_delivery(repo, delivery_id) do
        %ActorInputDelivery{state: "created"} = delivery ->
          delivery
          |> ActorInputDelivery.changeset(%{
            state: "sent",
            send_outcome: normalize_outcome(send_outcome),
            sent_at: now
          })
          |> repo.update()

        %ActorInputDelivery{} = delivery ->
          {:ok, delivery}

        nil ->
          {:error, :delivery_not_found}
      end
    end)
  end

  @doc """
  Marks a delivery accepted by a matching worker turn.accepted message.
  """
  @spec mark_delivery_accepted(Ecto.UUID.t(), map()) ::
          {:ok, ActorInputDelivery.t()} | {:error, term()}
  def mark_delivery_accepted(delivery_id, turn_ref) do
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      with %ActorInputDelivery{} = delivery <- lock_delivery(repo, delivery_id),
           :ok <- delivery_matches_turn_ref(delivery, turn_ref) do
        delivery
        |> ActorInputDelivery.changeset(%{state: "accepted", accepted_at: now})
        |> repo.update()
      else
        nil -> {:error, :delivery_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Marks a delivery transport failure.
  """
  @spec mark_delivery_failed(Ecto.UUID.t(), String.t() | atom(), term()) ::
          {:ok, ActorInputDelivery.t()} | {:error, term()}
  def mark_delivery_failed(delivery_id, send_outcome, reason) do
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      case lock_delivery(repo, delivery_id) do
        %ActorInputDelivery{} = delivery ->
          delivery
          |> ActorInputDelivery.changeset(%{
            state: "send_failed",
            send_outcome: normalize_outcome(send_outcome),
            failed_at: now,
            error: %{"reason" => inspect(reason)}
          })
          |> repo.update()

        nil ->
          {:error, :delivery_not_found}
      end
    end)
  end

  @doc """
  Handles an actor lane turn.accepted envelope.

  Acceptance is separate from final commit so the control plane can tell the
  difference between "worker received the turn" and "worker produced a durable
  proposal".
  """
  @spec handle_turn_accepted(map()) :: {:ok, [ActorInputDelivery.t()]} | {:error, term()}
  def handle_turn_accepted(envelope) when is_map(envelope) do
    payload = unwrap_body(envelope, "turn_accepted")
    turn_ref = fetch_map!(payload, "turn")
    accepted_ids = fetch_list(payload, "accepted_actor_input_ids")
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      # A fast worker can echo turn_accepted before send_turn_start/1 finishes
      # marking every delivery as "sent". The accepted envelope itself proves the
      # worker received this turn, so both created and sent are valid pending
      # states for this fence check. Already accepted deliveries are excluded:
      # active steer accepts only the new mailbox_updated delivery for the same
      # turn, not the original turn_start delivery again.
      deliveries =
        ActorInputDelivery
        |> where([delivery], delivery.llm_turn_id == ^fetch_turn_id(turn_ref))
        |> where([delivery], delivery.state in ["created", "sent"])
        |> lock("FOR UPDATE")
        |> repo.all()

      with :ok <- require_all_sent_inputs_accepted(deliveries, accepted_ids),
           :ok <- validate_deliveries_turn_ref(deliveries, turn_ref) do
        deliveries
        |> Enum.map(fn delivery ->
          delivery
          |> ActorInputDelivery.changeset(%{state: "accepted", accepted_at: now})
          |> repo.update()
        end)
        |> collect_results()
      end
    end)
  end

  @doc """
  Extends the live activation lease for a matching in-flight worker turn.

  `worker_progress` is deliberately fenced by the full turn reference. It is a
  lease keepalive, not durable output, so it never changes the activation
  revision or commits transcript state.
  """
  @spec handle_worker_progress(map(), keyword()) ::
          {:ok, ActorSessionActivation.t()} | {:error, term()}
  def handle_worker_progress(envelope, opts \\ []) when is_map(envelope) do
    payload = unwrap_body(envelope, "worker_progress")
    turn_ref = fetch_map!(payload, "turn")
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    lease_seconds = Keyword.get(opts, :lease_seconds, @activation_progress_lease_seconds)

    Repo.transact(fn repo ->
      with %ActorSessionActivation{} = activation <- activation_for_turn_ref(repo, turn_ref),
           %LlmTurn{} = llm_turn <- AIAgent.lock_turn(repo, fetch_turn_id(turn_ref)),
           :ok <- activation_accepts_progress(activation, turn_ref, llm_turn, now) do
        renew_activation_lease(repo, activation, now, lease_seconds)
      else
        nil -> {:error, :actor_runtime_fence_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Handles a final proposal envelope or body and commits it durably.
  """
  @spec commit_final_proposal(map()) :: {:ok, map()} | {:error, term()}
  defdelegate commit_final_proposal(proposal), to: CommitCoordinator

  @doc """
  Handles a worker turn.error envelope and releases the actor input for retry.
  """
  @spec handle_turn_error(map()) :: {:ok, map()} | {:error, term()}
  defdelegate handle_turn_error(envelope), to: CommitCoordinator

  @doc """
  Marks a turn failed.
  """
  @spec mark_turn_failed(Ecto.UUID.t(), term()) :: {:ok, LlmTurn.t()} | {:error, term()}
  def mark_turn_failed(llm_turn_id, reason), do: AIAgent.mark_turn_failed(llm_turn_id, reason)

  @doc """
  Fails started turns whose unlogged activation/delivery fence was lost.
  """
  @spec reconcile_projection_lost_started_turns(keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reconcile_projection_lost_started_turns(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo -> reconcile_projection_lost_started_turns_in_tx(repo, now) end)
  end

  @doc """
  Starts one ready actor if a worker is available.
  """
  @spec process_ready_inputs_once(keyword()) :: {:ok, map()} | {:error, term()}
  def process_ready_inputs_once(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    {:ok, _finalized_batches} = SignalsGateway.finalize_due_inbound_batches(now: now, limit: 1)

    case Actors.list_ready_actor_keys(now, 1) do
      [%{agent_uid: agent_uid, session_id: session_id}] ->
        process_ready_inputs_for_actor(%{agent_uid: agent_uid, session_id: session_id}, opts)

      [] ->
        {:ok, %{status: :idle}}
    end
  end

  @doc """
  Starts ready actors up to the requested limit.
  """
  @spec process_ready_inputs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def process_ready_inputs(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    limit = Keyword.get(opts, :limit, 25)

    {:ok, _finalized_batches} =
      SignalsGateway.finalize_due_inbound_batches(now: now, limit: limit)

    now
    |> Actors.list_ready_actor_keys(limit)
    |> Enum.map(&process_ready_inputs_for_actor(&1, opts))
    |> collect_results()
  end

  @doc """
  Enqueues daily reset barrier inputs for sessions due at the latest local 04:30.

  The control plane owns the timer and timezone. The reset itself is still an
  ordinary `actor_inputs` row, so per-session ordering stays in one queue.
  """
  @spec enqueue_daily_session_resets(keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue_daily_session_resets(opts \\ [])

  def enqueue_daily_session_resets(opts) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, boundary_at, timezone} <- daily_reset_boundary_at(now, opts) do
      enqueue_daily_session_resets(boundary_at, Keyword.put(opts, :timezone, timezone))
    end
  end

  def enqueue_daily_session_resets(%DateTime{} = boundary_at) do
    enqueue_daily_session_resets(boundary_at, [])
  end

  @spec enqueue_daily_session_resets(DateTime.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def enqueue_daily_session_resets(%DateTime{} = boundary_at, opts) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")

    Repo.transact(fn repo ->
      conversations = due_daily_reset_conversations(repo, boundary_at, opts)

      conversations
      |> Enum.map(&enqueue_session_reset_due_in_tx(repo, &1, boundary_at, now, opts))
      |> collect_results()
      |> case do
        {:ok, inputs} ->
          {:ok,
           %{
             status: :enqueued,
             boundary_at: boundary_at,
             timezone: timezone,
             due_sessions: length(conversations),
             actor_inputs: inputs
           }}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  @doc """
  Starts one ready input for an actor key.

  IM burst grouping is already resolved by SignalsGateway before ActorInput
  creation. ActorRuntime must not merge multiple ready ActorInputs into one
  worker turn just because they share a sender. While a generation is already
  running, explicit control commands may pass ordinary content inputs that
  cannot be delivered until the current turn ends.
  """
  @spec process_ready_inputs_for_actor(actor_key(), keyword()) :: {:ok, map()} | {:error, term()}
  def process_ready_inputs_for_actor(actor_key, opts \\ []) do
    actor_key = normalize_actor_key(actor_key)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    actor_key.agent_uid
    |> Actors.list_ready_inputs(actor_key.session_id, now)
    |> select_ready_inputs_for_actor(actor_key)
    |> case do
      [] ->
        {:ok, %{status: :idle}}

      [%ActorInput{type: "command.new"} = input | _inputs] ->
        process_new_command(actor_key, input, opts)

      [%ActorInput{type: "session.reset_due"} = input | _inputs] ->
        process_session_reset_due(actor_key, input, opts)

      [%ActorInput{type: type} = input | _inputs]
      when type in ["signal.entry.deleted", "signal.entry.recalled"] ->
        process_entry_lifecycle(actor_key, input, opts)

      [%ActorInput{type: "command.compress"} = input | _inputs] ->
        process_compress_command(actor_key, input, opts)

      [%ActorInput{type: type} = input | _inputs]
      when type in ["command.stop", "command.retry"] ->
        process_runtime_command(actor_key, input, opts)

      [%ActorInput{type: "command.steer"} = input | _inputs] ->
        process_steer_command(actor_key, input, opts)

      inputs ->
        start_llm_turn(actor_key, inputs, opts)
    end
  end

  @doc """
  Runs one actor-runtime watchdog pass.
  """
  @spec watchdog_once(keyword()) :: {:ok, map()} | {:error, term()}
  def watchdog_once(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    stale_after_seconds = Keyword.get(opts, :stale_after_seconds, 60)
    stale_worker_ttl_seconds = Keyword.get(opts, :stale_worker_ttl_seconds, 3_600)
    lease_grace_seconds = Keyword.get(opts, :lease_grace_seconds, 0)

    Repo.transact(fn repo ->
      with {:ok, stale_workers} <-
             WorkerAdmission.mark_stale_workers(repo, now, stale_after_seconds),
           {:ok, expired_activations} <- fail_expired_activations(repo, now, lease_grace_seconds),
           {:ok, projection_lost_turns} <-
             reconcile_projection_lost_started_turns_in_tx(repo, now),
           {deleted_stale_workers, _rows} <-
             WorkerAdmission.delete_expired_stale_workers(repo, now, stale_worker_ttl_seconds) do
        {:ok,
         %{
           stale_workers: stale_workers,
           expired_activations: expired_activations,
           projection_lost_turns: projection_lost_turns,
           deleted_stale_workers: deleted_stale_workers
         }}
      end
    end)
  end

  defp ready_input_head([]), do: []
  defp ready_input_head([input | _rest]), do: [input]

  defp select_ready_inputs_for_actor([], _actor_key), do: ready_input_head([])

  defp select_ready_inputs_for_actor(inputs, actor_key) do
    case active_generation_for_actor?(actor_key) do
      true ->
        case active_control_input(inputs) do
          %ActorInput{} = input -> [input]
          nil -> ready_input_head(inputs)
        end

      false ->
        ready_input_head(inputs)
    end
  end

  defp active_control_input(inputs) do
    inputs
    |> Enum.take_while(&(not hard_queue_barrier?(&1)))
    |> Enum.find(&active_control_input?/1)
  end

  defp active_control_input?(%ActorInput{type: type}), do: type in @active_control_command_types
  defp active_control_input?(_input), do: false

  defp hard_queue_barrier?(%ActorInput{type: "session.reset_due"}), do: true
  defp hard_queue_barrier?(_input), do: false

  defp active_generation_for_actor?(actor_key) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^actor_key.agent_uid)
    |> where([conversation], conversation.conversation_key == ^actor_key.session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> select([conversation], conversation.generation)
    |> Repo.one()
    |> conversation_has_active_generation?()
  end

  # Sends the already persisted turn-start envelope after the transaction has
  # committed. A failed send invalidates the route and leaves delivery rows as
  # retryable runtime projections instead of rolling back the durable turn.
  defp send_turn_start(
         {:ok,
          %{assignment: assignment, envelope: envelope, deliveries: deliveries} =
            result}
       ) do
    route = assignment.transport_route || assignment.worker_id

    case Broker.send_mandatory(route, envelope) do
      {:ok, :sent_or_queued} ->
        Enum.each(deliveries, &mark_delivery_sent(&1.id, "sent_or_queued"))
        {:ok, Map.put(result, :send_outcome, "sent_or_queued")}

      {:error, reason} ->
        Enum.each(deliveries, &mark_delivery_failed(&1.id, reason, reason))
        WorkerAdmission.mark_route_unusable(route, reason)
        {:ok, Map.put(result, :send_outcome, Atom.to_string(reason))}
    end
  end

  defp send_turn_start({:error, _reason} = error), do: error

  defp daily_reset_boundary_at(%DateTime{} = now, opts) do
    with {:ok, timezone} <- daily_reset_timezone(opts),
         {:ok, reset_time} <- daily_reset_time(opts),
         {:ok, local_now} <- shift_zone(now, timezone),
         date <- daily_reset_date(local_now, reset_time),
         {:ok, local_boundary} <- datetime_in_timezone(date, reset_time, timezone),
         {:ok, boundary_at} <- DateTime.shift_zone(local_boundary, "Etc/UTC") do
      {:ok, boundary_at, timezone}
    end
  end

  defp daily_reset_timezone(opts) do
    case Keyword.fetch(opts, :timezone) do
      {:ok, timezone} when is_binary(timezone) ->
        {:ok, normalize_timezone(timezone)}

      {:ok, _timezone} ->
        {:error, :invalid_timezone}

      :error ->
        SystemConfig.timezone()
    end
  end

  defp normalize_timezone("UTC"), do: "Etc/UTC"
  defp normalize_timezone(timezone), do: timezone

  defp daily_reset_time(opts) do
    opts
    |> Keyword.get(:reset_time, @daily_reset_time)
    |> normalize_reset_time()
  end

  defp normalize_reset_time(%Time{} = time), do: {:ok, Time.truncate(time, :second)}
  defp normalize_reset_time({hour, minute}), do: Time.new(hour, minute, 0)
  defp normalize_reset_time({hour, minute, second}), do: Time.new(hour, minute, second)
  defp normalize_reset_time(_value), do: {:error, :invalid_reset_time}

  defp shift_zone(%DateTime{} = now, timezone) do
    case DateTime.shift_zone(now, timezone) do
      {:ok, local_now} -> {:ok, local_now}
      {:error, reason} -> {:error, {:invalid_timezone, timezone, reason}}
    end
  end

  defp daily_reset_date(%DateTime{} = local_now, %Time{} = reset_time) do
    date = DateTime.to_date(local_now)

    case Time.compare(DateTime.to_time(local_now), reset_time) do
      :lt -> Date.add(date, -1)
      _comparison -> date
    end
  end

  defp datetime_in_timezone(%Date{} = date, %Time{} = time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} -> {:ok, datetime}
      {:ambiguous, first_datetime, _second_datetime} -> {:ok, first_datetime}
      {:gap, _before_gap, after_gap} -> {:ok, after_gap}
      {:error, reason} -> {:error, {:invalid_timezone, timezone, reason}}
    end
  end

  defp due_daily_reset_conversations(repo, %DateTime{} = boundary_at, opts) do
    limit = Keyword.get(opts, :limit, 1_000)

    Conversation
    |> where([conversation], is_nil(conversation.ended_at))
    |> where([conversation], conversation.inserted_at < ^boundary_at)
    |> order_by([conversation], asc: conversation.agent_uid, asc: conversation.conversation_key)
    |> limit(^limit)
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.reject(&skip_daily_reset_conversation?(&1, opts))
  end

  defp skip_daily_reset_conversation?(%Conversation{} = conversation, opts) do
    Keyword.get(opts, :include_provider_owned_cli_sessions?, false) == false and
      provider_owned_cli_session?(conversation)
  end

  defp provider_owned_cli_session?(%Conversation{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "provider_owned_cli_session") do
      true -> true
      %{"active" => true} -> true
      %{"session_id" => session_id} when is_binary(session_id) and session_id != "" -> true
      _value -> false
    end
  end

  defp provider_owned_cli_session?(_conversation), do: false

  defp enqueue_session_reset_due_in_tx(
         repo,
         %Conversation{} = conversation,
         %DateTime{} = boundary_at,
         %DateTime{} = now,
         opts
       ) do
    timezone = Keyword.get(opts, :timezone, "Etc/UTC")
    binding_name = Keyword.get(opts, :binding_name, @session_lifecycle_binding_name)
    event_id = session_reset_due_event_id(conversation, boundary_at)

    Actors.append_actor_input_in_tx(repo, %{
      agent_uid: conversation.agent_uid,
      binding_name: binding_name,
      session_id: conversation.conversation_key,
      ingress_event_id: event_id,
      type: "session.reset_due",
      available_at: now,
      sender_key: nil,
      payload:
        session_reset_due_payload(
          conversation,
          event_id,
          boundary_at,
          timezone,
          now,
          binding_name
        )
    })
  end

  defp session_reset_due_event_id(%Conversation{} = conversation, %DateTime{} = boundary_at) do
    "session.reset_due:daily:" <>
      conversation.agent_uid <>
      ":" <>
      conversation.conversation_key <>
      ":" <>
      DateTime.to_iso8601(boundary_at)
  end

  defp session_reset_due_payload(
         %Conversation{} = conversation,
         event_id,
         %DateTime{} = boundary_at,
         timezone,
         %DateTime{} = now,
         binding_name
       ) do
    %{
      "specversion" => "1.0",
      "id" => event_id,
      "source" => "control-plane://session-reset/daily",
      "subject" => "sessions:#{conversation.conversation_key}",
      "time" => DateTime.to_iso8601(now),
      "type" => "session.reset_due",
      "data" => %{
        "session" => %{
          "agent_uid" => conversation.agent_uid,
          "session_id" => conversation.conversation_key,
          "binding_name" => binding_name
        },
        "reset" => %{
          "kind" => "daily",
          "boundary_at" => DateTime.to_iso8601(boundary_at),
          "timezone" => timezone,
          "local_time" => "04:30"
        }
      }
    }
  end

  defp send_mailbox_updated(
         %{
           assignment: assignment,
           delivery: delivery,
           input: input,
           turn_ref: turn_ref
         } = result
       ) do
    route = assignment.transport_route || assignment.worker_id
    envelope = TurnEnvelope.mailbox_updated(turn_ref, [input])

    case Broker.send_mandatory(route, envelope) do
      {:ok, :sent_or_queued} ->
        {:ok, Map.put(result, :send_outcome, "sent_or_queued")}

      {:error, reason} ->
        mark_delivery_failed(delivery.id, reason, reason)
        WorkerAdmission.mark_route_unusable(route, reason)
        {:ok, Map.put(result, :send_outcome, Atom.to_string(reason))}
    end
  end

  defp process_session_reset_due(actor_key, %ActorInput{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %ActorInput{} = input <- lock_actor_input(repo, input.id),
           false <- session_has_running_work?(repo, actor_key),
           {:ok, closed_conversation} <- close_current_session_for_reset(repo, actor_key, now),
           {:ok, conversation} <-
             ensure_successor_conversation(repo, actor_key, closed_conversation),
           {:ok, stale_inputs} <- discard_stale_system_inputs_after_reset(repo, actor_key, input),
           {:ok, consumption} <-
             Actors.consume_session_lifecycle_input_in_tx(repo, input,
               conversation_id: closed_conversation && closed_conversation.id,
               consumed_at: now
             ) do
        {:ok,
         %{
           status: :session_reset,
           reset_input: input,
           closed_conversation: closed_conversation,
           conversation: conversation,
           stale_system_inputs: stale_inputs,
           consumption: consumption
         }}
      else
        nil ->
          {:ok, %{status: :idle}}

        true ->
          {:ok, %{status: :waiting_for_generation, reason: :session_reset_due, input: input}}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp process_entry_lifecycle(actor_key, %ActorInput{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %ActorInput{} = input <- lock_actor_input(repo, input.id),
           {:ok, conversation} <-
             AIAgent.ensure_conversation_in_tx(repo, actor_key.agent_uid, actor_key.session_id),
           %Conversation{} = conversation <- AIAgent.lock_conversation(repo, conversation.id),
           {:ok, message} <- insert_entry_lifecycle_introspection(repo, conversation, input, now),
           {:ok, consumption} <-
             Actors.consume_entry_lifecycle_input_in_tx(repo, input,
               conversation_id: conversation.id,
               consumed_at: now
             ) do
        {:ok,
         %{
           status: :entry_lifecycle_recorded,
           lifecycle_input: input,
           conversation: conversation,
           message: message,
           consumption: consumption
         }}
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp session_has_running_work?(repo, actor_key) do
    active_generation?(repo, actor_key) or live_delivery_for_session?(repo, actor_key)
  end

  defp live_delivery_for_session?(repo, actor_key) do
    ActorInputDelivery
    |> where([delivery], delivery.agent_uid == ^actor_key.agent_uid)
    |> where([delivery], delivery.session_id == ^actor_key.session_id)
    |> where([delivery], delivery.state in ^@live_delivery_states)
    |> repo.exists?()
  end

  defp close_current_session_for_reset(repo, actor_key, now) do
    case active_conversation_for_update(repo, actor_key) do
      %Conversation{} = conversation ->
        lease_id = generation_lease_id(conversation.generation || %{})
        generation = cancel_generation(conversation.generation || %{}, now, "session.reset_due")

        with {:ok, conversation} <-
               conversation
               |> Conversation.changeset(%{generation: generation, ended_at: now})
               |> repo.update(),
             {:ok, _cancelled_turn} <-
               cancel_started_turn_for_lease(
                 repo,
                 conversation,
                 lease_id,
                 now,
                 "session.reset_due"
               ) do
          {:ok, conversation}
        end

      nil ->
        {:ok, nil}
    end
  end

  defp ensure_successor_conversation(_repo, _actor_key, nil), do: {:ok, nil}

  defp ensure_successor_conversation(repo, actor_key, %Conversation{}) do
    AIAgent.ensure_conversation_in_tx(repo, actor_key.agent_uid, actor_key.session_id)
  end

  defp discard_stale_system_inputs_after_reset(repo, actor_key, %ActorInput{} = reset_input) do
    stale_inputs =
      ActorInput
      |> where([input], input.agent_uid == ^actor_key.agent_uid)
      |> where([input], input.session_id == ^actor_key.session_id)
      |> where([input], input.input_state == "open")
      |> where([input], input.broker_sequence > ^reset_input.broker_sequence)
      |> order_by([input], asc: input.broker_sequence)
      |> lock("FOR UPDATE")
      |> repo.all()
      |> Enum.filter(&ActorInputTypes.stale_after_session_reset?/1)

    stale_input_ids = Enum.map(stale_inputs, & &1.id)

    with :ok <- delete_delivery_projections(repo, stale_input_ids),
         :ok <- delete_actor_inputs(repo, stale_input_ids) do
      {:ok, stale_inputs}
    end
  end

  defp delete_delivery_projections(_repo, []), do: :ok

  defp delete_delivery_projections(repo, actor_input_ids) do
    ActorInputDelivery
    |> where([delivery], delivery.actor_input_id in ^actor_input_ids)
    |> repo.delete_all()

    :ok
  end

  defp delete_actor_inputs(_repo, []), do: :ok

  defp delete_actor_inputs(repo, actor_input_ids) do
    ActorInput
    |> where([input], input.id in ^actor_input_ids)
    |> repo.delete_all()

    :ok
  end

  defp process_new_command(actor_key, %ActorInput{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case command_args(input) do
      "" ->
        process_runtime_command(actor_key, input, opts)

      _args ->
        with {:ok, _result} <-
               Repo.transact(fn repo ->
                 with :ok <- end_active_conversation(repo, actor_key, input, now) do
                   {:ok, %{status: :conversation_rolled_over}}
                 end
               end) do
          start_llm_turn(actor_key, [input], opts)
        end
    end
  end

  defp process_runtime_command(actor_key, %ActorInput{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %ActorInput{} = input <- lock_actor_input(repo, input.id),
           {:ok, result} <- apply_runtime_command(repo, actor_key, input, now) do
        {:ok, result}
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
    |> TurnRetry.dispatch_retry_controls()
    |> tap(fn
      {:ok, %{status: :command_consumed}} -> OutboxDispatcher.wake()
      _result -> :ok
    end)
  end

  defp process_compress_command(actor_key, %ActorInput{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %ActorInput{} = input <- lock_actor_input(repo, input.id),
           {:ok, result} <- prepare_compress_command(repo, actor_key, input, now) do
        {:ok, result}
      else
        nil -> {:ok, %{status: :idle}}
        {:error, _reason} = error -> error
      end
    end)
    |> case do
      {:ok, %{status: :start_compression}} ->
        start_llm_turn(
          actor_key,
          [input],
          Keyword.merge(opts,
            kind: "compression",
            profile: "light",
            input_messages: {:existing, []}
          )
        )

      {:ok, %{status: :command_consumed}} = result ->
        OutboxDispatcher.wake()
        result

      other ->
        other
    end
  end

  defp apply_runtime_command(repo, actor_key, %ActorInput{type: "command.stop"} = input, now) do
    with :ok <- cancel_active_generation(repo, actor_key, input, now, "command.stop") do
      consume_command_feedback(repo, input, "Stopped.", now)
    end
  end

  defp apply_runtime_command(repo, actor_key, %ActorInput{type: "command.new"} = input, now) do
    with :ok <- end_active_conversation(repo, actor_key, input, now) do
      consume_command_feedback(repo, input, "Started a new conversation.", now)
    end
  end

  defp apply_runtime_command(repo, actor_key, %ActorInput{type: "command.retry"} = input, now) do
    case TurnRetry.retry_active_generation_in_tx(repo, actor_key, input, now) do
      {:ok, :no_active_generation} ->
        with {:ok, retry_input} <- append_retry_input(repo, actor_key, input, now),
             {:ok, consumption} <- consume_command_without_feedback(repo, input, now) do
          {:ok,
           %{
             status: :command_consumed,
             command: input.type,
             retry_actor_input: retry_input,
             consumption: consumption
           }}
        end

      {:ok, %{status: :command_consumed} = result} ->
        {:ok, result}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_runtime_command(repo, _actor_key, %ActorInput{type: "command.steer"} = input, now) do
    consume_command_feedback(repo, input, "Steer requires instructions.", now)
  end

  defp prepare_compress_command(repo, actor_key, %ActorInput{} = input, now) do
    cond do
      active_generation?(repo, actor_key) ->
        consume_command_feedback(
          repo,
          input,
          "A response is still running; stop it before compressing.",
          now
        )

      true ->
        prepare_idle_compression(repo, actor_key, input, now)
    end
  end

  defp process_steer_command(actor_key, %ActorInput{} = input, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    case command_args(input) do
      "" ->
        process_runtime_command(actor_key, input, opts)

      _args ->
        Repo.transact(fn repo ->
          with %ActorInput{} = input <- lock_actor_input(repo, input.id) do
            case active_generation?(repo, actor_key) do
              true ->
                prepare_active_steer(repo, actor_key, input, now)

              false ->
                {:ok, %{status: :steer_as_generation}}
            end
          else
            nil -> {:ok, %{status: :idle}}
            {:error, _reason} = error -> error
          end
        end)
        |> case do
          {:ok, %{status: :steer_as_generation}} ->
            start_llm_turn(actor_key, [input], opts)

          {:ok, %{status: :active_steer_nudged} = result} ->
            send_mailbox_updated(result)

          other ->
            other
        end
    end
  end

  defp prepare_active_steer(repo, actor_key, %ActorInput{} = input, now) do
    case live_delivery_for_input?(repo, input.id) do
      true ->
        {:ok, %{status: :waiting_for_generation, command: input.type}}

      false ->
        with %Conversation{} = conversation <- active_conversation_for_update(repo, actor_key),
             true <- conversation_has_active_generation?(conversation),
             %ActorSessionActivation{} = activation <- live_activation(repo, actor_key),
             true <- activation_lease_alive?(activation, now),
             %LlmTurn{} = llm_turn <- AIAgent.lock_turn(repo, activation.current_llm_turn_id),
             %ActorSessionWorkerAssignment{} = assignment <- live_assignment(repo, actor_key),
             {:ok, activation} <- bump_activation_revision(repo, activation, now),
             {:ok, _message} <-
               insert_command_introspection(
                 repo,
                 conversation,
                 input,
                 now,
                 "Steering note received: #{command_args(input)}"
               ),
             {:ok, delivery} <-
               create_input_delivery_in_tx(
                 repo,
                 input,
                 activation,
                 llm_turn,
                 assignment.transport_route || assignment.worker_id,
                 assignment,
                 now
               ),
             {:ok, delivery} <- mark_delivery_sent_in_tx(repo, delivery, now, "sent_or_queued") do
          {:ok,
           %{
             status: :active_steer_nudged,
             command: input.type,
             activation: activation,
             assignment: assignment,
             delivery: delivery,
             input: input,
             turn_ref: TurnEnvelope.turn_ref(repo, actor_key, activation, llm_turn)
           }}
        else
          false -> {:ok, %{status: :waiting_for_generation, command: input.type}}
          nil -> {:error, :active_turn_not_found}
          {:error, _reason} = error -> error
        end
    end
  end

  defp consume_command_feedback(repo, %ActorInput{} = input, text, now) do
    outbox_intents = command_feedback_outbox_intents(repo, input, text)

    with {:ok, consumption} <-
           Actors.consume_command_input_in_tx(repo, input,
             consumed_at: now,
             outbox_intents: outbox_intents
           ) do
      {:ok,
       %{
         status: :command_consumed,
         command: input.type,
         feedback: text,
         consumption: consumption
       }}
    end
  end

  defp consume_command_without_feedback(repo, %ActorInput{} = input, now) do
    Actors.consume_command_input_in_tx(repo, input,
      consumed_at: now,
      outbox_intents: []
    )
  end

  defp command_feedback_outbox_intents(_repo, %ActorInput{signal_channel_id: nil}, _text), do: []
  defp command_feedback_outbox_intents(_repo, %ActorInput{provider_entry_id: nil}, _text), do: []

  defp command_feedback_outbox_intents(repo, %ActorInput{} = input, text) do
    operation = SignalsGateway.outbox_operation_for_actor_input(input, repo)
    command_name = String.replace_prefix(input.type, "command.", "")

    [
      %{
        outbound_key: "command:#{input.id}:#{command_name}",
        operation: operation,
        target_provider_entry_id: input.provider_entry_id,
        provider_thread_id: input.provider_thread_id,
        payload: %{"text" => text},
        fallback_visible_text: text,
        idempotency_key: "command:#{input.id}:#{command_name}"
      }
    ]
  end

  defp append_retry_input(repo, actor_key, %ActorInput{} = command_input, now) do
    with %Conversation{} = conversation <- active_conversation_for_update(repo, actor_key),
         {:ok, retry_source} <- retry_source(repo, conversation) do
      Actors.append_actor_input_in_tx(repo, %{
        agent_uid: command_input.agent_uid,
        binding_name: command_input.binding_name,
        session_id: command_input.session_id,
        ingress_event_id: "retry:#{command_input.id}",
        signal_channel_id: command_input.signal_channel_id,
        provider_thread_id: command_input.provider_thread_id,
        provider_entry_id: command_input.provider_entry_id,
        type: "im.message.receive",
        available_at: now,
        sender_key: command_input.sender_key,
        payload: %{
          "type" => "im.message.receive",
          "data" => %{
            "entry" => %{
              "text" => retry_source.text,
              "retry_of_llm_turn_id" => retry_source.llm_turn_id,
              "retry_of_message_id" => retry_source.message_id
            }
          }
        }
      })
    else
      nil -> {:error, :conversation_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp retry_source(repo, %Conversation{} = conversation) do
    last_turn =
      LlmTurn
      |> where([turn], turn.conversation_id == ^conversation.id)
      |> where([turn], turn.kind in ["generation", "retry_generation"])
      |> where([turn], turn.status in ["succeeded", "failed", "cancelled"])
      |> order_by([turn], desc: turn.started_at, desc: turn.inserted_at)
      |> repo.one()

    case last_turn do
      %LlmTurn{input_message_ids: [message_id | _]} = turn ->
        case repo.get(Message, message_id) do
          %Message{} = message ->
            {:ok,
             %{
               llm_turn_id: turn.id,
               message_id: message.id,
               text: message_text(message)
             }}

          nil ->
            {:error, :retry_source_message_not_found}
        end

      %LlmTurn{} ->
        {:error, :retry_source_message_not_found}

      nil ->
        {:error, :retry_source_not_found}
    end
  end

  defp prepare_idle_compression(repo, actor_key, %ActorInput{} = input, now) do
    case active_conversation_for_update(repo, actor_key) do
      %Conversation{} ->
        {:ok, %{status: :start_compression}}

      nil ->
        consume_command_feedback(
          repo,
          input,
          "Conversation already fits in the active context.",
          now
        )
    end
  end

  defp message_text(%Message{content: content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _part -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp message_text(_message), do: ""

  defp cancel_active_generation(repo, actor_key, %ActorInput{} = input, now, reason) do
    case active_conversation_for_update(repo, actor_key) do
      %Conversation{} = conversation ->
        lease_id = generation_lease_id(conversation.generation || %{})
        generation = cancel_generation(conversation.generation || %{}, now, reason)

        with {:ok, conversation} <-
               conversation
               |> Conversation.changeset(%{generation: generation})
               |> repo.update(),
             {:ok, _cancelled_turn} <-
               cancel_started_turn_for_lease(repo, conversation, lease_id, now, reason),
             {:ok, _message} <-
               insert_command_introspection(repo, conversation, input, now, "Generation stopped.") do
          :ok
        end

      nil ->
        :ok
    end
  end

  defp end_active_conversation(repo, actor_key, %ActorInput{} = input, now) do
    case active_conversation_for_update(repo, actor_key) do
      %Conversation{} = conversation ->
        lease_id = generation_lease_id(conversation.generation || %{})
        generation = cancel_generation(conversation.generation || %{}, now, "command.new")

        with {:ok, conversation} <-
               conversation
               |> Conversation.changeset(%{generation: generation, ended_at: now})
               |> repo.update(),
             {:ok, _cancelled_turn} <-
               cancel_started_turn_for_lease(repo, conversation, lease_id, now, "command.new"),
             {:ok, _message} <-
               insert_command_introspection(
                 repo,
                 conversation,
                 input,
                 now,
                 "Conversation window closed."
               ) do
          :ok
        end

      nil ->
        :ok
    end
  end

  defp active_generation?(repo, actor_key) do
    case active_conversation_for_update(repo, actor_key) do
      %Conversation{generation: generation} when is_map(generation) ->
        conversation_has_active_generation?(generation)

      _conversation ->
        false
    end
  end

  defp conversation_has_active_generation?(%Conversation{generation: generation})
       when is_map(generation),
       do: conversation_has_active_generation?(generation)

  defp conversation_has_active_generation?(generation) when is_map(generation),
    do: is_binary(generation["lease_id"]) and is_nil(generation["cancelled_at"])

  defp conversation_has_active_generation?(_generation), do: false

  defp active_conversation_for_update(repo, actor_key) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^actor_key.agent_uid)
    |> where([conversation], conversation.conversation_key == ^actor_key.session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp live_assignment(repo, actor_key) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^actor_key.agent_uid)
    |> where([assignment], assignment.session_id == ^actor_key.session_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp live_delivery_for_input?(repo, actor_input_id) do
    ActorInputDelivery
    |> where([delivery], delivery.actor_input_id == ^actor_input_id)
    |> where([delivery], delivery.state in ^@live_delivery_states)
    |> repo.exists?()
  end

  defp bump_activation_revision(repo, %ActorSessionActivation{} = activation, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      revision: activation.revision + 1,
      last_actor_heartbeat_at: now
    })
    |> repo.update()
  end

  defp mark_delivery_sent_in_tx(repo, %ActorInputDelivery{} = delivery, now, send_outcome) do
    delivery
    |> ActorInputDelivery.changeset(%{
      state: "sent",
      send_outcome: send_outcome,
      sent_at: now
    })
    |> repo.update()
  end

  defp cancel_generation(generation, now, reason) when is_map(generation) do
    case blank?(generation["lease_id"]) do
      true ->
        generation

      false ->
        generation
        |> Map.put("cancelled_at", DateTime.to_iso8601(now))
        |> Map.put("cancel_reason", reason)
    end
  end

  defp generation_lease_id(generation) when is_map(generation) do
    case generation["lease_id"] do
      lease_id when is_binary(lease_id) and lease_id != "" -> lease_id
      _value -> nil
    end
  end

  defp cancel_started_turn_for_lease(_repo, _conversation, nil, _now, _reason), do: {:ok, nil}

  defp cancel_started_turn_for_lease(repo, %Conversation{} = conversation, lease_id, now, reason) do
    case started_turn_for_lease(repo, conversation, lease_id) do
      %LlmTurn{} = turn ->
        with {:ok, cancelled_turn} <- AIAgent.cancel_turn_in_tx(repo, turn, reason, now),
             {_count, _rows} <- supersede_turn_deliveries_by_id(turn.id, repo, now, reason) do
          {:ok, cancelled_turn}
        end

      nil ->
        {:ok, nil}
    end
  end

  defp insert_entry_lifecycle_introspection(
         repo,
         %Conversation{} = conversation,
         %ActorInput{} = input,
         now
       ) do
    lifecycle_kind = entry_lifecycle_kind(input)

    %Message{}
    |> Message.changeset(%{
      agent_uid: conversation.agent_uid,
      conversation_id: conversation.id,
      role: "user",
      kind: "introspection",
      status: "complete",
      content: [%{"type" => "text", "text" => entry_lifecycle_note(input, lifecycle_kind)}],
      event_source: "signals_gateway:#{input.binding_name}",
      event_id: input.ingress_event_id,
      metadata: entry_lifecycle_metadata(input, lifecycle_kind, now)
    })
    |> repo.insert()
  end

  defp entry_lifecycle_kind(%ActorInput{type: "signal.entry.deleted"}), do: "deleted"
  defp entry_lifecycle_kind(%ActorInput{type: "signal.entry.recalled"}), do: "recalled"

  defp entry_lifecycle_note(%ActorInput{} = input, lifecycle_kind) do
    "The provider reported that a previously visible user entry was #{lifecycle_kind}. " <>
      "Preserve the existing conversation history; use this only as lifecycle context for future reasoning. " <>
      "provider_entry_id=#{input.provider_entry_id || "unknown"}; signal_channel_id=#{input.signal_channel_id || "unknown"}."
  end

  defp entry_lifecycle_metadata(%ActorInput{} = input, lifecycle_kind, now) do
    %{
      "actor_input_id" => input.id,
      "actor_input_type" => input.type,
      "binding_name" => input.binding_name,
      "session_id" => input.session_id,
      "signal_channel_id" => input.signal_channel_id,
      "provider_thread_id" => input.provider_thread_id,
      "provider_entry_id" => input.provider_entry_id,
      "provider_refs" =>
        reject_nil_values(%{
          "event_id" => input.ingress_event_id,
          "provider_message_id" => input.provider_entry_id,
          "room_id" => input.signal_channel_id,
          "thread_id" => input.provider_thread_id || input.signal_channel_id
        }),
      "lifecycle" => %{
        "kind" => lifecycle_kind,
        "source" => "signals_gateway",
        "inserted_at" => DateTime.to_iso8601(now)
      }
    }
    |> reject_nil_values()
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp insert_command_introspection(
         repo,
         %Conversation{} = conversation,
         %ActorInput{} = input,
         now,
         text
       ) do
    %Message{}
    |> Message.changeset(%{
      agent_uid: conversation.agent_uid,
      conversation_id: conversation.id,
      role: "assistant",
      kind: "introspection",
      status: "complete",
      content: [%{"type" => "text", "text" => text}],
      event_source: "ai_agent.#{input.type}",
      event_id: input.ingress_event_id,
      metadata: %{
        "actor_input_id" => input.id,
        "command" => input.type,
        "command_args" => command_args(input),
        "inserted_at" => DateTime.to_iso8601(now)
      }
    })
    |> repo.insert()
  end

  defp command_args(%ActorInput{payload: payload}) when is_map(payload) do
    payload
    |> get_in(["data", "command", "argsText"])
    |> case do
      value when is_binary(value) -> String.trim(value)
      _value -> ""
    end
  end

  defp command_args(_input), do: ""

  # Reuses a live activation when its lease is valid, otherwise fails the old
  # activation before creating a new actor epoch. The epoch is the cheap fence
  # that makes late worker replies harmless.
  defp ensure_activation(repo, actor_key, assignment, now, opts) do
    case live_activation(repo, actor_key) do
      %ActorSessionActivation{} = activation ->
        case activation_lease_alive?(activation, now) do
          true ->
            refresh_activation_assignment(repo, activation, assignment, now)

          false ->
            with {:ok, _activation} <- fail_expired_activation(repo, activation, now) do
              insert_activation(repo, actor_key, assignment, now, opts)
            end
        end

      nil ->
        insert_activation(repo, actor_key, assignment, now, opts)
    end
  end

  defp activation_lease_alive?(%ActorSessionActivation{lease_expires_at: lease_expires_at}, now) do
    DateTime.compare(lease_expires_at, now) == :gt
  end

  defp activation_accepts_progress(
         %ActorSessionActivation{} = activation,
         turn_ref,
         %LlmTurn{} = llm_turn,
         now
       ) do
    cond do
      activation.status not in @live_activation_statuses ->
        {:error, :activation_not_live}

      not activation_lease_alive?(activation, now) ->
        {:error, :activation_lease_expired}

      activation.agent_uid != fetch_actor_agent_uid(turn_ref) ->
        {:error, :stale_actor_key}

      activation.session_id != fetch_actor_session_id(turn_ref) ->
        {:error, :stale_actor_key}

      activation.activation_uid != fetch_text!(turn_ref, "activation_uid") ->
        {:error, :stale_activation_uid}

      activation.actor_epoch != fetch_int!(turn_ref, "actor_epoch") ->
        {:error, :stale_actor_epoch}

      activation.revision != fetch_int!(turn_ref, "revision") ->
        {:error, :stale_revision}

      activation.current_llm_turn_id != llm_turn.id ->
        {:error, :stale_llm_turn}

      llm_turn.status != "started" ->
        {:error, :llm_turn_not_started}

      true ->
        :ok
    end
  end

  defp renew_activation_lease(repo, activation, now, lease_seconds) do
    next_lease_expires_at = DateTime.add(now, lease_seconds, :second)

    activation
    |> ActorSessionActivation.changeset(%{
      lease_expires_at: later_datetime(activation.lease_expires_at, next_lease_expires_at),
      last_actor_heartbeat_at: now
    })
    |> repo.update()
  end

  defp later_datetime(left, right) do
    case DateTime.compare(left, right) do
      :gt -> left
      _comparison -> right
    end
  end

  # Creates the control-plane projection that binds one actor session to a
  # worker route. The worker itself is homogeneous, so there is no feature
  # negotiation here.
  defp insert_activation(repo, actor_key, assignment, now, opts) do
    lease_seconds = Keyword.get(opts, :lease_seconds, 300)
    actor_epoch = next_actor_epoch(repo, actor_key)

    %ActorSessionActivation{}
    |> ActorSessionActivation.changeset(%{
      activation_uid: "activation-" <> Ecto.UUID.generate(),
      agent_uid: actor_key.agent_uid,
      session_id: actor_key.session_id,
      actor_epoch: actor_epoch,
      status: "starting",
      controller_node: Atom.to_string(Node.self()),
      lease_id: "activation-lease-" <> Ecto.UUID.generate(),
      lease_expires_at: DateTime.add(now, lease_seconds, :second),
      assigned_worker_id: assignment.worker_id,
      revision: 0,
      started_at: now,
      metadata: %{}
    })
    |> repo.insert()
  end

  # Keeps a live activation attached to the current worker assignment without
  # changing the actor epoch. Reassignment only needs a new epoch after a lease
  # failure, not after every scheduling pass.
  defp refresh_activation_assignment(repo, activation, assignment, now) do
    case activation.assigned_worker_id == assignment.worker_id do
      true ->
        {:ok, activation}

      false ->
        activation
        |> ActorSessionActivation.changeset(%{
          assigned_worker_id: assignment.worker_id,
          last_actor_heartbeat_at: now
        })
        |> repo.update()
    end
  end

  # Marks the activation as the owner of the started LLM turn so later worker
  # replies can be checked against a single durable fence.
  defp bind_activation_turn(repo, activation, llm_turn_id, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      status: "active",
      current_llm_turn_id: llm_turn_id,
      last_actor_heartbeat_at: now
    })
    |> repo.update()
  end

  # Creates one delivery projection per actor input while sharing a message and
  # correlation id for the batch. The worker receives one `turn_start`, but the
  # control plane still tracks each input independently for retry and cleanup.
  defp create_input_deliveries_in_tx(repo, actor_inputs, activation, llm_turn, assignment, now) do
    batch = %{
      delivery_batch_id: Ecto.UUID.generate(),
      actor_lane_message_id: "turn-start-" <> Ecto.UUID.generate()
    }

    actor_inputs
    |> Enum.map(fn actor_input ->
      create_input_delivery_in_tx(
        repo,
        actor_input,
        activation,
        llm_turn,
        assignment.transport_route || assignment.worker_id,
        assignment,
        now,
        batch
      )
    end)
    |> collect_results()
  end

  # Records a concrete attempt to deliver an actor input to a worker turn. Older
  # failed/superseded rows for the same input are compacted after the new fence
  # exists so watchdog scans do not see a gap.
  defp create_input_delivery_in_tx(
         repo,
         actor_input,
         activation,
         llm_turn,
         route,
         assignment,
         now,
         batch \\ nil
       ) do
    attempt_no = next_attempt_no(repo, actor_input.id)

    batch =
      batch ||
        %{
          delivery_batch_id: Ecto.UUID.generate(),
          actor_lane_message_id: "turn-start-" <> Ecto.UUID.generate()
        }

    attrs = %{
      actor_input_id: actor_input.id,
      agent_uid: actor_input.agent_uid,
      session_id: actor_input.session_id,
      broker_sequence: actor_input.broker_sequence,
      attempt_no: attempt_no,
      delivery_batch_id: batch.delivery_batch_id,
      actor_lane_message_id: batch.actor_lane_message_id,
      correlation_id: batch.actor_lane_message_id,
      activation_uid: activation.activation_uid,
      actor_epoch: activation.actor_epoch,
      llm_turn_id: llm_turn.id,
      revision: activation.revision,
      worker_id: Map.get(assignment, :worker_id),
      transport_route: route,
      state: "created",
      error: %{},
      inserted_at: now,
      updated_at: now
    }

    %ActorInputDelivery{}
    |> ActorInputDelivery.changeset(attrs)
    |> repo.insert()
    |> case do
      {:ok, delivery} ->
        delete_stale_delivery_projections(repo, actor_input.id, delivery.id)
        {:ok, delivery}

      {:error, _reason} = error ->
        error
    end
  end

  # Bridges the AI-agent lease model with the actor delivery model. If a prior
  # turn exists but lost its delivery projection before send, the runtime can
  # reuse it instead of creating a duplicate user-visible turn.
  defp start_or_reuse_llm_turn_in_tx(repo, conversation, actor_inputs, opts) do
    case AIAgent.start_llm_turn_in_tx(repo, conversation, actor_inputs, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, :active_turn_exists} ->
        reuse_started_turn_in_tx(repo, conversation)

      {:error, _reason} = error ->
        error
    end
  end

  # Reuses only a started turn that has no live delivery. A live delivery means
  # a worker may still be acting on the turn, so a second send would create two
  # workers for one user-visible response.
  defp reuse_started_turn_in_tx(repo, %Conversation{generation: generation} = conversation)
       when is_map(generation) do
    lease_id = generation["lease_id"]

    with lease_id when is_binary(lease_id) and lease_id != "" <- lease_id,
         %LlmTurn{} = llm_turn <- started_turn_for_lease(repo, conversation, lease_id),
         false <- turn_has_live_delivery?(repo, llm_turn.id),
         user_messages <- messages_for_turn(repo, llm_turn) do
      {:ok,
       %{
         conversation: conversation,
         user_messages: user_messages,
         llm_turn: llm_turn,
         lease_id: lease_id
       }}
    else
      true -> {:error, :active_turn_exists}
      nil -> {:error, :active_turn_exists}
      _value -> {:error, :active_turn_exists}
    end
  end

  defp reuse_started_turn_in_tx(_repo, _conversation), do: {:error, :active_turn_exists}

  defp started_turn_for_lease(repo, conversation, lease_id) do
    LlmTurn
    |> where([turn], turn.conversation_id == ^conversation.id)
    |> where([turn], turn.lease_id == ^lease_id)
    |> where([turn], turn.status == "started")
    |> order_by([turn], asc: turn.call_index)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp turn_has_live_delivery?(repo, llm_turn_id) do
    ActorInputDelivery
    |> where([delivery], delivery.llm_turn_id == ^llm_turn_id)
    |> where([delivery], delivery.state in ^@live_delivery_states)
    |> repo.exists?()
  end

  defp messages_for_turn(repo, %LlmTurn{input_message_ids: ids}) when is_list(ids) do
    Message
    |> where([message], message.id in ^ids)
    |> order_by([message], asc: message.inserted_at)
    |> repo.all()
  end

  defp messages_for_turn(_repo, _llm_turn), do: []

  # Locks the live activation for this actor key so activation reuse, expiry,
  # and replacement stay serialized.
  defp live_activation(repo, actor_key) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^actor_key.agent_uid)
    |> where([activation], activation.session_id == ^actor_key.session_id)
    |> where([activation], activation.status in ["starting", "active", "draining"])
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  # Resolves the activation named by a worker turn reference. The turn_ref is
  # trusted only after matching the locked row, not because it came from a route.
  defp activation_for_turn_ref(repo, turn_ref) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^fetch_actor_agent_uid(turn_ref))
    |> where([activation], activation.session_id == ^fetch_actor_session_id(turn_ref))
    |> where([activation], activation.activation_uid == ^fetch_text!(turn_ref, "activation_uid"))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp next_actor_epoch(repo, actor_key) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^actor_key.agent_uid)
    |> where([activation], activation.session_id == ^actor_key.session_id)
    |> select([activation], coalesce(max(activation.actor_epoch), 0) + 1)
    |> repo.one()
  end

  defp next_attempt_no(repo, actor_input_id) do
    ActorInputDelivery
    |> where([delivery], delivery.actor_input_id == ^actor_input_id)
    |> select([delivery], coalesce(max(delivery.attempt_no), 0) + 1)
    |> repo.one()
  end

  # Deletes old terminal projections for one input after a new attempt exists.
  # This keeps the table small without deleting live evidence needed by fences.
  defp delete_stale_delivery_projections(repo, actor_input_id, current_delivery_id) do
    ActorInputDelivery
    |> where([delivery], delivery.actor_input_id == ^actor_input_id)
    |> where([delivery], delivery.id != ^current_delivery_id)
    |> where([delivery], delivery.state in ["send_failed", "superseded"])
    |> repo.delete_all()
  end

  defp lock_actor_input(repo, actor_input_id) do
    ActorInput
    |> where([input], input.id == ^actor_input_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_delivery(repo, delivery_id) do
    ActorInputDelivery
    |> where([delivery], delivery.id == ^delivery_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  # Converts expired activation leases into explicit failures. The grace window
  # is an operator tradeoff: tests can set it to zero, while production can allow
  # small clock or scheduling delays before retrying a turn.
  defp fail_expired_activations(repo, now, lease_grace_seconds) do
    cutoff = DateTime.add(now, -lease_grace_seconds, :second)

    activations =
      ActorSessionActivation
      |> where([activation], activation.status in ^@live_activation_statuses)
      |> where([activation], activation.lease_expires_at <= ^cutoff)
      |> lock("FOR UPDATE")
      |> repo.all()

    activations
    |> Enum.map(&fail_expired_activation(repo, &1, now))
    |> collect_results()
    |> case do
      {:ok, activations} -> {:ok, length(activations)}
      {:error, _reason} = error -> error
    end
  end

  # Fails an activation that never reached a current turn. There is no LLM turn
  # lease to clear, so only the activation projection is stopped.
  defp fail_expired_activation(
         repo,
         %ActorSessionActivation{current_llm_turn_id: nil} = activation,
         now
       ) do
    fail_activation(repo, activation, :activation_lease_expired, now)
  end

  # Fails an activation with a current turn and clears all related live fences.
  # This lets the same open actor input be selected again on the next pass.
  defp fail_expired_activation(repo, %ActorSessionActivation{} = activation, now) do
    case AIAgent.lock_turn(repo, activation.current_llm_turn_id) do
      %LlmTurn{status: "started"} = turn ->
        with %Conversation{} = conversation <-
               AIAgent.lock_conversation(repo, turn.conversation_id),
             {:ok, failed_turn} <-
               AIAgent.fail_turn_in_tx(repo, turn, :activation_lease_expired, now),
             {:ok, _conversation} <-
               AIAgent.clear_generation_in_tx(repo, conversation, failed_turn.lease_id),
             {_count, _rows} <-
               supersede_turn_deliveries_by_id(turn.id, repo, now, :activation_lease_expired) do
          fail_activation(repo, activation, :activation_lease_expired, now)
        else
          nil -> {:error, :conversation_not_found}
          {:error, _reason} = error -> error
        end

      %LlmTurn{} ->
        fail_activation(repo, activation, :activation_lease_expired, now)

      nil ->
        fail_activation(repo, activation, :activation_lease_expired, now)
    end
  end

  defp fail_activation(repo, %ActorSessionActivation{} = activation, reason, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      status: "failed",
      current_llm_turn_id: nil,
      stopped_at: now,
      stop_reason: inspect(reason)
    })
    |> repo.update()
  end

  # Repairs the only intentionally weak guarantee in this path: AI-agent turns
  # are durable, while actor-runtime projections are retry-oriented. A started
  # turn without activation and delivery fences is failed so the user story can
  # retry from the actor input instead of waiting forever.
  defp reconcile_projection_lost_started_turns_in_tx(repo, now) do
    started_turns =
      LlmTurn
      |> where([turn], turn.status == "started")
      |> lock("FOR UPDATE")
      |> repo.all()

    started_turns
    |> Enum.reduce_while({:ok, 0}, fn turn, {:ok, count} ->
      case live_projection_exists?(repo, turn) do
        true ->
          {:cont, {:ok, count}}

        false ->
          with %Conversation{} = conversation <-
                 AIAgent.lock_conversation(repo, turn.conversation_id),
               {:ok, failed_turn} <-
                 AIAgent.fail_turn_in_tx(repo, turn, :actor_runtime_projection_lost, now),
               {:ok, _conversation} <-
                 AIAgent.clear_generation_in_tx(repo, conversation, failed_turn.lease_id),
               {_count, _rows} <-
                 supersede_turn_deliveries_by_id(
                   failed_turn.id,
                   repo,
                   now,
                   :actor_runtime_projection_lost
                 ) do
            {:cont, {:ok, count + 1}}
          else
            nil -> {:halt, {:error, :conversation_not_found}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
  end

  # Marks live delivery projections obsolete without deleting them. Keeping the
  # row records why a worker reply should no longer be accepted.
  defp supersede_turn_deliveries_by_id(llm_turn_id, repo, now, reason) do
    ActorInputDelivery
    |> where([delivery], delivery.llm_turn_id == ^llm_turn_id)
    |> where([delivery], delivery.state in ^@live_delivery_states)
    |> repo.update_all(
      set: [
        state: "superseded",
        superseded_at: now,
        error: %{"reason" => inspect(reason)},
        updated_at: now
      ]
    )
  end

  # Treats a started turn as runnable only when both sides of the runtime fence
  # exist: the activation names the turn, and at least one delivery names it.
  defp live_projection_exists?(repo, %LlmTurn{id: llm_turn_id}) do
    activation_exists =
      ActorSessionActivation
      |> where([activation], activation.current_llm_turn_id == ^llm_turn_id)
      |> repo.exists?()

    delivery_exists =
      ActorInputDelivery
      |> where([delivery], delivery.llm_turn_id == ^llm_turn_id)
      |> where([delivery], delivery.state in ^@live_delivery_states)
      |> repo.exists?()

    activation_exists and delivery_exists
  end

  # Requires the worker to accept exactly the sent input set. Partial acceptance
  # would make the durable transcript and actor-input consumption disagree.
  defp require_all_sent_inputs_accepted([], _accepted_ids), do: {:error, :sent_delivery_not_found}

  defp require_all_sent_inputs_accepted(deliveries, accepted_ids) do
    delivered_ids = deliveries |> Enum.map(& &1.actor_input_id) |> MapSet.new()

    case delivered_ids == MapSet.new(accepted_ids) do
      true -> :ok
      false -> {:error, :accepted_delivery_mismatch}
    end
  end

  # Checks every accepted delivery against the same turn fence before commit.
  defp validate_deliveries_turn_ref(deliveries, turn_ref) do
    Enum.reduce_while(deliveries, :ok, fn
      delivery, :ok ->
        case delivery_matches_turn_ref(delivery, turn_ref) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      _delivery, {:error, _reason} = error ->
        {:halt, error}
    end)
  end

  # Rejects late replies from an old activation, old actor epoch, or old turn.
  # The route alone is not a durable identity, because workers reconnect.
  defp delivery_matches_turn_ref(%ActorInputDelivery{} = delivery, turn_ref) do
    cond do
      delivery.agent_uid != fetch_actor_agent_uid(turn_ref) ->
        {:error, :stale_actor_key}

      delivery.session_id != fetch_actor_session_id(turn_ref) ->
        {:error, :stale_actor_key}

      delivery.activation_uid != fetch_text!(turn_ref, "activation_uid") ->
        {:error, :stale_activation_uid}

      delivery.actor_epoch != fetch_int!(turn_ref, "actor_epoch") ->
        {:error, :stale_actor_epoch}

      delivery.llm_turn_id != fetch_turn_id(turn_ref) ->
        {:error, :stale_llm_turn_id}

      # Acceptance demands an exact revision match (strict `!=`), unlike the
      # commit path which tolerates a newer delivery revision. Acceptance happens
      # right after send, before any steer can bump the revision, so the worker
      # must echo exactly what it was sent.
      delivery.revision != fetch_int!(turn_ref, "revision") ->
        {:error, :stale_revision}

      true ->
        :ok
    end
  end

  defp unwrap_body(%{"body" => %{"type" => type} = body}, type), do: fetch_map!(body, type)
  defp unwrap_body(%{body: %{"type" => type} = body}, type), do: fetch_map!(body, type)
  defp unwrap_body(%{body: %{type: type} = body}, type), do: fetch_map!(body, type)

  defp unwrap_body(%{} = map, type),
    do: fetch_map(map, type) || fetch_map(map, String.to_atom(type)) || map

  defp normalize_actor_key(%{agent_uid: agent_uid, session_id: session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  defp normalize_actor_key(%{"agent_uid" => agent_uid, "session_id" => session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  # agent_uid is case-insensitive identity. Both stored rows and incoming
  # turn_refs are downcased so fence equality checks never fail on letter case.
  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp fetch_actor_agent_uid(turn_ref),
    do: turn_ref |> fetch_map!("actor") |> fetch_text!("agent_uid") |> normalize_uid()

  defp fetch_actor_session_id(turn_ref),
    do: turn_ref |> fetch_map!("actor") |> fetch_text!("session_id")

  defp fetch_turn_id(turn_ref), do: fetch_text!(turn_ref, "llm_turn_id")

  defp fetch_text!(map, key) do
    case fetch_text(map, key) do
      value when is_binary(value) and value != "" -> value
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  # Reads a field whether the turn_ref arrived JSON-decoded (string keys, the
  # common transport case) or as an internal atom-keyed map (tests, recovery).
  # `String.to_atom/1` is safe here only because every `key` is a hardcoded
  # literal, never untrusted input, so the atom table stays bounded.
  defp fetch_text(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp fetch_map!(map, key) do
    case fetch_map(map, key) do
      %{} = value -> value
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  defp fetch_map(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key)

  defp fetch_map(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp fetch_list(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp fetch_int!(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _value -> raise ArgumentError, "missing #{key}"
    end
  end

  defp normalize_outcome(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_outcome(value), do: value

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
