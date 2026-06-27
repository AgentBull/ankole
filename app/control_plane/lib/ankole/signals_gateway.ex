defmodule Ankole.SignalsGateway do
  @moduledoc """
  Boundary between signal ingress, actor input handoff, and provider outbox.

  This is the provider-ingress layer described in the README: external chats,
  webhooks, and provider events arrive through the `emit_*` functions, become
  normalized "signal" facts, and turn into actor input — while the channel/entry
  mirror preserves the external source fact separately from agent execution.
  LLM-committed side effects flow back out as outbox entries.

  Three responsibilities live here, each with its own contract:

    * Ingress (`emit_entry`/`emit_entry_removed`/`emit_reaction`/`emit_action`/
      `emit_internal`): construct a fact, apply binding filters, then
      do the channel/entry mirror + actor-input append inside ONE Repo
      transaction. There is deliberately no stored ingress plan and no second
      queue — admission and effect happen in the request that received the
      signal, so a signal either fully lands or leaves no trace.

    * Tombstones: a short-lived guard (`InputTombstone`) so a late re-delivered
      receive can't resurrect a message the human already removed.

    * Outbox (`commit_outbox`/`dispatch_outbox`/`dispatch_due_outbox`): the
      durable, idempotent, retried path that actually performs provider-visible
      operations and mirrors the result back into the entry table.

  Most functions take an explicit `now` (via `options[:now]`) so timing-sensitive
  behavior — batch windows, tombstone expiry, retry schedules — is testable
  without a clock.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Adapters.SQL
  alias Ankole.ActorRuntime.ActivationManager
  alias Ankole.ActorRuntime.TurnRetry
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway.AmbientRecall
  alias Ankole.SignalsGateway.Commands
  alias Ankole.SignalsGateway.IngressPipeline
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.JsonPayload
  alias Ankole.SignalsGateway.OutboxAdapter
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.SignalBinding
  alias Ankole.SignalsGateway.SignalChannel
  alias Ankole.SignalsGateway.SignalEntry

  # How long a provider-side removal blocks a re-delivered receive for the same entry.
  # 24h comfortably outlives any provider's redelivery/retry window while keeping
  # the guard transient — long enough that a straggler receive is caught, short
  # enough that the cleanup job keeps the table from growing without bound. It is
  # an ordering guard, not a permanent record of the deletion.
  @tombstone_ttl_seconds 24 * 60 * 60

  @addressed_text_window_ms 600
  @addressed_attachment_window_ms 1_200
  @addressed_long_text_window_ms 2_000
  @addressed_long_text_threshold 3_000
  @addressed_text_budget 4_000
  @addressed_text_hard_cap 8_000
  @addressed_max_entries 8
  @ambient_batch_window_ms 15_000
  # Ambient is intentionally slower than direct input: the recognizer is a
  # token-spending intervention check, not the user's immediate reply path.
  @ambient_hard_cap_ms 5 * 60 * 1_000

  @type ingress_result :: {:ok, map()} | {:error, term()}

  # Exponential backoff bounds for outbox retries: first retry ~5s out, doubling
  # each failed attempt, never waiting more than 5 minutes between tries. Small
  # base so a transient provider blip recovers quickly; 5m cap so a hard outage
  # doesn't hammer the provider while still retrying often enough to recover
  # promptly once it heals.
  @outbox_base_retry_seconds 5
  @outbox_max_retry_seconds 5 * 60
  @outbox_in_flight_recovery_seconds 60

  @doc """
  Creates or updates a per-agent signal binding.
  """
  @spec upsert_binding(map()) :: {:ok, SignalBinding.t()} | {:error, term()}
  def upsert_binding(attrs) when is_map(attrs) do
    %SignalBinding{}
    |> SignalBinding.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:inserted_at]},
      conflict_target: [:agent_uid, :name],
      returning: true
    )
  end

  @doc """
  Loads an enabled binding by route key.

  Distinguishes three failure modes an adapter cares about: a binding that
  exists but is operator-flagged unavailable (`{:binding_unavailable, reason}`),
  one that is explicitly disabled, and one that simply isn't configured. Every
  `emit_*` call starts here, so an unconfigured/disabled route is rejected before
  any fact is constructed.
  """
  @spec get_binding(String.t(), String.t()) :: {:ok, SignalBinding.t()} | {:error, term()}
  def get_binding(agent_uid, binding_name) do
    case Repo.get_by(SignalBinding, agent_uid: normalize_uid(agent_uid), name: binding_name) do
      %SignalBinding{enabled: true, unavailable_reason: reason} when is_binary(reason) ->
        {:error, {:binding_unavailable, reason}}

      %SignalBinding{enabled: true} = binding ->
        {:ok, binding}

      %SignalBinding{enabled: false} ->
        {:error, :binding_disabled}

      nil ->
        {:error, :binding_not_found}
    end
  end

  @doc """
  Concrete adapter API for a provider entry receive.

  The main ingress path for an inbound message. Follows the fixed pipeline:
  resolve binding → construct fact → filter → accept. A filtered signal returns
  `{:ok, %{status: :filtered}}` (a successful no-op, not an error), and the actor
  runtime is woken only when the signal actually produced new actor input.
  """
  @spec emit_entry(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_entry(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- get_binding(agent_uid, binding_name),
         {:ok, fact} <-
           IngressPipeline.construct(:entry, binding, input, now, &normalize_entry_fact/3),
         :match <- IngressPipeline.filter(binding, fact) do
      binding
      |> accept_entry(fact, options, now)
      |> wake_actor_runtime()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Concrete adapter API for a provider entry removal.

  Provider-specific event names such as "delete" or "recall" are source facts,
  not separate Ankole capabilities. They may be kept in
  `options[:provider_lifecycle_kind]` for diagnostics, while the actor-facing
  contract remains `signal.entry.removed`.
  """
  @spec emit_entry_removed(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_entry_removed(agent_uid, binding_name, input, options \\ []) do
    provider_lifecycle_kind =
      Keyword.get(options, :provider_lifecycle_kind) ||
        fetch_value(input, :provider_lifecycle_kind)

    provider_lifecycle_kind = normalize_provider_lifecycle_kind(provider_lifecycle_kind)

    emit_lifecycle(agent_uid, binding_name, input, provider_lifecycle_kind, options)
  end

  @doc """
  Concrete adapter API for reaction changes.

  Reactions only update the mirror — they never create actor input — so this
  path stays self-contained: lock the entry, fold the add/remove into its
  reaction map, done. A reaction on an entry we never mirrored is ignored
  (`:ignored_unknown_entry`) rather than treated as an error, since the gateway
  has no entry to attach it to.
  """
  @spec emit_reaction(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_reaction(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- get_binding(agent_uid, binding_name),
         {:ok, fact} <-
           IngressPipeline.construct(:reaction, binding, input, now, &normalize_reaction_fact/3),
         :match <- IngressPipeline.filter(binding, fact) do
      Repo.transact(fn repo ->
        # Advisory lock on the entry key serializes concurrent reaction folds for
        # the same message so two simultaneous add/removes can't clobber the
        # reactions map.
        with :ok <- lock_entry(repo, fact) do
          case repo.get_by(SignalEntry,
                 signal_channel_id: fact.signal_channel_id,
                 provider_entry_id: fact.provider_entry_id
               ) do
            %SignalEntry{} = entry ->
              entry
              |> SignalEntry.changeset(reaction_entry_attrs(entry, fact, now))
              |> repo.update()
              |> reaction_result()

            nil ->
              {:ok, %{status: :ignored_unknown_entry}}
          end
        end
      end)
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Concrete adapter API for provider actions such as card clicks.
  """
  @spec emit_action(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_action(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- get_binding(agent_uid, binding_name),
         {:ok, fact} <-
           IngressPipeline.construct(:action, binding, input, now, &normalize_action_fact/3),
         :match <- IngressPipeline.filter(binding, fact) do
      Repo.transact(fn repo ->
        with {:ok, channel} <- maybe_upsert_channel(repo, fact, now),
             {:ok, append_result} <-
               append_actor_input(binding, fact, fact.actor_input_type, channel, nil, now) do
          {:ok, actor_input_append_result(append_result, %{signal_channel: channel})}
        end
      end)
      |> wake_actor_runtime()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Appends an internal ActorInput, such as a timer fire, without provider mirroring.

  Internal sources (timers, system-generated events) have no provider channel or
  entry to mirror, so this path skips the channel/entry write entirely and goes
  straight to actor input. It is how Ankole feeds itself — e.g. a fired reminder
  becomes input to the session that scheduled it.
  """
  @spec emit_internal(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_internal(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- get_binding(agent_uid, binding_name),
         {:ok, fact} <-
           IngressPipeline.construct(:internal, binding, input, now, &normalize_internal_fact/3),
         :match <- IngressPipeline.filter(binding, fact) do
      Repo.transact(fn _repo ->
        with {:ok, append_result} <-
               append_actor_input(binding, fact, fact.actor_input_type, nil, nil, now) do
          {:ok, actor_input_append_result(append_result)}
        end
      end)
      |> wake_actor_runtime()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Records a provider-visible outbox intent committed by the actor runtime.

  This is the "commit" half of the outbox: the actor declares it wants to do
  something to the provider, transactionally, without performing it yet. The
  `on_conflict: :nothing` upsert on `{agent_uid, binding_name, outbound_key}` is
  the idempotency contract — committing the same `outbound_key` twice yields the
  same single row (and therefore at most one provider side effect). Actual
  delivery happens later via `dispatch_outbox`/`dispatch_due_outbox`.
  """
  @spec commit_outbox(map()) :: {:ok, OutboxEntry.t()} | {:error, term()}
  def commit_outbox(attrs) when is_map(attrs) do
    %OutboxEntry{}
    |> OutboxEntry.changeset(default_outbox_attrs(attrs))
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:agent_uid, :binding_name, :outbound_key],
      returning: true
    )
    |> outbox_insert_result(attrs)
  end

  @doc """
  Chooses the provider-visible reply operation for an actor input.

  Decides whether the agent's reply should be a threaded `:reply` to the
  triggering entry or a top-level `:post`, based on the channel's reply_mode and
  the adapter's declared capabilities. Falls back to a safe operation when the
  channel/binding can't be resolved, so a reply is never silently dropped.
  """
  @spec outbox_operation_for_actor_input(ActorInput.t(), module()) :: atom()
  def outbox_operation_for_actor_input(%ActorInput{} = actor_input, repo \\ Repo) do
    with %SignalChannel{} = channel <- repo.get(SignalChannel, actor_input.signal_channel_id),
         %SignalBinding{} = binding <-
           repo.get_by(SignalBinding,
             agent_uid: actor_input.agent_uid,
             name: actor_input.binding_name
           ) do
      choose_outbox_operation(
        channel,
        adapter_outbound_capabilities(binding.adapter),
        actor_input
      )
    else
      _value -> fallback_outbox_operation(actor_input)
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
  @spec dispatch_outbox(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  def dispatch_outbox(agent_uid, binding_name, outbound_key, adapter, options \\ []) do
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

  @doc """
  Lists outbox rows that are ready for a dispatch attempt.

  "Due" means either freshly `:created` or `:failed` and past its
  `next_attempt_at` with retries remaining. Oldest-first and capped by `limit`
  so a periodic dispatcher drains a bounded, fair batch each tick. Rows in
  `:sending`/`:succeeded`/`:unsupported`/`:unknown_after_send` are intentionally
  excluded — they are either in progress or terminal.
  """
  @spec list_due_outbox(DateTime.t(), pos_integer()) :: [OutboxEntry.t()]
  def list_due_outbox(now \\ DateTime.utc_now(:microsecond), limit \\ 50)
      when is_integer(limit) and limit > 0 do
    in_flight_cutoff = DateTime.add(now, -@outbox_in_flight_recovery_seconds, :second)

    OutboxEntry
    |> where([entry], entry.status == :created)
    |> or_where(
      [entry],
      entry.status == :failed and not is_nil(entry.next_attempt_at) and
        entry.next_attempt_at <= ^now and entry.attempt_count < entry.max_attempts
    )
    |> or_where(
      [entry],
      entry.status == :sending and not is_nil(entry.platform_send_started_at) and
        entry.platform_send_started_at <= ^in_flight_cutoff
    )
    |> order_by([entry], asc: entry.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Dispatches due outbox rows with a code-owned adapter resolver.
  """
  @spec dispatch_due_outbox(
          (OutboxEntry.t() -> {:ok, map()} | map() | {:error, term()}),
          keyword()
        ) ::
          [term()]
  def dispatch_due_outbox(adapter_resolver, options \\ [])
      when is_function(adapter_resolver, 1) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))
    limit = Keyword.get(options, :limit, 50)

    now
    |> list_due_outbox(limit)
    |> Enum.map(&dispatch_due_outbox_entry(&1, adapter_resolver, now))
  end

  defp prepare_outbox_dispatch(agent_uid, binding_name, outbound_key, adapter, now) do
    with {:ok, adapter} <- OutboxAdapter.normalize(adapter) do
      Repo.transact(fn repo ->
        with %OutboxEntry{} = outbox <-
               fetch_outbox_for_update(repo, agent_uid, binding_name, outbound_key),
             {:ok, channel} <- outbox_channel(repo, outbox) do
          case in_flight_recovery_action(outbox, adapter) do
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

  @doc """
  Removes expired SignalsGateway TTL state.

  Deletes tombstones whose guard window has passed. Driven by the cleanup Oban
  job; safe to run anytime since an expired tombstone no longer affects ingress.
  """
  @spec cleanup_expired_state(DateTime.t()) :: %{tombstones: non_neg_integer()}
  def cleanup_expired_state(now \\ DateTime.utc_now(:microsecond)) do
    {tombstones, _} =
      InputTombstone
      |> where([tombstone], tombstone.tombstoned_until <= ^now)
      |> Repo.delete_all()

    %{tombstones: tombstones}
  end

  @doc """
  Default actor session id derived from a signal channel.
  """
  @spec signal_session_id(String.t()) :: String.t()
  def signal_session_id(signal_channel_id), do: "signal-channel:#{signal_channel_id}"

  @doc """
  Closes pending inbound IM batches whose quiet window has elapsed.

  This is called by the actor activation poll before it scans ready
  `actor_inputs`, so worker delivery still starts from ordinary ActorInput rows.
  """
  @spec finalize_due_inbound_batches(keyword()) :: {:ok, [map()]} | {:error, term()}
  def finalize_due_inbound_batches(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    limit = Keyword.get(opts, :limit, 25)

    InboundBatch
    |> where([batch], batch.batch_state == "open")
    |> where([batch], batch.available_at <= ^now)
    |> order_by([batch], asc: batch.available_at, asc: batch.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&finalize_inbound_batch(&1, now))
    |> collect_results()
  end

  # Only a result that actually produced new actor input (:accepted) wakes the
  # runtime. Filtered / recorded / ignored / mirror-only outcomes wrote nothing
  # the actor needs to run on, so they must NOT cost a wake-up — this is the hook
  # that keeps ambient mirroring from constantly poking the scheduler.
  defp wake_actor_runtime({:ok, %{status: :accepted}} = result) do
    ActivationManager.wake()
    result
  end

  defp wake_actor_runtime(result), do: result

  defp emit_lifecycle(agent_uid, binding_name, input, provider_lifecycle_kind, options) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- get_binding(agent_uid, binding_name),
         constructor <- lifecycle_constructor(provider_lifecycle_kind),
         {:ok, fact} <- IngressPipeline.construct(:lifecycle, binding, input, now, constructor),
         :match <- IngressPipeline.filter(binding, fact) do
      binding
      |> accept_lifecycle(fact, now)
      |> TurnRetry.dispatch_retry_controls()
      |> wake_actor_runtime()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  # Whole acceptance runs in one transaction behind the per-entry advisory lock,
  # so concurrent receives for the same message serialize and the
  # tombstone-check → mirror → actor-input sequence is atomic. The tombstone
  # check comes first: if the human already removed this entry, drop the
  # late receive before writing anything.
  defp accept_entry(binding, fact, options, now) do
    Repo.transact(fn repo ->
      with :ok <- lock_entry(repo, fact) do
        case active_tombstone?(repo, fact, now) do
          true ->
            {:ok, %{status: :dropped_tombstoned}}

          false ->
            with {:ok, policy} <- entry_policy(binding, fact, options),
                 {:ok, result} <- apply_entry_policy(repo, binding, fact, policy, now) do
              {:ok, result}
            end
        end
      end
    end)
  end

  defp lifecycle_constructor(provider_lifecycle_kind) do
    fn binding, input, now ->
      normalize_lifecycle_fact(binding, input, provider_lifecycle_kind, now)
    end
  end

  # Removal is the inverse of accept and does several things atomically:
  # 1) drop a tombstone so a re-delivered receive can't resurrect the entry,
  # 2) remove the source from any open inbound batch, 3) remove the mirror row,
  # 4) cancel any still-pending actor input for that entry, and 5) for input the
  # agent ALREADY consumed, append a lifecycle "removed" input that
  # ActorRuntime consumes into an introspection note. Steps 2-4 cover work that
  # has not committed yet; step 5 covers committed actor state.
  defp accept_lifecycle(binding, fact, now) do
    Repo.transact(fn repo ->
      with {:ok, channel} <- upsert_channel(repo, fact, now),
           :ok <- lock_entry(repo, fact),
           :ok <- lock_inbound_batch(repo, fact),
           {:ok, tombstone} <- upsert_tombstone(repo, fact, now),
           {:ok, updated_batches} <- remove_pending_inbound_entry(repo, fact, now),
           {deleted_count, _rows} <- delete_mirror_entry(repo, fact),
           {:ok, runtime_retractions} <-
             TurnRetry.retract_source_entry_in_tx(repo, fact, :removed, now),
           consumed_inputs <-
             Actors.consumed_inputs_for_entry(
               fact.agent_uid,
               fact.binding_name,
               fact.signal_channel_id,
               fact.provider_entry_id
             ),
           {:ok, lifecycle_inputs} <-
             append_lifecycle_inputs(binding, fact, consumed_inputs, channel, now) do
        {:ok,
         %{
           status: :accepted,
           tombstone: tombstone,
           updated_inbound_batches: length(updated_batches),
           deleted_mirror_entries: deleted_count,
           canceled_actor_inputs: runtime_retractions.canceled_actor_inputs,
           retried_actor_inputs: runtime_retractions.retried_actor_inputs,
           runtime_retractions: runtime_retractions,
           lifecycle_inputs: lifecycle_inputs
         }}
      end
    end)
  end

  defp normalize_entry_fact(%SignalBinding{} = binding, input, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, signal_channel_id} <- required_text(input, :signal_channel_id),
         {:ok, provider_entry_id} <- required_text(input, :provider_entry_id),
         {:ok, attachments} <- normalize_attachments(input) do
      channel = fetch_map(input, :channel, %{})
      author = normalize_author_principal(binding, fetch_map(input, :author, %{}))

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         signal_channel_id: signal_channel_id,
         provider_entry_id: provider_entry_id,
         provider_thread_id: optional_text(input, :provider_thread_id),
         channel_kind:
           normalize_channel_kind(
             fetch_value(channel, :kind) || fetch_value(input, :channel_kind)
           ),
         reply_mode:
           normalize_reply_mode(
             fetch_value(channel, :reply_mode) || fetch_value(input, :reply_mode)
           ),
         channel_name: optional_text(channel, :name) || optional_text(input, :channel_name),
         channel_title: optional_text(channel, :title) || optional_text(input, :channel_title),
         channel_visibility:
           optional_text(channel, :visibility) || optional_text(input, :channel_visibility),
         channel_metadata: fetch_map(channel, :metadata, %{}),
         channel_raw_payload: fetch_map(channel, :raw_payload, fetch_map(channel, :raw, %{})),
         text: optional_text(input, :text),
         formatted_content: fetch_map(input, :formatted_content, %{}),
         attachments: attachments,
         links: fetch_list(input, :links),
         author: author,
         mentions: normalize_mentions(fetch_list(input, :mentions)),
         metadata: fetch_map(input, :metadata, %{}),
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         provider_time: fetch_datetime(input, :provider_time),
         explicit?:
           truthy?(fetch_value(input, :explicit)) ||
             structured_agent_mention?(input, binding.agent_uid),
         mirror_only?: truthy?(fetch_value(input, :mirror_only)),
         actor_input_type: optional_text(input, :actor_input_type),
         command_prefixes: fetch_list(input, :structured_mention_prefixes),
         sender_key: sender_key(input, author),
         gateway_time: now
       }}
    end
  end

  defp normalize_lifecycle_fact(%SignalBinding{} = binding, input, provider_lifecycle_kind, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, signal_channel_id} <- required_text(input, :signal_channel_id),
         {:ok, provider_entry_id} <- required_text(input, :provider_entry_id) do
      channel = fetch_map(input, :channel, %{})
      metadata = fetch_map(input, :metadata, %{})

      provider_lifecycle_kind =
        provider_lifecycle_kind ||
          metadata
          |> fetch_value(:provider_lifecycle_kind)
          |> normalize_provider_lifecycle_kind()

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         signal_channel_id: signal_channel_id,
         provider_entry_id: provider_entry_id,
         provider_thread_id: optional_text(input, :provider_thread_id),
         channel_kind:
           normalize_channel_kind(
             fetch_value(channel, :kind) || fetch_value(input, :channel_kind)
           ),
         reply_mode:
           normalize_reply_mode(
             fetch_value(channel, :reply_mode) || fetch_value(input, :reply_mode)
           ),
         channel_name: optional_text(channel, :name) || optional_text(input, :channel_name),
         channel_title: optional_text(channel, :title) || optional_text(input, :channel_title),
         channel_visibility:
           optional_text(channel, :visibility) || optional_text(input, :channel_visibility),
         channel_metadata: fetch_map(channel, :metadata, %{}),
         channel_raw_payload: fetch_map(channel, :raw_payload, fetch_map(channel, :raw, %{})),
         metadata: metadata,
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         provider_time: fetch_datetime(input, :provider_time),
         lifecycle_kind: :removed,
         provider_lifecycle_kind: provider_lifecycle_kind,
         gateway_time: now
       }}
    end
  end

  defp normalize_reaction_fact(%SignalBinding{} = binding, input, now) do
    with {:ok, signal_channel_id} <- required_text(input, :signal_channel_id),
         {:ok, provider_entry_id} <- required_text(input, :provider_entry_id),
         {:ok, reaction_key} <- required_text(input, :reaction_key),
         {:ok, actor_key} <- required_text(input, :actor_key) do
      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: optional_text(input, :ingress_event_id),
         signal_channel_id: signal_channel_id,
         provider_entry_id: provider_entry_id,
         reaction_key: reaction_key,
         actor_key: actor_key,
         action: normalize_reaction_action(fetch_value(input, :action)),
         raw_reaction_key: optional_text(input, :raw_reaction_key) || reaction_key,
         provider_time: fetch_datetime(input, :provider_time),
         gateway_time: now
       }}
    end
  end

  defp normalize_action_fact(%SignalBinding{} = binding, input, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, session_id} <- action_session_id(input),
         {:ok, action_id} <- required_text(input, :action_id) do
      signal_channel_id = optional_text(input, :signal_channel_id)
      channel = fetch_map(input, :channel, %{})

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         action_id: action_id,
         session_id: session_id,
         signal_channel_id: signal_channel_id,
         provider_entry_id: optional_text(input, :provider_entry_id),
         provider_thread_id: optional_text(input, :provider_thread_id),
         sender_key: nil,
         channel_kind:
           normalize_channel_kind(
             fetch_value(channel, :kind) || fetch_value(input, :channel_kind)
           ),
         reply_mode:
           normalize_reply_mode(
             fetch_value(channel, :reply_mode) || fetch_value(input, :reply_mode)
           ),
         channel_name: optional_text(channel, :name) || optional_text(input, :channel_name),
         channel_title: optional_text(channel, :title) || optional_text(input, :channel_title),
         channel_visibility:
           optional_text(channel, :visibility) || optional_text(input, :channel_visibility),
         channel_metadata: fetch_map(channel, :metadata, %{}),
         channel_raw_payload: fetch_map(channel, :raw_payload, fetch_map(channel, :raw, %{})),
         actor_input_type: optional_text(input, :actor_input_type) || "signal.action.invoked",
         action: fetch_map(input, :action, input),
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         gateway_time: now
       }}
    end
  end

  defp normalize_internal_fact(%SignalBinding{} = binding, input, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, session_id} <- required_text(input, :session_id) do
      actor_input_type =
        optional_text(input, :actor_input_type) || optional_text(input, :type) || "timer.fired"

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         session_id: session_id,
         signal_channel_id: nil,
         provider_entry_id: nil,
         provider_thread_id: nil,
         sender_key: nil,
         actor_input_type: actor_input_type,
         timer_id: optional_text(input, :timer_id),
         internal_subject: optional_text(input, :subject),
         internal: fetch_map(input, :internal, input),
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         gateway_time: now
       }}
    end
  end

  # The routing decision: given an accepted entry fact, what should it become?
  # Order matters — these are tried top to bottom and the first match wins:
  #   1. mirror_only: caller asked to only record, never wake the agent.
  #   2. a recognized /slash command in addressed text → command.* input.
  #   3. an adapter-supplied explicit actor_input_type (non-IM sources).
  #   4. a DM, or a group message that explicitly @-addresses the agent → a
  #      normal addressed message.
  #   5. a group reply to one of the agent's own clarifying questions → also
  #      treated as addressed (the human is answering us).
  #   6. an unaddressed group message → defer to the binding's group policy.
  #   7. otherwise there is no rule that turns this into input → error.
  defp entry_policy(%SignalBinding{} = binding, fact, options) do
    cond do
      fact.mirror_only? ->
        {:ok, :record_only}

      command = command_payload(fact) ->
        {:ok, {:actor_input, "command.#{command["name"]}", command}}

      fact.actor_input_type ->
        {:ok, {:actor_input, fact.actor_input_type, nil}}

      explicit_im_entry?(fact) ->
        {:ok, {:actor_input, "im.message.addressed", nil}}

      clarify_reply?(binding, fact, options) ->
        {:ok, {:actor_input, "im.message.addressed", nil}}

      fact.channel_kind == :im_group ->
        group_policy(binding.unaddressed_group_message_policy)

      true ->
        {:error, :missing_actor_input_type}
    end
  end

  defp group_policy(:ignore), do: {:ok, :ignore}
  defp group_policy(:record_only), do: {:ok, :record_only}
  defp group_policy(:may_intervene), do: {:ok, {:actor_input, "im.message.may_intervene", nil}}

  # "Explicit" = the agent is unambiguously being talked to: every DM qualifies,
  # and a group message qualifies only if it @-mentions the agent. This gates
  # both command parsing and the default addressed-message path.
  defp explicit_im_entry?(%{channel_kind: :im_dm}), do: true
  defp explicit_im_entry?(%{channel_kind: :im_group, explicit?: true}), do: true
  defp explicit_im_entry?(_fact), do: false

  # Lets a human answer the agent's clarifying question in a group without having
  # to re-@-mention it. Only relevant for group text messages; the actual "did
  # the agent recently ask something here" check is injected by the caller as
  # `clarify_lookup` (kept out of the gateway so this module stays free of
  # conversation-history queries). Accepts a 1- or 2-arity lookup for caller
  # convenience.
  defp clarify_reply?(_binding, %{channel_kind: channel_kind}, _options)
       when channel_kind != :im_group,
       do: false

  defp clarify_reply?(_binding, %{text: text}, _options) when not is_binary(text), do: false

  defp clarify_reply?(binding, fact, options) do
    case Keyword.get(options, :clarify_lookup) do
      lookup when is_function(lookup, 2) -> lookup.(binding, fact) == true
      lookup when is_function(lookup, 1) -> lookup.(fact) == true
      _lookup -> false
    end
  end

  # Commands are only honored when the agent is explicitly addressed, so a "/stop"
  # overheard in an unaddressed group line is not treated as a command. The
  # leading @-mention is stripped before classification so "@agent /stop" parses.
  defp command_payload(fact) do
    case explicit_im_entry?(fact) do
      true ->
        case Commands.classify(fact.text,
               strip_leading_structured_mention: fact.explicit?,
               structured_mention_prefixes: fact.command_prefixes
             ) do
          {:ok, command} -> command
          :not_command -> nil
        end

      false ->
        nil
    end
  end

  defp apply_entry_policy(repo, binding, fact, :ignore, now)
       when fact.channel_kind == :im_group do
    apply_im_entry_policy(repo, binding, fact, :ignore, nil, now)
  end

  defp apply_entry_policy(_repo, _binding, _fact, :ignore, _now) do
    {:ok, %{status: :ignored}}
  end

  defp apply_entry_policy(repo, binding, fact, :record_only, now)
       when fact.channel_kind in [:im_dm, :im_group] do
    apply_im_entry_policy(repo, binding, fact, :record_only, nil, now)
  end

  defp apply_entry_policy(repo, _binding, fact, :record_only, now) do
    with {:ok, channel} <- upsert_channel(repo, fact, now),
         {:ok, entry} <- mirror_receive_entry(repo, fact, now) do
      {:ok, %{status: :recorded, signal_channel: channel, signal_entry: entry}}
    end
  end

  # The direct accept path is for non-IM inputs and typed command events. IM text
  # and attachment traffic has already been diverted into pending inbound batches.
  defp apply_entry_policy(repo, binding, fact, {:actor_input, "im.message.addressed", nil}, now)
       when fact.channel_kind in [:im_dm, :im_group] do
    apply_im_entry_policy(repo, binding, fact, :ignore, "im.message.addressed", now)
  end

  defp apply_entry_policy(
         repo,
         binding,
         fact,
         {:actor_input, "im.message.may_intervene", nil},
         now
       )
       when fact.channel_kind == :im_group do
    apply_im_entry_policy(repo, binding, fact, :may_intervene, nil, now)
  end

  defp apply_entry_policy(repo, binding, fact, {:actor_input, type, command_payload}, now) do
    fact = Map.put(fact, :command_payload, command_payload)

    with {:ok, channel} <- upsert_channel(repo, fact, now),
         {:ok, entry} <- mirror_receive_entry(repo, fact, now),
         {:ok, append_result} <- append_actor_input(binding, fact, type, channel, entry, now) do
      {:ok,
       actor_input_append_result(append_result, %{
         signal_channel: channel,
         signal_entry: entry
       })}
    end
  end

  defp apply_im_entry_policy(repo, binding, fact, policy, type, now) do
    with :ok <- lock_inbound_batch(repo, fact),
         {:ok, channel} <- upsert_channel(repo, fact, now),
         {:ok, mirror_entry} <- maybe_mirror_im_entry(repo, fact, policy, type, now),
         source_entry <- inbound_batch_entry(fact, mirror_entry, policy, type, now),
         {:ok, result} <-
           fact
           |> open_inbound_batch(repo)
           |> maybe_finalize_due_batch(repo, now)
           |> route_inbound_batch_entry(
             repo,
             binding,
             channel,
             fact,
             source_entry,
             policy,
             type,
             now
           ) do
      result =
        result
        |> Map.put(:signal_channel, channel)
        |> maybe_put_result(:signal_entry, mirror_entry)

      {:ok, result}
    end
  end

  defp actor_input_append_result(append_result, extra \\ %{})

  defp actor_input_append_result(%ActorInput{} = actor_input, extra) do
    extra
    |> Map.merge(%{status: :accepted, actor_input: actor_input})
  end

  defp maybe_put_result(result, _key, nil), do: result
  defp maybe_put_result(result, key, value), do: Map.put(result, key, value)

  defp maybe_mirror_im_entry(repo, fact, policy, type, now) do
    case should_mirror_im_entry?(policy, type) do
      true -> mirror_receive_entry(repo, fact, now)
      false -> {:ok, nil}
    end
  end

  defp should_mirror_im_entry?(_policy, "im.message.addressed"), do: true
  defp should_mirror_im_entry?(:record_only, _type), do: true
  defp should_mirror_im_entry?(:may_intervene, _type), do: true
  defp should_mirror_im_entry?(_policy, _type), do: false

  defp maybe_finalize_due_batch(nil, _repo, _now), do: {:ok, nil}

  defp maybe_finalize_due_batch(%InboundBatch{available_at: available_at} = batch, repo, now) do
    case DateTime.compare(available_at, now) do
      :gt ->
        {:ok, batch}

      _ready ->
        with {:ok, _result} <- finalize_inbound_batch_in_tx(repo, batch, now) do
          {:ok, nil}
        end
    end
  end

  defp route_inbound_batch_entry(
         {:ok, batch},
         repo,
         binding,
         channel,
         fact,
         entry,
         policy,
         type,
         now
       ) do
    route_inbound_batch_entry(batch, repo, binding, channel, fact, entry, policy, type, now)
  end

  defp route_inbound_batch_entry(
         batch,
         repo,
         binding,
         channel,
         fact,
         entry,
         policy,
         "im.message.addressed",
         now
       ) do
    append_addressed_inbound_entry(batch, repo, binding, channel, fact, entry, policy, now)
  end

  defp route_inbound_batch_entry(batch, repo, binding, channel, fact, entry, policy, _type, now) do
    append_neutral_inbound_entry(batch, repo, binding, channel, fact, entry, policy, now)
  end

  defp append_addressed_inbound_entry(nil, repo, _binding, _channel, fact, entry, policy, now)
       when is_map(entry) do
    create_inbound_batch(repo, fact, policy, "addressed", [entry], now)
    |> inbound_result(:accepted)
  end

  defp append_addressed_inbound_entry(
         %InboundBatch{mode: "addressed"} = batch,
         repo,
         binding,
         channel,
         fact,
         entry,
         policy,
         now
       ) do
    cond do
      batch.requester_sender_key == fact.sender_key and not non_bot_mention?(entry) and
          not addressed_batch_full?(batch.entries, entry) ->
        update_inbound_batch(batch, repo, [entry], now)
        |> inbound_result(:accepted)

      true ->
        with {:ok, _closed} <- finalize_inbound_batch_in_tx(repo, batch, now),
             {:ok, result} <-
               append_addressed_inbound_entry(
                 nil,
                 repo,
                 binding,
                 channel,
                 fact,
                 entry,
                 policy,
                 now
               ) do
          {:ok, result}
        end
    end
  end

  defp append_addressed_inbound_entry(
         %InboundBatch{mode: "neutral"} = batch,
         repo,
         binding,
         channel,
         fact,
         entry,
         policy,
         now
       ) do
    {prefix, tail} = split_addressable_tail(batch.entries, fact.sender_key)

    with {:ok, _closed_prefix} <- close_or_replace_neutral_prefix(repo, batch, prefix, tail, now),
         {:ok, result} <-
           append_addressed_inbound_entry(
             nil,
             repo,
             binding,
             channel,
             fact,
             tail ++ [entry],
             policy,
             now
           ) do
      {:ok, result}
    end
  end

  defp append_addressed_inbound_entry(
         nil,
         repo,
         _binding,
         _channel,
         fact,
         entries,
         policy,
         now
       )
       when is_list(entries) do
    create_inbound_batch(repo, fact, policy, "addressed", entries, now)
    |> inbound_result(:accepted)
  end

  defp append_neutral_inbound_entry(nil, repo, _binding, _channel, fact, entry, policy, now) do
    create_inbound_batch(repo, fact, policy, "neutral", [entry], now)
    |> inbound_result(neutral_status(policy))
  end

  defp append_neutral_inbound_entry(
         %InboundBatch{mode: "neutral"} = batch,
         repo,
         _binding,
         _channel,
         _fact,
         entry,
         policy,
         now
       ) do
    batch
    |> update_inbound_batch(repo, [entry], now)
    |> inbound_result(neutral_status(policy))
  end

  defp append_neutral_inbound_entry(
         %InboundBatch{mode: "addressed"} = batch,
         repo,
         binding,
         channel,
         fact,
         entry,
         policy,
         now
       ) do
    cond do
      batch.requester_sender_key == fact.sender_key and addressable_neutral_entry?(entry) and
          not addressed_batch_full?(batch.entries, entry) ->
        batch
        |> update_inbound_batch(repo, [entry], now)
        |> inbound_result(:accepted)

      batch.requester_sender_key == fact.sender_key and addressable_neutral_entry?(entry) ->
        with {:ok, _closed} <- finalize_inbound_batch_in_tx(repo, batch, now),
             {:ok, result} <-
               create_inbound_batch(repo, fact, policy, "addressed", [entry], now)
               |> inbound_result(:accepted) do
          {:ok, result}
        end

      true ->
        with {:ok, _closed} <- finalize_inbound_batch_in_tx(repo, batch, now),
             {:ok, result} <-
               append_neutral_inbound_entry(nil, repo, binding, channel, fact, entry, policy, now) do
          {:ok, result}
        end
    end
  end

  defp close_or_replace_neutral_prefix(repo, batch, [], _tail, now) do
    cancel_inbound_batch(repo, batch, now, %{entries: []})
  end

  defp close_or_replace_neutral_prefix(repo, batch, prefix, [] = _tail, now) do
    batch
    |> InboundBatch.changeset(%{entries: prefix})
    |> repo.update()
    |> case do
      {:ok, updated} -> finalize_inbound_batch_in_tx(repo, updated, now)
      {:error, _reason} = error -> error
    end
  end

  defp close_or_replace_neutral_prefix(repo, batch, prefix, tail, now) do
    batch
    |> InboundBatch.changeset(%{entries: prefix})
    |> repo.update()
    |> case do
      {:ok, updated} -> finalize_inbound_batch_in_tx(repo, updated, now)
      {:error, _reason} = error -> error
    end
    |> case do
      {:ok, _closed} -> {:ok, tail}
      {:error, _reason} = error -> error
    end
  end

  defp inbound_result({:ok, %InboundBatch{} = batch}, status) do
    {:ok, %{status: status, inbound_batch: batch}}
  end

  defp inbound_result({:error, _reason} = error, _status), do: error

  defp neutral_status(:record_only), do: :recorded
  defp neutral_status(:may_intervene), do: :recorded
  defp neutral_status(:ignore), do: :ignored

  defp finalize_inbound_batch(%InboundBatch{} = batch, now) do
    Repo.transact(fn repo ->
      with :ok <- lock_inbound_batch(repo, batch),
           %InboundBatch{} = fresh <- repo.get(InboundBatch, batch.id) do
        case fresh.batch_state do
          "open" -> finalize_inbound_batch_in_tx(repo, fresh, now)
          _closed -> {:ok, %{status: :already_finalized, inbound_batch: fresh}}
        end
      else
        nil -> {:ok, %{status: :missing}}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp finalize_inbound_batch_in_tx(repo, %InboundBatch{entries: []} = batch, now) do
    cancel_inbound_batch(repo, batch, now)
  end

  defp finalize_inbound_batch_in_tx(repo, %InboundBatch{mode: "addressed"} = batch, now) do
    with {:ok, append_result} <-
           append_batch_actor_input(repo, batch, "im.message.addressed", now) do
      finalize_batch_actor_input_append(repo, batch, now, "addressed", append_result)
    end
  end

  defp finalize_inbound_batch_in_tx(repo, %InboundBatch{mode: "neutral"} = batch, now) do
    case batch.policy do
      "may_intervene" ->
        with {:ok, append_result} <-
               append_batch_actor_input(repo, batch, "im.message.may_intervene", now) do
          finalize_batch_actor_input_append(repo, batch, now, "ambient", append_result)
        end

      _no_actor_input ->
        with {:ok, closed} <-
               batch
               |> InboundBatch.changeset(%{
                 batch_state: "finalized",
                 outcome: "no_actor_input",
                 finalized_at: now,
                 batch_revision: batch.batch_revision + 1
               })
               |> repo.update() do
          {:ok, %{status: :ignored, inbound_batch: closed}}
        end
    end
  end

  defp finalize_batch_actor_input_append(
         repo,
         %InboundBatch{} = batch,
         now,
         outcome,
         %ActorInput{} = actor_input
       ) do
    with {:ok, closed} <-
           batch
           |> InboundBatch.changeset(%{
             batch_state: "finalized",
             outcome: outcome,
             finalized_at: now,
             actor_input_id: actor_input.id,
             batch_revision: batch.batch_revision + 1
           })
           |> repo.update() do
      {:ok, %{status: :accepted, actor_input: actor_input, inbound_batch: closed}}
    end
  end

  defp cancel_inbound_batch(repo, batch, now, extra_attrs \\ %{}) do
    attrs =
      %{
        batch_state: "canceled",
        outcome: "canceled",
        finalized_at: now,
        batch_revision: batch.batch_revision + 1
      }
      |> Map.merge(extra_attrs)

    with {:ok, closed} <-
           batch
           |> InboundBatch.changeset(attrs)
           |> repo.update() do
      {:ok, %{status: :canceled, inbound_batch: closed}}
    end
  end

  defp remove_pending_inbound_entry(repo, fact, now) do
    fact
    |> pending_inbound_batches_for_lifecycle(repo)
    |> Enum.map(&remove_entry_from_inbound_batch(repo, &1, fact, now))
    |> collect_results()
    |> case do
      {:ok, results} -> {:ok, Enum.reject(results, &is_nil/1)}
      {:error, _reason} = error -> error
    end
  end

  defp pending_inbound_batches_for_lifecycle(fact, repo) do
    InboundBatch
    |> where([batch], batch.agent_uid == ^fact.agent_uid)
    |> where([batch], batch.binding_name == ^fact.binding_name)
    |> where([batch], batch.signal_channel_id == ^fact.signal_channel_id)
    |> maybe_where_thread(fact.provider_thread_id)
    |> where([batch], batch.batch_state == "open")
    |> order_by([batch], asc: batch.inserted_at)
    |> lock("FOR UPDATE")
    |> repo.all()
  end

  defp maybe_where_thread(query, nil), do: query

  defp maybe_where_thread(query, provider_thread_id) do
    where(query, [batch], batch.provider_thread_id == ^thread_key(provider_thread_id))
  end

  defp remove_entry_from_inbound_batch(repo, %InboundBatch{} = batch, fact, now) do
    entries = Enum.reject(batch.entries, &(&1["provider_entry_id"] == fact.provider_entry_id))

    cond do
      length(entries) == length(batch.entries) ->
        {:ok, nil}

      entries == [] ->
        with {:ok, %{inbound_batch: closed}} <-
               cancel_inbound_batch(repo, batch, now, %{entries: []}) do
          {:ok, closed}
        end

      true ->
        batch
        |> InboundBatch.changeset(%{
          entries: entries,
          requester_sender_key: requester_sender_key(batch.mode, entries),
          available_at: inbound_due_at(batch.mode, batch.policy, entries, batch, now),
          hard_cap_at: inbound_hard_cap_at(batch.mode, batch.policy, batch, now),
          batch_revision: batch.batch_revision + 1
        })
        |> repo.update()
    end
  end

  defp append_batch_actor_input(repo, batch, type, now) do
    with {:ok, binding} <- batch_binding(repo, batch),
         {:ok, channel} <- batch_channel(repo, batch),
         :ok <- mirror_unmirrored_batch_entries(repo, batch.entries, now) do
      fact = batch_actor_fact(batch, type, now)
      append_actor_input(binding, fact, type, channel, nil, now)
    end
  end

  defp batch_binding(repo, %InboundBatch{} = batch) do
    case repo.get_by(SignalBinding, agent_uid: batch.agent_uid, name: batch.binding_name) do
      %SignalBinding{} = binding -> {:ok, binding}
      nil -> {:error, :binding_not_found}
    end
  end

  defp batch_channel(repo, %InboundBatch{} = batch) do
    case repo.get(SignalChannel, batch.signal_channel_id) do
      %SignalChannel{} = channel -> {:ok, channel}
      nil -> {:error, :signal_channel_not_found}
    end
  end

  defp create_inbound_batch(repo, fact, policy, mode, entries, now) do
    policy = Atom.to_string(policy)

    attrs = %{
      agent_uid: fact.agent_uid,
      binding_name: fact.binding_name,
      session_id: Map.get(fact, :session_id) || signal_session_id(fact.signal_channel_id),
      signal_channel_id: fact.signal_channel_id,
      provider_thread_id: thread_key(fact.provider_thread_id),
      batch_state: "open",
      mode: mode,
      policy: policy,
      requester_sender_key: requester_sender_key(mode, entries),
      entries: entries,
      available_at: inbound_due_at(mode, policy, entries, nil, now),
      hard_cap_at: inbound_hard_cap_at(mode, policy, nil, now)
    }

    %InboundBatch{}
    |> InboundBatch.changeset(attrs)
    |> repo.insert()
  end

  defp update_inbound_batch(%InboundBatch{} = batch, repo, new_entries, now) do
    entries = batch.entries ++ new_entries

    batch
    |> InboundBatch.changeset(%{
      entries: entries,
      requester_sender_key: requester_sender_key(batch.mode, entries),
      available_at: inbound_due_at(batch.mode, batch.policy, entries, batch, now),
      hard_cap_at: inbound_hard_cap_at(batch.mode, batch.policy, batch, now)
    })
    |> repo.update()
  end

  defp open_inbound_batch(fact, repo) do
    InboundBatch
    |> where([batch], batch.agent_uid == ^fact.agent_uid)
    |> where([batch], batch.binding_name == ^fact.binding_name)
    |> where([batch], batch.signal_channel_id == ^fact.signal_channel_id)
    |> where([batch], batch.provider_thread_id == ^thread_key(fact.provider_thread_id))
    |> where([batch], batch.batch_state == "open")
    |> order_by([batch], asc: batch.inserted_at)
    |> limit(1)
    |> repo.one()
  end

  defp inbound_batch_entry(fact, mirror_entry, policy, type, now) do
    attrs = receive_entry_attrs(fact, now)

    %{
      "signal_channel_id" => fact.signal_channel_id,
      "provider_entry_id" => fact.provider_entry_id,
      "provider_thread_id" => fact.provider_thread_id,
      "sender_key" => fact.sender_key,
      "text" => fact.text,
      "formatted_content" => fact.formatted_content,
      "attachments" => fact.attachments,
      "links" => fact.links,
      "author" => fact.author,
      "mentions" => fact.mentions,
      "metadata" => signal_entry_metadata(fact),
      "raw_payload" => fact.raw_payload,
      "provider_time" => datetime_iso8601(fact.provider_time),
      "sent_at" => datetime_iso8601(fact.provider_time) || DateTime.to_iso8601(now),
      "document_id" => attrs.document_id,
      "search_text" => attrs.search_text,
      "metadata_text" => attrs.metadata_text,
      "content_hash" => attrs.content_hash,
      "explicit" => type == "im.message.addressed",
      "policy" => Atom.to_string(policy),
      "mirrored" => not is_nil(mirror_entry),
      "addressable_neutral" => addressable_neutral_fact?(fact, type),
      "non_bot_mention" => non_bot_mention?(fact),
      "text_length" => text_length(fact.text)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp batch_actor_fact(%InboundBatch{} = batch, type, now) do
    entries = batch.entries
    last_entry = List.last(entries) || %{}

    %{
      agent_uid: batch.agent_uid,
      binding_name: batch.binding_name,
      session_id: batch.session_id,
      ingress_event_id: "inbound-batch:#{batch.id}:#{batch.batch_revision + 1}",
      signal_channel_id: batch.signal_channel_id,
      provider_entry_id: last_entry["provider_entry_id"],
      provider_thread_id: unthread_key(batch.provider_thread_id),
      sender_key: batch.requester_sender_key,
      text: merged_entry_text(entries),
      attachments: merged_entry_list(entries, "attachments"),
      links: merged_entry_list(entries, "links"),
      author: last_entry["author"] || %{},
      mentions: merged_entry_list(entries, "mentions"),
      metadata: %{
        "source" => "inbound_batch",
        "batch_id" => batch.id,
        "batch_revision" => batch.batch_revision + 1,
        "source_provider_entry_ids" => Enum.map(entries, & &1["provider_entry_id"]),
        "source_signal_entries" =>
          Enum.map(entries, fn entry ->
            %{
              "signal_channel_id" => entry["signal_channel_id"],
              "provider_entry_id" => entry["provider_entry_id"]
            }
          end)
      },
      raw_payload: %{},
      provider_time: parse_datetime(last_entry["provider_time"]),
      available_at: now,
      finalized_batch_id: batch.id,
      batch_entries: entries,
      batch_outcome: type
    }
  end

  defp mirror_unmirrored_batch_entries(repo, entries, now) do
    entries
    |> Enum.reject(& &1["mirrored"])
    |> Enum.map(&mirror_batch_entry(repo, &1, now))
    |> collect_results()
    |> case do
      {:ok, _entries} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp mirror_batch_entry(repo, entry, now) do
    attrs = %{
      signal_channel_id: entry["signal_channel_id"],
      provider_entry_id: entry["provider_entry_id"],
      text: entry["text"],
      formatted_content: entry["formatted_content"] || %{},
      attachments: entry["attachments"] || [],
      links: entry["links"] || [],
      author: entry["author"] || %{},
      mentions: entry["mentions"] || [],
      metadata: entry["metadata"] || %{},
      raw_payload: entry["raw_payload"] || %{},
      provider_time: parse_datetime(entry["provider_time"]),
      fallback_visible_text: entry["text"],
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: entry["document_id"],
      search_text: entry["search_text"],
      metadata_text: entry["metadata_text"],
      content_hash: entry["content_hash"],
      first_seen_at: now,
      last_seen_at: now
    }

    case repo.get_by(SignalEntry,
           signal_channel_id: attrs.signal_channel_id,
           provider_entry_id: attrs.provider_entry_id
         ) do
      %SignalEntry{} = existing ->
        existing
        |> SignalEntry.changeset(%{
          attrs
          | first_seen_at: existing.first_seen_at,
            reactions: existing.reactions || %{},
            raw_reaction_keys: existing.raw_reaction_keys || %{}
        })
        |> repo.update()

      nil ->
        %SignalEntry{}
        |> SignalEntry.changeset(attrs)
        |> repo.insert()
    end
  end

  defp split_addressable_tail(entries, sender_key) do
    {tail_reversed, prefix_reversed} =
      entries
      |> Enum.reverse()
      |> Enum.split_while(fn entry ->
        entry["sender_key"] == sender_key and addressable_neutral_entry?(entry)
      end)

    {Enum.reverse(prefix_reversed), Enum.reverse(tail_reversed)}
  end

  defp addressable_neutral_fact?(fact, type) do
    type != "im.message.addressed" and fact.channel_kind == :im_group and
      not non_bot_mention?(fact)
  end

  defp addressable_neutral_entry?(entry), do: entry["addressable_neutral"] == true

  defp non_bot_mention?(%{} = entry) when is_map_key(entry, "non_bot_mention"),
    do: entry["non_bot_mention"] == true

  defp non_bot_mention?(fact) do
    fact
    |> Map.get(:mentions, [])
    |> Enum.any?(fn mention -> structured_non_bot_mention?(mention, fact.agent_uid) end)
  end

  defp structured_non_bot_mention?(mention, agent_uid) when is_map(mention) do
    structured? =
      truthy?(fetch_value(mention, :structured)) ||
        not is_nil(fetch_value(mention, :kind))

    structured? and not structured_mention?(mention, agent_uid)
  end

  defp structured_non_bot_mention?(_mention, _agent_uid), do: false

  defp addressed_batch_full?(entries, entry) do
    length(entries) >= @addressed_max_entries or text_budget_full?(entries, entry)
  end

  defp text_budget_full?(entries, entry) do
    current = entries_text_length(entries)
    incoming = entry["text_length"] || text_length(entry["text"])
    total = current + incoming

    cond do
      entries == [] -> false
      total <= @addressed_text_budget -> false
      long_text_continuation?(entries, entry) and total <= @addressed_text_hard_cap -> false
      true -> true
    end
  end

  defp long_text_continuation?(entries, entry) do
    previous = List.last(entries) || %{}

    (previous["text_length"] || 0) >= @addressed_long_text_threshold or
      (entry["text_length"] || 0) >= @addressed_long_text_threshold
  end

  defp inbound_due_at("addressed", _policy, entries, _batch, now) do
    DateTime.add(now, addressed_entry_window_ms(List.last(entries) || %{}), :millisecond)
  end

  defp inbound_due_at("neutral", "may_intervene", _entries, %InboundBatch{} = batch, now) do
    min_datetime(DateTime.add(now, @ambient_batch_window_ms, :millisecond), batch.hard_cap_at)
  end

  defp inbound_due_at("neutral", "may_intervene", _entries, nil, now) do
    DateTime.add(now, @ambient_batch_window_ms, :millisecond)
  end

  defp inbound_due_at("neutral", _policy, entries, _batch, now) do
    DateTime.add(now, addressed_entry_window_ms(List.last(entries) || %{}), :millisecond)
  end

  defp inbound_hard_cap_at("neutral", "may_intervene", nil, now) do
    DateTime.add(now, @ambient_hard_cap_ms, :millisecond)
  end

  defp inbound_hard_cap_at("neutral", "may_intervene", %InboundBatch{} = batch, _now),
    do: batch.hard_cap_at

  defp inbound_hard_cap_at(_mode, _policy, _batch, _now), do: nil

  defp addressed_entry_window_ms(entry) do
    cond do
      (entry["text_length"] || 0) >= @addressed_long_text_threshold ->
        @addressed_long_text_window_ms

      entry_has_attachments?(entry) ->
        @addressed_attachment_window_ms

      true ->
        @addressed_text_window_ms
    end
  end

  defp entry_has_attachments?(entry) do
    case entry["attachments"] do
      [_ | _] -> true
      _value -> false
    end
  end

  defp requester_sender_key("addressed", entries) do
    entries
    |> List.last()
    |> case do
      %{} = entry -> entry["sender_key"]
      _value -> nil
    end
  end

  defp requester_sender_key(_mode, _entries), do: nil

  defp merged_entry_text(entries) do
    entries
    |> Enum.map(& &1["text"])
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
  end

  defp merged_entry_list(entries, key) do
    entries
    |> Enum.flat_map(fn entry ->
      case entry[key] do
        values when is_list(values) -> values
        _value -> []
      end
    end)
  end

  defp entries_text_length(entries) do
    entries
    |> Enum.map(fn entry -> entry["text_length"] || text_length(entry["text"]) end)
    |> Enum.sum()
  end

  defp text_length(text) when is_binary(text), do: String.length(text)
  defp text_length(_text), do: 0

  defp thread_key(nil), do: ""
  defp thread_key(value) when is_binary(value), do: value
  defp thread_key(value), do: to_string(value)

  defp unthread_key(""), do: nil
  defp unthread_key(value), do: value

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_datetime(%DateTime{} = value), do: value
  defp parse_datetime(_value), do: nil

  defp maybe_upsert_channel(_repo, %{signal_channel_id: nil}, _now), do: {:ok, nil}
  defp maybe_upsert_channel(repo, fact, now), do: upsert_channel(repo, fact, now)

  defp upsert_channel(repo, fact, now) do
    attrs = %{
      id: fact.signal_channel_id,
      kind: fact.channel_kind,
      reply_mode: fact.reply_mode,
      name: fact.channel_name,
      title: fact.channel_title,
      visibility: fact.channel_visibility,
      metadata: fact.channel_metadata,
      raw_payload: fact.channel_raw_payload,
      first_seen_at: now,
      last_seen_at: now
    }

    case repo.get(SignalChannel, fact.signal_channel_id) do
      %SignalChannel{} = channel ->
        channel
        |> SignalChannel.changeset(merge_channel_attrs(channel, attrs))
        |> repo.update()

      nil ->
        %SignalChannel{}
        |> SignalChannel.changeset(attrs)
        |> repo.insert(on_conflict: :nothing, conflict_target: :id, returning: true)
        |> case do
          {:ok, %SignalChannel{id: id} = channel} when is_binary(id) ->
            {:ok, channel}

          {:ok, %SignalChannel{id: nil}} ->
            update_existing_channel(repo, fact.signal_channel_id, attrs)

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp update_existing_channel(repo, signal_channel_id, attrs) do
    case repo.get(SignalChannel, signal_channel_id) do
      %SignalChannel{} = channel ->
        channel
        |> SignalChannel.changeset(merge_channel_attrs(channel, attrs))
        |> repo.update()

      nil ->
        {:error, :signal_channel_conflict_not_visible}
    end
  end

  # Different providers send different subsets of channel detail per event, so a
  # later sparse event must not erase richer data from an earlier one. The merge
  # rule is "don't overwrite with nothing": a sparse enum (:unknown/:none), a nil
  # text field, or an empty map all keep the previously stored value.
  # `first_seen_at` is always preserved since it records the first observation.
  defp merge_channel_attrs(%SignalChannel{} = channel, attrs) do
    %{
      attrs
      | kind: preserve_enum(attrs.kind, :unknown, channel.kind),
        reply_mode: preserve_enum(attrs.reply_mode, :none, channel.reply_mode),
        name: attrs.name || channel.name,
        title: attrs.title || channel.title,
        visibility: attrs.visibility || channel.visibility,
        metadata: preserve_empty_map(attrs.metadata, channel.metadata),
        raw_payload: preserve_empty_map(attrs.raw_payload, channel.raw_payload),
        first_seen_at: channel.first_seen_at
    }
  end

  # `sparse_value` is the enum's "no info" member (:unknown / :none); receiving it
  # means the event carried no channel kind / reply mode, so keep what we had.
  defp preserve_enum(incoming, sparse_value, existing) when incoming == sparse_value, do: existing
  defp preserve_enum(incoming, _sparse_value, _existing), do: incoming

  defp preserve_empty_map(map, existing) when map == %{}, do: existing || %{}
  defp preserve_empty_map(map, _existing), do: map

  # Upsert the entry mirror, but never let an out-of-order (older) provider event
  # overwrite a newer stored state: if the incoming provider_time predates what's
  # stored, keep the existing row untouched. On a real update, reactions and
  # raw_reaction_keys are preserved because those are folded in by the reaction
  # path, not carried on a plain receive.
  defp mirror_receive_entry(repo, fact, now) do
    with :ok <- lock_entry(repo, fact) do
      attrs = receive_entry_attrs(fact, now)

      case repo.get_by(SignalEntry,
             signal_channel_id: fact.signal_channel_id,
             provider_entry_id: fact.provider_entry_id
           ) do
        %SignalEntry{} = entry ->
          case stale_provider_time?(entry.provider_time, fact.provider_time) do
            true ->
              {:ok, entry}

            false ->
              entry
              |> SignalEntry.changeset(%{
                attrs
                | first_seen_at: entry.first_seen_at,
                  reactions: entry.reactions || %{},
                  raw_reaction_keys: entry.raw_reaction_keys || %{}
              })
              |> repo.update()
          end

        nil ->
          %SignalEntry{}
          |> SignalEntry.changeset(attrs)
          |> repo.insert()
      end
    end
  end

  defp receive_entry_attrs(fact, now) do
    search_text = Map.get(fact, :text) || Map.get(fact, :fallback_visible_text)
    metadata_text = metadata_text(fact)

    %{
      signal_channel_id: fact.signal_channel_id,
      provider_entry_id: fact.provider_entry_id,
      text: fact.text,
      formatted_content: fact.formatted_content,
      attachments: fact.attachments,
      links: fact.links,
      author: fact.author,
      mentions: fact.mentions,
      metadata: signal_entry_metadata(fact),
      raw_payload: fact.raw_payload,
      provider_time: fact.provider_time,
      fallback_visible_text: fact.text,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: document_id(fact.signal_channel_id, fact.provider_entry_id),
      search_text: search_text,
      metadata_text: metadata_text,
      content_hash:
        content_hash([
          search_text,
          metadata_text,
          fact.formatted_content,
          fact.attachments,
          fact.links
        ]),
      first_seen_at: now,
      last_seen_at: now
    }
  end

  defp append_actor_input(binding, fact, type, channel, entry, now) do
    session_id = Map.get(fact, :session_id) || signal_session_id(fact.signal_channel_id)

    available_at =
      case Map.get(fact, :available_at) do
        %DateTime{} = available_at -> available_at
        _other -> now
      end

    attrs = %{
      agent_uid: binding.agent_uid,
      binding_name: binding.name,
      session_id: session_id,
      ingress_event_id: fact.ingress_event_id,
      signal_channel_id: fact.signal_channel_id,
      provider_thread_id: fact.provider_thread_id,
      provider_entry_id: fact.provider_entry_id,
      type: type,
      available_at: available_at,
      sender_key: Map.get(fact, :sender_key)
    }

    payload =
      binding
      |> actor_envelope(fact, type, channel, entry, now)
      |> maybe_ambient_batch_payload(type, attrs, fact, now)

    attrs = Map.put(attrs, :payload, payload)

    Actors.append_actor_input(attrs)
  end

  defp maybe_ambient_batch_payload(
         payload,
         "im.message.may_intervene",
         attrs,
         %{finalized_batch_id: _batch_id, batch_entries: entries},
         now
       )
       when is_list(entries) do
    refresh_ambient_batch_payload(payload, attrs, entries, now)
  end

  defp maybe_ambient_batch_payload(
         payload,
         _type,
         _attrs,
         %{finalized_batch_id: _batch_id},
         _now
       ),
       do: payload

  defp maybe_ambient_batch_payload(payload, _type, _attrs, _fact, _now), do: payload

  defp refresh_ambient_batch_payload(payload, attrs, entries, now) do
    payload
    |> put_in(["data", "entry"], batch_entry_summary(entries))
    |> put_in(["data", "entries"], entries)
    |> put_in(["data", "observed_messages"], AmbientRecall.observed_messages(attrs, entries))
    |> put_in(["data", "ambient_batch"], %{
      "size" => length(entries),
      "first_provider_entry_id" => entries |> List.first() |> Map.get("provider_entry_id"),
      "last_provider_entry_id" => entries |> List.last() |> Map.get("provider_entry_id"),
      "updated_at" => DateTime.to_iso8601(now)
    })
  end

  defp batch_entry_summary(entries) do
    text =
      entries
      |> Enum.map(& &1["text"])
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")

    entries
    |> List.last()
    |> Kernel.||(%{})
    |> Map.put("text", text)
  end

  defp signal_entry_metadata(fact) do
    fact.metadata
    |> Map.put_new("provider_thread_id", Map.get(fact, :provider_thread_id))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp min_datetime(%DateTime{} = left, %DateTime{} = right) do
    case DateTime.compare(left, right) do
      :gt -> right
      _other -> left
    end
  end

  # The payload stored on the ActorInput is a CloudEvents 1.0 envelope so the
  # worker sees a uniform shape regardless of which provider/source produced it.
  # `data` is assembled from whichever fact fields are present (nils dropped);
  # `source`/`subject` encode provenance (see envelope_source/2, envelope_subject/1).
  defp actor_envelope(binding, fact, type, channel, entry, now) do
    data =
      %{
        "session" => %{
          "agent_uid" => binding.agent_uid,
          "session_id" => Map.get(fact, :session_id) || signal_session_id(fact.signal_channel_id),
          "binding_name" => binding.name
        },
        "channel" => channel_payload(channel),
        "entry" => entry_payload(entry || fact, fact),
        "entries" => Map.get(fact, :batch_entries),
        "mentions" => Map.get(fact, :mentions),
        "raw" => Map.get(fact, :raw_payload),
        "command" => Map.get(fact, :command_payload),
        "action" => Map.get(fact, :action),
        "internal" => Map.get(fact, :internal),
        "lifecycle" => lifecycle_payload(fact)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      "specversion" => "1.0",
      "id" => fact.ingress_event_id,
      "source" => envelope_source(binding, fact),
      "subject" => envelope_subject(fact),
      "time" => DateTime.to_iso8601(now),
      "type" => type,
      "data" => data
    }
  end

  defp channel_payload(nil), do: nil

  defp channel_payload(%SignalChannel{} = channel) do
    %{
      "id" => channel.id,
      "kind" => Atom.to_string(channel.kind),
      "reply_mode" => Atom.to_string(channel.reply_mode),
      "name" => channel.name,
      "title" => channel.title,
      "visibility" => channel.visibility
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp lifecycle_payload(%{lifecycle_kind: lifecycle_kind} = fact)
       when not is_nil(lifecycle_kind) do
    %{
      "kind" => Atom.to_string(lifecycle_kind),
      "provider_kind" => Map.get(fact, :provider_lifecycle_kind)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp lifecycle_payload(_fact), do: nil

  defp entry_payload(%SignalEntry{} = entry, fact) do
    %{
      "signal_channel_id" => entry.signal_channel_id,
      "provider_entry_id" => entry.provider_entry_id,
      "provider_thread_id" => Map.get(fact, :provider_thread_id),
      "text" => entry.text,
      "attachments" => entry.attachments,
      "links" => entry.links,
      "author" => entry.author,
      "document_id" => entry.document_id,
      "provider_time" => datetime_iso8601(entry.provider_time)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp entry_payload(fact, _fact_context) when is_map(fact) do
    %{
      "signal_channel_id" => Map.get(fact, :signal_channel_id),
      "provider_entry_id" => Map.get(fact, :provider_entry_id),
      "provider_thread_id" => Map.get(fact, :provider_thread_id),
      "text" => Map.get(fact, :text),
      "attachments" => Map.get(fact, :attachments),
      "links" => Map.get(fact, :links),
      "author" => Map.get(fact, :author),
      "provider_time" => datetime_iso8601(Map.get(fact, :provider_time))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp envelope_source(binding, %{signal_channel_id: nil, session_id: session_id}) do
    "internal://#{binding.name}/#{session_id}"
  end

  defp envelope_source(binding, fact) do
    "signal://#{binding.adapter}/#{URI.encode_www_form(fact.signal_channel_id)}"
  end

  defp envelope_subject(%{action_id: action_id}) when is_binary(action_id),
    do: "signal_actions:#{action_id}"

  defp envelope_subject(%{timer_id: timer_id}) when is_binary(timer_id),
    do: "timers:#{timer_id}"

  defp envelope_subject(%{internal_subject: subject}) when is_binary(subject), do: subject

  defp envelope_subject(%{provider_entry_id: provider_entry_id})
       when is_binary(provider_entry_id), do: "signal_entries:#{provider_entry_id}"

  defp envelope_subject(_fact), do: nil

  defp datetime_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_iso8601(_value), do: nil

  # Re-tombstoning an entry simply refreshes the 24h window from `now`.
  defp upsert_tombstone(repo, fact, now) do
    attrs = %{
      agent_uid: fact.agent_uid,
      binding_name: fact.binding_name,
      signal_channel_id: fact.signal_channel_id,
      provider_entry_id: fact.provider_entry_id,
      tombstoned_until: DateTime.add(now, @tombstone_ttl_seconds, :second)
    }

    case repo.get_by(InputTombstone,
           agent_uid: fact.agent_uid,
           binding_name: fact.binding_name,
           signal_channel_id: fact.signal_channel_id,
           provider_entry_id: fact.provider_entry_id
         ) do
      %InputTombstone{} = tombstone ->
        tombstone
        |> InputTombstone.changeset(attrs)
        |> repo.update()

      nil ->
        %InputTombstone{}
        |> InputTombstone.changeset(attrs)
        |> repo.insert()
    end
  end

  defp active_tombstone?(repo, fact, now) do
    case repo.get_by(InputTombstone,
           agent_uid: fact.agent_uid,
           binding_name: fact.binding_name,
           signal_channel_id: fact.signal_channel_id,
           provider_entry_id: fact.provider_entry_id
         ) do
      %InputTombstone{tombstoned_until: tombstoned_until} ->
        case DateTime.compare(tombstoned_until, now) do
          :gt -> true
          _other -> false
        end

      nil ->
        false
    end
  end

  defp delete_mirror_entry(repo, fact) do
    SignalEntry
    |> where([entry], entry.signal_channel_id == ^fact.signal_channel_id)
    |> where([entry], entry.provider_entry_id == ^fact.provider_entry_id)
    |> repo.delete_all()
  end

  # Notify each session that already CONSUMED the now-removed entry. We
  # can't undo what the agent did, but it should know the source message is gone,
  # so we append a "removed" input per affected session, stripped of the
  # original content (no text/mentions/command). It is a tombstone notice, not a
  # re-delivery or user command. Sessions that never consumed the entry had their
  # pending input cancelled instead (see accept_lifecycle), so there's nothing to
  # notify there.
  defp append_lifecycle_inputs(_binding, _fact, [], _channel, _now), do: {:ok, []}

  defp append_lifecycle_inputs(binding, fact, consumed_inputs, channel, now) do
    consumed_inputs
    |> Enum.map(fn consumed_input ->
      lifecycle_fact =
        fact
        |> Map.put(:session_id, consumed_input.session_id)
        |> Map.put(:provider_thread_id, consumed_input.provider_thread_id)
        |> Map.put(:metadata, Map.get(fact, :metadata, %{}))
        |> Map.put(:text, nil)
        |> Map.put(:mentions, [])
        |> Map.put(:command_payload, nil)
        |> Map.put(:action, nil)

      append_actor_input(binding, lifecycle_fact, "signal.entry.removed", channel, nil, now)
    end)
    |> collect_results()
  end

  defp reaction_entry_attrs(%SignalEntry{} = entry, fact, now) do
    {reactions, raw_reaction_keys} =
      update_reactions(
        entry.reactions || %{},
        entry.raw_reaction_keys || %{},
        fact.action,
        fact.reaction_key,
        fact.actor_key,
        fact.raw_reaction_key
      )

    %{
      reactions: reactions,
      raw_reaction_keys: raw_reaction_keys,
      last_seen_at: now
    }
  end

  defp update_reactions(
         reactions,
         raw_reaction_keys,
         :add,
         reaction_key,
         actor_key,
         raw_reaction_key
       ) do
    actors =
      reactions
      |> Map.get(reaction_key, [])
      |> List.wrap()
      |> MapSet.new()
      |> MapSet.put(actor_key)
      |> MapSet.to_list()
      |> Enum.sort()

    {
      Map.put(reactions, reaction_key, actors),
      Map.put(raw_reaction_keys, reaction_key, raw_reaction_key)
    }
  end

  defp update_reactions(
         reactions,
         raw_reaction_keys,
         :remove,
         reaction_key,
         actor_key,
         raw_reaction_key
       ) do
    actors =
      reactions
      |> Map.get(reaction_key, [])
      |> List.wrap()
      |> MapSet.new()
      |> MapSet.delete(actor_key)
      |> MapSet.to_list()
      |> Enum.sort()

    next_reactions =
      case actors do
        [] -> Map.delete(reactions, reaction_key)
        [_ | _] -> Map.put(reactions, reaction_key, actors)
      end

    {
      next_reactions,
      Map.put(raw_reaction_keys, reaction_key, raw_reaction_key)
    }
  end

  defp reaction_result({:ok, entry}), do: {:ok, %{status: :mirrored, signal_entry: entry}}
  defp reaction_result({:error, _changeset} = error), do: error

  defp stale_provider_time?(%DateTime{} = stored_time, %DateTime{} = incoming_time) do
    DateTime.compare(incoming_time, stored_time) == :lt
  end

  defp stale_provider_time?(_stored_time, _incoming_time), do: false

  # Serialize all gateway work for a single entry without a row to lock (the entry
  # row may not exist yet on first receive). A transaction-scoped Postgres
  # advisory lock keyed by hash of `channel|entry` makes concurrent
  # receive/reaction/lifecycle handlers for the same message take turns, and it
  # releases automatically at commit/rollback. `hashtext` is acceptable here:
  # rare collisions only cause two unrelated entries to briefly serialize, which
  # is harmless.
  defp lock_entry(repo, fact) do
    key =
      Enum.join(
        [fact.signal_channel_id, fact.provider_entry_id],
        "|"
      )

    SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  defp lock_inbound_batch(repo, %InboundBatch{} = batch) do
    key =
      Enum.join(
        [
          "inbound_batch",
          batch.agent_uid,
          batch.binding_name,
          batch.signal_channel_id,
          batch.provider_thread_id
        ],
        "|"
      )

    SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  defp lock_inbound_batch(repo, fact) do
    key =
      Enum.join(
        [
          "inbound_batch",
          fact.agent_uid,
          fact.binding_name,
          fact.signal_channel_id,
          thread_key(fact.provider_thread_id)
        ],
        "|"
      )

    SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  # Fill the status-machine defaults a freshly committed intent needs: starts
  # :created with zero attempts and a 10-attempt ceiling. `put_new` so a caller
  # may override (e.g. a custom max_attempts) but normally doesn't have to.
  defp default_outbox_attrs(attrs) do
    attrs
    |> Map.put_new(:status, :created)
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
  defp outbox_insert_result({:ok, %OutboxEntry{agent_uid: nil}}, attrs) do
    attrs = default_outbox_attrs(attrs)

    case Repo.get_by(OutboxEntry,
           agent_uid: attrs.agent_uid,
           binding_name: attrs.binding_name,
           outbound_key: attrs.outbound_key
         ) do
      %OutboxEntry{} = entry -> {:ok, entry}
      nil -> {:error, :outbox_entry_not_found}
    end
  end

  defp outbox_insert_result({:ok, %OutboxEntry{} = entry}, _attrs), do: {:ok, entry}
  defp outbox_insert_result({:error, _changeset} = error, _attrs), do: error

  # Channel wants threaded replies and we have an entry to thread under: reply if
  # the adapter supports threaded replies, otherwise degrade to a top-level post
  # so the message still gets out. The capability key is the string form because
  # it comes from plugin declarations.
  defp choose_outbox_operation(
         %SignalChannel{reply_mode: :entry},
         capabilities,
         %ActorInput{provider_entry_id: provider_entry_id}
       )
       when is_binary(provider_entry_id) do
    case MapSet.member?(capabilities, "reply_entry") do
      true -> :reply
      false -> post_or_fallback(capabilities, :reply)
    end
  end

  defp choose_outbox_operation(%SignalChannel{reply_mode: mode}, capabilities, actor_input)
       when mode in [:channel, :entry] do
    post_or_fallback(capabilities, fallback_outbox_operation(actor_input))
  end

  defp choose_outbox_operation(_channel, _capabilities, actor_input) do
    fallback_outbox_operation(actor_input)
  end

  defp post_or_fallback(capabilities, fallback) do
    case MapSet.member?(capabilities, "post_entry") do
      true -> :post
      false -> fallback
    end
  end

  defp fallback_outbox_operation(%ActorInput{provider_entry_id: provider_entry_id})
       when is_binary(provider_entry_id),
       do: :reply

  defp fallback_outbox_operation(_actor_input), do: :post

  defp adapter_outbound_capabilities(adapter_id) when is_binary(adapter_id) do
    case Process.whereis(Ankole.Plugins.Registry) do
      nil ->
        MapSet.new()

      _pid ->
        "signals_gateway.adapter"
        |> Ankole.Plugins.adapter_declarations()
        |> Enum.find(fn declaration ->
          declaration[:id] == adapter_id or declaration["id"] == adapter_id
        end)
        |> case do
          nil ->
            MapSet.new()

          declaration ->
            MapSet.new(
              declaration[:outbound_capabilities] || declaration["outbound_capabilities"] || []
            )
        end
    end
  end

  defp adapter_outbound_capabilities(_adapter_id), do: MapSet.new()

  defp fetch_outbox_for_update(repo, agent_uid, binding_name, outbound_key) do
    OutboxEntry
    |> where([entry], entry.agent_uid == ^normalize_uid(agent_uid))
    |> where([entry], entry.binding_name == ^binding_name)
    |> where([entry], entry.outbound_key == ^outbound_key)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp dispatch_due_outbox_entry(%OutboxEntry{} = outbox, adapter_resolver, now) do
    with {:ok, adapter} <- resolve_outbox_adapter(adapter_resolver, outbox) do
      dispatch_outbox(outbox.agent_uid, outbox.binding_name, outbox.outbound_key, adapter,
        now: now
      )
    end
  end

  defp resolve_outbox_adapter(adapter_resolver, %OutboxEntry{} = outbox) do
    case adapter_resolver.(outbox) do
      {:ok, adapter} when is_map(adapter) or is_atom(adapter) -> {:ok, adapter}
      adapter when is_map(adapter) or is_atom(adapter) -> {:ok, adapter}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_outbox_adapter}
    end
  end

  defp outbox_channel(_repo, %OutboxEntry{signal_channel_id: nil}), do: {:ok, nil}

  defp outbox_channel(repo, %OutboxEntry{signal_channel_id: signal_channel_id}) do
    case repo.get(SignalChannel, signal_channel_id) do
      %SignalChannel{} = channel -> {:ok, channel}
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
         %OutboxEntry{status: :failed, attempt_count: attempts, max_attempts: max},
         _now
       )
       when attempts >= max,
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
          require_text(outbox.source_provider_entry_id, outbox)
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
         %SignalChannel{reply_mode: reply_mode},
         capabilities,
         capability
       )
       when reply_mode in [:channel, :entry] do
    require_capability(outbox, capabilities, capability)
  end

  defp require_channel_surface(outbox, _channel, _capabilities, _capability),
    do: {:unsupported, outbox}

  defp require_reply_surface(outbox, %SignalChannel{reply_mode: :entry}, capabilities) do
    require_capability(outbox, capabilities, :reply_entry)
  end

  defp require_reply_surface(outbox, _channel, _capabilities), do: {:unsupported, outbox}

  defp require_capability_and_target(outbox, capabilities, capability) do
    with :ok <- require_capability(outbox, capabilities, capability) do
      require_text(outbox.target_provider_entry_id, outbox)
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
  #   - if the adapter can reconcile AND we already captured a provider_entry_id,
  #     reconcile to learn whether the send actually landed;
  #   - otherwise we cannot safely tell, so park the row as unknown_after_send
  #     for an operator rather than guess.
  # (This is the durable counterpart to "streaming is progress; committed work is
  # truth" — an unconfirmed send is neither, so it is never silently retried.)
  defp in_flight_recovery_action(
         %OutboxEntry{
           status: :sending,
           platform_send_started_at: %DateTime{},
           provider_entry_id: provider_entry_id
         } = outbox,
         adapter
       )
       when is_binary(provider_entry_id) do
    capabilities = OutboxAdapter.capabilities(adapter)

    case MapSet.member?(capabilities, :outbound_reconciliation) do
      true -> {:reconcile, outbox}
      false -> {:unknown, outbox, %{"reason" => "provider send started before restart"}}
    end
  end

  # Same situation but no provider_entry_id was captured, so even a
  # reconciliation-capable adapter has nothing to look up → mark unknown.
  defp in_flight_recovery_action(
         %OutboxEntry{status: :sending, platform_send_started_at: %DateTime{}} = outbox,
         _adapter
       ),
       do:
         {:unknown, outbox,
          %{
            "reason" => "provider send started without provider entry id"
          }}

  # Not mid-send → proceed with a normal fresh dispatch.
  defp in_flight_recovery_action(_outbox, _adapter), do: :continue

  defp mark_outbox_sending(repo, outbox, now) do
    outbox
    |> OutboxEntry.changeset(%{
      status: :sending,
      platform_send_started_at: now,
      last_attempted_at: now,
      attempt_count: outbox.attempt_count + 1,
      next_attempt_at: nil
    })
    |> repo.update()
  end

  defp mark_outbox_unsupported(repo, outbox) do
    outbox
    |> OutboxEntry.changeset(%{status: :unsupported})
    |> repo.update()
  end

  defp call_adapter_send(adapter, outbox), do: OutboxAdapter.deliver(adapter, outbox)

  defp call_adapter_reconcile(adapter, outbox), do: OutboxAdapter.reconcile(adapter, outbox)

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
          Logger.warning(
            "signals_gateway outbox mirror failed after provider send agent_uid=#{outbox.agent_uid} binding_name=#{outbox.binding_name} outbound_key=#{outbox.outbound_key} reason=#{inspect(Sanitizer.transport(reason), limit: 20)}"
          )

          {:ok, succeeded_outbox}
      end
    end
  end

  defp fetch_outbox_for_update(repo, %OutboxEntry{} = outbox) do
    fetch_outbox_for_update(repo, outbox.agent_uid, outbox.binding_name, outbox.outbound_key)
  end

  defp mark_outbox_succeeded(repo, outbox, result) do
    recovery_state = fetch_value(result, :recovery_state) || %{}

    with {:ok, recovery_state} <-
           JsonPayload.normalize_map(recovery_state, allow_datetime: true) do
      outbox
      |> OutboxEntry.changeset(%{
        status: :succeeded,
        provider_entry_id: provider_entry_id_after_success(outbox, result),
        last_error: %{},
        next_attempt_at: nil,
        recovery_state: recovery_state
      })
      |> repo.update()
    end
  end

  defp mark_outbox_failed(repo, outbox, reason, now) do
    outbox
    |> OutboxEntry.changeset(%{
      status: :failed,
      last_error: %{"reason" => Sanitizer.transport(reason)},
      next_attempt_at: next_outbox_attempt_at(outbox, now)
    })
    |> repo.update()
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
  # If the provider gave us nothing (some adapters don't return an id), synthesize
  # a stable local id so the mirror still has a primary key — only for operations
  # that create a new entry, since edit/delete/reaction target an existing id.
  defp provider_entry_id_after_success(%OutboxEntry{} = outbox, result) do
    optional_text(result, :provider_entry_id) ||
      outbox.provider_entry_id ||
      stable_local_provider_entry_id(outbox)
  end

  # Derived from the idempotency/outbound key so the same committed intent always
  # maps to the same local id, keeping the mirror upsert idempotent.
  defp stable_local_provider_entry_id(%OutboxEntry{operation: operation} = outbox)
       when operation in [:post, :reply, :divider, :card] do
    "local-outbox:#{outbox.idempotency_key || outbox.outbound_key}"
  end

  defp stable_local_provider_entry_id(%OutboxEntry{}), do: nil

  # Exponential backoff: delay = 5s * 2^(attempt-1), clamped to the 5m ceiling
  # (so 5s, 10s, 20s, 40s, … capped at 300s). Returning nil once attempts are
  # exhausted is what makes list_due_outbox stop selecting the row — the retry
  # loop ends without a separate "give up" flag.
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
    case optional_text(result, :provider_entry_id) || outbox.provider_entry_id do
      nil ->
        :ok

      provider_entry_id ->
        fact = %{
          signal_channel_id: outbox.signal_channel_id,
          provider_entry_id: provider_entry_id,
          provider_thread_id: outbox.provider_thread_id,
          text: outbox.fallback_visible_text,
          fallback_visible_text: outbox.fallback_visible_text,
          formatted_content: fetch_map(outbox.payload, :formatted_content, %{}),
          attachments: fetch_list(outbox.payload, :attachments),
          links: [],
          author: %{"agent_uid" => outbox.agent_uid},
          mentions: [],
          metadata: fetch_map(outbox.payload, :metadata, %{}),
          raw_payload: fetch_map(result, :raw_payload, %{}),
          provider_time: fetch_datetime(result, :provider_time),
          channel_name: channel && channel.name,
          channel_title: channel && channel.title
        }

        case mirror_receive_entry(repo, fact, now) do
          {:ok, _entry} -> :ok
          {:error, _changeset} = error -> error
        end
    end
  end

  defp mirror_outbox_success(
         repo,
         %OutboxEntry{operation: :edit} = outbox,
         _channel,
         _result,
         now
       ) do
    case repo.get_by(SignalEntry,
           signal_channel_id: outbox.signal_channel_id,
           provider_entry_id: outbox.target_provider_entry_id
         ) do
      %SignalEntry{} = entry ->
        entry
        |> SignalEntry.changeset(%{
          text: outbox.fallback_visible_text,
          fallback_visible_text: outbox.fallback_visible_text,
          search_text: outbox.fallback_visible_text,
          last_seen_at: now
        })
        |> repo.update()
        |> case do
          {:ok, _entry} -> :ok
          {:error, _changeset} = error -> error
        end

      nil ->
        :ok
    end
  end

  defp mirror_outbox_success(
         repo,
         %OutboxEntry{operation: :delete} = outbox,
         _channel,
         _result,
         _now
       ) do
    SignalEntry
    |> where([entry], entry.signal_channel_id == ^outbox.signal_channel_id)
    |> where([entry], entry.provider_entry_id == ^outbox.target_provider_entry_id)
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
    case repo.get_by(SignalEntry,
           signal_channel_id: outbox.signal_channel_id,
           provider_entry_id: outbox.target_provider_entry_id
         ) do
      %SignalEntry{} = entry ->
        fact = %{
          action: if(operation == :reaction_add, do: :add, else: :remove),
          reaction_key: outbox.payload["reaction_key"] || outbox.payload[:reaction_key],
          actor_key: outbox.payload["actor_key"] || outbox.agent_uid,
          raw_reaction_key:
            outbox.payload["raw_reaction_key"] || outbox.payload[:raw_reaction_key]
        }

        entry
        |> SignalEntry.changeset(reaction_entry_attrs(entry, fact, now))
        |> repo.update()
        |> case do
          {:ok, _entry} -> :ok
          {:error, _changeset} = error -> error
        end

      nil ->
        :ok
    end
  end

  defp normalize_agent_uid_attr(%{agent_uid: agent_uid} = attrs) when is_binary(agent_uid) do
    %{attrs | agent_uid: normalize_uid(agent_uid)}
  end

  defp normalize_agent_uid_attr(attrs), do: attrs

  defp action_session_id(input) do
    case optional_text(input, :session_id) || optional_text(input, :signal_channel_id) do
      nil ->
        {:error, :missing_session_id}

      session_or_channel ->
        {:ok, optional_text(input, :session_id) || signal_session_id(session_or_channel)}
    end
  end

  defp structured_agent_mention?(input, agent_uid) do
    input
    |> fetch_list(:mentions)
    |> Enum.any?(fn mention ->
      structured_mention?(mention, agent_uid)
    end)
  end

  # A "structured" mention is a real provider @-mention entity (not the literal
  # text "@bot"), which is what makes a group message count as explicitly
  # addressed. It must target THIS agent: either it names this agent_uid, or it
  # carries no specific uid (a generic bot mention the binding owns).
  defp structured_mention?(mention, agent_uid) when is_map(mention) do
    structured? =
      truthy?(fetch_value(mention, :structured)) ||
        fetch_value(mention, :kind) in [:agent, "agent", :bot, "bot"]

    mentioned_agent = optional_text(mention, :agent_uid)
    structured? and (is_nil(mentioned_agent) or normalize_uid(mentioned_agent) == agent_uid)
  end

  defp structured_mention?(_mention, _agent_uid), do: false

  defp normalize_mentions(mentions) do
    Enum.map(mentions, fn
      %{} = mention -> update_enum_text(mention, :kind)
      mention -> mention
    end)
  end

  defp update_enum_text(map, key) do
    case fetch_value(map, key) do
      value when is_atom(value) -> Map.put(map, key, Atom.to_string(value))
      _value -> map
    end
  end

  defp sender_key(input, author) do
    optional_text(input, :sender_key) ||
      optional_text(author, :principal_uid) ||
      optional_text(author, :platform_subject) ||
      optional_text(author, :external_id) ||
      optional_text(author, :id)
  end

  defp normalize_author_principal(%SignalBinding{} = binding, author) when is_map(author) do
    case optional_text(author, :principal_uid) do
      principal_uid when is_binary(principal_uid) ->
        Map.put(author, "principal_uid", normalize_uid(principal_uid))

      nil ->
        enrich_author_principal(binding, author)
    end
  end

  defp enrich_author_principal(%SignalBinding{} = binding, author) do
    provider =
      optional_text(author, :provider) ||
        optional_text(fetch_map(author, :metadata, %{}), :provider) ||
        binding.name

    subject =
      optional_text(author, :platform_subject) ||
        optional_text(author, :external_id)

    case {provider, subject} do
      {provider, subject} when is_binary(provider) and is_binary(subject) ->
        case Principals.resolve_platform_subject(provider, subject) do
          {:ok, principal} -> Map.put(author, "principal_uid", principal.uid)
          {:error, _reason} -> author
        end

      _missing ->
        author
    end
  end

  defp normalize_attachments(input) do
    input
    |> fetch_list(:attachments)
    |> Enum.map(&normalize_attachment/1)
    |> collect_results()
  end

  defp normalize_attachment(%{} = attachment) do
    case JsonPayload.normalize_map(attachment, allow_datetime: true) do
      {:ok, normalized} ->
        case durable_attachment?(normalized) do
          true -> {:ok, normalized}
          false -> {:error, {:attachment_not_materialized, Sanitizer.transport(normalized)}}
        end

      {:error, _reason} ->
        {:error, {:invalid_attachment_payload, Sanitizer.transport(attachment)}}
    end
  end

  defp normalize_attachment(attachment),
    do: {:error, {:invalid_attachment_payload, Sanitizer.transport(attachment)}}

  # An attachment is only accepted into durable state once it points at something
  # that will still resolve later: a provider/blob/storage reference, or a file
  # already materialized on the Agent Computer workspace. A raw in-memory or
  # transient attachment is rejected (see normalize_attachment/1) so the mirror
  # never stores a dangling pointer the agent can't re-fetch.
  defp durable_attachment?(attachment) do
    Enum.any?(
      [
        "provider_ref",
        "provider_file_id",
        "provider_uri",
        "blob_ref",
        "storage_ref",
        "agent_computer_path"
      ],
      &present_text?(attachment, &1)
    ) || agent_computer_visible_file_path?(attachment)
  end

  defp present_text?(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value) != ""
      _value -> false
    end
  end

  defp agent_computer_visible_file_path?(attachment) do
    case Map.get(attachment, "file_path") do
      path when is_binary(path) ->
        String.starts_with?(path, "/workspace/") ||
          Map.get(attachment, "visible_to") == "agent_computer"

      _path ->
        false
    end
  end

  defp metadata_text(fact) do
    [fact.author, fact.metadata, fact.channel_name, fact.channel_title]
    |> List.flatten()
    |> Enum.map(&metadata_text_part/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp metadata_text_part(value) when is_binary(value), do: value

  defp metadata_text_part(value) when is_map(value),
    do: value |> Map.values() |> Enum.map(&metadata_text_part/1) |> Enum.join(" ")

  defp metadata_text_part(value) when is_list(value),
    do: value |> Enum.map(&metadata_text_part/1) |> Enum.join(" ")

  defp metadata_text_part(value) when is_number(value), do: to_string(value)
  defp metadata_text_part(_value), do: ""

  # Stable, opaque per-entry id derived from its identity (channel + provider
  # entry). `content_hash` instead digests the entry's *content* so a re-receive
  # with unchanged content produces the same hash (cheap change detection).
  defp document_id(signal_channel_id, provider_entry_id) do
    "signal-entry:" <> digest([signal_channel_id, provider_entry_id])
  end

  defp content_hash(parts), do: digest(parts)

  # term_to_binary → SHA-256 → url-safe base64. Hashing the BEAM term (not a
  # string) avoids having to define a canonical serialization for the mixed
  # list of text/maps/lists passed in.
  defp digest(parts) do
    parts
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

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

  defp normalize_provider_lifecycle_kind(nil), do: nil

  defp normalize_provider_lifecycle_kind(kind) when is_atom(kind) do
    kind
    |> Atom.to_string()
    |> normalize_provider_lifecycle_kind()
  end

  defp normalize_provider_lifecycle_kind(kind) when is_binary(kind) do
    case String.trim(kind) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_provider_lifecycle_kind(_kind), do: nil

  defp fetch_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp fetch_value(_map, _key), do: nil

  defp fetch_map(map, key, default) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp fetch_list(map, key) do
    case fetch_value(map, key) do
      value when is_list(value) -> value
      nil -> []
      value -> [value]
    end
  end

  defp required_text(map, key) do
    case optional_text(map, key) do
      nil -> {:error, {:missing_required_text, key}}
      value -> {:ok, value}
    end
  end

  defp optional_text(map, key) when is_map(map) do
    case fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      nil ->
        nil

      value when is_atom(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      _value ->
        nil
    end
  end

  defp optional_text(_map, _key), do: nil

  defp fetch_datetime(map, key) do
    case fetch_value(map, key) do
      %DateTime{} = datetime -> datetime
      _value -> nil
    end
  end

  defp normalize_channel_kind(value) when value in [:im_dm, "im_dm"], do: :im_dm
  defp normalize_channel_kind(value) when value in [:im_group, "im_group"], do: :im_group

  defp normalize_channel_kind(value) when value in [:webhook_endpoint, "webhook_endpoint"],
    do: :webhook_endpoint

  defp normalize_channel_kind(value) when value in [:issue, "issue"], do: :issue

  defp normalize_channel_kind(value) when value in [:alert_stream, "alert_stream"],
    do: :alert_stream

  defp normalize_channel_kind(_value), do: :unknown

  defp normalize_reply_mode(value) when value in [:channel, "channel"], do: :channel
  defp normalize_reply_mode(value) when value in [:entry, "entry"], do: :entry
  defp normalize_reply_mode(_value), do: :none

  defp normalize_reaction_action(value) when value in [:remove, "remove", :deleted, "deleted"],
    do: :remove

  defp normalize_reaction_action(_value), do: :add

  # Provider/JSON booleans arrive as strings or ints, so accept the common truthy
  # encodings rather than only the literal `true`.
  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_value), do: false

  # agent_uid is matched case-insensitively across the gateway, so every lookup
  # and write funnels through this same trim+downcase to keep keys consistent.
  defp normalize_uid(uid) when is_binary(uid), do: uid |> String.trim() |> String.downcase()
  defp normalize_uid(uid), do: uid
end
