defmodule Ankole.ActorRuntime.TurnLifecycle do
  @moduledoc false

  import Ecto.Query, warn: false
  import Ankole.ActorRuntime.Common

  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.TurnEnvelope
  alias Ankole.ActorRuntime.TurnRef
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.ActorRuntime.WorkerAdmission
  alias Ankole.ActorRuntime.WorkerPool
  alias Ankole.Repo
  alias Ankole.RuntimeEvents

  @live_activation_statuses ~w(starting active draining)
  @activation_progress_lease_seconds 300
  @worker_turn_error_dead_letter_attempts 3
  @worker_turn_error_retry_base_seconds 2
  @worker_turn_error_retry_max_seconds 60

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Starts one worker-backed run for a ready actor event.

  This is the control-plane side of the local actor loop. Normal text turns
  ensure an AIGateway conversation exists. Non-conversation work such as a
  subagent delegation passes `conversation: :none` and still receives the same
  activation, lease, delivery, and revision fences.
  """
  @spec start_worker_turn(actor_key(), ActorEvent.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_worker_turn(actor_key, %ActorEvent{} = actor_event, opts \\ []) do
    actor_key = normalize_actor_key(actor_key)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, assignment} <- WorkerPool.assign_worker(actor_key),
         {:ok, %{conversation: conversation, turn_start_spec: turn_start_spec}} <-
           prepare_turn_start(actor_key, opts) do
      Repo.transact(fn repo ->
        with {:ok, activation} <- ensure_activation(repo, actor_key, assignment, now, opts),
             {:ok, conversation} <- lock_turn_conversation(repo, conversation),
             {:ok, activation} <-
               bind_activation_turn(repo, activation, actor_event.id, now),
             {:ok, deliveries} <-
               create_event_deliveries_in_tx(
                 repo,
                 actor_event,
                 activation,
                 assignment,
                 now
               ) do
          turn_ref = TurnEnvelope.turn_ref(actor_key, activation)

          envelope =
            TurnEnvelope.turn_start(
              turn_ref,
              actor_event,
              deliveries,
              turn_start_spec
            )

          {:ok,
           %{
             activation: activation,
             assignment: assignment,
             conversation: conversation,
             deliveries: deliveries,
             turn_ref: turn_ref,
             turn_start_spec: turn_start_spec,
             envelope: envelope
           }}
        else
          {:error, _reason} = error -> error
        end
      end)
      |> send_turn_start()
    end
  end

  defp prepare_turn_start(actor_key, opts) do
    case Keyword.get(opts, :conversation, :required) do
      :none ->
        request_context =
          %{
            "actor_key" => %{
              "agent_uid" => actor_key.agent_uid,
              "session_id" => actor_key.session_id
            }
          }
          |> Map.merge(Keyword.get(opts, :request_context, %{}))

        {:ok,
         %{
           conversation: nil,
           turn_start_spec: %{model_ref: %{}, request_context: request_context}
         }}

      :required ->
        with {:ok, conversation} <-
               Conversations.ensure_conversation(actor_key.agent_uid, actor_key.session_id),
             {:ok, turn_start_spec} <- Conversations.build_turn_start_spec(conversation, opts) do
          {:ok, %{conversation: conversation, turn_start_spec: turn_start_spec}}
        end

      mode ->
        {:error, {:invalid_turn_conversation_mode, mode}}
    end
  end

  defp lock_turn_conversation(_repo, nil), do: {:ok, nil}

  defp lock_turn_conversation(repo, %Conversation{} = conversation) do
    case Conversations.lock_conversation(repo, conversation.id) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :conversation_not_found}
    end
  end

  @doc """
  Marks a delivery sent.
  """
  @spec mark_delivery_sent(Ecto.UUID.t(), String.t() | atom()) ::
          {:ok, ActorEventDelivery.t()} | {:error, term()}
  def mark_delivery_sent(delivery_id, send_outcome \\ "sent_or_queued") do
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      case lock_delivery(repo, delivery_id) do
        %ActorEventDelivery{state: "created"} = delivery ->
          delivery
          |> ActorEventDelivery.changeset(%{
            state: "sent",
            send_outcome: normalize_outcome(send_outcome),
            sent_at: now
          })
          |> repo.update()

        %ActorEventDelivery{} = delivery ->
          {:ok, delivery}

        nil ->
          {:error, :delivery_not_found}
      end
    end)
  end

  @doc """
  Marks a delivery transport failure.
  """
  @spec mark_delivery_failed(Ecto.UUID.t(), String.t() | atom(), term()) ::
          {:ok, ActorEventDelivery.t()} | {:error, term()}
  def mark_delivery_failed(delivery_id, send_outcome, reason) do
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      case lock_delivery(repo, delivery_id) do
        %ActorEventDelivery{} = delivery ->
          delivery
          |> ActorEventDelivery.changeset(%{
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
  difference between "worker received the turn" and "worker finished durable
  response processing".
  """
  @spec handle_turn_accepted(map()) :: {:ok, [ActorEventDelivery.t()]} | {:error, term()}
  def handle_turn_accepted(envelope) when is_map(envelope) do
    payload = unwrap_body(envelope, "turn_accepted")

    with {:ok, turn_ref} <- TurnRef.from_request(payload, :turn) do
      accepted_actor_event_id = turn_ref.actor_event_id
      now = DateTime.utc_now(:microsecond)

      Repo.transact(fn repo ->
        deliveries =
          pending_deliveries_for_turn_ref(repo, turn_ref)

        with :ok <- require_sent_event_accepted(deliveries, accepted_actor_event_id),
             :ok <- validate_deliveries_turn_ref(deliveries, turn_ref, :exact_revision) do
          deliveries
          |> Enum.map(fn delivery ->
            delivery
            |> ActorEventDelivery.changeset(%{state: "accepted", accepted_at: now})
            |> repo.update()
          end)
          |> collect_results()
        end
      end)
    end
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

    with {:ok, turn_ref} <- TurnRef.from_request(payload, :turn) do
      now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
      lease_seconds = Keyword.get(opts, :lease_seconds, @activation_progress_lease_seconds)

      Repo.transact(fn repo ->
        with %ActorSessionActivation{} = activation <- activation_for_turn_ref(repo, turn_ref),
             :ok <- activation_accepts_progress(activation, turn_ref, now) do
          renew_activation_lease(repo, activation, now, lease_seconds)
        else
          nil -> {:error, :actor_runtime_fence_not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  @doc """
  Completes a worker turn that deliberately produced no AIGateway response.

  This is only for runtime decisions that consume an actor event without
  provider-visible output, such as ambient silence. Normal text turns complete
  through the AIGateway terminal commit path.
  """
  @spec handle_turn_noop_completed(map()) :: {:ok, map()} | {:error, term()}
  def handle_turn_noop_completed(envelope) when is_map(envelope) do
    payload = unwrap_body(envelope, "turn_noop_completed")

    with {:ok, turn_ref} <- TurnRef.from_request(payload, :turn) do
      reason = map_text(payload, "reason") || "noop_completed"
      now = DateTime.utc_now(:microsecond)

      Repo.transact(fn repo ->
        with %ActorEvent{} = event <- lock_actor_event_for_turn_ref(repo, turn_ref),
             %ActorSessionActivation{} = activation <- activation_for_turn_ref(repo, turn_ref),
             :ok <- activation_accepts_progress(activation, turn_ref, now),
             already_completed? = match?(%DateTime{}, event.completed_at),
             {:ok, deliveries} <- live_deliveries_for_noop(repo, event, turn_ref),
             {:ok, _completed_events} <-
               mark_noop_delivery_events_completed(repo, deliveries, now),
             {:ok, event} <- mark_noop_event_completed(repo, event, now),
             {deleted_count, superseded_count} <-
               cleanup_noop_deliveries(repo, turn_ref.actor_event_id, now, reason) do
          {:ok,
           %{
             status: if(already_completed?, do: :already_completed, else: :noop_completed),
             reason: reason,
             actor_event: event,
             activation: activation,
             delivery_count: length(deliveries),
             deleted_deliveries: deleted_count,
             superseded_deliveries: superseded_count
           }}
        else
          nil -> {:error, :actor_runtime_fence_not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  @doc """
  Handles a worker turn error without consuming the actor event.

  The event stays `open` for retry until repeated worker failures cross the
  dead-letter threshold. Runtime fences are superseded and the activation is
  failed so late replies from the failed attempt cannot match a later retry.
  """
  @spec handle_turn_error(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_turn_error(envelope, opts \\ []) when is_map(envelope) do
    payload = unwrap_body(envelope, "turn_error")

    with {:ok, turn_ref} <- TurnRef.from_request(payload, :turn) do
      reason = turn_error_reason(payload)
      now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

      Repo.transact(fn repo ->
        with %ActorEvent{} = event <- lock_actor_event_for_turn_ref(repo, turn_ref),
             %ActorSessionActivation{} = activation <- activation_for_turn_ref(repo, turn_ref),
             :ok <- activation_accepts_progress(activation, turn_ref, now),
             {:ok, deliveries} <- live_deliveries_for_turn_ref(repo, turn_ref),
             {:ok, event} <- maybe_mark_overflow_retry(repo, event, reason),
             dead_letter? = dead_letter_after_turn_error?(deliveries, reason),
             {superseded_count, _rows} <- supersede_live_deliveries(repo, turn_ref, now, reason),
             {:ok, event} <- maybe_mark_event_dead_letter(repo, event, dead_letter?, now),
             {:ok, event} <-
               maybe_delay_retryable_turn_error(
                 repo,
                 event,
                 deliveries,
                 reason,
                 now,
                 dead_letter?
               ),
             {:ok, activation} <- fail_activation_for_turn_error(repo, activation, reason, now) do
          {:ok,
           %{
             status: if(dead_letter?, do: :turn_dead_lettered, else: :turn_failed),
             reason: reason,
             actor_event: event,
             activation: activation,
             delivery_count: length(deliveries),
             superseded_deliveries: superseded_count,
             dead_lettered?: dead_letter?,
             retry_available_at: retry_available_at(event)
           }}
        else
          nil -> {:error, :actor_runtime_fence_not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
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
    live_delivery_for_session?(repo, actor_key)
  end

  def live_delivery_for_session?(repo, actor_key) do
    ActorEventDelivery
    |> where([delivery], delivery.agent_uid == ^actor_key.agent_uid)
    |> where([delivery], delivery.session_id == ^actor_key.session_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> repo.exists?()
  end

  def active_conversation_for_update(repo, actor_key) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^actor_key.agent_uid)
    |> where([conversation], conversation.conversation_key == ^actor_key.session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  def fail_activations_for_worker(repo, worker_id, now, reason) when is_binary(worker_id) do
    activations =
      ActorSessionActivation
      |> where([activation], activation.assigned_worker_id == ^worker_id)
      |> where([activation], activation.status in ^@live_activation_statuses)
      |> lock("FOR UPDATE")
      |> repo.all()

    activations
    |> Enum.map(&fail_worker_activation(repo, &1, now, reason))
    |> collect_results()
    |> case do
      {:ok, activations} -> {:ok, length(activations)}
      {:error, _reason} = error -> error
    end
  end

  def fail_activations_for_worker(_repo, _worker_id, _now, _reason), do: {:ok, 0}

  def live_assignment(repo, actor_key) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^actor_key.agent_uid)
    |> where([assignment], assignment.session_id == ^actor_key.session_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  def live_delivery_for_event?(repo, actor_event_id) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id == ^actor_event_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
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

  def mark_delivery_sent_in_tx(repo, %ActorEventDelivery{} = delivery, now, send_outcome) do
    delivery
    |> ActorEventDelivery.changeset(%{
      state: "sent",
      send_outcome: send_outcome,
      sent_at: now
    })
    |> repo.update()
  end

  def cancel_started_turn_for_actor_event(_repo, nil, _now, _reason), do: {:ok, nil}

  def cancel_started_turn_for_actor_event(repo, actor_event_id, now, reason) do
    with {:ok, cancelled_turn} <-
           cancel_generating_message_for_actor_event(repo, actor_event_id, now, reason),
         {_count, _rows} <-
           supersede_turn_deliveries_by_actor_event_id(actor_event_id, repo, now, reason) do
      {:ok, cancelled_turn}
    end
  end

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    activation_deadline_events() ++ ai_message_deadline_events()
  end

  @doc false
  @spec fail_activation_if_expired(String.t(), keyword()) ::
          {:ok, ActorSessionActivation.t()} | {:error, term()}
  def fail_activation_if_expired(activation_uid, opts \\ []) when is_binary(activation_uid) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    lease_grace_seconds = Keyword.get(opts, :lease_grace_seconds, 0)
    cutoff = DateTime.add(now, -lease_grace_seconds, :second)

    Repo.transact(fn repo ->
      case lock_activation_by_uid(repo, activation_uid) do
        %ActorSessionActivation{} = activation ->
          cond do
            activation.status not in @live_activation_statuses ->
              {:error, :activation_not_due}

            DateTime.compare(activation.lease_expires_at, cutoff) == :gt ->
              {:error, :activation_not_due}

            true ->
              fail_expired_activation(repo, activation, now)
          end

        nil ->
          {:error, :activation_not_found}
      end
    end)
  end

  @doc false
  @spec reconcile_projection_lost_started_turn(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def reconcile_projection_lost_started_turn(message_id, opts \\ []) when is_binary(message_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case lock_generating_message(repo, message_id) do
        %Message{} = message ->
          cond do
            not StatefulResponses.generating_message_stale?(message, now) ->
              {:error, :message_not_due}

            live_projection_exists?(repo, message) ->
              {:ok, %{status: :live_projection_present, message: message}}

            true ->
              with {:ok, failed_turn} <-
                     fail_generating_message(repo, message, now, :actor_runtime_projection_lost),
                   {_count, _rows} <-
                     supersede_turn_deliveries_by_actor_event_id(
                       turn_actor_event_id(failed_turn),
                       repo,
                       now,
                       :actor_runtime_projection_lost
                     ),
                   :ok <- notify_actor_event_ready(repo, turn_actor_event_id(failed_turn), now) do
                {:ok, %{status: :projection_lost_failed, message: failed_turn}}
              end
          end

        nil ->
          {:error, :message_not_found}
      end
    end)
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

  defp activation_accepts_progress(%ActorSessionActivation{} = activation, turn_ref, now) do
    cond do
      activation.status not in @live_activation_statuses ->
        {:error, :activation_not_live}

      not activation_lease_alive?(activation, now) ->
        {:error, :activation_lease_expired}

      activation.agent_uid != turn_ref.agent_uid ->
        {:error, :stale_actor_key}

      activation.session_id != turn_ref.session_id ->
        {:error, :stale_actor_key}

      activation.activation_uid != turn_ref.activation_uid ->
        {:error, :stale_activation_uid}

      activation.actor_epoch != turn_ref.actor_epoch ->
        {:error, :stale_actor_epoch}

      activation.revision < turn_ref.revision ->
        {:error, :stale_revision}

      activation.current_actor_event_id != turn_ref.actor_event_id ->
        {:error, :stale_actor_event_id}

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
    |> notify_activation_deadline(repo)
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
      # Source table: this actor_session_activations row originates the worker
      # fence; activation_uid/lease_id are generated here, actor_epoch is the
      # next epoch for the actor key, and revision starts at zero.
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
    |> notify_activation_deadline(repo)
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

  # Marks the activation as the owner of the actor event being executed. Source
  # table: current_actor_event_id stores actor_events.id.
  defp bind_activation_turn(repo, activation, actor_event_id, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      status: "active",
      current_actor_event_id: actor_event_id,
      last_actor_heartbeat_at: now
    })
    |> repo.update()
  end

  # Creates one delivery projection for the single actor event. One worker run
  # handles exactly one actor_event_id.
  defp create_event_deliveries_in_tx(
         repo,
         %ActorEvent{} = actor_event,
         activation,
         assignment,
         now
       ) do
    batch = %{
      actor_lane_message_id: "turn-start-" <> Ecto.UUID.generate()
    }

    create_event_delivery_in_tx(
      repo,
      actor_event,
      activation,
      assignment.transport_route || assignment.worker_id,
      assignment,
      now,
      batch
    )
    |> List.wrap()
    |> collect_results()
  end

  # Records a concrete attempt to deliver an actor event to a worker turn, then
  # compacts obsolete failed/superseded attempts for the same event.
  def create_event_delivery_in_tx(
        repo,
        actor_event,
        activation,
        route,
        assignment,
        now,
        batch \\ nil
      ) do
    attempt_no = next_attempt_no(repo, actor_event.id)

    batch =
      batch ||
        %{
          actor_lane_message_id: "turn-start-" <> Ecto.UUID.generate()
        }

    # Source tables: actor_event_* values copy actor_events, activation_* and
    # revision copy actor_session_activations, and correlation_id mirrors the
    # actor lane message id for transport tracing.
    attrs = %{
      actor_event_id: actor_event.id,
      agent_uid: actor_event.agent_uid,
      session_id: actor_event.session_id,
      queue_sequence: actor_event.queue_sequence,
      attempt_no: attempt_no,
      actor_lane_message_id: batch.actor_lane_message_id,
      correlation_id: batch.actor_lane_message_id,
      activation_uid: activation.activation_uid,
      actor_epoch: activation.actor_epoch,
      actor_event_id_fence: activation.current_actor_event_id,
      revision: activation.revision,
      worker_id: Map.get(assignment, :worker_id),
      transport_route: route,
      state: "created",
      error: %{},
      inserted_at: now,
      updated_at: now
    }

    %ActorEventDelivery{}
    |> ActorEventDelivery.changeset(attrs)
    |> repo.insert()
    |> case do
      {:ok, delivery} ->
        delete_stale_delivery_projections(repo, actor_event.id, delivery.id)
        {:ok, delivery}

      {:error, _reason} = error ->
        error
    end
  end

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

  defp lock_activation_by_uid(repo, activation_uid) do
    ActorSessionActivation
    |> where([activation], activation.activation_uid == ^activation_uid)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_generating_message(repo, message_id) do
    Message
    |> where([message], message.id == ^message_id)
    |> where([message], message.type == "message")
    |> where([message], message.status == "generating")
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp activation_deadline_events do
    ActorSessionActivation
    |> where([activation], activation.status in ^@live_activation_statuses)
    |> Repo.all()
    |> Enum.map(fn activation ->
      {RuntimeEvents.activation_deadline_channel(),
       %{
         "activation_uid" => activation.activation_uid,
         "agent_uid" => activation.agent_uid,
         "session_id" => activation.session_id,
         "lease_expires_at" => RuntimeEvents.encode_datetime(activation.lease_expires_at)
       }}
    end)
  end

  defp ai_message_deadline_events do
    Message
    |> where([message], message.type == "message")
    |> where([message], message.status == "generating")
    |> Repo.all()
    |> Enum.map(fn message ->
      {RuntimeEvents.ai_message_deadline_channel(),
       %{
         "message_id" => message.id,
         "orphan_at" => RuntimeEvents.encode_datetime(ai_message_orphan_at(message))
       }}
    end)
  end

  defp ai_message_orphan_at(%Message{} = message) do
    base_at = message.updated_at || message.inserted_at || DateTime.utc_now(:microsecond)
    DateTime.add(base_at, StatefulResponses.orphaned_generating_grace_seconds(), :second)
  end

  defp notify_activation_deadline({:ok, %ActorSessionActivation{} = activation}, repo) do
    with :ok <- RuntimeEvents.notify_activation_deadline(repo, activation) do
      {:ok, activation}
    end
  end

  defp notify_activation_deadline({:error, _reason} = error, _repo), do: error

  defp notify_actor_event_ready({:ok, %ActorEvent{} = event}, repo) do
    with :ok <-
           RuntimeEvents.notify_actor_session_ready(
             repo,
             event.agent_uid,
             event.session_id,
             event.available_at
           ) do
      {:ok, event}
    end
  end

  defp notify_actor_event_ready({:error, _reason} = error, _repo), do: error

  defp notify_actor_event_ready(_repo, nil, _now), do: :ok

  defp notify_actor_event_ready(repo, actor_event_id, now) when is_binary(actor_event_id) do
    case repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{completed_at: nil} = event ->
        RuntimeEvents.notify_actor_session_ready(repo, event.agent_uid, event.session_id, now)

      %ActorEvent{} ->
        :ok

      nil ->
        :ok
    end
  end

  # Resolves the activation named by a worker turn reference. The turn_ref is
  # trusted only after matching the locked row, not because it came from a route.
  defp activation_for_turn_ref(repo, turn_ref) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^turn_ref.agent_uid)
    |> where([activation], activation.session_id == ^turn_ref.session_id)
    |> where([activation], activation.activation_uid == ^turn_ref.activation_uid)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_actor_event_for_turn_ref(repo, turn_ref) do
    ActorEvent
    |> where([event], event.id == ^turn_ref.actor_event_id)
    |> where([event], event.agent_uid == ^turn_ref.agent_uid)
    |> where([event], event.session_id == ^turn_ref.session_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp live_deliveries_for_turn_ref(repo, turn_ref) do
    deliveries =
      ActorEventDelivery
      |> where([delivery], delivery.actor_event_id_fence == ^turn_ref.actor_event_id)
      |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
      |> lock("FOR UPDATE")
      |> repo.all()

    cond do
      deliveries == [] ->
        {:error, :actor_runtime_fence_not_found}

      true ->
        with :ok <- validate_deliveries_turn_ref(deliveries, turn_ref, :minimum_revision) do
          {:ok, deliveries}
        end
    end
  end

  defp live_deliveries_for_noop(_repo, %ActorEvent{completed_at: %DateTime{}}, _turn_ref),
    do: {:ok, []}

  defp live_deliveries_for_noop(repo, %ActorEvent{}, turn_ref) do
    live_deliveries_for_turn_ref(repo, turn_ref)
  end

  defp mark_noop_delivery_events_completed(_repo, [], _now), do: {:ok, []}

  defp mark_noop_delivery_events_completed(repo, deliveries, now) do
    deliveries
    |> Enum.filter(&(&1.state == "accepted"))
    |> Enum.uniq_by(& &1.actor_event_id)
    |> Enum.reduce_while({:ok, []}, fn delivery, {:ok, completed_events} ->
      case lock_actor_event(repo, delivery.actor_event_id) do
        %ActorEvent{completed_at: nil} = event ->
          case Actors.mark_event_completed_in_tx(repo, event, now) do
            {:ok, completed_event} -> {:cont, {:ok, [completed_event | completed_events]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        %ActorEvent{} = event ->
          {:cont, {:ok, [event | completed_events]}}

        nil ->
          {:cont, {:ok, completed_events}}
      end
    end)
  end

  defp mark_noop_event_completed(_repo, %ActorEvent{completed_at: %DateTime{}} = event, _now),
    do: {:ok, event}

  defp mark_noop_event_completed(repo, %ActorEvent{} = event, now) do
    Actors.mark_event_completed_in_tx(repo, event, now)
  end

  defp cleanup_noop_deliveries(repo, actor_event_id, now, reason) do
    {deleted_count, _rows} = delete_accepted_deliveries(repo, actor_event_id)
    {superseded_count, _rows} = supersede_pending_deliveries(repo, actor_event_id, now, reason)
    {deleted_count, superseded_count}
  end

  defp delete_accepted_deliveries(repo, actor_event_id) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
    |> where([delivery], delivery.state == "accepted")
    |> repo.delete_all()
  end

  defp supersede_pending_deliveries(repo, actor_event_id, now, reason) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
    |> where([delivery], delivery.state in ["created", "sent"])
    |> repo.update_all(
      set: [
        state: "superseded",
        superseded_at: now,
        error: %{"reason" => inspect(reason)},
        updated_at: now
      ]
    )
  end

  defp supersede_live_deliveries(repo, turn_ref, now, reason) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id_fence == ^turn_ref.actor_event_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> repo.update_all(
      set: [
        state: "superseded",
        superseded_at: now,
        error: %{"reason" => inspect(reason)},
        updated_at: now
      ]
    )
  end

  defp fail_activation_for_turn_error(repo, %ActorSessionActivation{} = activation, reason, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      status: "failed",
      current_actor_event_id: nil,
      stopped_at: now,
      stop_reason: inspect(reason)
    })
    |> repo.update()
  end

  defp dead_letter_after_turn_error?(deliveries, reason),
    do:
      not retryable_turn_error?(reason) and
        max_delivery_attempt_no(deliveries) >= @worker_turn_error_dead_letter_attempts

  defp maybe_mark_event_dead_letter(repo, %ActorEvent{} = event, true, now) do
    Actors.mark_event_dead_letter_in_tx(repo, event, now)
  end

  defp maybe_mark_event_dead_letter(_repo, %ActorEvent{} = event, false, _now), do: {:ok, event}

  defp maybe_delay_retryable_turn_error(
         _repo,
         %ActorEvent{} = event,
         _deliveries,
         _reason,
         _now,
         true
       ),
       do: {:ok, event}

  defp maybe_delay_retryable_turn_error(
         repo,
         %ActorEvent{} = event,
         deliveries,
         reason,
         now,
         false
       ) do
    if retryable_turn_error?(reason) do
      retry_available_at = DateTime.add(now, retry_backoff_seconds(deliveries), :second)

      event
      |> ActorEvent.changeset(%{available_at: retry_available_at})
      |> repo.update()
      |> notify_actor_event_ready(repo)
    else
      {:ok, event}
    end
  end

  defp retry_available_at(%ActorEvent{input_state: "open", available_at: available_at}),
    do: available_at

  defp retry_available_at(_event), do: nil

  defp retryable_turn_error?(%{"details_json" => details}) when is_map(details) do
    details["retryable"] == true or
      get_in(details, ["aigateway", "details_json", "retryable"]) == true
  end

  defp retryable_turn_error?(_reason), do: false

  defp retry_backoff_seconds(deliveries) do
    attempt_no = max(max_delivery_attempt_no(deliveries), 1)
    exponential = round(@worker_turn_error_retry_base_seconds * :math.pow(2, attempt_no - 1))
    min(exponential, @worker_turn_error_retry_max_seconds)
  end

  defp max_delivery_attempt_no(deliveries) do
    case Enum.map(deliveries, & &1.attempt_no) do
      [] -> 0
      attempt_numbers -> Enum.max(attempt_numbers)
    end
  end

  defp turn_error_reason(payload) do
    %{
      "code" => map_text(payload, "code") || "worker_turn_error",
      "message" => map_text(payload, "message") || "worker turn failed",
      "details_json" => fetch_map(payload, "details_json") || %{}
    }
  end

  defp maybe_mark_overflow_retry(repo, %ActorEvent{} = event, reason) do
    if overflow_turn_error?(reason) do
      payload = put_overflow_retry_metadata(event.payload, event.id, reason)

      event
      |> ActorEvent.changeset(%{payload: payload})
      |> repo.update()
    else
      {:ok, event}
    end
  end

  defp overflow_turn_error?(%{"code" => "context_overflow"}), do: true

  defp overflow_turn_error?(%{"details_json" => %{} = details}) do
    details["llm_error_kind"] == "overflow" or
      details["should_compress"] == true or
      get_in(details, ["aigateway", "code"]) == "context_overflow"
  end

  defp overflow_turn_error?(_reason), do: false

  defp put_overflow_retry_metadata(payload, actor_event_id, reason) when is_map(payload) do
    data =
      payload
      |> Map.get("data", %{})
      |> ensure_map()

    entry =
      data
      |> Map.get("entry", %{})
      |> ensure_map()
      |> Map.put("retry_of_actor_event_id", actor_event_id)
      |> Map.put("retry_reason", "overflow_retry")
      |> Map.put("overflow_retry", overflow_retry_details(reason))

    payload
    |> Map.put("data", Map.put(data, "entry", entry))
  end

  defp put_overflow_retry_metadata(_payload, actor_event_id, reason) do
    put_overflow_retry_metadata(%{"data" => %{"entry" => %{}}}, actor_event_id, reason)
  end

  defp overflow_retry_details(%{} = reason) do
    reason
    |> Map.take(["code", "message", "details_json"])
  end

  defp ensure_map(%{} = map), do: map
  defp ensure_map(_value), do: %{}

  defp next_actor_epoch(repo, actor_key) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^actor_key.agent_uid)
    |> where([activation], activation.session_id == ^actor_key.session_id)
    |> select([activation], coalesce(max(activation.actor_epoch), 0) + 1)
    |> repo.one()
  end

  defp next_attempt_no(repo, actor_event_id) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id == ^actor_event_id)
    |> select([delivery], coalesce(max(delivery.attempt_no), 0) + 1)
    |> repo.one()
  end

  # Deletes terminal projections for one event after a new attempt exists.
  # This keeps the table small without deleting live evidence needed by fences.
  defp delete_stale_delivery_projections(repo, actor_event_id, current_delivery_id) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id == ^actor_event_id)
    |> where([delivery], delivery.id != ^current_delivery_id)
    |> where([delivery], delivery.state in ["send_failed", "superseded"])
    |> repo.delete_all()
  end

  def lock_actor_event(repo, actor_event_id) do
    ActorEvent
    |> where([input], input.id == ^actor_event_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_delivery(repo, delivery_id) do
    ActorEventDelivery
    |> where([delivery], delivery.id == ^delivery_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  # Fails an activation that never bound an actor event. There is no AIGateway
  # generating row or delivery fence to clear, so only the activation projection
  # is stopped.
  defp fail_expired_activation(
         repo,
         %ActorSessionActivation{current_actor_event_id: nil} = activation,
         now
       ) do
    fail_activation(repo, activation, :activation_lease_expired, now)
  end

  # Fails an activation with a current turn and clears all related live fences.
  # This lets the same open actor event be selected again on the next pass.
  defp fail_expired_activation(repo, %ActorSessionActivation{} = activation, now) do
    with {:ok, _failed_message} <-
           fail_generating_message_for_actor_event(
             repo,
             activation.current_actor_event_id,
             now,
             :activation_lease_expired
           ),
         {_count, _rows} <-
           supersede_turn_deliveries_by_actor_event_id(
             activation.current_actor_event_id,
             repo,
             now,
             :activation_lease_expired
           ) do
      fail_activation(repo, activation, :activation_lease_expired, now)
    end
  end

  defp fail_worker_activation(repo, %ActorSessionActivation{} = activation, now, reason) do
    with {:ok, _failed_message} <-
           fail_generating_message_for_actor_event(
             repo,
             activation.current_actor_event_id,
             now,
             reason
           ),
         {_count, _rows} <-
           supersede_turn_deliveries_by_actor_event_id(
             activation.current_actor_event_id,
             repo,
             now,
             reason
           ) do
      fail_activation(repo, activation, reason, now)
    end
  end

  defp fail_activation(repo, %ActorSessionActivation{} = activation, reason, now) do
    actor_event_id = activation.current_actor_event_id

    with {:ok, activation} <-
           activation
           |> ActorSessionActivation.changeset(%{
             status: "failed",
             current_actor_event_id: nil,
             stopped_at: now,
             stop_reason: inspect(reason)
           })
           |> repo.update(),
         :ok <- notify_actor_event_ready(repo, actor_event_id, now) do
      {:ok, activation}
    end
  end

  # Marks live delivery projections obsolete without deleting them. Keeping the
  # row records why a worker reply should no longer be accepted.
  def supersede_turn_deliveries_by_actor_event_id(nil, _repo, _now, _reason), do: {0, nil}

  def supersede_turn_deliveries_by_actor_event_id(actor_event_id, repo, now, reason) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
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
  defp live_projection_exists?(repo, turn) do
    case turn_actor_event_id(turn) do
      nil ->
        false

      actor_event_id ->
        activation_exists =
          ActorSessionActivation
          |> where([activation], activation.current_actor_event_id == ^actor_event_id)
          |> repo.exists?()

        delivery_exists =
          ActorEventDelivery
          |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
          |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
          |> repo.exists?()

        activation_exists and delivery_exists
    end
  end

  def generating_message_for_actor_event(repo, actor_event_id) do
    StatefulResponses.generating_message_for_actor_event(repo, actor_event_id)
  end

  defp turn_actor_event_id(%Message{metadata: metadata}) when is_map(metadata),
    do: metadata["actor_event_id"]

  defp turn_actor_event_id(_turn), do: nil

  defp fail_generating_message_for_actor_event(repo, actor_event_id, now, reason) do
    case generating_ai_message_for_actor_event(repo, actor_event_id) do
      %Message{} = message -> fail_generating_message(repo, message, now, reason)
      nil -> {:ok, nil}
    end
  end

  defp cancel_generating_message_for_actor_event(repo, actor_event_id, now, reason) do
    case generating_ai_message_for_actor_event(repo, actor_event_id) do
      %Message{} = message -> cancel_generating_message(repo, message, now, reason)
      nil -> {:ok, nil}
    end
  end

  defp generating_ai_message_for_actor_event(_repo, nil), do: nil

  defp generating_ai_message_for_actor_event(repo, actor_event_id) do
    StatefulResponses.generating_message_for_actor_event(repo, actor_event_id)
  end

  defp fail_generating_message(repo, %Message{} = message, now, reason) do
    metadata =
      message.metadata
      |> runtime_failure_metadata(reason)

    transition_generating_message(repo, message, now, metadata)
  end

  defp cancel_generating_message(repo, %Message{} = message, now, reason) do
    metadata =
      message.metadata
      |> runtime_cancel_metadata(reason)

    transition_generating_message(repo, message, now, metadata)
  end

  defp transition_generating_message(repo, %Message{} = message, now, metadata) do
    case repo.update_all(
           from(m in Message,
             where: m.id == ^message.id and m.status == "generating",
             select: m
           ),
           [
             set: [
               status: "error",
               metadata: metadata,
               updated_at: now
             ]
           ],
           returning: true
         ) do
      {count, [updated]} when count > 0 -> {:ok, updated}
      {0, []} -> {:ok, nil}
    end
  end

  defp runtime_failure_metadata(metadata, reason) when is_map(metadata) do
    response =
      metadata
      |> metadata_map_value("response")
      |> Map.put("error_code", runtime_reason_code(reason))
      |> Map.put("error", inspect(reason))

    error =
      metadata
      |> metadata_map_value("error")
      |> Map.put("code", runtime_reason_code(reason))
      |> Map.put("reason", inspect(reason))
      |> Map.put("stage", "actor_runtime_cleanup")

    metadata
    |> Map.put("response", response)
    |> Map.put("error", error)
  end

  defp runtime_failure_metadata(_metadata, reason),
    do: runtime_failure_metadata(%{}, reason)

  defp runtime_cancel_metadata(metadata, reason) when is_map(metadata) do
    response =
      metadata
      |> metadata_map_value("response")
      |> Map.put("cancel_code", runtime_reason_code(reason))
      |> Map.put("cancel_reason", inspect(reason))

    error =
      metadata
      |> metadata_map_value("error")
      |> Map.put("code", runtime_reason_code(reason))
      |> Map.put("reason", inspect(reason))
      |> Map.put("stage", "actor_runtime_cancel")

    metadata
    |> Map.put("response", response)
    |> Map.put("error", error)
  end

  defp runtime_cancel_metadata(_metadata, reason),
    do: runtime_cancel_metadata(%{}, reason)

  defp metadata_map_value(metadata, key) do
    case Map.get(metadata, key) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp runtime_reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp runtime_reason_code(reason) when is_binary(reason), do: reason
  defp runtime_reason_code(_reason), do: "actor_runtime_cleanup"

  defp pending_deliveries_for_turn_ref(repo, turn_ref) do
    ActorEventDelivery
    |> where([delivery], delivery.agent_uid == ^turn_ref.agent_uid)
    |> where([delivery], delivery.session_id == ^turn_ref.session_id)
    |> where([delivery], delivery.activation_uid == ^turn_ref.activation_uid)
    |> where([delivery], delivery.actor_epoch == ^turn_ref.actor_epoch)
    |> where([delivery], delivery.actor_event_id_fence == ^turn_ref.actor_event_id)
    |> where([delivery], delivery.revision == ^turn_ref.revision)
    |> where([delivery], delivery.state in ["created", "sent"])
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  # Both the turn_ref actor_event_id and each delivery actor_event_id_fence store
  # actor_events.id.
  defp require_sent_event_accepted([], _accepted_actor_event_id),
    do: {:error, :sent_delivery_not_found}

  defp require_sent_event_accepted(deliveries, accepted_actor_event_id) do
    delivered_ids = deliveries |> Enum.map(& &1.actor_event_id_fence) |> MapSet.new()

    case MapSet.member?(delivered_ids, accepted_actor_event_id) do
      true -> :ok
      false -> {:error, :accepted_delivery_mismatch}
    end
  end

  # Checks every accepted delivery against the same turn fence before commit.
  defp validate_deliveries_turn_ref(deliveries, turn_ref, revision_mode) do
    Enum.reduce_while(deliveries, :ok, fn
      delivery, :ok ->
        case delivery_matches_turn_ref(delivery, turn_ref, revision_mode) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      _delivery, {:error, _reason} = error ->
        {:halt, error}
    end)
  end

  # Rejects late replies from an old activation, actor epoch, or turn reference.
  # The route alone is not a durable identity, because workers reconnect.
  defp delivery_matches_turn_ref(%ActorEventDelivery{} = delivery, turn_ref, revision_mode) do
    cond do
      delivery.agent_uid != turn_ref.agent_uid ->
        {:error, :stale_actor_key}

      delivery.session_id != turn_ref.session_id ->
        {:error, :stale_actor_key}

      delivery.activation_uid != turn_ref.activation_uid ->
        {:error, :stale_activation_uid}

      delivery.actor_epoch != turn_ref.actor_epoch ->
        {:error, :stale_actor_epoch}

      delivery.actor_event_id_fence != turn_ref.actor_event_id ->
        {:error, :stale_actor_event_id}

      not delivery_revision_matches?(
        delivery.revision,
        turn_ref.revision,
        revision_mode
      ) ->
        {:error, :stale_revision}

      true ->
        :ok
    end
  end

  # Acceptance demands an exact revision match. Final commits tolerate newer
  # mailbox revisions because active steer updates the same worker run before the
  # original turn eventually completes.
  defp delivery_revision_matches?(revision, turn_revision, :exact_revision),
    do: revision == turn_revision

  defp delivery_revision_matches?(revision, turn_revision, :minimum_revision),
    do: revision >= turn_revision
end
