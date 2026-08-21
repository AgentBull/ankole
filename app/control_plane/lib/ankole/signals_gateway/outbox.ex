defmodule Ankole.SignalsGateway.Outbox do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.I18n
  alias Ankole.Logging
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.Ecto.JSONPayload
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.OutboxAdapter
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SignalsGateway.ReplyAttachment
  alias Ankole.SignalsGateway.ReplyInteractionState
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.Utils

  import Ankole.SignalsGateway.Utils,
    only: [
      collect_results: 1,
      normalize_agent_uid_attr: 1,
      normalize_uid: 1
    ]

  @outbox_base_retry_seconds 5
  @outbox_max_retry_seconds 5 * 60
  @outbox_in_flight_recovery_seconds 60
  @stopped_delivery_limit 100
  @reply_preview_settle_timeout_ms 30_000
  @reply_preview_finalization_sources ~w(
    actor_dead_letter_notice
    actor_model_profile_unavailable_notice
    actor_turn_stopped
    ai_gateway_clarify
    ai_gateway_final_reply
  )

  @spec outbox_in_flight_recovery_seconds() :: pos_integer()
  def outbox_in_flight_recovery_seconds, do: @outbox_in_flight_recovery_seconds

  @doc """
  Records a provider-visible outbox intent committed by the actor runtime.

  This is the "commit" half of the outbox: the actor declares it wants to do
  something to the provider, transactionally, without performing it yet. The
  `on_conflict: :nothing` upsert on `{agent_uid, binding_name, outbound_key}` is
  the idempotency contract — committing the same `outbound_key` twice yields the
  same single row (and therefore at most one provider side effect). Actual
  delivery happens later via exact runtime events and `dispatch_outbox`.
  """
  @spec commit_outbox(map()) :: {:ok, OutboxEntry.t()} | {:error, term()}
  def commit_outbox(attrs) when is_map(attrs) do
    commit_outbox_in_tx(Repo, attrs)
  end

  @doc """
  Records a provider-visible outbox intent inside a caller-owned transaction.
  """
  @spec commit_outbox_in_tx(module(), map()) :: {:ok, OutboxEntry.t()} | {:error, term()}
  def commit_outbox_in_tx(repo, attrs) when is_map(attrs) do
    with {:ok, %OutboxEntry{} = outbox} <-
           %OutboxEntry{}
           |> OutboxEntry.changeset(default_outbox_attrs(attrs))
           |> repo.insert(
             on_conflict: :nothing,
             conflict_target: [:agent_uid, :binding_name, :outbound_key],
             returning: true
           )
           |> outbox_insert_result(repo, attrs),
         :ok <- notify_outbox_deadline(repo, outbox) do
      {:ok, outbox}
    end
  end

  @doc """
  Commits reply-attachment effects adopted by an explicit Agent Turn completion.

  The attachment row carries no visible text: no adapter renders a caption next
  to an uploaded file, and the final reply already delivers the answer. Giving
  the attachment its own copy of that text posted the same wall twice into the
  channel mirror the agent reads back.
  """
  @spec commit_reply_attachment_outboxes_in_tx(
          module(),
          ActorEvent.t(),
          binary(),
          [map()],
          keyword()
        ) :: {:ok, [OutboxEntry.t()]} | {:error, term()}
  def commit_reply_attachment_outboxes_in_tx(
        repo,
        %ActorEvent{} = actor_event,
        ai_message_id,
        attachments,
        opts \\ []
      )
      when is_binary(ai_message_id) and is_list(attachments) do
    with {:ok, attachments} <- ReplyAttachment.normalize_attachments(attachments) do
      for target <- reply_targets(actor_event, opts),
          {attachment, index} <- Enum.with_index(attachments) do
        commit_reply_attachment_outbox_in_tx(
          repo,
          actor_event,
          ai_message_id,
          target,
          attachment,
          index,
          opts
        )
      end
      |> collect_results()
    end
  end

  @doc """
  Commits the durable final IM replies adopted by an explicit Agent Turn completion.
  """
  @spec commit_final_reply_outboxes_in_tx(
          module(),
          ActorEvent.t(),
          Message.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, [OutboxEntry.t()]} | {:error, term()}
  def commit_final_reply_outboxes_in_tx(
        repo,
        %ActorEvent{} = actor_event,
        %Message{} = message,
        text,
        opts \\ []
      ) do
    case normalize_visible_text(text) do
      "" ->
        {:ok, []}

      final_text ->
        actor_event
        |> reply_targets(opts)
        |> Enum.map(
          &commit_final_reply_outbox_in_tx(
            repo,
            actor_event,
            message,
            final_text,
            &1,
            opts
          )
        )
        |> collect_results()
    end
  end

  @doc false
  @spec commit_clarify_reply_outbox_in_tx(
          module(),
          ActorEvent.t(),
          Message.t(),
          String.t(),
          map(),
          keyword()
        ) :: {:ok, OutboxEntry.t()} | {:error, term()}
  def commit_clarify_reply_outbox_in_tx(
        repo,
        %ActorEvent{} = actor_event,
        %Message{} = message,
        text,
        interactive_output,
        opts \\ []
      )
      when is_binary(text) and is_map(interactive_output) do
    with {:ok, operation, operation_attrs} <-
           final_reply_operation(repo, actor_event) do
      outbound_key = "ai-reply:#{message.id}"

      commit_outbox_in_tx(
        repo,
        Map.merge(
          %{
            agent_uid: actor_event.agent_uid,
            binding_name: actor_event.binding_name,
            outbound_key: outbound_key,
            operation: operation,
            signal_channel_id: actor_event.signal_channel_id,
            provider_thread_id: actor_event.provider_thread_id,
            source_actor_event_id: actor_event.id,
            ai_message_id: message.id,
            delivery_class: :durable_ai_reply,
            payload: %{
              "text" => text,
              "interactive_output" => interactive_output,
              "reply_presentation" =>
                clarify_reply_presentation(actor_event, text, interactive_output),
              "metadata" => %{
                "ai_message_id" => message.id,
                "actor_event_id" => actor_event.id,
                "source" => "ai_gateway_clarify",
                "turn_completion_outcome" => Keyword.get(opts, :turn_completion_outcome)
              }
            },
            fallback_visible_text: text,
            idempotency_key: outbound_key
          },
          operation_attrs
        )
      )
    end
  end

  @doc """
  Commits a dead-letter failure notice inside the transaction that marks the
  ActorEvent dead-lettered.

  Terminal delivery is outbox-owned, so the notice edits an existing preview or
  posts a fresh reply after commit. There is deliberately no standalone wrapper:
  the dead-letter state must never commit without its user-visible intent.
  """
  @spec commit_dead_letter_notice_outbox_in_tx(module(), ActorEvent.t(), String.t()) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  def commit_dead_letter_notice_outbox_in_tx(repo, %ActorEvent{} = actor_event, text) do
    commit_actor_notice_outbox_in_tx(
      repo,
      actor_event,
      text,
      "ai-dead-letter",
      :empty_dead_letter_notice_text,
      %{"source" => "actor_dead_letter_notice"},
      "failed"
    )
  end

  @doc """
  Commits a durable stopped-state edit for an existing live reply preview.

  Runtime commands use this only after a provider-visible preview exists. The
  finalization source participates in the same preview-settle fence as normal
  AI replies, so the stopped card cannot race a late streaming flush.
  """
  @spec commit_stopped_turn_notice_outbox(ActorEvent.t(), String.t(), String.t()) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  def commit_stopped_turn_notice_outbox(%ActorEvent{} = actor_event, text, reason)
      when is_binary(reason) do
    Repo.transact(fn repo ->
      commit_stopped_turn_notice_outbox_in_tx(repo, actor_event, text, reason)
    end)
  end

  @doc false
  @spec commit_stopped_turn_notice_outbox_in_tx(
          module(),
          ActorEvent.t(),
          String.t(),
          String.t()
        ) :: {:ok, OutboxEntry.t()} | {:error, term()}
  def commit_stopped_turn_notice_outbox_in_tx(repo, %ActorEvent{} = actor_event, text, reason)
      when is_binary(reason) do
    commit_actor_notice_outbox_in_tx(
      repo,
      actor_event,
      text,
      "ai-turn-stopped",
      :empty_stopped_turn_notice_text,
      %{"source" => "actor_turn_stopped", "reason" => reason},
      "stopped"
    )
  end

  @doc """
  Commits a durable user notice when a turn cannot start because its model
  profile is unavailable.
  """
  @spec commit_model_profile_unavailable_notice_outbox_in_tx(
          module(),
          ActorEvent.t(),
          String.t(),
          String.t()
        ) :: {:ok, OutboxEntry.t()} | {:error, term()}
  def commit_model_profile_unavailable_notice_outbox_in_tx(
        repo,
        %ActorEvent{} = actor_event,
        profile,
        text
      )
      when is_binary(profile) do
    commit_actor_notice_outbox_in_tx(
      repo,
      actor_event,
      text,
      "ai-model-profile-unavailable",
      :empty_model_profile_unavailable_notice_text,
      %{
        "source" => "actor_model_profile_unavailable_notice",
        "profile" => profile
      },
      "failed"
    )
  end

  defp commit_actor_notice_outbox_in_tx(
         repo,
         %ActorEvent{} = actor_event,
         text,
         outbound_key_prefix,
         empty_text_error,
         metadata,
         terminal_state
       ) do
    case normalize_visible_text(text) do
      "" ->
        {:error, empty_text_error}

      final_text ->
        with {:ok, operation, operation_attrs} <- final_reply_operation(repo, actor_event) do
          outbound_key = "#{outbound_key_prefix}:#{actor_event.id}"

          commit_outbox_in_tx(
            repo,
            Map.merge(
              %{
                agent_uid: actor_event.agent_uid,
                binding_name: actor_event.binding_name,
                outbound_key: outbound_key,
                operation: operation,
                signal_channel_id: actor_event.signal_channel_id,
                provider_thread_id: actor_event.provider_thread_id,
                source_actor_event_id: actor_event.id,
                delivery_class: :durable_ai_reply,
                payload: %{
                  "text" => final_text,
                  "reply_presentation" =>
                    actor_notice_reply_presentation(actor_event, terminal_state, final_text),
                  "metadata" => Map.put(metadata, "actor_event_id", actor_event.id)
                },
                fallback_visible_text: final_text,
                idempotency_key: outbound_key
              },
              operation_attrs
            )
          )
        end
    end
  end

  defp actor_notice_reply_presentation(actor_event, "stopped", _fallback_text) do
    presentation = reply_presentation_checkpoint(actor_event) |> ReplyPresentation.normalize()
    partial_answer = presentation["answer"] || ""

    presentation
    |> ReplyPresentation.terminal("stopped", partial_answer)
    |> Map.put("answer", partial_answer)
  end

  defp actor_notice_reply_presentation(actor_event, terminal_state, text),
    do: terminal_reply_presentation(actor_event, terminal_state, text)

  @doc """
  Chooses the provider-visible reply operation for an actor event.

  Decides whether the agent's reply should be a threaded `:reply` to the
  triggering entry or a top-level `:post`, from the durable route rows alone:
  the channel's reply_mode and the entry the event arrived on. Missing route
  state is returned as an error so a provider-visible side effect is never
  committed to an invented route.

  Whether the bound adapter can perform that operation is deliberately not asked
  here. Adapter availability is live process state, so a commit that consulted
  it failed the whole caller transaction whenever a plugin was absent — which
  let one old event block worker takeover and turn cleanup. `dispatch_outbox`
  owns that question under the row lock, where it can also degrade an operation
  the adapter cannot perform.
  """
  @spec outbox_operation_for_actor_event(ActorEvent.t(), module()) ::
          {:ok, atom()} | {:error, term()}
  def outbox_operation_for_actor_event(%ActorEvent{} = actor_event, repo \\ Repo) do
    with {:ok, channel} <- outbox_route_channel(repo, actor_event),
         {:ok, _binding} <- outbox_route_binding(repo, actor_event) do
      choose_outbox_operation(channel, actor_event)
    end
  end

  @doc """
  Returns true when an error means this route can never accept a message.

  A channel that accepts no replies, and a deleted channel or binding row, are
  durable facts of the route, not delivery failures a later attempt can clear.
  A caller that owns a durable decision — completing a Turn, or dead-lettering
  one — records that decision and skips the provider-visible intent. Failing
  instead would roll back work that already happened.
  """
  @spec unroutable_reply_reason?(term()) :: boolean()
  def unroutable_reply_reason?(:outbox_reply_not_supported), do: true
  def unroutable_reply_reason?({:signal_channel_not_found, _channel_id}), do: true
  def unroutable_reply_reason?({:signal_binding_not_found, _agent_uid, _binding_name}), do: true
  def unroutable_reply_reason?(_reason), do: false

  @doc """
  Returns the operation a bound adapter can actually perform.

  Only threaded replies degrade: a channel that wants a threaded reply still
  gets its message out as a top-level post when the adapter cannot thread. An
  adapter that can do neither keeps the requested operation, so dispatch records
  the row as `:unsupported` instead of silently sending something else.
  """
  @spec effective_outbox_operation(atom(), MapSet.t(atom())) :: atom()
  def effective_outbox_operation(:reply, capabilities) do
    cond do
      MapSet.member?(capabilities, :reply_entry) -> :reply
      MapSet.member?(capabilities, :post_entry) -> :post
      true -> :reply
    end
  end

  def effective_outbox_operation(operation, _capabilities), do: operation

  @doc """
  Dispatches one outbox row through a concrete adapter runtime.

  The "perform" half of the outbox. `prepare_outbox_dispatch` runs first under a
  row lock to claim the work and decide the route — a normal `:send`, a
  `:reconcile` for a row that was mid-send when the node restarted, or an
  already-terminal row that needs no action — and only then is the adapter
  called outside any held resources. Splitting prepare (locked, mutates status
  to `:sending`) from the adapter call avoids holding a DB lock across a network
  round-trip.
  """
  @spec dispatch_outbox(
          String.t(),
          String.t(),
          String.t(),
          OutboxAdapter.t(),
          keyword()
        ) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  def dispatch_outbox(
        agent_uid,
        binding_name,
        outbound_key,
        %OutboxAdapter{} = adapter,
        options \\ []
      ) do
    with :ok <- await_reply_preview_finalization(agent_uid, binding_name, outbound_key, options) do
      now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

      case prepare_outbox_dispatch(agent_uid, binding_name, outbound_key, adapter, now) do
        {:ok, {:send, outbox, channel, adapter}} ->
          adapter
          |> call_adapter_send(outbox)
          |> finalize_outbox_send(outbox, channel, now)

        {:ok, {:reconcile, outbox, channel, adapter}} ->
          adapter
          |> call_adapter_reconcile(outbox)
          |> finalize_outbox_reconcile(outbox, channel, now)

        {:ok, %OutboxEntry{} = outbox} ->
          {:ok, outbox}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Dispatches one outbox row by its durable key using the registered adapter.
  """
  @spec dispatch_outbox_by_key(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  def dispatch_outbox_by_key(agent_uid, binding_name, outbound_key, options \\ []) do
    with %OutboxEntry{} = outbox <- fetch_outbox(agent_uid, binding_name, outbound_key),
         {:ok, adapter} <- resolve_registered_adapter(outbox) do
      dispatch_outbox(agent_uid, binding_name, outbound_key, adapter, options)
    else
      nil -> {:error, :outbox_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    OutboxEntry
    |> where([entry], entry.status == :created)
    |> or_where(
      [entry],
      entry.status in [:failed, :unknown_after_send] and
        not is_nil(entry.next_attempt_at) and entry.attempt_count < entry.max_attempts
    )
    |> or_where(
      [entry],
      entry.status == :sending and not is_nil(entry.platform_send_started_at)
    )
    |> Repo.all()
    |> Enum.map(&outbox_runtime_event/1)
  end

  @doc """
  Lists the latest stopped durable replies, optionally for one Agent.

  This projection is bounded for the Console. PostgreSQL keeps every row.
  """
  @spec list_stopped_deliveries(String.t() | nil) :: {:ok, [OutboxEntry.t()]}
  def list_stopped_deliveries(agent_uid \\ nil) when is_binary(agent_uid) or is_nil(agent_uid) do
    deliveries =
      OutboxEntry
      |> maybe_where_agent(agent_uid)
      |> where([entry], entry.delivery_class == :durable_ai_reply)
      # `:unsupported` is already terminal by itself: the route can never accept
      # this reply, so it carries no retry state to inspect. Retryable classes
      # only stop once their recovery state says they will not run again.
      |> where(
        [entry],
        entry.status == :unsupported or
          (entry.status in [:failed, :unknown_after_send] and is_nil(entry.next_attempt_at) and
             fragment(
               "?->>'state' IN ('blocked', 'permanent', 'exhausted')",
               entry.recovery_state
             ))
      )
      |> order_by(
        [entry],
        desc: entry.updated_at,
        desc: entry.binding_name,
        desc: entry.outbound_key
      )
      |> limit(@stopped_delivery_limit)
      |> Repo.all()

    {:ok, deliveries}
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid),
    do: where(query, [entry], entry.agent_uid == ^normalize_uid(agent_uid))

  @doc """
  Returns whether one stopped outbox row can receive an explicit retry.
  """
  @spec requeueable?(OutboxEntry.t()) :: boolean()
  def requeueable?(%OutboxEntry{} = outbox) do
    match?(
      {:ok, _attrs},
      explicit_requeue_attrs(outbox, DateTime.utc_now(:microsecond))
    )
  end

  @doc """
  Gives one stopped durable reply one explicit provider call on the same row.

  The attempt count remains monotonic. If an earlier send was uncertain, the
  possible-duplicate notice remains part of the visible reply.
  """
  @spec requeue_outbox(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  def requeue_outbox(agent_uid, binding_name, outbound_key, options \\ [])

  def requeue_outbox(agent_uid, binding_name, outbound_key, options)
      when is_binary(agent_uid) and is_binary(binding_name) and is_binary(outbound_key) and
             is_list(options) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %OutboxEntry{} = outbox <-
             fetch_outbox_for_update(repo, agent_uid, binding_name, outbound_key),
           {:ok, attrs} <- explicit_requeue_attrs(outbox, now),
           {:ok, outbox} <- outbox |> OutboxEntry.changeset(attrs) |> repo.update(),
           :ok <- notify_outbox_deadline(repo, outbox) do
        {:ok, outbox}
      else
        nil -> {:error, :outbox_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  def requeue_outbox(_agent_uid, _binding_name, _outbound_key, _options),
    do: {:error, :invalid_outbox_key}

  @doc false
  @spec wake_blocked_for_binding(String.t(), String.t()) :: :ok | {:error, term()}
  def wake_blocked_for_binding(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    now = DateTime.utc_now(:microsecond)

    case Repo.transact(fn repo ->
           rows =
             OutboxEntry
             |> where([entry], entry.agent_uid == ^normalize_uid(agent_uid))
             |> where([entry], entry.binding_name == ^binding_name)
             |> where([entry], entry.delivery_class == :durable_ai_reply)
             |> where([entry], entry.status == :failed)
             |> where([entry], fragment("?->>'state' = 'blocked'", entry.recovery_state))
             |> lock("FOR UPDATE")
             |> repo.all()

           Enum.reduce_while(rows, {:ok, []}, fn outbox, {:ok, acc} ->
             with {:ok, attrs} <- explicit_requeue_attrs(outbox, now),
                  {:ok, outbox} <-
                    outbox
                    |> OutboxEntry.changeset(attrs)
                    |> repo.update(),
                  :ok <- notify_outbox_deadline(repo, outbox) do
               {:cont, {:ok, [outbox | acc]}}
             else
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end)
         end) do
      {:ok, _rows} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def wake_blocked_for_binding(_agent_uid, _binding_name),
    do: {:error, :invalid_signal_binding}

  defp explicit_requeue_attrs(
         %OutboxEntry{
           delivery_class: :durable_ai_reply,
           status: status,
           next_attempt_at: nil
         } = outbox,
         now
       )
       when status in [:failed, :unknown_after_send] do
    ambiguous? = status == :unknown_after_send or possible_duplicate?(outbox.recovery_state)

    with {:ok, content_attrs, notice} <- requeue_content_attrs(outbox, ambiguous?) do
      {:ok,
       Map.merge(content_attrs, %{
         max_attempts: outbox.attempt_count + 1,
         next_attempt_at: now,
         recovery_state: active_recovery_state(outbox, ambiguous?, notice)
       })}
    end
  end

  defp explicit_requeue_attrs(%OutboxEntry{}, _now),
    do: {:error, :outbox_not_requeueable}

  defp requeue_content_attrs(_outbox, false), do: {:ok, %{}, nil}

  defp requeue_content_attrs(outbox, true) do
    case possible_duplicate_notice(outbox.recovery_state) do
      notice when is_binary(notice) -> {:ok, %{}, notice}
      nil -> ambiguous_reply_content_attrs(outbox)
    end
  end

  defp prepare_outbox_dispatch(
         agent_uid,
         binding_name,
         outbound_key,
         %OutboxAdapter{} = adapter,
         now
       ) do
    Repo.transact(fn repo ->
      with %OutboxEntry{} = outbox <-
             fetch_outbox_for_update(repo, agent_uid, binding_name, outbound_key),
           {:ok, outbox} <- refresh_late_reply_presentation(repo, outbox),
           {:ok, outbox} <- adopt_late_reply_preview(repo, outbox),
           {:ok, channel} <- outbox_channel(repo, outbox) do
        case in_flight_recovery_action(outbox, adapter, now) do
          {:in_flight, outbox} ->
            {:ok, outbox}

          {:reconcile, outbox} ->
            {:ok, {:reconcile, outbox, channel, adapter}}

          {:unknown, outbox, reason} ->
            mark_outbox_unknown(repo, outbox, reason, now)

          :continue ->
            prepare_fresh_outbox_dispatch(repo, outbox, channel, adapter, now)
        end
      else
        nil -> {:error, :outbox_not_found}
        {:unsupported, outbox} -> mark_outbox_unsupported(repo, outbox)
        {:error, _reason} = error -> error
      end
    end)
  end

  # Actor completion and the transient preview use different transactions. A
  # very short model response can commit its durable final outbox while the
  # provider has already accepted the first preview but its entry id is still
  # waiting to acquire the ActorEvent row lock. Wait for the preview owner to
  # stop before claiming terminal delivery, then re-read the ActorEvent under
  # the outbox lock so the final operation edits that preview instead of posting
  # a duplicate reply. The timeout leaves the durable row in `created`; the
  # runtime snapshot will retry it without risking a second provider message.
  defp await_reply_preview_finalization(agent_uid, binding_name, outbound_key, options) do
    case fetch_outbox(agent_uid, binding_name, outbound_key) do
      %OutboxEntry{} = outbox ->
        if reply_preview_finalization?(outbox) do
          timeout_ms =
            Keyword.get(
              options,
              :reply_preview_settle_timeout_ms,
              @reply_preview_settle_timeout_ms
            )

          # The durable terminal intent is also the recovery owner. If the
          # lifecycle process exited after commit but before its best-effort
          # stop cast, startup hydration can still complete the handoff.
          AIReplyPreview.stop(outbox.source_actor_event_id)
          await_reply_preview_stop(outbox.source_actor_event_id, timeout_ms)
        else
          :ok
        end

      nil ->
        :ok
    end
  end

  defp await_reply_preview_stop(actor_event_id, timeout_ms)
       when is_binary(actor_event_id) and is_integer(timeout_ms) and timeout_ms >= 0 do
    case Registry.lookup(Ankole.SignalsGateway.PreviewRegistry, actor_event_id) do
      [{pid, _value}] ->
        monitor = Process.monitor(pid)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          timeout_ms ->
            Process.demonitor(monitor, [:flush])
            {:error, :reply_preview_settle_timeout}
        end

      [] ->
        :ok
    end
  end

  defp await_reply_preview_stop(_actor_event_id, _timeout_ms),
    do: {:error, :invalid_reply_preview_settle_timeout}

  # Actor completion commits the durable outbox before the asynchronous preview
  # process finishes checkpointing its final semantic projection. Refresh the
  # renderer-safe payload under the outbox lock after that process has stopped,
  # so plans, receipts, and other metadata cannot be frozen out of the terminal
  # card merely because the provider update was still in flight.
  defp refresh_late_reply_presentation(
         repo,
         %OutboxEntry{status: status, payload: %{"reply_presentation" => original}} = outbox
       )
       when status in [:created, :failed] and is_map(original) do
    if reply_preview_finalization?(outbox) do
      case repo.get(ActorEvent, outbox.source_actor_event_id) do
        %ActorEvent{} = event ->
          refreshed = terminal_presentation_from_latest_checkpoint(event, original)

          if refreshed == original do
            {:ok, outbox}
          else
            payload = Map.put(outbox.payload, "reply_presentation", refreshed)

            outbox
            |> OutboxEntry.changeset(%{payload: payload})
            |> repo.update()
          end

        nil ->
          {:error, :actor_event_not_found}
      end
    else
      {:ok, outbox}
    end
  end

  defp refresh_late_reply_presentation(_repo, %OutboxEntry{} = outbox), do: {:ok, outbox}

  defp terminal_presentation_from_latest_checkpoint(event, original) do
    latest = reply_presentation_checkpoint(event)
    state = Map.get(original, "state") || "completed"

    answer =
      if state == "stopped" do
        Map.get(latest, "answer") || Map.get(original, "answer") || ""
      else
        Map.get(original, "answer") || ""
      end

    latest
    |> ReplyPresentation.terminal(state, answer)
    |> preserve_empty_stopped_answer(state, answer)
    |> preserve_terminal_field(original, "prompt")
    |> preserve_terminal_field(original, "actions")
    |> merge_terminal_meta(original)
  end

  # A stopped rich reply is useful with status and progress metadata alone. The text
  # fallback remains available to providers that cannot render the rich card,
  # but a late preview checkpoint must not turn that fallback concern into a
  # fabricated answer.
  defp preserve_empty_stopped_answer(presentation, "stopped", ""),
    do: Map.put(presentation, "answer", "")

  defp preserve_empty_stopped_answer(presentation, _state, _answer), do: presentation

  defp preserve_terminal_field(presentation, original, key) do
    case Map.fetch(original, key) do
      {:ok, value} -> Map.put(presentation, key, value)
      :error -> presentation
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

  defp adopt_late_reply_preview(
         repo,
         %OutboxEntry{status: status, operation: operation} = outbox
       )
       when status in [:created, :failed] and operation in [:post, :reply] do
    if reply_preview_finalization?(outbox) do
      case repo.get(ActorEvent, outbox.source_actor_event_id) do
        %ActorEvent{reply_preview_source_entry_id: source_entry_id}
        when is_binary(source_entry_id) ->
          outbox
          |> OutboxEntry.changeset(%{
            operation: :edit,
            reply_to_source_entry_id: nil,
            target_source_entry_id: source_entry_id
          })
          |> repo.update()

        %ActorEvent{} ->
          {:ok, outbox}

        nil ->
          {:error, :actor_event_not_found}
      end
    else
      {:ok, outbox}
    end
  end

  defp adopt_late_reply_preview(_repo, %OutboxEntry{} = outbox), do: {:ok, outbox}

  defp reply_preview_finalization?(%OutboxEntry{
         source_actor_event_id: actor_event_id,
         payload: %{"metadata" => %{"source" => source} = metadata}
       })
       when is_binary(actor_event_id),
       do:
         source in @reply_preview_finalization_sources and
           get_in(metadata, ["delivery_target", "primary"]) != false

  defp reply_preview_finalization?(%OutboxEntry{}), do: false

  defp default_outbox_attrs(attrs) do
    attrs
    |> Map.put_new(:status, :created)
    |> Map.put_new(:delivery_class, :generic)
    |> Map.put_new(:payload, %{})
    |> Map.put_new(:attempt_count, 0)
    |> Map.put_new(:max_attempts, 10)
    |> Map.put_new(:last_error, %{})
    |> Map.put_new(:recovery_state, %{})
    |> normalize_agent_uid_attr()
  end

  # `on_conflict: :nothing` returns a struct with nil fields when the row already
  # existed (the commit was a duplicate). That's success for an idempotent
  # commit, so re-read the existing row by its key and return it instead of the
  # empty conflict struct.
  defp outbox_insert_result({:ok, %OutboxEntry{agent_uid: nil}}, repo, attrs) do
    attrs = default_outbox_attrs(attrs)

    case repo.get_by(OutboxEntry,
           agent_uid: attrs.agent_uid,
           binding_name: attrs.binding_name,
           outbound_key: attrs.outbound_key
         ) do
      %OutboxEntry{} = entry -> {:ok, entry}
      nil -> {:error, :outbox_entry_not_found}
    end
  end

  defp outbox_insert_result({:ok, %OutboxEntry{} = entry}, _repo, _attrs), do: {:ok, entry}
  defp outbox_insert_result({:error, _changeset} = error, _repo, _attrs), do: error

  defp commit_reply_attachment_outbox_in_tx(
         repo,
         %ActorEvent{} = actor_event,
         ai_message_id,
         target,
         attachment,
         index,
         opts
       ) do
    routed_event = routed_actor_event(actor_event, target)

    with {:ok, operation, operation_attrs} <-
           reply_attachment_operation(repo, routed_event, target) do
      outbound_key = reply_attachment_outbound_key(ai_message_id, target, index)

      commit_outbox_in_tx(
        repo,
        Map.merge(
          %{
            agent_uid: routed_event.agent_uid,
            binding_name: routed_event.binding_name,
            outbound_key: outbound_key,
            operation: operation,
            signal_channel_id: routed_event.signal_channel_id,
            provider_thread_id: routed_event.provider_thread_id,
            reply_to_source_entry_id: ActorEvent.reply_anchor_source_entry_id(routed_event),
            # Source table: source_actor_event_id stores the actor_events.id that
            # caused this provider-visible side effect.
            source_actor_event_id: actor_event.id,
            ai_message_id: ai_message_id,
            delivery_class: :durable_ai_reply,
            payload: %{
              "attachments" => [attachment],
              "metadata" =>
                reply_metadata(target, %{
                  "turn_completion_outcome" => Keyword.get(opts, :turn_completion_outcome)
                })
            },
            idempotency_key: outbound_key
          },
          operation_attrs
        )
      )
    end
  end

  defp commit_final_reply_outbox_in_tx(
         repo,
         %ActorEvent{} = actor_event,
         %Message{} = message,
         final_text,
         target,
         opts
       ) do
    routed_event = routed_actor_event(actor_event, target)

    with {:ok, operation, operation_attrs} <-
           final_reply_operation_for_target(repo, routed_event, target) do
      outbound_key = final_reply_outbound_key(message.id, target)

      payload = %{
        "text" => final_text,
        "metadata" =>
          reply_metadata(target, %{
            "ai_message_id" => message.id,
            "actor_event_id" => actor_event.id,
            "source" => "ai_gateway_final_reply",
            "turn_completion_outcome" => Keyword.get(opts, :turn_completion_outcome)
          })
      }

      payload = maybe_put_reply_presentation(payload, routed_event, target, final_text, opts)

      commit_outbox_in_tx(
        repo,
        Map.merge(
          %{
            agent_uid: routed_event.agent_uid,
            binding_name: routed_event.binding_name,
            outbound_key: outbound_key,
            operation: operation,
            signal_channel_id: routed_event.signal_channel_id,
            provider_thread_id: routed_event.provider_thread_id,
            source_actor_event_id: actor_event.id,
            ai_message_id: message.id,
            delivery_class: :durable_ai_reply,
            payload: payload,
            fallback_visible_text: final_text,
            idempotency_key: outbound_key
          },
          operation_attrs
        )
      )
    end
  end

  defp reply_targets(actor_event, opts) do
    Keyword.get(opts, :delivery_targets, [default_reply_target(actor_event)])
  end

  defp default_reply_target(actor_event) do
    %{
      binding_name: actor_event.binding_name,
      signal_channel_id: actor_event.signal_channel_id,
      provider_thread_id: actor_event.provider_thread_id,
      primary: true,
      key: nil
    }
  end

  defp routed_actor_event(actor_event, target) do
    routed = %{
      actor_event
      | binding_name: target.binding_name,
        signal_channel_id: target.signal_channel_id,
        provider_thread_id: target.provider_thread_id
    }

    if target.primary do
      routed
    else
      %{
        routed
        | source_entry_id: nil,
          ambient_asked_source_entry_id: nil,
          reply_preview_source_entry_id: nil
      }
    end
  end

  # Every target resolves its own route through the same reader. The caller
  # already projected the target onto `routed_event`, so a single default target
  # is the one-element case of the same rule rather than a separate path.
  defp reply_attachment_operation(repo, routed_event, %{key: nil}) do
    with {:ok, operation} <- outbox_operation_for_actor_event(routed_event, repo) do
      {:ok, operation, %{}}
    end
  end

  defp reply_attachment_operation(repo, routed_event, %{key: key}) when is_binary(key) do
    case outbox_operation_for_actor_event(routed_event, repo) do
      {:ok, operation} -> {:ok, operation, %{}}
      {:error, reason} -> unroutable_target_operation(reason, :post)
    end
  end

  defp final_reply_operation_for_target(repo, routed_event, %{key: nil}),
    do: final_reply_operation(repo, routed_event)

  defp final_reply_operation_for_target(repo, routed_event, %{key: key}) when is_binary(key) do
    case final_reply_operation(repo, routed_event) do
      {:ok, _operation, _attrs} = operation -> operation
      {:error, reason} -> unroutable_target_operation(reason, :post)
    end
  end

  # A cron target is an independent delivery intent, so one unreachable route
  # must not cancel the others. The target is still recorded, as a terminal
  # `:unsupported` row, because a deleted channel or binding is a durable fact of
  # the route. An operator then sees a route that can never accept this reply
  # instead of a row that waits for a retry that can never help.
  defp unroutable_target_operation(reason, operation) do
    if unroutable_reply_reason?(reason) do
      {:ok, operation,
       %{
         status: :unsupported,
         last_error: %{
           "code" => "unroutable_reply_route",
           "reason" => inspect(reason, limit: 20)
         }
       }}
    else
      {:error, reason}
    end
  end

  defp final_reply_outbound_key(message_id, %{key: nil}), do: "ai-reply:#{message_id}"

  defp final_reply_outbound_key(message_id, %{key: key}),
    do: "ai-reply:#{message_id}:#{key}"

  defp reply_attachment_outbound_key(message_id, %{key: nil}, index),
    do: "ai-reply-attachment:#{message_id}:#{index}"

  defp reply_attachment_outbound_key(message_id, %{key: key}, index),
    do: "ai-reply-attachment:#{message_id}:#{key}:#{index}"

  defp reply_metadata(%{key: nil}, metadata), do: metadata

  defp reply_metadata(target, metadata) do
    Map.put(metadata, "delivery_target", %{
      "binding_name" => target.binding_name,
      "signal_channel_id" => target.signal_channel_id,
      "provider_thread_id" => target.provider_thread_id,
      "primary" => target.primary,
      "key" => target.key
    })
  end

  defp maybe_put_reply_presentation(payload, actor_event, %{primary: true}, text, opts) do
    Map.put(
      payload,
      "reply_presentation",
      terminal_reply_presentation(actor_event, "completed", text,
        attachment_count: Keyword.get(opts, :attachment_count, 0)
      )
    )
  end

  defp maybe_put_reply_presentation(payload, _actor_event, _target, _text, _opts), do: payload

  # A committed final reply reuses the streaming preview message when one was
  # established: editing it in place turns the transient preview into the durable
  # reply. Without a preview it posts a fresh threaded reply or top-level message.
  # The same operation selection serves any actor-event terminal state, so a
  # dead-letter notice finalizes the preview exactly like a successful reply.
  defp final_reply_operation(repo, %ActorEvent{} = actor_event) do
    case actor_event.reply_preview_source_entry_id do
      source_entry_id when is_binary(source_entry_id) ->
        {:ok, :edit, %{target_source_entry_id: source_entry_id}}

      nil ->
        with {:ok, operation} <- outbox_operation_for_actor_event(actor_event, repo) do
          attrs =
            if operation == :reply do
              %{reply_to_source_entry_id: ActorEvent.reply_anchor_source_entry_id(actor_event)}
            else
              %{}
            end

          {:ok, operation, attrs}
        end
    end
  end

  defp normalize_visible_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> ""
      text -> text
    end
  end

  defp normalize_visible_text(_text), do: ""

  defp terminal_reply_presentation(%ActorEvent{} = actor_event, state, text, opts \\ []) do
    presentation =
      actor_event
      |> reply_presentation_checkpoint()
      |> ReplyPresentation.terminal(state, text)

    case Keyword.get(opts, :attachment_count, 0) do
      count when is_integer(count) and count > 0 ->
        put_in(presentation, ["meta", "attachment_count"], count)

      _count ->
        presentation
    end
  end

  defp clarify_reply_presentation(actor_event, text, interactive_output) do
    card_visible_text = Map.get(interactive_output, "body") || text

    presentation =
      terminal_reply_presentation(actor_event, "awaiting_input", card_visible_text)

    controls =
      interactive_output
      |> json_list("choices")
      |> Enum.map(fn choice ->
        %{
          "id" => Map.get(choice, "id"),
          "type" => "button",
          "label" => Map.get(choice, "label"),
          "description" => Map.get(choice, "description"),
          "source_actor_event_id" => actor_event.id,
          "interaction_id" => Map.get(interactive_output, "interaction_id"),
          "control_id" => Map.get(interactive_output, "control_id"),
          "selected_option_id" => Map.get(choice, "id"),
          "option_value" => Map.get(choice, "value"),
          "revision" => Map.get(interactive_output, "version")
        }
      end)
      |> maybe_append_free_input_control(actor_event, interactive_output)

    ReplyPresentation.apply_event(presentation, "interaction.request", %{
      "operation_id" => Map.get(interactive_output, "interaction_id") || "clarify",
      "revision" => presentation["revision"] + 1,
      "prompt" => Map.get(interactive_output, "body") || text,
      "controls" => controls
    })
  end

  defp maybe_append_free_input_control(controls, actor_event, interactive_output) do
    if Map.get(interactive_output, "free_input") == true do
      controls ++
        [
          %{
            "id" => "clarify-free-input",
            "type" => "form",
            "label" => "Reply",
            "style" => "primary",
            "source_actor_event_id" => actor_event.id,
            "interaction_id" => Map.get(interactive_output, "interaction_id"),
            "control_id" => "clarify-free-input",
            "revision" => Map.get(interactive_output, "version"),
            "fields" => [
              %{
                "id" => "clarify-answer",
                "type" => "input",
                "label" => "Your answer",
                "placeholder" => Map.get(interactive_output, "free_input_hint"),
                "required" => true,
                "multiline" => true,
                "max_length" => 1_000
              }
            ]
          }
        ]
    else
      controls
    end
  end

  defp reply_presentation_checkpoint(%ActorEvent{} = actor_event) do
    presentation =
      case actor_event.reply_preview_checkpoint do
        %{"presentation" => presentation} when is_map(presentation) -> presentation
        _checkpoint -> ReplyPresentation.new()
      end

    ReplyPresentation.project_trigger(presentation, actor_event.type, actor_event.payload)
  end

  # Channel wants threaded replies and we have an entry to thread under.
  defp choose_outbox_operation(
         %Channel{reply_mode: :entry},
         %ActorEvent{source_entry_id: source_entry_id}
       )
       when is_binary(source_entry_id),
       do: {:ok, :reply}

  defp choose_outbox_operation(%Channel{reply_mode: mode}, _actor_event)
       when mode in [:channel, :entry],
       do: {:ok, :post}

  defp choose_outbox_operation(%Channel{reply_mode: :none}, _actor_event),
    do: {:error, :outbox_reply_not_supported}

  defp outbox_route_channel(_repo, %ActorEvent{signal_channel_id: nil}),
    do: {:error, :signal_channel_id_missing}

  defp outbox_route_channel(repo, %ActorEvent{signal_channel_id: signal_channel_id}) do
    case repo.get(Channel, signal_channel_id) do
      %Channel{} = channel -> {:ok, channel}
      nil -> {:error, {:signal_channel_not_found, signal_channel_id}}
    end
  end

  defp outbox_route_binding(repo, %ActorEvent{} = actor_event) do
    case repo.get_by(Binding,
           agent_uid: actor_event.agent_uid,
           name: actor_event.binding_name
         ) do
      %Binding{} = binding ->
        {:ok, binding}

      nil ->
        {:error, {:signal_binding_not_found, actor_event.agent_uid, actor_event.binding_name}}
    end
  end

  defp fetch_outbox_for_update(repo, agent_uid, binding_name, outbound_key) do
    OutboxEntry
    |> where([entry], entry.agent_uid == ^normalize_uid(agent_uid))
    |> where([entry], entry.binding_name == ^binding_name)
    |> where([entry], entry.outbound_key == ^outbound_key)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp resolve_registered_adapter(%OutboxEntry{} = outbox) do
    with {:ok, binding} <-
           Ankole.SignalsGateway.get_binding(outbox.agent_uid, outbox.binding_name) do
      Adapters.fetch_outbox(binding.adapter)
    end
  end

  defp outbox_channel(_repo, %OutboxEntry{signal_channel_id: nil}), do: {:ok, nil}

  defp outbox_channel(repo, %OutboxEntry{signal_channel_id: signal_channel_id}) do
    case repo.get(Channel, signal_channel_id) do
      %Channel{} = channel -> {:ok, channel}
      nil -> {:error, :signal_channel_not_found}
    end
  end

  # Claim a row for a fresh send: confirm it's due, confirm the channel+adapter
  # can perform the operation, then flip it to :sending (which also stamps
  # platform_send_started_at and bumps attempt_count). All under the row lock
  # held by the caller, so two dispatchers can't both claim the same row.
  defp prepare_fresh_outbox_dispatch(repo, outbox, channel, adapter, now) do
    with :ok <- dispatchable_outbox?(outbox, now),
         {:ok, outbox} <- degrade_threaded_reply(repo, outbox, adapter),
         :ok <- outbox_supported?(outbox, channel, adapter),
         {:ok, sending_outbox} <- mark_outbox_sending(repo, outbox, now) do
      {:ok, {:send, sending_outbox, channel, adapter}}
    else
      {:unsupported, outbox} -> mark_outbox_unsupported(repo, outbox)
      {:error, _reason} = error -> error
    end
  end

  # The committed intent names what the channel wants; the bound adapter decides
  # what it can do. Rewriting the row keeps the attempted operation durable, and
  # the reply anchor stays: it records what the message answers, and no adapter
  # that needs this degrade reads it.
  defp degrade_threaded_reply(repo, %OutboxEntry{operation: :reply} = outbox, adapter) do
    case effective_outbox_operation(:reply, OutboxAdapter.capabilities(adapter)) do
      :reply ->
        {:ok, outbox}

      operation ->
        outbox
        |> OutboxEntry.changeset(%{operation: operation})
        |> repo.update()
    end
  end

  defp degrade_threaded_reply(_repo, %OutboxEntry{} = outbox, _adapter), do: {:ok, outbox}

  # Guard clauses encode the status machine's "may I attempt this now?" rules:
  # fresh rows go; failed or uncertain rows go only if retries remain and the
  # deadline has passed; a row already :sending is refused (another dispatcher
  # owns it); anything terminal is not dispatchable.
  defp dispatchable_outbox?(%OutboxEntry{status: :created}, _now), do: :ok

  defp dispatchable_outbox?(
         %OutboxEntry{status: :failed, recovery_state: %{"state" => "blocked"}},
         _now
       ),
       do: {:error, :outbox_operator_action_required}

  defp dispatchable_outbox?(
         %OutboxEntry{
           status: :failed,
           recovery_state: %{"state" => state}
         },
         _now
       )
       when state in ["permanent", "exhausted"],
       do: {:error, :outbox_manual_requeue_required}

  defp dispatchable_outbox?(
         %OutboxEntry{
           status: status,
           attempt_count: attempts,
           max_attempts: max
         },
         _now
       )
       when status in [:failed, :unknown_after_send] and attempts >= max,
       do: {:error, :outbox_attempts_exhausted}

  defp dispatchable_outbox?(
         %OutboxEntry{status: status, next_attempt_at: nil},
         _now
       )
       when status in [:failed, :unknown_after_send],
       do: {:error, :outbox_not_dispatchable}

  defp dispatchable_outbox?(
         %OutboxEntry{
           status: status,
           next_attempt_at: %DateTime{} = next_attempt_at
         },
         now
       )
       when status in [:failed, :unknown_after_send] do
    case DateTime.compare(next_attempt_at, now) do
      :gt -> {:error, :outbox_not_due}
      _ready -> :ok
    end
  end

  defp dispatchable_outbox?(%OutboxEntry{status: :sending}, _now),
    do: {:error, :outbox_send_in_progress}

  defp dispatchable_outbox?(%OutboxEntry{}, _now), do: {:error, :outbox_not_dispatchable}

  defp outbox_supported?(%OutboxEntry{} = outbox, channel, adapter) do
    capabilities = OutboxAdapter.capabilities(adapter)

    case outbox.operation do
      :post ->
        require_channel_surface(outbox, channel, capabilities, :post_entry)

      :reply ->
        with :ok <- require_reply_surface(outbox, channel, capabilities) do
          require_text(outbox.reply_to_source_entry_id, outbox)
        end

      :edit ->
        require_capability_and_target(outbox, capabilities, :edit_entry)

      :delete ->
        require_capability_and_target(outbox, capabilities, :delete_entry)

      :reaction_add ->
        require_capability_and_target(outbox, capabilities, :add_reaction)

      :reaction_remove ->
        require_capability_and_target(outbox, capabilities, :remove_reaction)

      :divider ->
        with :ok <- require_fallback_text(outbox),
             :ok <- require_channel_surface(outbox, channel, capabilities, :post_entry) do
          require_capability(outbox, capabilities, :divider)
        end

      :card ->
        with :ok <- require_fallback_text(outbox),
             :ok <- require_channel_surface(outbox, channel, capabilities, :post_entry) do
          require_capability(outbox, capabilities, :card)
        end
    end
  end

  defp require_channel_surface(
         outbox,
         %Channel{reply_mode: reply_mode},
         capabilities,
         capability
       )
       when reply_mode in [:channel, :entry] do
    require_capability(outbox, capabilities, capability)
  end

  defp require_channel_surface(outbox, _channel, _capabilities, _capability),
    do: {:unsupported, outbox}

  defp require_reply_surface(outbox, %Channel{reply_mode: :entry}, capabilities) do
    require_capability(outbox, capabilities, :reply_entry)
  end

  defp require_reply_surface(outbox, _channel, _capabilities), do: {:unsupported, outbox}

  defp require_capability_and_target(outbox, capabilities, capability) do
    with :ok <- require_capability(outbox, capabilities, capability) do
      require_text(outbox.target_source_entry_id, outbox)
    end
  end

  defp require_capability(outbox, capabilities, capability) do
    case MapSet.member?(capabilities, capability) do
      true -> :ok
      false -> {:unsupported, outbox}
    end
  end

  defp require_text(value, _outbox) when is_binary(value), do: :ok
  defp require_text(_value, outbox), do: {:unsupported, outbox}

  defp require_fallback_text(%OutboxEntry{fallback_visible_text: text}) when is_binary(text),
    do: :ok

  defp require_fallback_text(outbox), do: {:unsupported, outbox}

  # Recovery for a row found in :sending — meaning a previous dispatch told the
  # adapter to send and the node died before recording the outcome. A blind
  # resend risks a duplicate provider post, so:
  #   - if the adapter can reconcile AND we already captured a created_source_entry_id,
  #     reconcile to learn whether the send actually landed;
  #   - otherwise we cannot safely tell, so park the row as unknown_after_send
  #     for an operator rather than guess.
  # (This is the durable counterpart to "streaming is progress; committed work is
  # truth" — an unconfirmed send is neither, so it is never silently retried.)
  defp in_flight_recovery_action(
         %OutboxEntry{status: :sending, platform_send_started_at: %DateTime{} = started_at} =
           outbox,
         adapter,
         now
       ) do
    case in_flight_recovery_due?(started_at, now) do
      true -> stale_in_flight_recovery_action(outbox, adapter)
      false -> {:in_flight, outbox}
    end
  end

  defp in_flight_recovery_action(_outbox, _adapter, _now), do: :continue

  defp stale_in_flight_recovery_action(
         %OutboxEntry{
           delivery_class: :durable_ai_reply,
           payload: %{"reply_presentation" => presentation}
         } = outbox,
         adapter
       )
       when is_map(presentation) do
    capabilities = OutboxAdapter.capabilities(adapter)

    case MapSet.member?(capabilities, :outbound_reconciliation) do
      true -> {:reconcile, outbox}
      false -> {:unknown, outbox, %{"reason" => "durable AI reply cannot be reconciled"}}
    end
  end

  defp stale_in_flight_recovery_action(
         %OutboxEntry{created_source_entry_id: created_source_entry_id} = outbox,
         adapter
       )
       when is_binary(created_source_entry_id) do
    capabilities = OutboxAdapter.capabilities(adapter)

    case MapSet.member?(capabilities, :outbound_reconciliation) do
      true -> {:reconcile, outbox}
      false -> {:unknown, outbox, %{"reason" => "provider send started before restart"}}
    end
  end

  # Same situation but no created_source_entry_id was captured, so even a
  # reconciliation-capable adapter has nothing to look up → mark unknown.
  defp stale_in_flight_recovery_action(outbox, _adapter),
    do:
      {:unknown, outbox,
       %{
         "reason" => "provider send started without provider entry id"
       }}

  defp in_flight_recovery_due?(%DateTime{} = started_at, %DateTime{} = now) do
    cutoff = DateTime.add(now, -@outbox_in_flight_recovery_seconds, :second)
    DateTime.compare(started_at, cutoff) != :gt
  end

  defp mark_outbox_sending(repo, outbox, now) do
    with {:ok, %OutboxEntry{} = outbox} <-
           outbox
           |> OutboxEntry.changeset(%{
             status: :sending,
             platform_send_started_at: now,
             last_attempted_at: now,
             attempt_count: outbox.attempt_count + 1,
             next_attempt_at: nil
           })
           |> repo.update(),
         :ok <- notify_outbox_deadline(repo, outbox) do
      {:ok, outbox}
    end
  end

  defp mark_outbox_unsupported(repo, outbox) do
    outbox
    |> OutboxEntry.changeset(%{status: :unsupported})
    |> repo.update()
  end

  defp call_adapter_send(adapter, outbox) do
    OutboxAdapter.deliver(adapter, project_reply_interaction(outbox))
  end

  defp call_adapter_reconcile(adapter, outbox) do
    OutboxAdapter.reconcile(adapter, project_reply_interaction(outbox))
  end

  defp project_reply_interaction(
         %OutboxEntry{
           source_actor_event_id: actor_event_id,
           payload: %{"reply_presentation" => presentation} = payload
         } = outbox
       )
       when is_binary(actor_event_id) and is_map(presentation) do
    case Repo.get(ActorEvent, actor_event_id) do
      %ActorEvent{reply_preview_checkpoint: checkpoint} when is_map(checkpoint) ->
        %{
          outbox
          | payload:
              Map.put(
                payload,
                "reply_presentation",
                ReplyInteractionState.project(presentation, checkpoint)
              )
        }

      _missing ->
        outbox
    end
  end

  defp project_reply_interaction(%OutboxEntry{} = outbox), do: outbox

  # Runs after the adapter call returns (outside the prepare transaction). Re-open
  # a transaction and re-lock the row before recording the outcome, because the
  # network call happened with no lock held and the row could have changed.
  # Outcome → status: ok ⇒ succeeded (+ mirror the posted entry), error ⇒ failed
  # (schedule a bounded retry), :unknown ⇒ unknown_after_send. A visible durable
  # reply can retry inside the same bound after it gains a possible-duplicate
  # notice; other uncertain operations stop.
  defp finalize_outbox_send(send_result, outbox, channel, now) do
    Repo.transact(fn repo ->
      with %OutboxEntry{} = current_outbox <- fetch_outbox_for_update(repo, outbox) do
        case send_result do
          {:ok, result} ->
            finalize_successful_outbox(repo, current_outbox, channel, result, now)

          {:error, reason} ->
            mark_outbox_failed(repo, current_outbox, reason, now)

          :unknown ->
            mark_outbox_unknown(
              repo,
              current_outbox,
              %{
                "reason" => "adapter returned unknown_after_send"
              },
              now
            )
        end
      else
        nil -> {:error, :outbox_not_found}
      end
    end)
  end

  defp finalize_outbox_reconcile(reconcile_result, outbox, channel, now) do
    Repo.transact(fn repo ->
      with %OutboxEntry{} = current_outbox <- fetch_outbox_for_update(repo, outbox) do
        case reconcile_result do
          {:ok, result} ->
            finalize_successful_outbox(repo, current_outbox, channel, result, now)

          {:error, reason} ->
            mark_outbox_unknown(
              repo,
              current_outbox,
              %{
                "reason" => "reconciliation adapter error",
                "error" => reason
              },
              now
            )

          :unknown ->
            mark_outbox_unknown(
              repo,
              current_outbox,
              %{
                "reason" => "reconciliation could not confirm provider send"
              },
              now
            )
        end
      else
        nil -> {:error, :outbox_not_found}
      end
    end)
  end

  defp finalize_successful_outbox(repo, outbox, channel, result, now) do
    with {:ok, succeeded_outbox} <- mark_outbox_succeeded(repo, outbox, result) do
      case mirror_outbox_success(repo, succeeded_outbox, channel, result, now) do
        :ok ->
          {:ok, succeeded_outbox}

        {:error, reason} ->
          Logging.warning(
            "signals_gateway.outbox.mirror_failed_after_provider_send",
            "signals gateway outbox mirror failed after provider send",
            %{
              agent_uid: outbox.agent_uid,
              binding_name: outbox.binding_name,
              outbound_key: outbox.outbound_key,
              reason: inspect(Sanitizer.transport(reason), limit: 20)
            }
          )

          {:ok, succeeded_outbox}
      end
    end
  end

  defp fetch_outbox_for_update(repo, %OutboxEntry{} = outbox) do
    fetch_outbox_for_update(repo, outbox.agent_uid, outbox.binding_name, outbox.outbound_key)
  end

  defp fetch_outbox(agent_uid, binding_name, outbound_key) do
    OutboxEntry
    |> where([entry], entry.agent_uid == ^normalize_uid(agent_uid))
    |> where([entry], entry.binding_name == ^binding_name)
    |> where([entry], entry.outbound_key == ^outbound_key)
    |> Repo.one()
  end

  defp mark_outbox_succeeded(repo, outbox, result) do
    recovery_state = result_map(result, :recovery_state, %{})
    payload = result_map(result, :payload, outbox.payload)
    delivered_operation_attrs = delivered_operation_attrs(outbox, result)

    with {:ok, recovery_state} <-
           JSONPayload.normalize_map(recovery_state, allow_datetime: true),
         {:ok, payload} <- JSONPayload.normalize_map(payload, allow_datetime: true) do
      outbox
      |> OutboxEntry.changeset(
        Map.merge(
          %{
            status: :succeeded,
            created_source_entry_id: created_source_entry_id_after_success(outbox, result),
            provider_thread_id: provider_thread_id_after_success(outbox, result),
            payload: payload,
            fallback_visible_text:
              result_text(result, :fallback_visible_text) || outbox.fallback_visible_text,
            last_error: %{},
            next_attempt_at: nil,
            recovery_state: recovery_state
          },
          delivered_operation_attrs
        )
      )
      |> repo.update()
    end
  end

  # An adapter may intentionally degrade a provider operation after a
  # deterministic rejection. Persist the operation that actually happened so
  # the outbox audit row and the local provider mirror keep the same identity.
  defp delivered_operation_attrs(%OutboxEntry{operation: :edit}, result) do
    case Map.get(result, :delivered_operation) do
      :post ->
        %{
          operation: :post,
          target_source_entry_id: nil,
          reply_to_source_entry_id: nil
        }

      :reply ->
        %{
          operation: :reply,
          target_source_entry_id: nil,
          reply_to_source_entry_id: Map.get(result, :reply_to_source_entry_id)
        }

      _operation ->
        %{}
    end
  end

  defp delivered_operation_attrs(_outbox, _result), do: %{}

  defp mark_outbox_failed(repo, outbox, reason, now) do
    {last_error, next_attempt_at, recovery_state} = failure_recovery(outbox, reason, now)

    with {:ok, %OutboxEntry{} = outbox} <-
           outbox
           |> OutboxEntry.changeset(%{
             status: :failed,
             last_error: last_error,
             next_attempt_at: next_attempt_at,
             recovery_state: recovery_state
           })
           |> repo.update(),
         :ok <- notify_outbox_deadline(repo, outbox) do
      log_delivery_failure(outbox, reason)
      {:ok, outbox}
    end
  end

  defp failure_recovery(
         outbox,
         {:reply_delivery, :operator_action_required, detail},
         _now
       ) do
    {
      %{"reason" => Sanitizer.transport(detail)},
      nil,
      terminal_recovery_state(outbox, "blocked", "operator_action_required")
    }
  end

  defp failure_recovery(outbox, {:reply_delivery, :permanent, detail}, _now) do
    {
      %{"reason" => Sanitizer.transport(detail)},
      nil,
      terminal_recovery_state(outbox, "permanent", "permanent_failure")
    }
  end

  defp failure_recovery(outbox, {:reply_delivery, :retryable, detail}, now) do
    retry_failure_recovery(outbox, detail, now)
  end

  defp failure_recovery(outbox, reason, now) do
    retry_failure_recovery(outbox, reason, now)
  end

  defp retry_failure_recovery(outbox, detail, now) do
    next_attempt_at = next_outbox_attempt_at(outbox, now, retry_after_seconds(detail))

    {
      %{"reason" => Sanitizer.transport(detail)},
      next_attempt_at,
      if(is_nil(next_attempt_at),
        do: terminal_recovery_state(outbox, "exhausted", "max_attempts_reached"),
        else: active_recovery_state(outbox)
      )
    }
  end

  defp log_delivery_failure(%OutboxEntry{} = outbox, reason) do
    {failure_class, failure_code} = delivery_failure_identity(reason)

    fields = %{
      agent_uid: outbox.agent_uid,
      binding_name: outbox.binding_name,
      outbound_key: outbox.outbound_key,
      source_actor_event_id: outbox.source_actor_event_id,
      operation: outbox.operation,
      delivery_class: outbox.delivery_class,
      attempt_count: outbox.attempt_count,
      max_attempts: outbox.max_attempts,
      failure_class: failure_class,
      failure_code: failure_code,
      recovery_state: outbox.recovery_state["state"],
      retry_scheduled: not is_nil(outbox.next_attempt_at),
      next_attempt_at: encode_log_datetime(outbox.next_attempt_at)
    }

    if is_nil(outbox.next_attempt_at) do
      Logging.error(
        "signals_gateway.outbox.delivery_failed",
        "signals gateway outbox delivery stopped",
        fields
      )
    else
      Logging.warning(
        "signals_gateway.outbox.delivery_failed",
        "signals gateway outbox delivery will retry",
        fields
      )
    end
  end

  defp delivery_failure_identity({:reply_delivery, :operator_action_required, detail}),
    do: {"operator_action_required", delivery_failure_code(detail)}

  defp delivery_failure_identity({:reply_delivery, :retryable, detail}),
    do: {"retryable", delivery_failure_code(detail)}

  defp delivery_failure_identity({:reply_delivery, :permanent, detail}),
    do: {"permanent", delivery_failure_code(detail)}

  defp delivery_failure_identity(reason) when is_atom(reason),
    do: {"adapter_error", Atom.to_string(reason)}

  defp delivery_failure_identity({reason, _detail}) when is_atom(reason),
    do: {"adapter_error", Atom.to_string(reason)}

  defp delivery_failure_identity(reason),
    do: {"adapter_error", delivery_failure_code(reason)}

  defp delivery_failure_code(%{} = detail) do
    detail
    |> Map.get(:code, Map.get(detail, "code"))
    |> normalize_log_code()
  end

  defp delivery_failure_code(_detail), do: nil

  defp normalize_log_code(value) when is_binary(value), do: value
  defp normalize_log_code(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_log_code(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_log_code(_value), do: nil

  defp encode_log_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_log_datetime(nil), do: nil

  defp mark_outbox_unknown(repo, outbox, reason, now) do
    attrs =
      outbox
      |> unknown_recovery_attrs(now)
      |> Map.merge(%{
        status: :unknown_after_send,
        last_error: Sanitizer.transport(reason)
      })

    with {:ok, outbox} <- outbox |> OutboxEntry.changeset(attrs) |> repo.update(),
         :ok <- notify_outbox_deadline(repo, outbox) do
      {:ok, outbox}
    end
  end

  defp unknown_recovery_attrs(%OutboxEntry{delivery_class: :durable_ai_reply} = outbox, now) do
    case ambiguous_reply_content_attrs(outbox) do
      {:ok, content_attrs, notice} ->
        next_attempt_at = next_outbox_attempt_at(outbox, now)

        recovery_state =
          if is_nil(next_attempt_at) do
            terminal_recovery_state(
              outbox,
              "exhausted",
              "max_attempts_reached",
              true,
              notice
            )
          else
            active_recovery_state(outbox, true, notice)
          end

        Map.merge(content_attrs, %{
          next_attempt_at: next_attempt_at,
          recovery_state: recovery_state
        })

      {:error, :outbox_ambiguous_delivery_not_requeueable} ->
        %{
          next_attempt_at: nil,
          recovery_state:
            terminal_recovery_state(
              outbox,
              "blocked",
              "ambiguous_delivery_without_visible_text",
              true,
              nil
            )
        }
    end
  end

  defp unknown_recovery_attrs(%OutboxEntry{} = outbox, _now) do
    %{
      next_attempt_at: nil,
      recovery_state:
        terminal_recovery_state(
          outbox,
          "blocked",
          "ambiguous_delivery_not_retried",
          true,
          nil
        )
    }
  end

  defp ambiguous_reply_content_attrs(%OutboxEntry{} = outbox) do
    notice = possible_duplicate_notice(outbox.recovery_state) || ambiguous_delivery_notice()
    payload = prefix_ambiguous_payload(outbox.payload, notice)
    fallback_visible_text = prefix_ambiguous_text(outbox.fallback_visible_text, notice)

    if visible_reply_content?(outbox) do
      {:ok, %{payload: payload, fallback_visible_text: fallback_visible_text}, notice}
    else
      {:error, :outbox_ambiguous_delivery_not_requeueable}
    end
  end

  defp visible_reply_content?(%OutboxEntry{
         payload: payload,
         fallback_visible_text: fallback_visible_text
       }) do
    presentation_answer =
      case payload do
        %{"reply_presentation" => presentation} when is_map(presentation) ->
          Map.get(presentation, "answer")

        _missing ->
          nil
      end

    payload_text = if is_map(payload), do: Map.get(payload, "text")

    Enum.any?(
      [payload_text, presentation_answer, fallback_visible_text],
      &(normalize_visible_text(&1) != "")
    )
  end

  defp prefix_ambiguous_payload(payload, notice) when is_map(payload) do
    payload = prefix_map_text(payload, "text", notice)

    case Map.get(payload, "reply_presentation") do
      presentation when is_map(presentation) ->
        Map.put(
          payload,
          "reply_presentation",
          prefix_map_text(presentation, "answer", notice)
        )

      _missing_or_invalid ->
        payload
    end
  end

  defp prefix_map_text(map, key, notice) do
    case Map.get(map, key) do
      text when is_binary(text) -> Map.put(map, key, prefix_ambiguous_text(text, notice))
      _missing -> map
    end
  end

  defp prefix_ambiguous_text(text, notice) when is_binary(text) do
    cond do
      String.trim(text) == "" -> notice
      String.starts_with?(text, notice) -> text
      true -> notice <> "\n\n" <> text
    end
  end

  defp prefix_ambiguous_text(value, _notice), do: value

  defp ambiguous_delivery_notice,
    do: I18n.t("signals_gateway.reply.possible_duplicate_delivery")

  defp active_recovery_state(outbox),
    do: active_recovery_state(outbox, possible_duplicate?(outbox.recovery_state), nil)

  defp active_recovery_state(outbox, ambiguous?, notice),
    do: possible_duplicate_recovery_state(outbox.recovery_state, ambiguous?, notice)

  defp terminal_recovery_state(outbox, state, reason),
    do:
      terminal_recovery_state(
        outbox,
        state,
        reason,
        possible_duplicate?(outbox.recovery_state),
        nil
      )

  defp terminal_recovery_state(outbox, state, reason, ambiguous?, notice) do
    outbox.recovery_state
    |> possible_duplicate_recovery_state(ambiguous?, notice)
    |> Map.merge(%{"state" => state, "reason" => reason})
  end

  defp possible_duplicate_recovery_state(_recovery_state, false, _notice), do: %{}

  defp possible_duplicate_recovery_state(recovery_state, true, notice) do
    notice = notice || possible_duplicate_notice(recovery_state)
    state = %{"possible_duplicate" => true}

    if is_binary(notice) and notice != "" do
      Map.put(state, "possible_duplicate_notice", notice)
    else
      state
    end
  end

  defp possible_duplicate?(recovery_state) when is_map(recovery_state),
    do: Map.get(recovery_state, "possible_duplicate") == true

  defp possible_duplicate?(_recovery_state), do: false

  defp possible_duplicate_notice(recovery_state) when is_map(recovery_state) do
    case Map.get(recovery_state, "possible_duplicate_notice") do
      notice when is_binary(notice) and notice != "" -> notice
      _missing -> nil
    end
  end

  defp possible_duplicate_notice(_recovery_state), do: nil

  # Prefer the id the provider returned; fall back to one already on the row.
  # Without a provider-derived entry id there is no source mirror identity, so a
  # successful outbox row remains succeeded but does not write signal_gateway_entries.
  defp created_source_entry_id_after_success(%OutboxEntry{} = outbox, result) do
    result_text(result, :created_source_entry_id) ||
      outbox.created_source_entry_id
  end

  defp provider_thread_id_after_success(%OutboxEntry{} = outbox, result) do
    result_text(result, :provider_thread_id) || outbox.provider_thread_id
  end

  # Exponential backoff: delay = 5s * 2^(attempt-1), clamped to the 5m ceiling
  # (so 5s, 10s, 20s, 40s, … capped at 300s). Returning nil once attempts are
  # exhausted is what makes the deadline handler no-op on the row — the retry
  # loop ends without a separate "give up" flag.
  defp next_outbox_attempt_at(outbox, now), do: next_outbox_attempt_at(outbox, now, 0)

  defp next_outbox_attempt_at(
         %OutboxEntry{attempt_count: attempts, max_attempts: max},
         _now,
         _minimum_delay_seconds
       )
       when attempts >= max,
       do: nil

  defp next_outbox_attempt_at(
         %OutboxEntry{attempt_count: attempts},
         now,
         minimum_delay_seconds
       ) do
    backoff_seconds =
      attempts
      |> max(1)
      |> then(&(@outbox_base_retry_seconds * Integer.pow(2, &1 - 1)))
      |> min(@outbox_max_retry_seconds)

    delay_seconds = max(backoff_seconds, minimum_delay_seconds)
    DateTime.add(now, delay_seconds, :second)
  end

  defp retry_after_seconds(detail), do: Utils.reply_delivery_retry_after_seconds(detail)

  defp notify_outbox_deadline(repo, %OutboxEntry{} = outbox) do
    RuntimeEvents.notify_outbox_due(repo, outbox, outbox_due_at(outbox))
  end

  defp outbox_runtime_event(%OutboxEntry{} = outbox) do
    {RuntimeEvents.outbox_due_channel(),
     %{
       "agent_uid" => outbox.agent_uid,
       "binding_name" => outbox.binding_name,
       "outbound_key" => outbox.outbound_key,
       "due_at" => RuntimeEvents.encode_datetime(outbox_due_at(outbox))
     }}
  end

  defp outbox_due_at(%OutboxEntry{status: :created}), do: nil

  defp outbox_due_at(%OutboxEntry{status: :failed, next_attempt_at: next_attempt_at}),
    do: next_attempt_at

  defp outbox_due_at(%OutboxEntry{
         status: :unknown_after_send,
         next_attempt_at: next_attempt_at
       }),
       do: next_attempt_at

  defp outbox_due_at(%OutboxEntry{
         status: :sending,
         platform_send_started_at: %DateTime{} = started_at
       }),
       do: DateTime.add(started_at, @outbox_in_flight_recovery_seconds, :second)

  defp outbox_due_at(%OutboxEntry{}), do: nil

  # After a successful send, write the agent's own output into the SAME entry
  # mirror humans' messages land in, so the channel history is unified and the
  # agent can later see what it said. Each operation maps to the matching mirror
  # mutation: post/reply/card/divider create a row, edit rewrites text, delete
  # removes the row, reactions fold into the reaction map. Constructs a synthetic
  # fact authored by the agent and reuses mirror_receive_entry.
  defp mirror_outbox_success(
         repo,
         %OutboxEntry{operation: operation} = outbox,
         channel,
         result,
         now
       )
       when operation in [:post, :reply, :divider, :card] do
    case result_text(result, :created_source_entry_id) || outbox.created_source_entry_id do
      nil ->
        :ok

      source_entry_id ->
        fact = %{
          signal_channel_id: outbox.signal_channel_id,
          source_entry_id: source_entry_id,
          reply_to_source_entry_id: outbox.reply_to_source_entry_id,
          provider_thread_id: outbox.provider_thread_id,
          text: outbox.fallback_visible_text,
          formatted_content: json_map(outbox.payload, "formatted_content", %{}),
          attachments: json_list(outbox.payload, "attachments"),
          links: [],
          author: %{"agent_uid" => outbox.agent_uid},
          mentions: [],
          metadata: json_map(outbox.payload, "metadata", %{}),
          raw_payload: result_map(result, :raw_payload, %{}),
          provider_time: result_datetime(result, :provider_time),
          channel_name: channel && channel.name,
          ai_message_id: outbox.ai_message_id
        }

        case Projection.mirror_receive_entry(repo, fact, now) do
          {:ok, _entry} -> :ok
          {:error, _changeset} = error -> error
        end
    end
  end

  defp mirror_outbox_success(
         repo,
         %OutboxEntry{operation: :edit} = outbox,
         _channel,
         result,
         now
       ) do
    case repo.get_by(Entry,
           signal_channel_id: outbox.signal_channel_id,
           source_entry_id: outbox.target_source_entry_id
         ) do
      %Entry{} = entry ->
        entry
        |> Entry.changeset(final_reply_edit_attrs(entry, outbox, now))
        |> repo.update()
        |> case do
          {:ok, _entry} -> :ok
          {:error, _changeset} = error -> error
        end

      nil ->
        case outbox.ai_message_id do
          nil ->
            :ok

          _ai_message_id ->
            %Entry{}
            |> Entry.changeset(final_reply_insert_attrs(outbox, result, now))
            |> repo.insert()
            |> case do
              {:ok, _entry} -> :ok
              {:error, _changeset} = error -> error
            end
        end
    end
  end

  defp mirror_outbox_success(
         repo,
         %OutboxEntry{operation: :delete} = outbox,
         _channel,
         _result,
         _now
       ) do
    Entry
    |> where([entry], entry.signal_channel_id == ^outbox.signal_channel_id)
    |> where([entry], entry.source_entry_id == ^outbox.target_source_entry_id)
    |> repo.delete_all()

    :ok
  end

  defp mirror_outbox_success(
         repo,
         %OutboxEntry{operation: operation} = outbox,
         _channel,
         _result,
         now
       )
       when operation in [:reaction_add, :reaction_remove] do
    case repo.get_by(Entry,
           signal_channel_id: outbox.signal_channel_id,
           source_entry_id: outbox.target_source_entry_id
         ) do
      %Entry{} = entry ->
        fact = %{
          action: if(operation == :reaction_add, do: :add, else: :remove),
          reaction_key: outbox.payload["reaction_key"],
          actor_key: outbox.payload["actor_key"] || outbox.agent_uid,
          raw_reaction_key: outbox.payload["raw_reaction_key"]
        }

        entry
        |> Entry.changeset(Projection.reaction_entry_attrs(entry, fact, now))
        |> repo.update()
        |> case do
          {:ok, _entry} -> :ok
          {:error, _changeset} = error -> error
        end

      nil ->
        :ok
    end
  end

  defp final_reply_entry_metadata(metadata, %OutboxEntry{ai_message_id: nil}),
    do: metadata || %{}

  defp final_reply_entry_metadata(metadata, %OutboxEntry{} = outbox) do
    (metadata || %{})
    |> Map.put("ai_message_id", outbox.ai_message_id)
    |> maybe_put_metadata("actor_event_id", outbox.source_actor_event_id)
    |> maybe_put_metadata("source", "ai_gateway_final_reply")
  end

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp final_reply_edit_attrs(%Entry{} = entry, %OutboxEntry{} = outbox, now) do
    metadata = final_reply_entry_metadata(entry.metadata, outbox)
    text = outbox.fallback_visible_text

    rich_content =
      Projection.rich_content(text, json_map(outbox.payload, "formatted_content", %{}))

    provider_thread_id = outbox.provider_thread_id || entry.provider_thread_id

    reply_to_source_entry_id =
      outbox.reply_to_source_entry_id || entry.reply_to_source_entry_id

    %{
      text: text,
      rich_content: rich_content,
      provider_thread_id: provider_thread_id,
      reply_to_source_entry_id: reply_to_source_entry_id,
      metadata: metadata,
      content_hash:
        Projection.entry_content_hash([
          text,
          rich_content,
          entry.attachments || [],
          entry.links || [],
          entry.author || %{},
          entry.mentions || [],
          metadata,
          reply_to_source_entry_id,
          provider_thread_id
        ]),
      ai_message_id: outbox.ai_message_id || entry.ai_message_id,
      last_seen_at: now
    }
  end

  defp final_reply_insert_attrs(%OutboxEntry{} = outbox, result, now) do
    metadata = final_reply_entry_metadata(%{}, outbox)
    author = %{"agent_uid" => outbox.agent_uid}
    text = outbox.fallback_visible_text

    rich_content =
      Projection.rich_content(text, json_map(outbox.payload, "formatted_content", %{}))

    %{
      signal_channel_id: outbox.signal_channel_id,
      source_entry_id: outbox.target_source_entry_id,
      reply_to_source_entry_id: outbox.reply_to_source_entry_id,
      provider_thread_id: outbox.provider_thread_id,
      text: text,
      rich_content: rich_content,
      attachments: [],
      links: [],
      author: author,
      mentions: [],
      metadata: metadata,
      raw_payload: result_map(result, :raw_payload, %{}),
      document_id:
        Projection.entry_document_id(outbox.signal_channel_id, outbox.target_source_entry_id),
      content_hash:
        Projection.entry_content_hash([
          text,
          rich_content,
          [],
          [],
          author,
          [],
          metadata,
          outbox.reply_to_source_entry_id,
          outbox.provider_thread_id
        ]),
      first_seen_at: now,
      last_seen_at: now,
      ai_message_id: outbox.ai_message_id
    }
  end

  defp json_map(map, key, default) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp json_map(_map, _key, default), do: default

  defp json_list(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_list(value) -> value
      _value -> []
    end
  end

  defp json_list(_map, _key), do: []

  defp result_map(result, key, default) when is_map(result) and is_atom(key) do
    case Map.get(result, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp result_map(_result, _key, default), do: default

  defp result_datetime(result, key) when is_map(result) and is_atom(key) do
    case Map.get(result, key) do
      %DateTime{} = datetime -> datetime
      _value -> nil
    end
  end

  defp result_datetime(_result, _key), do: nil

  defp result_text(result, key) when is_map(result) and is_atom(key) do
    case Map.get(result, key) do
      value when is_binary(value) -> String.trim(value)
      _value -> nil
    end
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp result_text(_result, _key), do: nil
end
