defmodule Ankole.SignalsGateway.Outbox do
  @moduledoc false

  import Ecto.Query, warn: false

  require Logger

  alias Ankole.Actors.ActorInput
  alias Ankole.Repo
  alias Ankole.SignalsGateway.JsonPayload
  alias Ankole.SignalsGateway.OutboxAdapter
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.SignalBinding
  alias Ankole.SignalsGateway.SignalChannel
  alias Ankole.SignalsGateway.SignalEntry

  import Ankole.SignalsGateway.Utils,
    only: [
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
  @outbox_in_flight_recovery_seconds 60

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
        |> SignalEntry.changeset(Projection.reaction_entry_attrs(entry, fact, now))
        |> repo.update()
        |> case do
          {:ok, _entry} -> :ok
          {:error, _changeset} = error -> error
        end

      nil ->
        :ok
    end
  end
end
