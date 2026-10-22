defmodule Ankole.Conversations.Delivery.Dispatch do
  @moduledoc false
  import Ecto.Query, only: [from: 2]
  require Ash.Query

  alias Ankole.Conversations.Delivery.PreviewState
  alias Ankole.Logging
  alias Ankole.Signals.Signal
  alias Ankole.Repo
  alias Ankole.Signals.Adapters
  alias Ankole.Conversations.Delivery.Preview
  alias Ankole.Conversations.Delivery.Adapter
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.Jobs.Dispatch
  alias Ankole.Conversations.Delivery.InteractionState
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.PreviewAdapter
  alias Ankole.Conversations.Conversation

  # Release the outbox slot promptly while a preview finishes its provider IO.
  @reply_preview_settle_timeout_ms 100
  # Delivery sources that must stop a live preview before dispatch.
  @reply_preview_finalization_sources ~w(
    session_dead_letter_notice
    session_model_profile_unavailable_notice
    session_tenant_suspended_notice
    session_token_quota_exceeded_notice
    session_turn_stopped
    ai_gateway_clarify
    ai_gateway_final_reply
  )

  @doc "Restores missing dispatch jobs for due intent rows that can still recover."
  @spec reconcile_wakeups(DateTime.t()) :: :ok | {:error, term()}
  def reconcile_wakeups(now \\ DateTime.utc_now(:microsecond)) do
    recovery_before =
      DateTime.add(
        now,
        -Ankole.Conversations.Delivery.Recovery.in_flight_recovery_seconds(),
        :second
      )

    # Oban owns the job rows; the key of each live dispatch job is in its args.
    active_keys =
      Repo.all(
        from(job in Oban.Job,
          where: job.worker == ^Oban.Worker.to_string(Dispatch),
          where: job.state in ["available", "scheduled", "retryable", "executing"],
          select: job.args
        )
      )
      |> MapSet.new(&{&1["agent_uid"], &1["binding_name"], &1["outbound_key"]})

    keys =
      Repo.across_tenants(fn ->
        Intent
        |> Ash.Query.for_read(:due_across_tenants, %{now: now, recovery_before: recovery_before})
        |> Ash.Query.select([:agent_uid, :binding_name, :outbound_key, :tenant_id])
        |> Ash.read!(authorize?: false)
      end)
      |> Enum.reject(
        &MapSet.member?(active_keys, {&1.agent_uid, &1.binding_name, &1.outbound_key})
      )
      |> Enum.map(&Map.take(&1, [:agent_uid, :binding_name, :outbound_key, :tenant_id]))

    Enum.reduce_while(keys, :ok, fn key, :ok ->
      result =
        Repo.with_tenant(key.tenant_id, fn ->
          # Recovery must not add a successor to a job that started after the query.
          key
          |> Dispatch.new(unique: [states: [:available, :scheduled, :retryable, :executing]])
          |> Oban.insert()
        end)

      case result do
        {:ok, _job} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delivery_trace_attributes(intent, phase) do
    %{
      "ankole.tenant.id" => intent.tenant_id,
      "ankole.principal.uid" => intent.agent_uid,
      "ankole.signal.id" => intent.source_signal_id,
      "ankole.ai_gateway.response_id" => intent.ai_message_id,
      "ankole.delivery.key" => intent.outbound_key,
      "ankole.delivery.binding" => intent.binding_name,
      "ankole.delivery.attempt" => intent.attempt_count,
      "ankole.delivery.phase" => phase
    }
  end

  @doc """
  Dispatches one intent row through a concrete adapter runtime.

  The "perform" half of the intent. `prepare_intent_dispatch` runs first under a
  row lock to claim the work and decide the route — a normal `:send`, a
  `:reconcile` for a row that was mid-send when the node restarted, or an
  already-terminal row that needs no action — and only then is the adapter
  called outside any held resources. Splitting prepare (locked, mutates status
  to `:pending`) from the adapter call avoids holding a DB lock across a network
  round-trip.
  """
  @spec dispatch(
          String.t(),
          String.t(),
          String.t(),
          Adapter.t(),
          keyword()
        ) ::
          {:ok, Intent.t()} | {:error, term()}
  def dispatch(
        agent_uid,
        binding_name,
        outbound_key,
        %Adapter{} = adapter,
        options \\ []
      ) do
    with :ok <- await_reply_preview_finalization(agent_uid, binding_name, outbound_key, options) do
      now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

      claim =
        Ankole.Observability.stage(
          "delivery.claim",
          %{
            "ankole.principal.uid" => agent_uid,
            "ankole.delivery.binding" => binding_name,
            "ankole.delivery.key" => outbound_key
          },
          fn -> prepare_intent_dispatch(agent_uid, binding_name, outbound_key, adapter, now) end
        )

      case claim do
        {:ok, {:send, intent, conversation, adapter}} ->
          attributes = delivery_trace_attributes(intent, "send")

          result =
            Ankole.Observability.stage("delivery.send", attributes, fn ->
              call_adapter_send(adapter, intent)
            end)

          Ankole.Observability.stage("delivery.finalize", attributes, fn ->
            finalize_intent_send(result, intent, conversation, now)
          end)

        {:ok, {:reconcile, intent, conversation, adapter}} ->
          attributes = delivery_trace_attributes(intent, "reconcile")

          result =
            Ankole.Observability.stage("delivery.reconcile", attributes, fn ->
              call_adapter_reconcile(adapter, intent)
            end)

          Ankole.Observability.stage("delivery.finalize", attributes, fn ->
            finalize_intent_reconcile(result, intent, conversation, now)
          end)

        {:ok, %Intent{} = intent} ->
          {:ok, intent}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Dispatches one intent row by its durable key using the registered adapter.
  """
  @spec dispatch_by_key(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Intent.t()} | {:error, term()}
  def dispatch_by_key(agent_uid, binding_name, outbound_key, options \\ []) do
    with %Intent{} = intent <-
           Ankole.Conversations.Delivery.Queries.fetch_delivery(
             agent_uid,
             binding_name,
             outbound_key
           ),
         {:ok, adapter} <- resolve_registered_adapter(intent) do
      dispatch(agent_uid, binding_name, outbound_key, adapter, options)
    else
      nil -> {:error, :intent_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_intent_dispatch(
         agent_uid,
         binding_name,
         outbound_key,
         %Adapter{} = adapter,
         now
       ) do
    agent_uid
    |> Ankole.Conversations.claim_intent_dispatch(binding_name, outbound_key, adapter, now)
    |> Ankole.Errors.reason()
  end

  @doc false
  def claim_in_tx(repo, agent_uid, binding_name, outbound_key, %Adapter{} = adapter, now) do
    with %Intent{} = intent <-
           Ankole.Conversations.Delivery.Queries.fetch_delivery_for_update(
             repo,
             agent_uid,
             binding_name,
             outbound_key
           ),
         {:ok, intent} <- refresh_late_reply_presentation(intent),
         {:ok, intent} <- adopt_late_reply_preview(intent),
         {:ok, conversation} <- intent_channel(intent) do
      case Ankole.Conversations.Delivery.Recovery.in_flight_recovery_action(
             intent,
             adapter,
             now
           ) do
        {:in_flight, intent} ->
          {:ok, intent}

        {:reconcile, intent} ->
          {:ok, {:reconcile, intent, conversation, adapter}}

        {:unknown, intent, reason} ->
          Ankole.Conversations.Delivery.Recovery.mark_intent_unknown(repo, intent, reason, now)

        :continue ->
          prepare_fresh_intent_dispatch(repo, intent, conversation, adapter, now)
      end
    else
      nil -> {:error, :intent_not_found}
      {:unsupported, intent} -> mark_intent_unsupported(repo, intent)
      {:error, _reason} = error -> error
    end
  end

  # Actor completion and the transient preview use different transactions. A
  # very short model response can commit its durable final intent while the
  # provider has already accepted the first preview but its entry id is still
  # waiting to acquire the Signal row lock. Wait for the preview owner to
  # stop before claiming terminal delivery, then re-read the Signal under
  # the intent lock so the final operation edits that preview instead of posting
  # a duplicate reply. A timeout leaves the intent untouched; the job snoozes
  # before it claims an attempt or sends a provider request.
  defp await_reply_preview_finalization(agent_uid, binding_name, outbound_key, options) do
    case Ankole.Conversations.Delivery.Queries.fetch_delivery(
           agent_uid,
           binding_name,
           outbound_key
         ) do
      %Intent{} = intent ->
        if reply_preview_finalization?(intent) do
          timeout_ms =
            Keyword.get(
              options,
              :reply_preview_settle_timeout_ms,
              @reply_preview_settle_timeout_ms
            )

          # The durable terminal intent is also the recovery owner. If the
          # lifecycle process exited after commit but before its best-effort
          # stop cast, a recovered dispatch job can still complete the handoff.
          Preview.stop(intent.source_signal_id)
          await_reply_preview_stop(intent.source_signal_id, timeout_ms)
        else
          :ok
        end

      nil ->
        :ok
    end
  end

  defp await_reply_preview_stop(signal_id, timeout_ms)
       when is_binary(signal_id) and is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case Preview.lookup(signal_id, @reply_preview_settle_timeout_ms) do
      [{pid, _value}] ->
        monitor = Process.monitor(pid)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          max(0, deadline - System.monotonic_time(:millisecond)) ->
            Process.demonitor(monitor, [:flush])
            {:error, :reply_preview_settle_timeout}
        end

      [] ->
        :ok

      {:error, :reply_preview_owner_unavailable} ->
        {:error, :reply_preview_settle_timeout}
    end
  end

  defp await_reply_preview_stop(_signal_id, _timeout_ms),
    do: {:error, :invalid_reply_preview_settle_timeout}

  # Actor completion commits the durable intent before the asynchronous preview
  # process finishes checkpointing its final semantic projection. Refresh the
  # renderer-safe payload under the intent lock after that process has stopped,
  # so plans, receipts, and other metadata cannot be frozen out of the terminal
  # card merely because the provider update was still in flight.
  defp refresh_late_reply_presentation(
         %Intent{status: status, payload: %{"reply_presentation" => original}} = intent
       )
       when status in [:pending, :failed] and is_map(original) do
    if reply_preview_finalization?(intent) do
      case PreviewState.load_signal(intent.source_signal_id) do
        %Signal{} = event ->
          with {:ok, refreshed} <-
                 terminal_presentation_from_latest_checkpoint(
                   event,
                   original,
                   intent.payload["metadata"]
                 ) do
            if refreshed == original do
              {:ok, intent}
            else
              payload = Map.put(intent.payload, "reply_presentation", refreshed)

              Ankole.Ash.update(intent, :prepare, %{payload: payload})
            end
          end

        nil ->
          {:error, :signal_not_found}
      end
    else
      {:ok, intent}
    end
  end

  defp refresh_late_reply_presentation(%Intent{} = intent), do: {:ok, intent}

  defp terminal_presentation_from_latest_checkpoint(_event, original, %{
         "reason" => "context_withdrawn"
       }) do
    state = Map.get(original, "state")

    if state in ReplyPresentation.terminal_states() do
      {:ok, original}
    else
      {:error, {:reply_presentation_not_terminal, state}}
    end
  end

  defp terminal_presentation_from_latest_checkpoint(event, original, _metadata) do
    state = Map.get(original, "state")
    latest = Ankole.Conversations.Delivery.reply_presentation_checkpoint(event)

    answer =
      if state == "stopped" do
        Map.get(latest, "answer") || Map.get(original, "answer") || ""
      else
        Map.get(original, "answer") || ""
      end

    case ReplyPresentation.fetch_terminal(latest, state, answer,
           preserve_interaction_from: original
         ) do
      {:ok, refreshed} ->
        {:ok, merge_terminal_meta(refreshed, original)}

      {:error, {:invalid_terminal_state, invalid}} ->
        {:error, {:reply_presentation_not_terminal, invalid}}
    end
  end

  defp merge_terminal_meta(presentation, original) do
    original_meta = Map.get(original, "meta")

    if is_map(original_meta) do
      terminal_meta = Map.delete(original_meta, "status")
      Map.put(presentation, "meta", Map.merge(presentation["meta"] || %{}, terminal_meta))
    else
      presentation
    end
  end

  defp adopt_late_reply_preview(%Intent{status: status, operation: operation} = intent)
       when status in [:pending, :failed] and operation in [:post, :reply] do
    if reply_preview_finalization?(intent) do
      case PreviewState.load_signal(intent.source_signal_id) do
        %Signal{
          preview: %PreviewState{
            provider_message_id: provider_message_id
          }
        }
        when is_binary(provider_message_id) ->
          Ankole.Ash.update(intent, :prepare, %{
            operation: :edit,
            reply_to_provider_message_id: nil,
            target_provider_message_id: provider_message_id
          })

        %Signal{} ->
          {:ok, intent}

        nil ->
          {:error, :signal_not_found}
      end
    else
      {:ok, intent}
    end
  end

  defp adopt_late_reply_preview(%Intent{} = intent), do: {:ok, intent}

  defp reply_preview_finalization?(%Intent{
         source_signal_id: signal_id,
         payload: %{"metadata" => %{"source" => source} = metadata}
       })
       when is_binary(signal_id),
       do:
         source in @reply_preview_finalization_sources and
           get_in(metadata, ["delivery_target", "primary"]) != false

  defp reply_preview_finalization?(%Intent{}), do: false

  defp resolve_registered_adapter(%Intent{} = intent) do
    with {:ok, binding} <-
           Ankole.Signals.Bindings.get_binding(intent.agent_uid, intent.binding_name) do
      Adapters.fetch_delivery(binding.adapter)
    end
  end

  defp intent_channel(%Intent{conversation_id: nil}), do: {:ok, nil}

  defp intent_channel(%Intent{conversation_id: conversation_id}) do
    case Conversation |> Ash.Query.filter(id == ^conversation_id) |> Ankole.Ash.read_one!() do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :signal_channel_not_found}
    end
  end

  # Claim a row for a fresh send: confirm it's due, confirm the conversation+adapter
  # can perform the operation, then flip it to :pending (which also stamps
  # platform_send_started_at and bumps attempt_count). All under the row lock
  # held by the caller, so two dispatchers can't both claim the same row.
  defp prepare_fresh_intent_dispatch(repo, intent, conversation, adapter, now) do
    if intent.expires_at && DateTime.compare(intent.expires_at, now) != :gt do
      with {:ok, expired} <-
             Ankole.Ash.update(intent, :expire, %{}),
           :ok <- Ankole.Conversations.Delivery.Recovery.notify_intent_deadline(repo, expired),
           do: {:ok, expired}
    else
      claim_intent(repo, intent, conversation, adapter, now)
    end
  end

  defp claim_intent(repo, intent, conversation, adapter, now) do
    with :ok <- dispatchable_intent?(intent, now),
         :ok <- attachments_migrated(intent),
         {:ok, intent} <- degrade_threaded_reply(repo, intent, adapter),
         :ok <- intent_supported?(intent, conversation, adapter),
         {:ok, sending_intent} <- mark_intent_sending(repo, intent, now) do
      {:ok, {:send, sending_intent, conversation, adapter}}
    else
      {:unsupported, intent} -> mark_intent_unsupported(repo, intent)
      {:error, _reason} = error -> error
    end
  end

  # Legacy bytes must enter Files through Upgrade202610.import_agent_home/1 before a new send.
  # This gate keeps the stored attempt count and recovery evidence unchanged.
  defp attachments_migrated(%Intent{payload: payload}) do
    legacy? =
      Enum.any?(Map.get(payload, "attachments", []), fn attachment ->
        not is_binary(attachment["blob_ref"]) and
          (Map.has_key?(attachment, "user_files_relative_path") or
             Map.has_key?(attachment, "agent_computer_path"))
      end)

    if legacy?, do: {:error, :attachment_migration_required}, else: :ok
  end

  # The committed intent names what the conversation wants; the bound adapter decides
  # what it can do. Rewriting the row keeps the attempted operation durable, and
  # the reply anchor stays: it records what the message answers, and no adapter
  # that needs this degrade reads it.
  defp degrade_threaded_reply(_repo, %Intent{operation: :reply} = intent, adapter) do
    case Ankole.Conversations.Delivery.effective_operation(:reply, Adapter.capabilities(adapter)) do
      :reply ->
        {:ok, intent}

      operation ->
        Ankole.Ash.update(intent, :prepare, %{operation: operation})
    end
  end

  defp degrade_threaded_reply(_repo, %Intent{} = intent, _adapter), do: {:ok, intent}

  # The resource owns attempt admission. Dispatch also checks retry policy and time.
  defp dispatchable_intent?(%Intent{status: :pending} = intent, _now),
    do: Intent.check_attempt(intent)

  defp dispatchable_intent?(
         %Intent{status: :failed, recovery_status: :blocked},
         _now
       ),
       do: {:error, :intent_operator_action_required}

  defp dispatchable_intent?(
         %Intent{
           status: :failed,
           recovery_status: state
         },
         _now
       )
       when state in [:permanent, :exhausted],
       do: {:error, :intent_manual_requeue_required}

  defp dispatchable_intent?(%Intent{status: :failed, possible_duplicate: true}, _now),
    do: {:error, :intent_manual_requeue_required}

  defp dispatchable_intent?(%Intent{status: :failed} = intent, now) do
    with :ok <- Intent.check_attempt(intent) do
      case intent.next_attempt_at do
        nil ->
          {:error, :intent_not_dispatchable}

        %DateTime{} = next_attempt_at ->
          if DateTime.compare(next_attempt_at, now) == :gt,
            do: {:error, :intent_not_due},
            else: :ok
      end
    end
  end

  defp dispatchable_intent?(%Intent{}, _now), do: {:error, :intent_not_dispatchable}

  defp intent_supported?(%Intent{} = intent, conversation, adapter) do
    capabilities = Adapter.capabilities(adapter)

    case intent.operation do
      :post ->
        require_channel_surface(intent, conversation, capabilities, :post_entry)

      :reply ->
        with :ok <- require_reply_surface(intent, conversation, capabilities) do
          require_text(intent.reply_to_provider_message_id, intent)
        end

      :edit ->
        require_capability_and_target(intent, capabilities, :edit_entry)

      :delete ->
        require_capability_and_target(intent, capabilities, :delete_entry)

      :reaction_add ->
        require_capability_and_target(intent, capabilities, :add_reaction)

      :reaction_remove ->
        require_capability_and_target(intent, capabilities, :remove_reaction)

      :divider ->
        with :ok <- require_fallback_text(intent),
             :ok <- require_channel_surface(intent, conversation, capabilities, :post_entry) do
          require_capability(intent, capabilities, :divider)
        end

      :card ->
        with :ok <- require_fallback_text(intent),
             :ok <- require_channel_surface(intent, conversation, capabilities, :post_entry) do
          require_capability(intent, capabilities, :card)
        end
    end
  end

  defp require_channel_surface(
         intent,
         %Conversation{reply_mode: reply_mode},
         capabilities,
         capability
       )
       when reply_mode in [:channel, :entry] do
    require_capability(intent, capabilities, capability)
  end

  defp require_channel_surface(intent, _channel, _capabilities, _capability),
    do: {:unsupported, intent}

  defp require_reply_surface(intent, %Conversation{reply_mode: :entry}, capabilities) do
    require_capability(intent, capabilities, :reply_entry)
  end

  defp require_reply_surface(intent, _channel, _capabilities), do: {:unsupported, intent}

  defp require_capability_and_target(intent, capabilities, capability) do
    with :ok <- require_capability(intent, capabilities, capability) do
      require_text(intent.target_provider_message_id, intent)
    end
  end

  defp require_capability(intent, capabilities, capability) do
    case MapSet.member?(capabilities, capability) do
      true -> :ok
      false -> {:unsupported, intent}
    end
  end

  defp require_text(value, _intent) when is_binary(value), do: :ok
  defp require_text(_value, intent), do: {:unsupported, intent}

  defp require_fallback_text(%Intent{fallback_visible_text: text}) when is_binary(text),
    do: :ok

  defp require_fallback_text(intent), do: {:unsupported, intent}

  # Reconcile durable AI replies that have a reply presentation and a provider
  # reconciliation capability. Other sends have no provable outcome after a
  # crash, so recovery marks them unknown instead of repeating the operation.
  defp mark_intent_sending(repo, intent, now) do
    with {:ok, %Intent{} = intent} <-
           Ankole.Ash.update(intent, :start_attempt, %{platform_send_started_at: now}),
         :ok <- Ankole.Conversations.Delivery.Recovery.notify_intent_deadline(repo, intent) do
      {:ok, intent}
    end
  end

  defp mark_intent_unsupported(_repo, intent) do
    Ankole.Ash.update(intent, :fail, %{
      next_attempt_at: nil,
      last_error: %{"code" => "unsupported_operation"},
      recovery_status: :permanent,
      recovery_reason: "unsupported_operation"
    })
  end

  # A durable AI reply whose adapter declares a reply-preview module is the
  # terminal step of that preview: the preview module finalizes the surface it
  # already owns instead of the adapter posting a second message. Reconciling
  # such a row repeats that finalize, because the preview checkpoint records
  # every provider mutation and finalize is idempotent against it.
  defp call_adapter_send(adapter, intent) do
    case terminal_reply_preview(adapter, intent) do
      %PreviewAdapter{} = preview ->
        PreviewAdapter.finalize_intent(preview, project_reply_interaction(intent))

      nil ->
        Adapter.deliver(adapter, project_reply_interaction(intent))
    end
  end

  defp call_adapter_reconcile(adapter, intent) do
    case terminal_reply_preview(adapter, intent) do
      %PreviewAdapter{} = preview ->
        PreviewAdapter.finalize_intent(preview, project_reply_interaction(intent))

      nil ->
        Adapter.reconcile(adapter, project_reply_interaction(intent))
    end
  end

  defp terminal_reply_preview(
         %Adapter{reply_preview: %PreviewAdapter{} = preview},
         %Intent{
           payload: %{"reply_presentation" => presentation},
           source_signal_id: signal_id
         }
       )
       when is_map(presentation) and is_binary(signal_id),
       do: preview

  defp terminal_reply_preview(_adapter, _intent), do: nil

  defp project_reply_interaction(
         %Intent{
           source_signal_id: signal_id,
           payload: %{"reply_presentation" => presentation} = payload
         } = intent
       )
       when is_binary(signal_id) and is_map(presentation) do
    case PreviewState.load_signal(signal_id) do
      %Signal{preview: %PreviewState{checkpoint: checkpoint}}
      when is_map(checkpoint) ->
        %{
          intent
          | payload:
              Map.put(
                payload,
                "reply_presentation",
                InteractionState.project(presentation, checkpoint)
              )
        }

      _missing ->
        intent
    end
  end

  defp project_reply_interaction(%Intent{} = intent), do: intent

  # Runs after the adapter call returns (outside the prepare transaction). Re-open
  # a transaction and re-lock the row before recording the outcome, because the
  # network call happened with no lock held and the row could have changed:
  # recovery may already have taken the attempt over and committed a terminal
  # state, in which case this late result is stale and must not be recorded.
  # Outcome → status: ok ⇒ succeeded (+ mirror the posted entry), error ⇒ failed
  # (schedule a bounded retry), :unknown ⇒ unknown_after_send. A visible durable
  # reply can retry inside the same bound after it gains a possible-duplicate
  # notice; other uncertain operations stop.
  defp finalize_intent_send(send_result, intent, conversation, now) do
    intent
    |> Ankole.Conversations.finalize_intent_attempt(:send, send_result, conversation, now)
    |> Ankole.Errors.reason()
  end

  defp finalize_intent_reconcile(reconcile_result, intent, conversation, now) do
    intent
    |> Ankole.Conversations.finalize_intent_attempt(
      :reconcile,
      reconcile_result,
      conversation,
      now
    )
    |> Ankole.Errors.reason()
  end

  @doc false
  def finalize_in_tx(repo, intent, phase, result, conversation, now) do
    case refetch_claimed_intent(repo, intent, Atom.to_string(phase)) do
      {:ok, current_intent} ->
        record_outcome(repo, phase, result, current_intent, conversation, now)

      {:stale, current_intent} ->
        {:ok, current_intent}

      {:error, _reason} = error ->
        error
    end
  end

  defp record_outcome(repo, _phase, {:ok, result}, intent, conversation, now),
    do:
      Ankole.Conversations.Delivery.Mirror.finalize_successful_intent(
        repo,
        intent,
        conversation,
        result,
        now
      )

  defp record_outcome(repo, :send, {:error, reason}, intent, _conversation, now),
    do: Ankole.Conversations.Delivery.Recovery.mark_intent_failed(repo, intent, reason, now)

  defp record_outcome(repo, :reconcile, {:error, reason}, intent, _conversation, now) do
    detail = %{"reason" => "reconciliation adapter error", "error" => reason}
    Ankole.Conversations.Delivery.Recovery.mark_intent_unknown(repo, intent, detail, now)
  end

  defp record_outcome(repo, _phase, {:unknown, detail}, intent, _conversation, now),
    do: Ankole.Conversations.Delivery.Recovery.mark_intent_unknown(repo, intent, detail, now)

  defp record_outcome(repo, phase, :unknown, intent, _conversation, now) do
    reason =
      if phase == :send,
        do: "adapter could not confirm provider delivery",
        else: "reconciliation could not confirm provider send"

    Ankole.Conversations.Delivery.Recovery.mark_intent_unknown(
      repo,
      intent,
      %{"reason" => reason},
      now
    )
  end

  # The attempt fence between the claim and its result. A finalizer may only
  # record an outcome for the attempt it claimed: the row must still be
  # :pending with the same attempt_count (platform_send_started_at is a
  # redundant guard for the same claim). Otherwise recovery took the row over
  # and committed first, so the first committed outcome wins and the late
  # result becomes a logged no-op. Without this fence a late error could turn
  # a delivered succeeded row back into a retryable one and post a duplicate.
  defp refetch_claimed_intent(repo, %Intent{} = intent, phase) do
    case Ankole.Conversations.Delivery.Queries.fetch_delivery_for_update(repo, intent) do
      %Intent{} = current_intent ->
        if current_intent.status == :pending and
             current_intent.attempt_count == intent.attempt_count and
             same_send_start?(
               current_intent.platform_send_started_at,
               intent.platform_send_started_at
             ) do
          {:ok, current_intent}
        else
          Ankole.Observability.stage(
            "delivery.stale_result",
            Map.merge(delivery_trace_attributes(intent, phase), %{
              "ankole.delivery.current_attempt" => current_intent.attempt_count,
              "ankole.delivery.current_status" => to_string(current_intent.status)
            }),
            fn -> :stale end
          )

          Logging.warning(
            "conversations.delivery.stale_attempt_result_ignored",
            "signals gateway intent ignored a stale attempt result",
            %{
              tenant_id: intent.tenant_id,
              signal_id: intent.source_signal_id,
              ai_message_id: intent.ai_message_id,
              agent_uid: intent.agent_uid,
              binding_name: intent.binding_name,
              outbound_key: intent.outbound_key,
              phase: phase,
              claimed_attempt_count: intent.attempt_count,
              current_attempt_count: current_intent.attempt_count,
              current_status: current_intent.status
            }
          )

          {:stale, current_intent}
        end

      nil ->
        {:error, :intent_not_found}
    end
  end

  defp same_send_start?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_send_start?(left, right), do: left == right
end
