defmodule Ankole.ActorRuntime.TurnLifecycle do
  @moduledoc false

  import Ecto.Query, warn: false
  import Ankole.ActorRuntime.Common

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.TurnEnvelope
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.ActorRuntime.WorkerAdmission
  alias Ankole.ActorRuntime.WorkerPool
  alias Ankole.Repo

  @live_delivery_states ~w(created sent accepted)
  @live_activation_statuses ~w(starting active draining)
  @activation_progress_lease_seconds 300

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

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

    with {:ok, assignment} <- WorkerPool.assign_worker(actor_key) do
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

  def session_has_running_work?(repo, actor_key) do
    active_generation?(repo, actor_key) or live_delivery_for_session?(repo, actor_key)
  end

  def live_delivery_for_session?(repo, actor_key) do
    ActorInputDelivery
    |> where([delivery], delivery.agent_uid == ^actor_key.agent_uid)
    |> where([delivery], delivery.session_id == ^actor_key.session_id)
    |> where([delivery], delivery.state in ^@live_delivery_states)
    |> repo.exists?()
  end

  def active_generation?(repo, actor_key) do
    case active_conversation_for_update(repo, actor_key) do
      %Conversation{generation: generation} when is_map(generation) ->
        conversation_has_active_generation?(generation)

      _conversation ->
        false
    end
  end

  def conversation_has_active_generation?(%Conversation{generation: generation})
      when is_map(generation),
      do: conversation_has_active_generation?(generation)

  def conversation_has_active_generation?(generation) when is_map(generation),
    do: is_binary(generation["lease_id"]) and is_nil(generation["cancelled_at"])

  def conversation_has_active_generation?(_generation), do: false

  def active_conversation_for_update(repo, actor_key) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^actor_key.agent_uid)
    |> where([conversation], conversation.conversation_key == ^actor_key.session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  def live_assignment(repo, actor_key) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^actor_key.agent_uid)
    |> where([assignment], assignment.session_id == ^actor_key.session_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  def live_delivery_for_input?(repo, actor_input_id) do
    ActorInputDelivery
    |> where([delivery], delivery.actor_input_id == ^actor_input_id)
    |> where([delivery], delivery.state in ^@live_delivery_states)
    |> repo.exists?()
  end

  def bump_activation_revision(repo, %ActorSessionActivation{} = activation, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      revision: activation.revision + 1,
      last_actor_heartbeat_at: now
    })
    |> repo.update()
  end

  def mark_delivery_sent_in_tx(repo, %ActorInputDelivery{} = delivery, now, send_outcome) do
    delivery
    |> ActorInputDelivery.changeset(%{
      state: "sent",
      send_outcome: send_outcome,
      sent_at: now
    })
    |> repo.update()
  end

  def cancel_generation(generation, now, reason) when is_map(generation) do
    case blank?(generation["lease_id"]) do
      true ->
        generation

      false ->
        generation
        |> Map.put("cancelled_at", DateTime.to_iso8601(now))
        |> Map.put("cancel_reason", reason)
    end
  end

  def generation_lease_id(generation) when is_map(generation) do
    case generation["lease_id"] do
      lease_id when is_binary(lease_id) and lease_id != "" -> lease_id
      _value -> nil
    end
  end

  def cancel_started_turn_for_lease(_repo, _conversation, nil, _now, _reason), do: {:ok, nil}

  def cancel_started_turn_for_lease(repo, %Conversation{} = conversation, lease_id, now, reason) do
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

  def activation_lease_alive?(%ActorSessionActivation{lease_expires_at: lease_expires_at}, now) do
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
  def create_input_delivery_in_tx(
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
      live_queue_sequence: actor_input.live_queue_sequence,
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
  def live_activation(repo, actor_key) do
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

  def lock_actor_input(repo, actor_input_id) do
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
  def fail_expired_activations(repo, now, lease_grace_seconds) do
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
  def reconcile_projection_lost_started_turns_in_tx(repo, now) do
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
  def supersede_turn_deliveries_by_id(llm_turn_id, repo, now, reason) do
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

  def reconcile_projection_lost_started_turns(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo -> reconcile_projection_lost_started_turns_in_tx(repo, now) end)
  end
end
