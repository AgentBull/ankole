defmodule Ankole.SignalsGateway.ActorRuntime.TurnLifecycle do
  @moduledoc false

  import Ecto.Query, warn: false
  import Ankole.SignalsGateway.ActorRuntime.Common

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.TurnEnvelope
  alias Ankole.SignalsGateway.ActorRuntime.TurnStartFailure
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool
  alias Ankole.I18n
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway.ActorRuntime.TurnPolicy
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.BackgroundAgentJobs

  require Ankole.BackgroundAgentJobs

  @live_activation_statuses ~w(starting active draining)
  @activation_progress_lease_seconds 2_100
  @activation_lease_grace_seconds 120
  @worker_turn_error_dead_letter_attempts 5
  @worker_turn_error_retry_base_seconds 5
  @worker_turn_error_retry_max_seconds 120

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Starts one worker-backed run for a ready actor event.

  This is the control-plane side of the local actor loop. Normal text turns
  ensure an AIGateway conversation exists. Non-conversation work such as a
  BackgroundAgentJob passes `conversation: :none` and still receives the same
  activation, lease, delivery, and revision fences.

  A caller may provide `admit_in_tx: (repo -> :ok | {:error, term()})` when its
  own durable admission must commit with worker assignment and turn fences. The
  callback must not perform external side effects.
  """
  @spec start_worker_turn(actor_key(), ActorEvent.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_worker_turn(actor_key, %ActorEvent{} = actor_event, opts \\ []) do
    actor_key = normalize_actor_key(actor_key)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    turn_start_spec_result = prepare_turn_start_spec(actor_key, opts)

    Repo.transact(fn repo ->
      with {:ok, assignment} <- WorkerPool.assign_worker_in_tx(repo, actor_key, now),
           :ok <- run_admission_in_tx(repo, opts),
           {:ok, turn_start_spec} <- turn_start_spec_result,
           {:ok, activation} <- ensure_activation(repo, actor_key, assignment, now, opts),
           {:ok, conversation} <-
             ensure_and_lock_turn_conversation_in_tx(repo, actor_key, actor_event, opts),
           {:ok, activation} <-
             bind_activation_turn(repo, activation, actor_event.id, now),
           {:ok, delivery} <-
             create_event_delivery_in_tx(repo, actor_event, activation, assignment, now) do
        deliveries = [delivery]
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
           actor_event: actor_event,
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
    |> TurnStartFailure.finalize(actor_event, now)
  end

  defp run_admission_in_tx(repo, opts) do
    case Keyword.get(opts, :admit_in_tx) do
      callback when is_function(callback, 1) ->
        case callback.(repo) do
          :ok ->
            :ok

          {:error, _reason} = error ->
            error

          other ->
            {:error, {:invalid_turn_admission_result, other}}
        end

      nil ->
        :ok

      other ->
        {:error, {:invalid_turn_admission_callback, other}}
    end
  end

  defp prepare_turn_start_spec(actor_key, opts) do
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

        {:ok, %{request_context: request_context}}

      :required ->
        TurnPolicy.build_turn_start_spec(actor_key, opts)

      mode ->
        {:error, {:invalid_turn_conversation_mode, mode}}
    end
  end

  defp ensure_and_lock_turn_conversation_in_tx(repo, actor_key, actor_event, opts) do
    case Keyword.get(opts, :conversation, :required) do
      :none ->
        {:ok, nil}

      :required ->
        AIGatewayLink.ensure_and_lock_conversation_in_tx(
          repo,
          actor_key.agent_uid,
          actor_key.session_id,
          actor_event
        )
    end
  end

  defp mark_delivery_sent(delivery_id, send_outcome) do
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
  @spec handle_turn_accepted(FabricProto.TurnAccepted.t()) ::
          {:ok, [ActorEventDelivery.t()]} | {:error, term()}
  def handle_turn_accepted(%FabricProto.TurnAccepted{} = payload) do
    with {:ok, turn_ref} <- TurnRef.from_proto(payload.turn) do
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
  @spec handle_worker_progress(FabricProto.WorkerProgress.t(), keyword()) ::
          {:ok, ActorSessionActivation.t()} | {:error, term()}
  def handle_worker_progress(%FabricProto.WorkerProgress{} = payload, opts \\ []) do
    with {:ok, turn_ref} <- TurnRef.from_proto(payload.turn) do
      now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
      lease_seconds = Keyword.get(opts, :lease_seconds, @activation_progress_lease_seconds)

      with {:ok, activation} <-
             Repo.transact(fn repo ->
               with %ActorSessionActivation{} = activation <-
                      activation_for_turn_ref(repo, turn_ref),
                    :ok <- activation_accepts_progress(activation, turn_ref, now) do
                 renew_activation_lease(repo, activation, now, lease_seconds)
               else
                 nil -> {:error, :actor_runtime_fence_not_found}
                 {:error, _reason} = error -> error
               end
             end) do
        forward_reply_presentation(payload, turn_ref, opts)
        {:ok, activation}
      end
    end
  end

  defp forward_reply_presentation(%FabricProto.WorkerProgress{} = payload, turn_ref, opts) do
    refs = decode_json_bytes(payload.refs_json)
    event = if is_map(refs), do: Map.get(refs, "presentation_event")

    if payload.kind == "reply_presentation" and is_map(event) do
      callback = Keyword.get(opts, :presentation_event_fun, &AIReplyPreview.presentation_event/2)
      callback.(turn_ref.actor_event_id, event)
    end

    :ok
  end

  @doc """
  Completes a worker turn that deliberately adopts no provider-visible output.

  This is only for runtime decisions that consume an actor event without
  provider-visible output, such as ambient silence. Normal text turns complete
  through an explicit `turn_completed` carrying the adopted Response id.
  """
  @spec handle_turn_noop_completed(FabricProto.TurnNoopCompleted.t()) ::
          {:ok, map()} | {:error, term()}
  def handle_turn_noop_completed(%FabricProto.TurnNoopCompleted{} = payload) do
    with {:ok, turn_ref} <- TurnRef.from_proto(payload.turn) do
      reason = presence(payload.reason) || "noop_completed"
      now = DateTime.utc_now(:microsecond)

      Repo.transact(fn repo ->
        case lock_actor_event_for_turn_ref(repo, turn_ref) do
          %ActorEvent{completed_at: %DateTime{}} = event ->
            {:ok,
             %{
               status: :already_completed,
               reason: reason,
               actor_event: event,
               activation: activation_snapshot_for_turn_ref(repo, turn_ref),
               delivery_count: 0,
               deleted_deliveries: 0,
               superseded_deliveries: 0
             }}

          %ActorEvent{} = event ->
            with %ActorSessionActivation{} = activation <-
                   activation_for_turn_ref(repo, turn_ref),
                 :ok <- activation_accepts_progress(activation, turn_ref, now),
                 {:ok, deliveries} <- live_deliveries_for_noop(repo, event, turn_ref),
                 {:ok, _completed_events} <-
                   mark_noop_delivery_events_completed(repo, deliveries, now),
                 {:ok, event} <- mark_noop_event_completed(repo, event, now),
                 {deleted_count, superseded_count} <-
                   cleanup_noop_deliveries(repo, turn_ref.actor_event_id, now, reason),
                 :ok <-
                   Ankole.BackgroundAgentJobs.Lifecycle.finalize_worker_turn_in_tx(
                     repo,
                     turn_ref,
                     now
                   ),
                 {:ok, activation} <- mark_activation_idle_in_tx(repo, activation, now) do
              {:ok,
               %{
                 status: :noop_completed,
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

          nil ->
            {:error, :actor_runtime_fence_not_found}
        end
      end)
      |> stop_preview_after_terminal(turn_ref.actor_event_id)
    end
  end

  defp stop_preview_after_terminal({:ok, _result} = success, actor_event_id) do
    AIReplyPreview.stop(actor_event_id)
    success
  end

  defp stop_preview_after_terminal({:error, _reason} = error, _actor_event_id), do: error

  @doc """
  Handles a worker turn error without consuming the actor event.

  The event stays `open` for retry until repeated worker failures cross the
  dead-letter threshold. Runtime fences are superseded and the activation is
  failed so late replies from the failed attempt cannot match a later retry.
  """
  @spec handle_turn_error(FabricProto.TurnError.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def handle_turn_error(%FabricProto.TurnError{} = payload, opts \\ []) do
    with {:ok, turn_ref} <- TurnRef.from_proto(payload.turn) do
      reason = turn_error_reason(payload)
      now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
      compensate_in_tx = Keyword.get(opts, :compensate_turn_error_in_tx)

      Repo.transact(fn repo ->
        with %ActorEvent{} = event <- lock_actor_event_for_turn_ref(repo, turn_ref),
             %ActorSessionActivation{} = activation <- activation_for_turn_ref(repo, turn_ref),
             :ok <- activation_accepts_progress(activation, turn_ref, now),
             {:ok, deliveries} <- live_deliveries_for_turn_ref(repo, turn_ref),
             {:ok, event} <- maybe_mark_overflow_retry(repo, event, reason),
             dead_letter? = dead_letter_after_turn_error?(event, deliveries, reason),
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
             {:ok, _dead_letter_notice} <-
               maybe_commit_dead_letter_notice(repo, event, dead_letter?),
             {:ok, activation} <- fail_activation_for_turn_error(repo, activation, reason, now),
             {:ok, compensation} <-
               compensate_turn_error_in_tx(compensate_in_tx, repo, event, reason, now) do
          {:ok,
           maybe_put_turn_error_compensation(
             %{
               status: if(dead_letter?, do: :turn_dead_lettered, else: :turn_failed),
               reason: reason,
               actor_event: event,
               activation: activation,
               delivery_count: length(deliveries),
               superseded_deliveries: superseded_count,
               dead_lettered?: dead_letter?,
               retry_available_at: retry_available_at(event)
             },
             compensation
           )}
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
          %{
            assignment: assignment,
            envelope: envelope,
            deliveries: deliveries,
            actor_event: actor_event,
            conversation: conversation
          } =
            result}
       ) do
    maybe_start_preview(actor_event, conversation)
    route = assignment.transport_route || assignment.worker_id

    case Broker.send_mandatory(route, envelope) do
      {:ok, :sent_or_queued} ->
        Enum.each(deliveries, &mark_delivery_sent(&1.id, "sent_or_queued"))
        {:ok, Map.put(result, :send_outcome, "sent_or_queued")}

      {:error, reason} ->
        AIReplyPreview.stop(actor_event.id)
        Enum.each(deliveries, &mark_delivery_failed(&1.id, reason, reason))
        WorkerAdmission.mark_route_unusable(route, reason)
        {:ok, Map.put(result, :send_outcome, reason_text(reason))}
    end
  end

  defp send_turn_start({:error, _reason} = error), do: error

  defp maybe_start_preview(%ActorEvent{} = actor_event, %{id: conversation_id}) do
    _ = AIReplyPreview.maybe_start_for(actor_event, actor_event.agent_uid, conversation_id)
    :ok
  end

  defp maybe_start_preview(_actor_event, _conversation), do: :ok

  @doc false
  @spec live_delivery_for_session?(module(), actor_key()) :: boolean()
  def live_delivery_for_session?(repo, actor_key) do
    ActorEventDelivery
    |> where([delivery], delivery.agent_uid == ^actor_key.agent_uid)
    |> where([delivery], delivery.session_id == ^actor_key.session_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> repo.exists?()
  end

  @doc false
  @spec fail_worker_activations_in_tx(module(), String.t(), DateTime.t(), term()) ::
          {:ok, %{count: non_neg_integer(), actor_keys: [actor_key()]}} | {:error, term()}
  def fail_worker_activations_in_tx(repo, worker_id, now, reason) when is_binary(worker_id) do
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
      {:ok, failed_activations} ->
        actor_keys =
          failed_activations
          |> Enum.map(&%{agent_uid: &1.agent_uid, session_id: &1.session_id})
          |> Enum.uniq()

        {:ok, %{count: length(failed_activations), actor_keys: actor_keys}}

      {:error, _reason} = error ->
        error
    end
  end

  def fail_worker_activations_in_tx(_repo, _worker_id, _now, _reason),
    do: {:ok, %{count: 0, actor_keys: []}}

  @doc false
  @spec cancel_started_turn_in_tx(
          module(),
          actor_key(),
          Ecto.UUID.t() | nil,
          DateTime.t(),
          term()
        ) ::
          {:ok, map() | nil} | {:error, term()}
  def cancel_started_turn_in_tx(_repo, _actor_key, nil, _now, _reason), do: {:ok, nil}

  def cancel_started_turn_in_tx(repo, actor_key, actor_event_id, now, reason) do
    with {:ok, cancelled_turn} <-
           AIGatewayLink.cancel_generating_turn_in_tx(
             repo,
             actor_key,
             actor_event_id,
             now,
             reason
           ),
         {_count, _rows} <-
           supersede_turn_deliveries_by_actor_event_id(actor_event_id, repo, now, reason) do
      {:ok, cancelled_turn}
    end
  end

  @doc false
  @spec supersede_started_turn_in_tx(
          module(),
          actor_key(),
          Ecto.UUID.t() | nil,
          DateTime.t(),
          String.t()
        ) ::
          {:ok, map() | nil} | {:error, term()}
  def supersede_started_turn_in_tx(_repo, _actor_key, nil, _now, _reason), do: {:ok, nil}

  def supersede_started_turn_in_tx(repo, actor_key, actor_event_id, now, reason) do
    with {:ok, retracted_turn} <-
           AIGatewayLink.retract_generating_turn_in_tx(
             repo,
             actor_key,
             actor_event_id,
             now,
             reason
           ),
         {_count, _rows} <-
           supersede_turn_deliveries_by_actor_event_id(actor_event_id, repo, now, reason) do
      {:ok, retracted_turn}
    end
  end

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot, do: activation_deadline_events()

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

  # Reuses a live activation when its lease is valid, otherwise fails the old
  # activation before creating a new actor epoch. The epoch is the cheap fence
  # that makes late worker replies harmless.
  defp ensure_activation(repo, actor_key, assignment, now, opts) do
    case lock_live_activation(repo, actor_key) do
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

  @doc false
  @spec mark_activation_idle_in_tx(module(), ActorSessionActivation.t(), DateTime.t()) ::
          {:ok, ActorSessionActivation.t()} | {:error, term()}
  def mark_activation_idle_in_tx(repo, %ActorSessionActivation{} = activation, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      status: "active",
      current_actor_event_id: nil,
      lease_expires_at: DateTime.add(now, @activation_progress_lease_seconds, :second)
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

  # Records a concrete attempt to deliver an actor event to a worker turn, then
  # compacts obsolete failed/superseded attempts for the same event.
  @doc false
  @spec create_event_delivery_in_tx(
          module(),
          ActorEvent.t(),
          ActorSessionActivation.t(),
          ActorSessionWorkerAssignment.t(),
          DateTime.t()
        ) :: {:ok, ActorEventDelivery.t()} | {:error, term()}
  def create_event_delivery_in_tx(
        repo,
        %ActorEvent{} = actor_event,
        %ActorSessionActivation{} = activation,
        %ActorSessionWorkerAssignment{} = assignment,
        now
      ) do
    attempt_no = next_attempt_no(repo, actor_event.id)
    actor_lane_message_id = "turn-start-" <> Ecto.UUID.generate()
    route = assignment.transport_route || assignment.worker_id

    # Source tables: actor_event_* values copy actor_events, activation_* and
    # revision copy actor_session_activations, and correlation_id mirrors the
    # actor lane message id for transport tracing.
    attrs = %{
      actor_event_id: actor_event.id,
      agent_uid: actor_event.agent_uid,
      session_id: actor_event.session_id,
      queue_sequence: actor_event.queue_sequence,
      attempt_no: attempt_no,
      actor_lane_message_id: actor_lane_message_id,
      correlation_id: actor_lane_message_id,
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
  @doc false
  @spec lock_live_activation(module(), actor_key()) :: ActorSessionActivation.t() | nil
  def lock_live_activation(repo, actor_key) do
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
         "lease_expires_at" => RuntimeEvents.encode_datetime(activation.lease_expires_at),
         "due_at" => RuntimeEvents.encode_datetime(activation_deadline_at(activation))
       }}
    end)
  end

  defp notify_activation_deadline({:ok, %ActorSessionActivation{} = activation}, repo) do
    with :ok <-
           RuntimeEvents.notify_activation_deadline(
             repo,
             activation,
             activation_deadline_at(activation)
           ) do
      {:ok, activation}
    end
  end

  defp notify_activation_deadline({:error, _reason} = error, _repo), do: error

  defp activation_deadline_at(%ActorSessionActivation{} = activation),
    do: DateTime.add(activation.lease_expires_at, @activation_lease_grace_seconds, :second)

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
  # Lock the worker first so worker-originated progress/error paths share the
  # placement and admission prefix instead of forming worker/agent/activation
  # lock cycles during recovery.
  defp activation_for_turn_ref(repo, turn_ref) do
    case activation_snapshot_for_turn_ref(repo, turn_ref) do
      %ActorSessionActivation{assigned_worker_id: worker_id} when is_binary(worker_id) ->
        with %AgentComputerWorker{} <- lock_activation_worker(repo, worker_id) do
          lock_activation_for_turn_ref(repo, turn_ref, worker_id)
        else
          nil -> nil
        end

      _activation ->
        nil
    end
  end

  defp activation_snapshot_for_turn_ref(repo, turn_ref) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^turn_ref.agent_uid)
    |> where([activation], activation.session_id == ^turn_ref.session_id)
    |> where([activation], activation.activation_uid == ^turn_ref.activation_uid)
    |> repo.one()
  end

  defp lock_activation_worker(repo, worker_id) do
    AgentComputerWorker
    |> where([worker], worker.worker_id == ^worker_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_activation_for_turn_ref(repo, turn_ref, worker_id) do
    ActorSessionActivation
    |> where([activation], activation.agent_uid == ^turn_ref.agent_uid)
    |> where([activation], activation.session_id == ^turn_ref.session_id)
    |> where([activation], activation.activation_uid == ^turn_ref.activation_uid)
    |> where([activation], activation.assigned_worker_id == ^worker_id)
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

  defp live_deliveries_for_noop(repo, %ActorEvent{}, turn_ref) do
    live_deliveries_for_turn_ref(repo, turn_ref)
  end

  defp mark_noop_delivery_events_completed(_repo, [], _now), do: {:ok, []}

  defp mark_noop_delivery_events_completed(repo, deliveries, now) do
    deliveries
    |> Enum.filter(&(&1.state == "accepted"))
    |> Enum.uniq_by(& &1.actor_event_id)
    |> Enum.reduce_while({:ok, []}, fn delivery, {:ok, completed_events} ->
      case Actors.lock_actor_event_in_tx(repo, delivery.actor_event_id) do
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

  # A durable Job owns the retry budget for its wake events: recoverable worker
  # errors keep the event open until `BackgroundAgentJobs` exhausts the job
  # attempts, fails the Job, and wakes the owner. The delivery-attempt
  # dead-letter threshold only bounds ordinary actor events.
  defp dead_letter_after_turn_error?(
         %ActorEvent{session_id: session_id},
         _deliveries,
         reason
       )
       when BackgroundAgentJobs.is_job_session_id(session_id) do
    not recoverable_turn_error?(reason)
  end

  defp dead_letter_after_turn_error?(%ActorEvent{}, deliveries, reason) do
    not recoverable_turn_error?(reason) or
      max_delivery_attempt_no(deliveries) >= @worker_turn_error_dead_letter_attempts
  end

  defp recoverable_turn_error?(reason),
    do: retryable_turn_error?(reason) or overflow_turn_error?(reason)

  defp maybe_mark_event_dead_letter(repo, %ActorEvent{} = event, true, now) do
    Actors.mark_event_dead_letter_in_tx(repo, event, now)
  end

  defp maybe_mark_event_dead_letter(_repo, %ActorEvent{} = event, false, _now), do: {:ok, event}

  # The dead-letter row and its provider-visible terminal intent are one durable
  # fact. Committing them in separate transactions leaves an accepted message
  # permanently silent if the control plane exits between the two writes.
  defp maybe_commit_dead_letter_notice(repo, %ActorEvent{} = event, true) do
    if AIReplyPreview.im_visible_event?(event) do
      text = I18n.t("signals_gateway.reply.dead_letter", %{"ref" => event.id})
      Outbox.commit_dead_letter_notice_outbox_in_tx(repo, event, text)
    else
      {:ok, nil}
    end
  end

  defp maybe_commit_dead_letter_notice(_repo, %ActorEvent{}, false), do: {:ok, nil}

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

  defp turn_error_reason(%FabricProto.TurnError{} = payload) do
    %{
      "code" => presence(payload.code) || "worker_turn_error",
      "message" => presence(payload.message) || "worker turn failed",
      "details_json" => decode_json_bytes(payload.details_json) || %{}
    }
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp compensate_turn_error_in_tx(nil, _repo, %ActorEvent{}, _reason, _now), do: {:ok, nil}

  defp compensate_turn_error_in_tx(callback, repo, %ActorEvent{} = event, reason, now)
       when is_function(callback, 4) do
    case callback.(repo, event, reason, now) do
      {:ok, _compensation} = success -> success
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_turn_error_compensation_result, other}}
    end
  end

  defp compensate_turn_error_in_tx(callback, _repo, %ActorEvent{}, _reason, _now),
    do: {:error, {:invalid_turn_error_compensation_callback, callback}}

  defp maybe_put_turn_error_compensation(result, nil), do: result

  defp maybe_put_turn_error_compensation(result, compensation),
    do: Map.put(result, :turn_error_compensation, compensation)

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

  defp lock_delivery(repo, delivery_id) do
    ActorEventDelivery
    |> where([delivery], delivery.id == ^delivery_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  # A live activation with no current event is warm but idle. Expiry is a normal
  # stop, not worker failure, so it must not create retry or error evidence.
  defp fail_expired_activation(
         repo,
         %ActorSessionActivation{current_actor_event_id: nil} = activation,
         now
       ) do
    stop_idle_activation(repo, activation, now)
  end

  # Fails an activation with a current turn and clears all related live fences.
  # This lets the same open actor event be selected again on the next pass.
  defp fail_expired_activation(repo, %ActorSessionActivation{} = activation, now) do
    if actor_event_completed?(repo, activation.current_actor_event_id) do
      stop_idle_activation(repo, activation, now)
    else
      with {:ok, _failed_message} <-
             AIGatewayLink.fail_generating_turn_in_tx(
               repo,
               activation_actor_key(activation),
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
  end

  defp actor_event_completed?(repo, actor_event_id) do
    ActorEvent
    |> where([event], event.id == ^actor_event_id)
    |> where([event], not is_nil(event.completed_at))
    |> repo.exists?()
  end

  defp stop_idle_activation(repo, %ActorSessionActivation{} = activation, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      status: "stopped",
      current_actor_event_id: nil,
      stopped_at: now,
      stop_reason: inspect(:activation_idle_timeout)
    })
    |> repo.update()
  end

  defp fail_worker_activation(repo, %ActorSessionActivation{} = activation, now, reason) do
    with {:ok, _failed_message} <-
           AIGatewayLink.fail_generating_turn_in_tx(
             repo,
             activation_actor_key(activation),
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
      mark_activation_failed(repo, activation, reason, now)
    end
  end

  defp fail_activation(repo, %ActorSessionActivation{} = activation, reason, now) do
    actor_event_id = activation.current_actor_event_id

    with {:ok, activation} <- mark_activation_failed(repo, activation, reason, now),
         :ok <- notify_actor_event_ready(repo, actor_event_id, now) do
      {:ok, activation}
    end
  end

  defp mark_activation_failed(repo, %ActorSessionActivation{} = activation, reason, now) do
    activation
    |> ActorSessionActivation.changeset(%{
      status: "failed",
      current_actor_event_id: nil,
      stopped_at: now,
      stop_reason: inspect(reason)
    })
    |> repo.update()
  end

  # Marks live delivery projections obsolete without deleting them. Keeping the
  # row records why a worker reply should no longer be accepted.
  defp supersede_turn_deliveries_by_actor_event_id(nil, _repo, _now, _reason), do: {0, nil}

  defp supersede_turn_deliveries_by_actor_event_id(actor_event_id, repo, now, reason) do
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

  defp activation_actor_key(%ActorSessionActivation{} = activation) do
    %{agent_uid: activation.agent_uid, session_id: activation.session_id}
  end

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
