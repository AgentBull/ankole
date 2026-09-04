defmodule Ankole.SignalsGateway.ActorRuntime.TurnLifecycle do
  @moduledoc false

  import Ecto.Query, warn: false
  import Ankole.SignalsGateway.ActorRuntime.Common

  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.ChannelContext
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.DeadLetterNoticeConfig
  alias Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit
  alias Ankole.SignalsGateway.ActorRuntime.SessionWorkspaces
  alias Ankole.SignalsGateway.ActorRuntime.TurnEnvelope
  alias Ankole.SignalsGateway.ActorRuntime.TurnRuntimeEnv
  alias Ankole.SignalsGateway.ActorRuntime.TurnStartFailure
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool
  alias Ankole.I18n
  alias Ankole.Logging
  alias Ankole.Observability
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway.ActorRuntime.TurnPolicy
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.Sanitizer

  # Keep a responsive Worker activation through long model or tool work.
  @activation_progress_lease_seconds 2_100
  # Prevent scheduler delay from expiring an activation at its exact deadline.
  @activation_lease_grace_seconds 120
  # Stop retry loops after repeated recoverable Worker failures. Each delivery
  # attempt lets the Worker retry one model call locally
  # (`app/agent_computer/src/core/pi-loop/stream-fn.ts`), so one actor event
  # can cost local attempts x this delivery count model calls before it
  # dead-letters.
  @worker_turn_error_dead_letter_attempts 5
  # Give a transient Worker failure a short recovery window before redispatch.
  @worker_turn_error_retry_base_seconds 5
  # Prevent repeated Worker failures from increasing one retry delay without
  # limit.
  @worker_turn_error_retry_max_seconds 120

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Starts one worker-backed run for a ready actor event.

  This is the control-plane side of the local actor loop. Normal text turns
  ensure an AIGateway conversation exists. Non-conversation work such as a
  BackgroundAgentJob passes `conversation: :none` and still receives the same
  activation, lease, delivery, and revision fences.

  A caller may provide `admit_in_tx: (repo, turn_start_spec -> result)` when its
  own durable admission must commit with worker assignment and turn fences. A
  successful callback returns `:ok` or `{:ok, turn_start_overrides}`. The
  callback must not perform external side effects.
  """
  @spec start_worker_turn(actor_key(), ActorEvent.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_worker_turn(actor_key, %ActorEvent{} = actor_event, opts \\ []) do
    actor_key = normalize_actor_key(actor_key)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    turn_start_spec_result = prepare_turn_start_spec(actor_key, actor_event, opts)
    job_limit = WorkerPool.job_turn_limit(actor_key)

    Repo.transact(fn repo ->
      with {:ok, assignment} <- WorkerPool.assign_worker_in_tx(repo, actor_key, now, job_limit),
           {:ok, turn_start_spec} <- turn_start_spec_result,
           {:ok, turn_start_overrides} <- run_admission_in_tx(repo, turn_start_spec, opts),
           turn_start_spec <- merge_turn_start_spec(turn_start_spec, turn_start_overrides),
           {:ok, workspace} <-
             SessionWorkspaces.ensure_in_tx(repo, actor_key.agent_uid, actor_key.session_id),
           turn_start_spec = Map.put(turn_start_spec, :workspace_id, workspace.id),
           {:ok, activation} <- ensure_activation(repo, actor_key, assignment, now, opts),
           {:ok, conversation} <-
             ensure_and_lock_turn_conversation_in_tx(repo, actor_key, actor_event, opts),
           {:ok, activation} <-
             bind_activation_turn(repo, activation, actor_event.id, now),
           {:ok, delivery} <-
             create_event_delivery_in_tx(repo, actor_event, activation, assignment, now) do
        deliveries = [delivery]
        turn_ref = TurnEnvelope.turn_ref(actor_key, activation)

        delivered_actor_event =
          dedupe_delivered_channel_context(actor_event, actor_key, conversation)

        {:ok,
         %{
           actor_event: actor_event,
           activation: activation,
           assignment: assignment,
           conversation: conversation,
           delivered_actor_event: delivered_actor_event,
           deliveries: deliveries,
           turn_ref: turn_ref,
           turn_start_spec: turn_start_spec
         }}
      else
        {:error, _reason} = error -> error
      end
    end)
    |> send_turn_start()
    |> TurnStartFailure.finalize(actor_event, now)
  end

  defp run_admission_in_tx(repo, turn_start_spec, opts) do
    case Keyword.get(opts, :admit_in_tx) do
      callback when is_function(callback, 2) ->
        normalize_admission_result(callback.(repo, turn_start_spec))

      callback when is_function(callback, 1) ->
        normalize_admission_result(callback.(repo))

      nil ->
        {:ok, %{}}

      other ->
        {:error, {:invalid_turn_admission_callback, other}}
    end
  end

  defp normalize_admission_result(:ok), do: {:ok, %{}}
  defp normalize_admission_result({:ok, %{} = overrides}), do: {:ok, overrides}
  defp normalize_admission_result({:error, _reason} = error), do: error

  defp normalize_admission_result(other),
    do: {:error, {:invalid_turn_admission_result, other}}

  defp merge_turn_start_spec(turn_start_spec, overrides) do
    request_context =
      turn_start_spec
      |> Map.get(:request_context, %{})
      |> Map.merge(Map.get(overrides, :request_context, %{}))

    turn_start_spec
    |> Map.merge(Map.delete(overrides, :request_context))
    |> Map.put(:request_context, request_context)
  end

  defp prepare_turn_start_spec(actor_key, actor_event, opts) do
    result =
      case Keyword.get(opts, :conversation, :required) do
        :none ->
          TurnPolicy.build_turn_start_spec(actor_key, opts)

        :required ->
          TurnPolicy.build_turn_start_spec(actor_key, opts)

        mode ->
          {:error, {:invalid_turn_conversation_mode, mode}}
      end

    with {:ok, turn_start_spec} <- result do
      {:ok, Map.put(turn_start_spec, :runtime_env, TurnRuntimeEnv.resolve(actor_event))}
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

  # The delivered envelope drops quoted context the conversation already holds;
  # the stored actor event keeps its full payload. Session turns are serialized,
  # so at this point the prior turn is terminal and visibility is definitive —
  # a rapid consecutive message no longer repeats its predecessor's quote block,
  # while a retracted turn's quotes come back on the next delivery.
  defp dedupe_delivered_channel_context(%ActorEvent{} = actor_event, _actor_key, nil),
    do: actor_event

  defp dedupe_delivered_channel_context(%ActorEvent{} = actor_event, actor_key, _conversation) do
    visible_refs =
      AIGatewayLink.visible_channel_context_refs(actor_key.agent_uid, actor_key.session_id)

    case MapSet.size(visible_refs) do
      0 ->
        actor_event

      _visible ->
        %{
          actor_event
          | payload: ChannelContext.drop_visible_messages(actor_event.payload, visible_refs)
        }
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
  @spec handle_turn_accepted(FabricProto.TurnAccepted.t(), keyword()) ::
          {:ok, [ActorEventDelivery.t()]} | {:error, term()}
  def handle_turn_accepted(%FabricProto.TurnAccepted{} = payload, opts \\ []) do
    with {:ok, turn_ref} <- TurnRef.from_proto(payload.turn) do
      accepted_actor_event_id = turn_ref.actor_event_id
      now = DateTime.utc_now(:microsecond)

      with {:ok, deliveries} <-
             Repo.transact(fn repo ->
               deliveries =
                 deliveries_for_turn_acceptance(repo, turn_ref)

               with :ok <- require_sent_event_accepted(deliveries, accepted_actor_event_id) do
                 deliveries
                 |> Enum.map(fn delivery ->
                   case delivery.state do
                     "accepted" ->
                       {:ok, delivery}

                     _pending ->
                       delivery
                       |> ActorEventDelivery.changeset(%{state: "accepted", accepted_at: now})
                       |> repo.update()
                   end
                 end)
                 |> collect_results()
               end
             end) do
        continue_reply_preview_on_accepted_steers(turn_ref.actor_event_id, deliveries, opts)
        {:ok, deliveries}
      end
    end
  end

  defp continue_reply_preview_on_accepted_steers(stream_actor_event_id, deliveries, opts) do
    continue_fun = Keyword.get(opts, :continue_reply_preview_fun, &AIReplyPreview.continue_on/2)

    deliveries
    |> Repo.preload(:actor_event)
    |> Enum.each(fn
      %ActorEventDelivery{actor_event: %ActorEvent{type: "command.steer"} = event} ->
        if AIReplyPreview.channel_reply_eligible?(event) do
          continue_fun.(stream_actor_event_id, event)
        end

      %ActorEventDelivery{} ->
        :ok
    end)
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
               rows = TurnRef.lookup(repo, turn_ref)

               with :ok <- TurnRef.match(rows, turn_ref, :progress, now: now) do
                 renew_activation_lease(repo, rows.activation, now, lease_seconds)
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

  @doc false
  @spec handle_turn_abort(TurnRef.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_turn_abort(%TurnRef{} = turn_ref, %{} = reason, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    async_work_unit = Keyword.get(opts, :async_work_unit)

    compensate_in_tx =
      Keyword.get(opts, :compensate_turn_error_in_tx, async_work_unit)

    Repo.transact(fn repo ->
      with %ActorEvent{} = event <- lock_actor_event_for_turn_ref(repo, turn_ref),
           rows = TurnRef.lookup(repo, turn_ref, deliveries: :live),
           %ActorSessionActivation{} = activation <- rows.activation do
        case prior_abort_result(repo, event, activation, turn_ref, reason) do
          {:ok, result} ->
            {:ok, result}

          :not_aborted ->
            abort_live_attempt_in_tx(
              repo,
              event,
              rows,
              turn_ref,
              reason,
              now,
              async_work_unit,
              compensate_in_tx
            )

          {:error, _reason} = error ->
            error
        end
      else
        nil -> {:error, :actor_runtime_fence_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp abort_live_attempt_in_tx(
         repo,
         event,
         %{activation: activation, deliveries: deliveries} = rows,
         turn_ref,
         reason,
         now,
         async_work_unit,
         compensate_in_tx
       ) do
    with :ok <- TurnRef.match(rows, turn_ref, :abort),
         {:ok, event} <- maybe_mark_overflow_retry(repo, event, reason),
         dead_letter? =
           dead_letter_after_turn_error?(event, deliveries, reason, async_work_unit),
         {superseded_count, _rows} <- supersede_live_deliveries(repo, turn_ref, now, reason),
         {:ok, event} <- maybe_mark_event_dead_letter(repo, event, dead_letter?, reason, now),
         {:ok, event} <-
           maybe_delay_retryable_turn_error(
             repo,
             event,
             deliveries,
             reason,
             now,
             dead_letter?,
             async_work_unit
           ),
         {:ok, _dead_letter_notice} <-
           maybe_commit_dead_letter_notice(repo, event, dead_letter?, reason),
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
    end
  end

  defp prior_abort_result(repo, event, activation, turn_ref, reason) do
    prior_reasons =
      turn_ref
      |> superseded_abort_deliveries()
      |> select([delivery], delivery.error)
      |> repo.all()
      |> Enum.map(&Map.get(&1, "reason"))
      |> Enum.uniq()

    expected_reason = inspect(reason)

    cond do
      ActorSessionActivation.live?(activation) ->
        :not_aborted

      activation.status == "failed" and prior_reasons == [expected_reason] and
          activation.stop_reason == expected_reason ->
        {:ok,
         %{
           status: :already_aborted,
           reason: reason,
           actor_event: event,
           activation: activation,
           delivery_count: 0,
           superseded_deliveries: 0,
           dead_lettered?: event.input_state == "dead_letter",
           retry_available_at: retry_available_at(event)
         }}

      activation.status == "failed" and prior_reasons != [] ->
        {:error, :actor_turn_abort_conflict}

      true ->
        :not_aborted
    end
  end

  @doc false
  @spec aborted_delivery_exists_in_tx(module(), TurnRef.t()) :: boolean()
  def aborted_delivery_exists_in_tx(repo, %TurnRef{} = turn_ref) do
    turn_ref
    |> superseded_abort_deliveries()
    |> repo.exists?()
  end

  defp superseded_abort_deliveries(turn_ref) do
    ActorEventDelivery
    |> where([delivery], delivery.agent_uid == ^turn_ref.agent_uid)
    |> where([delivery], delivery.session_id == ^turn_ref.session_id)
    |> where([delivery], delivery.activation_uid == ^turn_ref.activation_uid)
    |> where([delivery], delivery.actor_epoch == ^turn_ref.actor_epoch)
    |> where([delivery], delivery.actor_event_id_fence == ^turn_ref.actor_event_id)
    |> where([delivery], delivery.revision <= ^turn_ref.revision)
    |> where([delivery], delivery.state == "superseded")
  end

  # Builds and sends the turn-start envelope after the transaction has
  # committed. The turn span starts here, outside the transaction, so the
  # canonical trace facts can join the request context before the one envelope
  # build.
  # A failed send invalidates the route and leaves delivery rows as retryable
  # runtime projections instead of rolling back the durable turn.
  defp send_turn_start(
         {:ok,
          %{
            assignment: assignment,
            deliveries: deliveries,
            actor_event: actor_event,
            conversation: conversation,
            delivered_actor_event: delivered_actor_event,
            turn_ref: turn_ref,
            turn_start_spec: turn_start_spec
          } =
            result}
       ) do
    request_context =
      turn_start_spec
      |> Map.get(:request_context, %{})
      |> Map.drop(["traceparent", "observability_user_id"])

    turn_start_spec =
      case Observability.start_turn(actor_event, turn_start_spec) do
        %{traceparent: traceparent, user_id: user_id} ->
          request_context =
            request_context
            |> Map.put("traceparent", traceparent)
            |> maybe_put_observability_user_id(user_id)

          Map.put(turn_start_spec, :request_context, request_context)

        nil ->
          Map.put(turn_start_spec, :request_context, request_context)
      end

    envelope =
      TurnEnvelope.turn_start(turn_ref, delivered_actor_event, deliveries, turn_start_spec)

    result =
      result
      |> Map.put(:turn_start_spec, turn_start_spec)
      |> Map.put(:envelope, envelope)

    maybe_start_preview(actor_event, conversation)
    route = assignment.transport_route || assignment.worker_id

    case Broker.send_mandatory(route, envelope) do
      {:ok, :sent_or_queued} ->
        Enum.each(deliveries, &mark_delivery_sent(&1.id, "sent_or_queued"))
        {:ok, Map.put(result, :send_outcome, "sent_or_queued")}

      {:error, reason} ->
        Observability.finish_turn(actor_event.id, error_type: "turn_start_send_failed")
        AIReplyPreview.stop(actor_event.id)
        Enum.each(deliveries, &mark_delivery_failed(&1.id, reason, reason))
        WorkerAdmission.mark_route_unusable(route, reason)
        {:ok, Map.put(result, :send_outcome, reason_text(reason))}
    end
  end

  defp send_turn_start({:error, _reason} = error), do: error

  defp maybe_put_observability_user_id(request_context, user_id) when is_binary(user_id),
    do: Map.put(request_context, "observability_user_id", user_id)

  defp maybe_put_observability_user_id(request_context, _user_id), do: request_context

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
      |> where([activation], activation.status in ^ActorSessionActivation.live_statuses())
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
            not ActorSessionActivation.live?(activation) ->
              {:error, :activation_not_due}

            ActorSessionActivation.lease_alive?(activation, cutoff) ->
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
        case ActorSessionActivation.lease_alive?(activation, now) do
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
    |> where([activation], activation.status in ^ActorSessionActivation.live_statuses())
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
    |> where([activation], activation.status in ^ActorSessionActivation.live_statuses())
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

  defp lock_actor_event_for_turn_ref(repo, turn_ref) do
    ActorEvent
    |> where([event], event.id == ^turn_ref.actor_event_id)
    |> where([event], event.agent_uid == ^turn_ref.agent_uid)
    |> where([event], event.session_id == ^turn_ref.session_id)
    |> lock("FOR UPDATE")
    |> repo.one()
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

  defp dead_letter_after_turn_error?(
         %ActorEvent{} = event,
         _deliveries,
         reason,
         async_work_unit
       )
       when is_atom(async_work_unit) and not is_nil(async_work_unit) do
    async_work_unit.dead_letter_after_turn_error?(
      event,
      reason,
      recoverable_turn_error?(reason)
    )
  end

  defp dead_letter_after_turn_error?(
         %ActorEvent{},
         deliveries,
         reason,
         nil
       ) do
    not recoverable_turn_error?(reason) or
      max_delivery_attempt_no(deliveries) >= @worker_turn_error_dead_letter_attempts
  end

  defp recoverable_turn_error?(reason),
    do: retryable_turn_error?(reason) or overflow_turn_error?(reason)

  defp maybe_mark_event_dead_letter(repo, %ActorEvent{} = event, true, reason, now) do
    Actors.mark_event_dead_letter_in_tx(repo, event, now, reason)
  end

  defp maybe_mark_event_dead_letter(_repo, %ActorEvent{} = event, false, _reason, _now),
    do: {:ok, event}

  # The dead-letter row and its provider-visible terminal intent are one durable
  # fact. Committing them in separate transactions leaves an accepted message
  # permanently silent if the control plane exits between the two writes.
  defp maybe_commit_dead_letter_notice(
         repo,
         %ActorEvent{} = event,
         true,
         reason
       ) do
    if AIReplyPreview.channel_reply_eligible?(event) do
      text = dead_letter_notice_text(repo, event, reason)

      case Outbox.commit_dead_letter_notice_outbox_in_tx(repo, event, text) do
        {:ok, notice} -> {:ok, notice}
        {:error, reason} -> skip_unroutable_dead_letter_notice(event, reason)
      end
    else
      {:ok, nil}
    end
  end

  defp maybe_commit_dead_letter_notice(_repo, %ActorEvent{}, false, _reason),
    do: {:ok, nil}

  defp dead_letter_notice_text(%ActorEvent{} = event),
    do: I18n.t("signals_gateway.reply.dead_letter", %{"ref" => event.id})

  defp dead_letter_notice_text(repo, %ActorEvent{} = event, reason) do
    text = AsyncWorkUnit.dead_letter_notice_text(event) || dead_letter_notice_text(event)

    if DeadLetterNoticeConfig.enabled_in_tx?(repo) do
      detail = Sanitizer.preview(reason)

      text <>
        "\n" <>
        I18n.t("signals_gateway.reply.dead_letter_error_details", %{"detail" => detail})
    else
      text
    end
  end

  # A deleted route, or a channel that never accepts replies, has nowhere to put
  # this notice. Failing here would roll back whichever transaction decided the
  # dead letter — a worker takeover, a worker expiry, or a turn abort — so one
  # unreachable old event could stop a whole worker from being replaced. The
  # dead-lettered event row remains the checkable record of that failure.
  defp skip_unroutable_dead_letter_notice(%ActorEvent{} = event, reason) do
    if Outbox.unroutable_reply_reason?(reason) do
      Logging.warning(
        "signals_gateway.actor_runtime.dead_letter_notice_unroutable",
        "actor dead letter notice has no reachable route",
        %{
          actor_event_id: event.id,
          agent_uid: event.agent_uid,
          binding_name: event.binding_name,
          reason: inspect(reason, limit: 20)
        }
      )

      {:ok, nil}
    else
      {:error, reason}
    end
  end

  defp maybe_delay_retryable_turn_error(
         _repo,
         %ActorEvent{} = event,
         _deliveries,
         _reason,
         _now,
         true,
         _async_work_unit
       ),
       do: {:ok, event}

  defp maybe_delay_retryable_turn_error(
         repo,
         %ActorEvent{} = event,
         deliveries,
         reason,
         now,
         false,
         async_work_unit
       ) do
    if retryable_turn_error?(reason) do
      retry_available_at =
        turn_error_retry_at(deliveries, reason, now, async_work_unit)

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

  defp turn_error_retry_at(deliveries, reason, now, async_work_unit)
       when is_atom(async_work_unit) and not is_nil(async_work_unit) do
    attempt_no = max(max_delivery_attempt_no(deliveries), 1)
    async_work_unit.turn_error_retry_at(reason, attempt_no, now)
  end

  defp turn_error_retry_at(deliveries, _reason, now, nil) do
    attempt_no = max(max_delivery_attempt_no(deliveries), 1)
    exponential = round(@worker_turn_error_retry_base_seconds * :math.pow(2, attempt_no - 1))
    DateTime.add(now, min(exponential, @worker_turn_error_retry_max_seconds), :second)
  end

  defp max_delivery_attempt_no(deliveries) do
    case Enum.map(deliveries, & &1.attempt_no) do
      [] -> 0
      attempt_numbers -> Enum.max(attempt_numbers)
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

  defp compensate_turn_error_in_tx(module, repo, %ActorEvent{} = event, reason, now)
       when is_atom(module) and not is_nil(module) do
    case module.compensate_turn_error_in_tx(repo, event, reason, now) do
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

  defp fail_worker_activation(
         repo,
         %ActorSessionActivation{current_actor_event_id: nil} = activation,
         now,
         reason
       ) do
    mark_activation_failed(repo, activation, reason, now)
  end

  defp fail_worker_activation(repo, %ActorSessionActivation{} = activation, now, reason) do
    actor_key = activation_actor_key(activation)
    actor_event_id = activation.current_actor_event_id

    case prepare_worker_loss_retry(repo, actor_key, actor_event_id, now) do
      {:ok, :retry} ->
        fail_replayable_worker_turn(repo, activation, actor_key, actor_event_id, now, reason)

      {:ok, :dead_letter} ->
        dead_letter_unacknowledged_worker_turn(
          repo,
          activation,
          actor_key,
          actor_event_id,
          now,
          reason
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_worker_loss_retry(repo, actor_key, actor_event_id, now) do
    if AIGatewayLink.turn_replay_safe_in_tx(repo, actor_key, actor_event_id) do
      case AIGatewayLink.retract_visible_turn_suffix_in_tx(
             repo,
             actor_key.agent_uid,
             actor_key.session_id,
             actor_event_id,
             now,
             reason: "worker_lost_before_turn_completion"
           ) do
        {:ok, %{status: :retracted}} -> {:ok, :retry}
        {:ok, %{status: :noop, reason: reason}} when reason != :not_visible_tail -> {:ok, :retry}
        {:ok, %{status: :noop}} -> {:ok, :dead_letter}
        {:error, _reason} = error -> error
      end
    else
      {:ok, :dead_letter}
    end
  end

  defp fail_replayable_worker_turn(
         repo,
         activation,
         actor_key,
         actor_event_id,
         now,
         reason
       ) do
    with {:ok, _failed_message} <-
           AIGatewayLink.fail_generating_turn_in_tx(
             repo,
             actor_key,
             actor_event_id,
             now,
             reason
           ),
         {_count, _rows} <-
           supersede_turn_deliveries_by_actor_event_id(actor_event_id, repo, now, reason) do
      mark_activation_failed(repo, activation, reason, now)
    end
  end

  defp dead_letter_unacknowledged_worker_turn(
         repo,
         activation,
         actor_key,
         actor_event_id,
         now,
         reason
       ) do
    with %ActorEvent{} = event <- Actors.lock_actor_event_in_tx(repo, actor_event_id),
         {:ok, _failed_message} <-
           AIGatewayLink.fail_generating_turn_in_tx(
             repo,
             actor_key,
             actor_event_id,
             now,
             reason
           ),
         {_count, _rows} <-
           supersede_turn_deliveries_by_actor_event_id(actor_event_id, repo, now, reason),
         {:ok, event} <- Actors.mark_event_dead_letter_in_tx(repo, event, now, reason),
         {:ok, _notice} <- maybe_commit_dead_letter_notice(repo, event, true, reason) do
      mark_activation_failed(repo, activation, reason, now)
    else
      nil -> {:error, :actor_runtime_fence_not_found}
      {:error, _reason} = error -> error
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

  defp deliveries_for_turn_acceptance(repo, turn_ref) do
    ActorEventDelivery
    |> where([delivery], delivery.agent_uid == ^turn_ref.agent_uid)
    |> where([delivery], delivery.session_id == ^turn_ref.session_id)
    |> where([delivery], delivery.activation_uid == ^turn_ref.activation_uid)
    |> where([delivery], delivery.actor_epoch == ^turn_ref.actor_epoch)
    |> where([delivery], delivery.actor_event_id_fence == ^turn_ref.actor_event_id)
    |> where([delivery], delivery.revision == ^turn_ref.revision)
    |> where([delivery], delivery.state in ["created", "sent", "accepted"])
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
end
