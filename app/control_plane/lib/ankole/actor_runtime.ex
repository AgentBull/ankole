defmodule Ankole.ActorRuntime do
  @moduledoc """
  Control-plane API for the Actor Runtime PING/PONG main path.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.CommitCoordinator
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.ActorRuntime.WorkerAdmission
  alias Ankole.ActorRuntime.WorkerPool
  alias Ankole.Repo

  @live_delivery_states ~w(created sent accepted)
  @live_activation_statuses ~w(starting active draining)

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
  Starts a placeholder PING/PONG turn for a ready actor input set.
  """
  @spec start_placeholder_llm_turn(actor_key(), [ActorInput.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_placeholder_llm_turn(actor_key, actor_inputs, opts \\ [])
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
               start_or_reuse_placeholder_turn_in_tx(
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
          turn_ref = turn_ref(actor_key, activation, turn_result.llm_turn)
          envelope = turn_start_envelope(turn_ref, actor_inputs, deliveries)

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
  Handles an Actor Bus turn.accepted envelope.
  """
  @spec handle_turn_accepted(map()) :: {:ok, [ActorInputDelivery.t()]} | {:error, term()}
  def handle_turn_accepted(envelope) when is_map(envelope) do
    payload = unwrap_body(envelope, "turn_accepted")
    turn_ref = fetch_map!(payload, "turn")
    accepted_ids = fetch_list(payload, "accepted_actor_input_ids")
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      deliveries =
        ActorInputDelivery
        |> where([delivery], delivery.llm_turn_id == ^fetch_turn_id(turn_ref))
        |> where([delivery], delivery.state == "sent")
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

    now
    |> Actors.list_ready_actor_keys(limit)
    |> Enum.map(&process_ready_inputs_for_actor(&1, opts))
    |> collect_results()
  end

  @doc """
  Starts the ready input prefix for one actor key.
  """
  @spec process_ready_inputs_for_actor(actor_key(), keyword()) :: {:ok, map()} | {:error, term()}
  def process_ready_inputs_for_actor(actor_key, opts \\ []) do
    actor_key = normalize_actor_key(actor_key)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    actor_key.agent_uid
    |> Actors.list_ready_inputs(actor_key.session_id, now)
    |> Actors.contiguous_same_sender_prefix()
    |> case do
      [] ->
        {:ok, %{status: :idle}}

      inputs ->
        start_placeholder_llm_turn(actor_key, inputs, opts)
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

  defp send_turn_start(
         {:ok,
          %{assignment: assignment, envelope: envelope, deliveries: deliveries} =
            result}
       ) do
    route = assignment.transport_route || assignment.worker_instance_id || assignment.worker_id

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
      assigned_worker_instance_id: assignment.worker_instance_id,
      revision: 0,
      started_at: now,
      metadata: %{}
    })
    |> repo.insert()
  end

  defp refresh_activation_assignment(repo, activation, assignment, now) do
    case activation.assigned_worker_id == assignment.worker_id and
           activation.assigned_worker_instance_id == assignment.worker_instance_id do
      true ->
        {:ok, activation}

      false ->
        activation
        |> ActorSessionActivation.changeset(%{
          assigned_worker_id: assignment.worker_id,
          assigned_worker_instance_id: assignment.worker_instance_id,
          last_actor_heartbeat_at: now
        })
        |> repo.update()
    end
  end

  defp bind_activation_turn(repo, activation, llm_turn_id, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      status: "active",
      current_llm_turn_id: llm_turn_id,
      last_actor_heartbeat_at: now
    })
    |> repo.update()
  end

  defp create_input_deliveries_in_tx(repo, actor_inputs, activation, llm_turn, assignment, now) do
    batch = %{
      delivery_batch_id: Ecto.UUID.generate(),
      actor_bus_message_id: "turn-start-" <> Ecto.UUID.generate()
    }

    actor_inputs
    |> Enum.map(fn actor_input ->
      create_input_delivery_in_tx(
        repo,
        actor_input,
        activation,
        llm_turn,
        assignment.transport_route || assignment.worker_instance_id,
        assignment,
        now,
        batch
      )
    end)
    |> collect_results()
  end

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
          actor_bus_message_id: "turn-start-" <> Ecto.UUID.generate()
        }

    attrs = %{
      actor_input_id: actor_input.id,
      agent_uid: actor_input.agent_uid,
      session_id: actor_input.session_id,
      broker_sequence: actor_input.broker_sequence,
      attempt_no: attempt_no,
      delivery_batch_id: batch.delivery_batch_id,
      actor_bus_message_id: batch.actor_bus_message_id,
      correlation_id: batch.actor_bus_message_id,
      activation_uid: activation.activation_uid,
      actor_epoch: activation.actor_epoch,
      llm_turn_id: llm_turn.id,
      revision: activation.revision,
      worker_id: Map.get(assignment, :worker_id),
      worker_instance_id: Map.get(assignment, :worker_instance_id),
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

  defp start_or_reuse_placeholder_turn_in_tx(repo, conversation, actor_inputs, opts) do
    case AIAgent.start_placeholder_llm_turn_in_tx(repo, conversation, actor_inputs, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, :active_turn_exists} ->
        reuse_started_turn_in_tx(repo, conversation)

      {:error, _reason} = error ->
        error
    end
  end

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

  defp live_activation(repo, actor_key) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^actor_key.agent_uid)
    |> where([activation], activation.session_id == ^actor_key.session_id)
    |> where([activation], activation.status in ["starting", "active", "draining"])
    |> lock("FOR UPDATE")
    |> repo.one()
  end

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

  defp fail_expired_activation(
         repo,
         %ActorSessionActivation{current_llm_turn_id: nil} = activation,
         now
       ) do
    fail_activation(repo, activation, :activation_lease_expired, now)
  end

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

  defp turn_ref(actor_key, activation, llm_turn) do
    %{
      "actor" => %{
        "agent_uid" => actor_key.agent_uid,
        "session_id" => actor_key.session_id
      },
      "activation_uid" => activation.activation_uid,
      "actor_epoch" => activation.actor_epoch,
      "llm_turn_id" => llm_turn.id,
      "revision" => activation.revision
    }
  end

  defp turn_start_envelope(turn_ref, actor_inputs, deliveries) do
    message_id =
      deliveries
      |> List.first()
      |> case do
        %ActorInputDelivery{actor_bus_message_id: message_id} -> message_id
        _delivery -> "turn-start-" <> Ecto.UUID.generate()
      end

    %{
      "protocol_version" => 1,
      "message_id" => message_id,
      "correlation_id" => message_id,
      "seq" => 0,
      "lane" => "LANE_TURN",
      "sent_at_unix_ms" => System.system_time(:millisecond),
      "durability" => "CONTROL_REPLAYABLE",
      "body" => %{
        "type" => "turn_start",
        "turn_start" => %{
          "turn" => turn_ref,
          "inputs" => Enum.map(actor_inputs, &actor_input_envelope/1)
        }
      }
    }
  end

  defp actor_input_envelope(%ActorInput{} = actor_input) do
    %{
      "actor_input_id" => actor_input.id,
      "broker_sequence" => actor_input.broker_sequence,
      "type" => actor_input.type,
      "ingress_event_id" => actor_input.ingress_event_id,
      "provider_entry_id" => actor_input.provider_entry_id,
      "payload_json" => actor_input.payload
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp require_all_sent_inputs_accepted([], _accepted_ids), do: {:error, :sent_delivery_not_found}

  defp require_all_sent_inputs_accepted(deliveries, accepted_ids) do
    delivered_ids = deliveries |> Enum.map(& &1.actor_input_id) |> MapSet.new()

    case delivered_ids == MapSet.new(accepted_ids) do
      true -> :ok
      false -> {:error, :accepted_delivery_mismatch}
    end
  end

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

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)

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
