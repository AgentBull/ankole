defmodule Ankole.SignalsGateway.Outbox do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Logging
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.Ecto.JSONPayload
  alias Ankole.SignalsGateway.Adapters
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

  import Ankole.SignalsGateway.Utils,
    only: [
      collect_results: 1,
      fetch_datetime: 2,
      fetch_list: 2,
      fetch_map: 3,
      fetch_value: 2,
      normalize_agent_uid_attr: 1,
      normalize_uid: 1,
      optional_text: 2
    ]

  @outbox_base_retry_seconds 5
  @outbox_max_retry_seconds 5 * 60
  @durable_ai_reply_retry_seconds 15 * 60
  @outbox_in_flight_recovery_seconds 60
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
  """
  @spec commit_reply_attachment_outboxes_in_tx(
          module(),
          ActorEvent.t(),
          binary(),
          String.t(),
          [map()],
          keyword()
        ) :: {:ok, [OutboxEntry.t()]} | {:error, term()}
  def commit_reply_attachment_outboxes_in_tx(
        repo,
        %ActorEvent{} = actor_event,
        ai_message_id,
        text,
        attachments,
        opts \\ []
      )
      when is_binary(ai_message_id) and is_list(attachments) do
    with {:ok, attachments} <- ReplyAttachment.normalize_attachments(attachments),
         {:ok, operation} <- outbox_operation_for_actor_event(actor_event, repo) do
      attachments
      |> Enum.with_index()
      |> Enum.map(fn {attachment, index} ->
        commit_reply_attachment_outbox_in_tx(
          repo,
          actor_event,
          ai_message_id,
          operation,
          attachment,
          text,
          index,
          opts
        )
      end)
      |> collect_results()
    end
  end

  @doc """
  Commits the durable final IM reply adopted by an explicit Agent Turn completion.
  """
  @spec commit_final_reply_outbox_in_tx(
          module(),
          ActorEvent.t(),
          Message.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, OutboxEntry.t() | nil} | {:error, term()}
  def commit_final_reply_outbox_in_tx(
        repo,
        %ActorEvent{} = actor_event,
        %Message{} = message,
        text,
        opts \\ []
      ) do
    case normalize_visible_text(text) do
      "" ->
        {:ok, nil}

      final_text ->
        with {:ok, operation, operation_attrs} <-
               final_reply_operation(repo, actor_event, message) do
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
                  "text" => final_text,
                  "reply_presentation" =>
                    terminal_reply_presentation(
                      actor_event,
                      "completed",
                      final_text,
                      attachment_count: Keyword.get(opts, :attachment_count, 0)
                    ),
                  "metadata" => %{
                    "ai_message_id" => message.id,
                    "actor_event_id" => actor_event.id,
                    "source" => "ai_gateway_final_reply",
                    "turn_completion_outcome" => Keyword.get(opts, :turn_completion_outcome)
                  }
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
           final_reply_operation(repo, actor_event, message) do
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
  Commits a durable failure notice for an actor event that reached dead-letter.

  Terminal delivery is outbox-owned, so a dead-lettered addressed message still
  reaches the user through the same finalize path as a successful reply: it edits
  the reply preview in place when one exists, otherwise posts a fresh message.
  This is the durable counterpart to the transient preview, which is stopped
  without a final edit once a turn is dead-lettered.
  """
  @spec commit_dead_letter_notice_outbox(ActorEvent.t(), String.t()) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  def commit_dead_letter_notice_outbox(%ActorEvent{} = actor_event, text) do
    Repo.transact(fn repo ->
      commit_dead_letter_notice_outbox_in_tx(repo, actor_event, text)
    end)
  end

  @doc """
  Commits a dead-letter failure notice inside a caller-owned transaction.
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
  triggering entry or a top-level `:post`, based on the channel's reply_mode and
  the adapter's declared capabilities. Missing route state is returned as an
  error so a provider-visible side effect is never committed to an invented
  route.
  """
  @spec outbox_operation_for_actor_event(ActorEvent.t(), module()) ::
          {:ok, atom()} | {:error, term()}
  def outbox_operation_for_actor_event(%ActorEvent{} = actor_event, repo \\ Repo) do
    with {:ok, channel} <- outbox_route_channel(repo, actor_event),
         {:ok, binding} <- outbox_route_binding(repo, actor_event),
         {:ok, adapter} <- Adapters.fetch_outbox(binding.adapter),
         capabilities <- OutboxAdapter.capabilities(adapter),
         {:ok, operation} <-
           choose_outbox_operation(
             channel,
             capabilities,
             actor_event
           ) do
      {:ok, operation}
    end
  end

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
          OutboxAdapter.t() | map(),
          keyword()
        ) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  def dispatch_outbox(agent_uid, binding_name, outbound_key, adapter, options \\ []) do
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
      entry.status == :failed and not is_nil(entry.next_attempt_at) and
        (entry.attempt_count < entry.max_attempts or entry.delivery_class == :durable_ai_reply)
    )
    |> or_where(
      [entry],
      entry.status == :sending and not is_nil(entry.platform_send_started_at)
    )
    |> Repo.all()
    |> Enum.map(&outbox_runtime_event/1)
  end

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
             with {:ok, outbox} <-
                    outbox
                    |> OutboxEntry.changeset(%{
                      next_attempt_at: now,
                      recovery_state: %{}
                    })
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

  defp prepare_outbox_dispatch(agent_uid, binding_name, outbound_key, adapter, now) do
    with {:ok, adapter} <- OutboxAdapter.normalize(adapter) do
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
              mark_outbox_unknown(repo, outbox, reason)

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
    state = fetch_value(original, "state") || "completed"

    answer =
      if state == "stopped" do
        fetch_value(latest, "answer") || fetch_value(original, "answer") || ""
      else
        fetch_value(original, "answer") || ""
      end

    latest
    |> ReplyPresentation.terminal(state, answer)
    |> preserve_empty_stopped_answer(state, answer)
    |> preserve_terminal_field(original, "prompt")
    |> preserve_terminal_field(original, "actions")
    |> merge_terminal_meta(original)
  end

  # A stopped card is useful with status and progress metadata alone. The text
  # fallback remains available to providers that cannot render the rich card,
  # but a late preview checkpoint must not turn that fallback concern into a
  # fabricated CardKit answer.
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
    original_meta = fetch_value(original, "meta")

    if is_map(original_meta) do
      Map.put(presentation, "meta", Map.merge(presentation["meta"] || %{}, original_meta))
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
         payload: %{"metadata" => %{"source" => source}}
       })
       when is_binary(actor_event_id),
       do: source in @reply_preview_finalization_sources

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
         operation,
         attachment,
         text,
         index,
         opts
       ) do
    outbound_key = "ai-reply-attachment:#{ai_message_id}:#{index}"

    commit_outbox_in_tx(repo, %{
      agent_uid: actor_event.agent_uid,
      binding_name: actor_event.binding_name,
      outbound_key: outbound_key,
      operation: operation,
      signal_channel_id: actor_event.signal_channel_id,
      provider_thread_id: actor_event.provider_thread_id,
      reply_to_source_entry_id: actor_event.source_entry_id,
      # Source table: source_actor_event_id stores the actor_events.id that
      # caused this provider-visible side effect.
      source_actor_event_id: actor_event.id,
      ai_message_id: ai_message_id,
      delivery_class: :durable_ai_reply,
      payload: %{
        "text" => text,
        "attachments" => [attachment],
        "metadata" => %{
          "turn_completion_outcome" => Keyword.get(opts, :turn_completion_outcome)
        }
      },
      fallback_visible_text: text,
      idempotency_key: outbound_key
    })
  end

  # A committed final reply reuses the streaming preview message when one was
  # established: editing it in place turns the transient preview into the durable
  # reply. Without a preview it posts a fresh threaded reply or top-level message.
  # The same operation selection serves any actor-event terminal state, so a
  # dead-letter notice finalizes the preview exactly like a successful reply.
  defp final_reply_operation(repo, %ActorEvent{} = actor_event, %Message{}),
    do: final_reply_operation(repo, actor_event)

  defp final_reply_operation(repo, %ActorEvent{} = actor_event) do
    case actor_event.reply_preview_source_entry_id do
      source_entry_id when is_binary(source_entry_id) ->
        {:ok, :edit, %{target_source_entry_id: source_entry_id}}

      nil ->
        with {:ok, operation} <- outbox_operation_for_actor_event(actor_event, repo) do
          attrs =
            if operation == :reply do
              %{reply_to_source_entry_id: actor_event.source_entry_id}
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
    card_visible_text = fetch_value(interactive_output, "body") || text

    presentation =
      terminal_reply_presentation(actor_event, "awaiting_input", card_visible_text)

    controls =
      interactive_output
      |> fetch_list("choices")
      |> Enum.map(fn choice ->
        %{
          "id" => fetch_value(choice, "id"),
          "type" => "button",
          "label" => fetch_value(choice, "label"),
          "source_actor_event_id" => actor_event.id,
          "interaction_id" => fetch_value(interactive_output, "interaction_id"),
          "control_id" => fetch_value(interactive_output, "control_id"),
          "selected_option_id" => fetch_value(choice, "id"),
          "option_value" => fetch_value(choice, "value"),
          "revision" => fetch_value(interactive_output, "version")
        }
      end)
      |> maybe_append_free_input_control(actor_event, interactive_output)

    ReplyPresentation.apply_event(presentation, "interaction.request", %{
      "operation_id" => fetch_value(interactive_output, "interaction_id") || "clarify",
      "revision" => presentation["revision"] + 1,
      "prompt" => fetch_value(interactive_output, "body") || text,
      "controls" => controls
    })
  end

  defp maybe_append_free_input_control(controls, actor_event, interactive_output) do
    if fetch_value(interactive_output, "free_input") == true do
      controls ++
        [
          %{
            "id" => "clarify-free-input",
            "type" => "form",
            "label" => "Reply",
            "style" => "primary",
            "source_actor_event_id" => actor_event.id,
            "interaction_id" => fetch_value(interactive_output, "interaction_id"),
            "control_id" => "clarify-free-input",
            "revision" => fetch_value(interactive_output, "version"),
            "fields" => [
              %{
                "id" => "clarify-answer",
                "type" => "input",
                "label" => "Your answer",
                "placeholder" => fetch_value(interactive_output, "free_input_hint"),
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

  # Channel wants threaded replies and we have an entry to thread under: reply if
  # the adapter supports threaded replies, otherwise degrade to a top-level post
  # so the message still gets out.
  defp choose_outbox_operation(
         %Channel{reply_mode: :entry},
         capabilities,
         %ActorEvent{source_entry_id: source_entry_id}
       )
       when is_binary(source_entry_id) do
    {:ok,
     case MapSet.member?(capabilities, :reply_entry) do
       true -> :reply
       false -> post_or_fallback(capabilities, :reply)
     end}
  end

  defp choose_outbox_operation(%Channel{reply_mode: mode}, capabilities, _actor_event)
       when mode in [:channel, :entry] do
    {:ok, post_or_fallback(capabilities, :post)}
  end

  defp choose_outbox_operation(%Channel{reply_mode: :none}, _capabilities, _actor_event),
    do: {:error, :outbox_reply_not_supported}

  defp choose_outbox_operation(_channel, _capabilities, _actor_event),
    do: {:error, :outbox_reply_mode_unknown}

  defp post_or_fallback(capabilities, fallback) do
    case MapSet.member?(capabilities, :post_entry) do
      true -> :post
      false -> fallback
    end
  end

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
         :ok <- outbox_supported?(outbox, channel, adapter),
         {:ok, sending_outbox} <- mark_outbox_sending(repo, outbox, now) do
      {:ok, {:send, sending_outbox, channel, adapter}}
    else
      {:unsupported, outbox} -> mark_outbox_unsupported(repo, outbox)
      {:error, _reason} = error -> error
    end
  end

  # Guard clauses encode the status machine's "may I attempt this now?" rules:
  # fresh rows go; failed rows go only if retries remain and the backoff time has
  # passed; a row already :sending is refused (another dispatcher owns it);
  # anything terminal is not dispatchable.
  defp dispatchable_outbox?(%OutboxEntry{status: :created}, _now), do: :ok

  defp dispatchable_outbox?(
         %OutboxEntry{status: :failed, recovery_state: %{"state" => "blocked"}},
         _now
       ),
       do: {:error, :outbox_operator_action_required}

  defp dispatchable_outbox?(
         %OutboxEntry{
           status: :failed,
           delivery_class: delivery_class,
           attempt_count: attempts,
           max_attempts: max
         },
         _now
       )
       when attempts >= max and delivery_class != :durable_ai_reply,
       do: {:error, :outbox_attempts_exhausted}

  defp dispatchable_outbox?(%OutboxEntry{status: :failed, next_attempt_at: nil}, _now),
    do: :ok

  defp dispatchable_outbox?(
         %OutboxEntry{status: :failed, next_attempt_at: %DateTime{} = next_attempt_at},
         now
       ) do
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
  # (schedule retry), :unknown ⇒ unknown_after_send (never auto-retried).
  defp finalize_outbox_send(send_result, outbox, channel, now) do
    Repo.transact(fn repo ->
      with %OutboxEntry{} = current_outbox <- fetch_outbox_for_update(repo, outbox) do
        case send_result do
          {:ok, result} ->
            finalize_successful_outbox(repo, current_outbox, channel, result, now)

          {:error, reason} ->
            mark_outbox_failed(repo, current_outbox, reason, now)

          :unknown ->
            mark_outbox_unknown(repo, current_outbox, %{
              "reason" => "adapter returned unknown_after_send"
            })
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
            mark_outbox_unknown(repo, current_outbox, %{
              "reason" => "reconciliation adapter error",
              "error" => reason
            })

          :unknown ->
            mark_outbox_unknown(repo, current_outbox, %{
              "reason" => "reconciliation could not confirm provider send"
            })
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
    recovery_state = fetch_value(result, :recovery_state) || %{}
    payload = fetch_value(result, :payload) || outbox.payload
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
            payload: payload,
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
    case fetch_value(result, :delivered_operation) do
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
          reply_to_source_entry_id: fetch_value(result, :reply_to_source_entry_id)
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
      {:ok, outbox}
    end
  end

  defp failure_recovery(
         _outbox,
         {:reply_delivery, :operator_action_required, detail},
         _now
       ) do
    {
      %{"reason" => Sanitizer.transport(detail)},
      nil,
      %{"state" => "blocked", "reason" => "operator_action_required"}
    }
  end

  defp failure_recovery(outbox, {:reply_delivery, :retryable, detail}, now) do
    {
      %{"reason" => Sanitizer.transport(detail)},
      next_outbox_attempt_at(outbox, now),
      %{}
    }
  end

  defp failure_recovery(outbox, reason, now) do
    {
      %{"reason" => Sanitizer.transport(reason)},
      next_outbox_attempt_at(outbox, now),
      %{}
    }
  end

  defp mark_outbox_unknown(repo, outbox, reason) do
    outbox
    |> OutboxEntry.changeset(%{
      status: :unknown_after_send,
      last_error: Sanitizer.transport(reason),
      next_attempt_at: nil
    })
    |> repo.update()
  end

  # Prefer the id the provider returned; fall back to one already on the row.
  # Without a provider-derived entry id there is no source mirror identity, so a
  # successful outbox row remains succeeded but does not write signal_gateway_entries.
  defp created_source_entry_id_after_success(%OutboxEntry{} = outbox, result) do
    optional_text(result, :created_source_entry_id) ||
      outbox.created_source_entry_id
  end

  # Exponential backoff: delay = 5s * 2^(attempt-1), clamped to the 5m ceiling
  # (so 5s, 10s, 20s, 40s, … capped at 300s). Returning nil once attempts are
  # exhausted is what makes the deadline handler no-op on the row — the retry
  # loop ends without a separate "give up" flag.
  defp next_outbox_attempt_at(
         %OutboxEntry{
           delivery_class: :durable_ai_reply,
           attempt_count: attempts,
           max_attempts: max
         },
         now
       )
       when attempts >= max,
       do: DateTime.add(now, @durable_ai_reply_retry_seconds, :second)

  defp next_outbox_attempt_at(%OutboxEntry{attempt_count: attempts, max_attempts: max}, _now)
       when attempts >= max,
       do: nil

  defp next_outbox_attempt_at(%OutboxEntry{attempt_count: attempts}, now) do
    delay_seconds =
      attempts
      |> max(1)
      |> then(&(@outbox_base_retry_seconds * Integer.pow(2, &1 - 1)))
      |> min(@outbox_max_retry_seconds)

    DateTime.add(now, delay_seconds, :second)
  end

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
    case optional_text(result, :created_source_entry_id) || outbox.created_source_entry_id do
      nil ->
        :ok

      source_entry_id ->
        fact = %{
          signal_channel_id: outbox.signal_channel_id,
          source_entry_id: source_entry_id,
          reply_to_source_entry_id: outbox.reply_to_source_entry_id,
          provider_thread_id: outbox.provider_thread_id,
          text: outbox.fallback_visible_text,
          formatted_content: fetch_map(outbox.payload, :formatted_content, %{}),
          attachments: fetch_list(outbox.payload, :attachments),
          links: [],
          author: %{"agent_uid" => outbox.agent_uid},
          mentions: [],
          metadata: fetch_map(outbox.payload, :metadata, %{}),
          raw_payload: fetch_map(result, :raw_payload, %{}),
          provider_time: fetch_datetime(result, :provider_time),
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
          reaction_key: outbox.payload["reaction_key"] || outbox.payload[:reaction_key],
          actor_key: outbox.payload["actor_key"] || outbox.agent_uid,
          raw_reaction_key:
            outbox.payload["raw_reaction_key"] || outbox.payload[:raw_reaction_key]
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
      Projection.rich_content(text, fetch_map(outbox.payload, :formatted_content, %{}))

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
      Projection.rich_content(text, fetch_map(outbox.payload, :formatted_content, %{}))

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
      raw_payload: fetch_map(result, :raw_payload, %{}),
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
end
