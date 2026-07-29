defmodule Ankole.SignalsGateway.InboundBatches do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway.ActorEventEnvelope
  alias Ankole.SignalsGateway.ActorRuntime.TurnRetry
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.IngressFact
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry

  import Ankole.SignalsGateway.Utils,
    only: [
      collect_results: 1,
      datetime_iso8601: 1,
      min_datetime: 2,
      parse_datetime: 1,
      signal_session_id: 1,
      structured_mention?: 2,
      text_length: 1,
      thread_key: 1,
      truthy?: 1,
      unthread_key: 1
    ]

  @addressed_text_window_ms 1_000
  @neutral_text_window_ms 600
  @addressed_attachment_window_ms 1_200
  @attachment_materialization_hard_cap_ms 4_000
  @addressed_long_text_window_ms 2_000
  @addressed_long_text_threshold 3_000
  @addressed_text_budget 4_000
  @addressed_text_hard_cap 8_000
  @addressed_max_entries 8
  @ambient_batch_window_ms 15_000
  @ambient_hard_cap_ms 5 * 60 * 1_000

  @doc false
  @spec finalize_inbound_batch_by_id(String.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def finalize_inbound_batch_by_id(batch_id, batch_revision, opts \\ [])
      when is_binary(batch_id) and is_integer(batch_revision) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %InboundBatch{} = batch <- lock_inbound_batch_by_id(repo, batch_id),
           :ok <- require_current_batch_revision(batch, batch_revision),
           :ok <- require_inbound_batch_due(batch, now) do
        case batch.batch_state do
          "open" -> finalize_inbound_batch_in_tx(repo, batch, now)
          _closed -> {:ok, %{status: :already_finalized, inbound_batch: batch}}
        end
      else
        nil -> {:error, :inbound_batch_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc false
  @spec runtime_event_snapshot() :: [{String.t(), map()}]
  def runtime_event_snapshot do
    InboundBatch
    |> where([batch], batch.batch_state == "open")
    |> Repo.all()
    |> Enum.map(&inbound_batch_runtime_event/1)
  end

  @spec entry_snapshot(module(), String.t(), String.t(), String.t(), String.t()) :: map() | nil
  def entry_snapshot(
        repo,
        agent_uid,
        binding_name,
        signal_channel_id,
        source_entry_id
      )
      when is_binary(agent_uid) and is_binary(binding_name) and is_binary(signal_channel_id) and
             is_binary(source_entry_id) do
    InboundBatch
    |> where([batch], batch.agent_uid == ^agent_uid)
    |> where([batch], batch.binding_name == ^binding_name)
    |> where([batch], batch.signal_channel_id == ^signal_channel_id)
    |> where(
      [batch],
      fragment(
        "EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS entry WHERE entry->>'source_entry_id' = ?)",
        batch.entries,
        ^source_entry_id
      )
    )
    |> order_by([batch], desc: batch.inserted_at)
    |> limit(1)
    |> select([batch], batch.entries)
    |> repo.one()
    |> case do
      entries when is_list(entries) -> find_entry(entries, source_entry_id)
      nil -> nil
    end
  end

  def apply_im_entry_policy(repo, binding, fact, policy, type, now) do
    with :ok <- Projection.lock_inbound_batch(repo, fact),
         {:ok, channel} <- Projection.upsert_channel(repo, fact, now) do
      batch = open_inbound_batch(fact, repo)

      case mirrored_outside_open_batch?(repo, fact, batch) do
        true ->
          with {:ok, mirror_entry} <- maybe_mirror_im_entry(repo, fact, policy, type, now),
               source_entry <- inbound_batch_entry(fact, mirror_entry, policy, type, now),
               {:ok, supplement} <-
                 maybe_apply_live_attachment_supplement(
                   batch,
                   repo,
                   fact,
                   source_entry,
                   now
                 ),
               {:ok, result} <-
                 route_finalized_duplicate_or_attachment_supplement(
                   supplement,
                   batch,
                   repo,
                   binding,
                   channel,
                   fact,
                   source_entry,
                   policy,
                   type,
                   now
                 ) do
            {:ok,
             result
             |> Map.put(:signal_channel, channel)
             |> maybe_put_result(:signal_entry, mirror_entry)}
          end

        false ->
          with {:ok, mirror_entry} <- maybe_mirror_im_entry(repo, fact, policy, type, now),
               source_entry <- inbound_batch_entry(fact, mirror_entry, policy, type, now),
               {:ok, supplement} <-
                 maybe_apply_live_attachment_supplement(
                   batch,
                   repo,
                   fact,
                   source_entry,
                   now
                 ),
               {:ok, result} <-
                 route_after_live_attachment_supplement(
                   supplement,
                   batch,
                   repo,
                   binding,
                   channel,
                   fact,
                   source_entry,
                   policy,
                   type,
                   now
                 ) do
            {:ok,
             result
             |> Map.put(:signal_channel, channel)
             |> maybe_put_result(:signal_entry, mirror_entry)}
          end
      end
    end
  end

  defp mirrored_outside_open_batch?(repo, fact, batch) do
    not batch_contains_source_entry?(batch, fact.source_entry_id) and
      Entry
      |> where([entry], entry.signal_channel_id == ^fact.signal_channel_id)
      |> where([entry], entry.source_entry_id == ^fact.source_entry_id)
      |> repo.exists?() and
      finalized_batch_contains_source_entry?(repo, fact)
  end

  defp finalized_batch_contains_source_entry?(repo, fact) do
    InboundBatch
    |> where([batch], batch.agent_uid == ^fact.agent_uid)
    |> where([batch], batch.binding_name == ^fact.binding_name)
    |> where([batch], batch.signal_channel_id == ^fact.signal_channel_id)
    |> where([batch], batch.batch_state == "finalized")
    |> where(
      [batch],
      fragment(
        "EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS entry WHERE entry->>'source_entry_id' = ?)",
        batch.entries,
        ^fact.source_entry_id
      )
    )
    |> repo.exists?()
  end

  defp batch_contains_source_entry?(%InboundBatch{entries: entries}, source_entry_id) do
    Enum.any?(entries, &(&1["source_entry_id"] == source_entry_id))
  end

  defp batch_contains_source_entry?(nil, _source_entry_id), do: false

  defp find_entry(entries, source_entry_id),
    do: Enum.find(entries, &(&1["source_entry_id"] == source_entry_id))

  defp maybe_put_result(result, _key, nil), do: result
  defp maybe_put_result(result, key, value), do: Map.put(result, key, value)

  defp maybe_apply_live_attachment_supplement(
         nil,
         repo,
         fact,
         source_entry,
         now
       ) do
    TurnRetry.merge_attachment_supplement_in_tx(repo, fact, source_entry, now)
  end

  defp maybe_apply_live_attachment_supplement(
         %InboundBatch{},
         repo,
         fact,
         source_entry,
         now
       ) do
    TurnRetry.refresh_attachment_supplement_in_tx(repo, fact, source_entry, now)
  end

  defp route_finalized_duplicate_or_attachment_supplement(
         :not_supplement,
         batch,
         _repo,
         _binding,
         _channel,
         _fact,
         _source_entry,
         _policy,
         _type,
         _now
       ) do
    {:ok, %{status: :duplicate, inbound_batch: batch}}
  end

  defp route_finalized_duplicate_or_attachment_supplement(
         supplement,
         batch,
         repo,
         binding,
         channel,
         fact,
         source_entry,
         policy,
         type,
         now
       ) do
    route_after_live_attachment_supplement(
      supplement,
      batch,
      repo,
      binding,
      channel,
      fact,
      source_entry,
      policy,
      type,
      now
    )
  end

  defp route_after_live_attachment_supplement(
         :not_supplement,
         batch,
         repo,
         binding,
         channel,
         fact,
         source_entry,
         policy,
         type,
         now
       ) do
    batch
    |> maybe_finalize_due_batch(repo, now)
    |> maybe_finalize_reply_boundary(repo, fact, now)
    |> route_inbound_batch_entry(
      repo,
      binding,
      channel,
      fact,
      source_entry,
      policy,
      type,
      now
    )
  end

  defp route_after_live_attachment_supplement(
         {:consumed, result},
         _batch,
         repo,
         _binding,
         _channel,
         fact,
         _source_entry,
         _policy,
         _type,
         now
       ) do
    with {:ok, mirror_entry} <- Projection.mirror_receive_entry(repo, fact, now) do
      {:ok, Map.put(result, :signal_entry, mirror_entry)}
    end
  end

  defp route_after_live_attachment_supplement(
         {:next_turn, reason},
         nil,
         repo,
         binding,
         channel,
         fact,
         source_entry,
         _policy,
         _type,
         now
       ) do
    source_entry = Map.put(source_entry, "explicit", true)

    with {:ok, result} <-
           append_addressed_inbound_entry(
             nil,
             repo,
             binding,
             channel,
             fact,
             source_entry,
             :ignore,
             now
           ) do
      {:ok, Map.put(result, :input_supersession_fallback, reason)}
    end
  end

  defp route_after_live_attachment_supplement(
         {:next_turn, reason},
         %InboundBatch{} = batch,
         repo,
         binding,
         channel,
         fact,
         source_entry,
         _policy,
         _type,
         now
       ) do
    source_entry = Map.put(source_entry, "explicit", true)

    with {:ok, closed} <- finalize_inbound_batch_in_tx(repo, batch, now),
         {:ok, result} <-
           append_addressed_inbound_entry(
             nil,
             repo,
             binding,
             channel,
             fact,
             source_entry,
             :ignore,
             now
           ) do
      {:ok,
       result
       |> merge_finalized_actor_events(closed)
       |> Map.put(:input_supersession_fallback, reason)}
    end
  end

  defp maybe_mirror_im_entry(repo, fact, policy, type, now) do
    case should_mirror_im_entry?(policy, type) do
      true -> Projection.mirror_receive_entry(repo, fact, now)
      false -> {:ok, nil}
    end
  end

  defp should_mirror_im_entry?(_policy, "im.message.addressed"), do: true
  defp should_mirror_im_entry?(:record_only, _type), do: true
  defp should_mirror_im_entry?(:may_intervene, _type), do: true
  defp should_mirror_im_entry?(_policy, _type), do: false

  defp maybe_finalize_due_batch(nil, _repo, _now) do
    {:ok, %{inbound_batch: nil, finalized_actor_events: []}}
  end

  defp maybe_finalize_due_batch(%InboundBatch{available_at: available_at} = batch, repo, now) do
    case DateTime.compare(available_at, now) do
      :gt ->
        {:ok, %{inbound_batch: batch, finalized_actor_events: []}}

      _ready ->
        with {:ok, result} <- finalize_inbound_batch_in_tx(repo, batch, now) do
          {:ok, %{inbound_batch: nil, finalized_actor_events: finalized_actor_events(result)}}
        end
    end
  end

  defp maybe_finalize_reply_boundary(
         {:ok, %{inbound_batch: nil} = state},
         _repo,
         _fact,
         _now
       ),
       do: {:ok, state}

  defp maybe_finalize_reply_boundary(
         {:ok, %{inbound_batch: %InboundBatch{} = batch} = state},
         repo,
         fact,
         now
       ) do
    reply_to_source_entry_id = Map.get(fact, :reply_to_source_entry_id)

    if batch.reply_to_source_entry_id == reply_to_source_entry_id do
      {:ok, state}
    else
      with {:ok, finalized} <- finalize_inbound_batch_in_tx(repo, batch, now) do
        events =
          (state.finalized_actor_events ++ finalized_actor_events(finalized))
          |> Enum.uniq_by(& &1.id)

        {:ok, %{state | inbound_batch: nil, finalized_actor_events: events}}
      end
    end
  end

  defp maybe_finalize_reply_boundary({:error, _reason} = error, _repo, _fact, _now),
    do: error

  defp route_inbound_batch_entry(
         {:ok, %{inbound_batch: batch, finalized_actor_events: finalized_events}},
         repo,
         binding,
         channel,
         fact,
         entry,
         policy,
         type,
         now
       ) do
    with {:ok, result} <-
           route_inbound_batch_entry(
             batch,
             repo,
             binding,
             channel,
             fact,
             entry,
             policy,
             type,
             now
           ) do
      {:ok, put_finalized_actor_events(result, finalized_events)}
    end
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
        with {:ok, closed} <- finalize_inbound_batch_in_tx(repo, batch, now),
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
          {:ok, merge_finalized_actor_events(result, closed)}
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
    addressed_entries = tail ++ [entry]

    case prefix do
      [] ->
        batch
        |> upgrade_neutral_batch_to_addressed(repo, addressed_entries, policy, now)
        |> inbound_result(:accepted)

      [_ | _] ->
        with {:ok, closed_prefix} <-
               close_or_replace_neutral_prefix(repo, batch, prefix, tail, now),
             {:ok, result} <-
               append_addressed_inbound_entry(
                 nil,
                 repo,
                 binding,
                 channel,
                 fact,
                 addressed_entries,
                 policy,
                 now
               ) do
          {:ok, put_finalized_actor_events(result, closed_prefix.finalized_actor_events)}
        end
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
        with {:ok, closed} <- finalize_inbound_batch_in_tx(repo, batch, now),
             {:ok, result} <-
               create_inbound_batch(repo, fact, policy, "addressed", [entry], now)
               |> inbound_result(:accepted) do
          {:ok, merge_finalized_actor_events(result, closed)}
        end

      true ->
        with {:ok, closed} <- finalize_inbound_batch_in_tx(repo, batch, now),
             {:ok, result} <-
               append_neutral_inbound_entry(nil, repo, binding, channel, fact, entry, policy, now) do
          {:ok, merge_finalized_actor_events(result, closed)}
        end
    end
  end

  defp close_or_replace_neutral_prefix(repo, batch, prefix, [] = _tail, now) do
    batch
    |> InboundBatch.changeset(%{entries: prefix})
    |> repo.update()
    |> case do
      {:ok, updated} ->
        with {:ok, result} <- finalize_inbound_batch_in_tx(repo, updated, now) do
          {:ok, %{tail: [], finalized_actor_events: finalized_actor_events(result)}}
        end

      {:error, _reason} = error ->
        error
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
      {:ok, result} ->
        {:ok, %{tail: tail, finalized_actor_events: finalized_actor_events(result)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp inbound_result({:ok, %InboundBatch{} = batch}, status) do
    {:ok, %{status: status, inbound_batch: batch}}
  end

  defp inbound_result({:error, _reason} = error, _status), do: error

  defp merge_finalized_actor_events(result, finalized_result) when is_map(result) do
    put_finalized_actor_events(result, finalized_actor_events(finalized_result))
  end

  defp put_finalized_actor_events(result, []), do: result

  defp put_finalized_actor_events(result, events) when is_map(result) and is_list(events) do
    existing = Map.get(result, :finalized_actor_events, [])

    events =
      (existing ++ events)
      |> Enum.uniq_by(& &1.id)

    Map.put(result, :finalized_actor_events, events)
  end

  defp finalized_actor_events(%{actor_event: %ActorEvent{} = event}), do: [event]
  defp finalized_actor_events(_result), do: []

  defp neutral_status(:record_only), do: :recorded
  defp neutral_status(:may_intervene), do: :recorded
  defp neutral_status(:ignore), do: :ignored

  defp lock_inbound_batch_by_id(repo, batch_id) do
    InboundBatch
    |> where([batch], batch.id == ^batch_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp require_current_batch_revision(%InboundBatch{batch_revision: revision}, revision), do: :ok

  defp require_current_batch_revision(%InboundBatch{}, _revision),
    do: {:error, :inbound_batch_revision_stale}

  defp require_inbound_batch_due(%InboundBatch{available_at: %DateTime{} = available_at}, now) do
    case DateTime.compare(available_at, now) do
      :gt -> {:error, :inbound_batch_not_due}
      _due -> :ok
    end
  end

  defp finalize_inbound_batch_in_tx(repo, %InboundBatch{entries: []} = batch, now) do
    cancel_inbound_batch(repo, batch, now)
  end

  defp finalize_inbound_batch_in_tx(repo, %InboundBatch{mode: "addressed"} = batch, now) do
    with {:ok, append_result} <-
           append_batch_actor_event(repo, batch, "im.message.addressed", now) do
      finalize_batch_actor_event_append(repo, batch, now, "addressed", append_result)
    end
  end

  defp finalize_inbound_batch_in_tx(repo, %InboundBatch{mode: "neutral"} = batch, now) do
    case batch.policy do
      "may_intervene" ->
        with {:ok, append_result} <-
               append_batch_actor_event(repo, batch, "im.message.may_intervene", now) do
          finalize_batch_actor_event_append(repo, batch, now, "ambient", append_result)
        end

      _no_actor_event ->
        with {:ok, closed} <-
               batch
               |> InboundBatch.changeset(%{
                 batch_state: "finalized",
                 outcome: "no_actor_event",
                 finalized_at: now,
                 batch_revision: batch.batch_revision + 1
               })
               |> repo.update() do
          {:ok, %{status: :ignored, inbound_batch: closed}}
        end
    end
  end

  defp finalize_batch_actor_event_append(
         repo,
         %InboundBatch{} = batch,
         now,
         outcome,
         %ActorEvent{} = actor_event
       ) do
    with {:ok, closed} <-
           batch
           |> InboundBatch.changeset(%{
             batch_state: "finalized",
             outcome: outcome,
             finalized_at: now,
             # Source table: actor_event_id stores the actor_events.id created
             # by finalizing this inbound batch.
             actor_event_id: actor_event.id,
             batch_revision: batch.batch_revision + 1
           })
           |> repo.update() do
      {:ok, %{status: :accepted, actor_event: actor_event, inbound_batch: closed}}
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

  def remove_pending_inbound_entry(repo, fact, now) do
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
    entries =
      batch.entries
      |> Enum.reject(&(&1["source_entry_id"] == fact.source_entry_id))
      |> sort_batch_entries()

    cond do
      length(entries) == length(batch.entries) ->
        {:ok, nil}

      entries == [] ->
        with {:ok, %{inbound_batch: closed}} <-
               cancel_inbound_batch(repo, batch, now, %{entries: []}) do
          {:ok, closed}
        end

      true ->
        mode = recompute_batch_mode(entries)

        batch
        |> InboundBatch.changeset(%{
          mode: mode,
          entries: entries,
          reply_to_source_entry_id: reply_target_from_entries(entries),
          requester_sender_key: requester_sender_key(mode, entries),
          available_at: inbound_due_at(mode, batch.policy, entries, batch, now),
          hard_cap_at: inbound_hard_cap_at(mode, batch.policy, entries, batch, now),
          batch_revision: batch.batch_revision + 1
        })
        |> repo.update()
        |> notify_inbound_batch_deadline(repo)
    end
  end

  defp append_batch_actor_event(repo, batch, type, now) do
    with {:ok, binding} <- batch_binding(repo, batch),
         {:ok, channel} <- batch_channel(repo, batch),
         :ok <- mirror_unmirrored_batch_entries(repo, batch, binding, now) do
      fact = batch_actor_fact(batch, type, now)
      ActorEventEnvelope.append_actor_event(repo, binding, fact, type, channel, nil, now)
    end
  end

  defp batch_binding(repo, %InboundBatch{} = batch) do
    case repo.get_by(Binding, agent_uid: batch.agent_uid, name: batch.binding_name) do
      %Binding{} = binding -> {:ok, binding}
      nil -> {:error, :binding_not_found}
    end
  end

  defp batch_channel(repo, %InboundBatch{} = batch) do
    case repo.get(Channel, batch.signal_channel_id) do
      %Channel{} = channel -> {:ok, channel}
      nil -> {:error, :signal_channel_not_found}
    end
  end

  defp create_inbound_batch(repo, fact, policy, mode, entries, now) do
    policy = Atom.to_string(policy)

    entries = normalize_batch_entries(entries)

    attrs = %{
      agent_uid: fact.agent_uid,
      binding_name: fact.binding_name,
      session_id: Map.get(fact, :session_id) || signal_session_id(fact.signal_channel_id),
      signal_channel_id: fact.signal_channel_id,
      provider_thread_id: thread_key(fact.provider_thread_id),
      reply_to_source_entry_id: Map.get(fact, :reply_to_source_entry_id),
      batch_state: "open",
      mode: mode,
      policy: policy,
      requester_sender_key: requester_sender_key(mode, entries),
      entries: entries,
      available_at: inbound_due_at(mode, policy, entries, nil, now),
      hard_cap_at: inbound_hard_cap_at(mode, policy, entries, nil, now)
    }

    %InboundBatch{}
    |> InboundBatch.changeset(attrs)
    |> repo.insert()
    |> notify_inbound_batch_deadline(repo)
  end

  defp update_inbound_batch(%InboundBatch{} = batch, repo, new_entries, now) do
    existing_entries = normalize_batch_entries(batch.entries)
    entries = normalize_batch_entries(existing_entries ++ new_entries)

    if entries == batch.entries do
      {:ok, batch}
    else
      batch
      |> InboundBatch.changeset(%{
        entries: entries,
        requester_sender_key: requester_sender_key(batch.mode, entries),
        available_at: inbound_due_at(batch.mode, batch.policy, entries, batch, now),
        hard_cap_at: inbound_hard_cap_at(batch.mode, batch.policy, entries, batch, now),
        batch_revision: batch.batch_revision + 1
      })
      |> repo.update()
      |> notify_inbound_batch_deadline(repo)
    end
  end

  defp upgrade_neutral_batch_to_addressed(%InboundBatch{} = batch, repo, entries, policy, now) do
    entries = normalize_batch_entries(entries)

    batch
    |> InboundBatch.changeset(%{
      entries: entries,
      mode: "addressed",
      policy: Atom.to_string(policy),
      requester_sender_key: requester_sender_key("addressed", entries),
      available_at: inbound_due_at("addressed", policy, entries, batch, now),
      hard_cap_at: inbound_hard_cap_at("addressed", policy, entries, batch, now),
      batch_revision: batch.batch_revision + 1
    })
    |> repo.update()
    |> notify_inbound_batch_deadline(repo)
  end

  defp notify_inbound_batch_deadline({:ok, %InboundBatch{} = batch}, repo) do
    with :ok <- RuntimeEvents.notify_inbound_batch_due(repo, batch, batch.available_at) do
      {:ok, batch}
    end
  end

  defp notify_inbound_batch_deadline(result, _repo), do: result

  defp inbound_batch_runtime_event(%InboundBatch{} = batch) do
    {RuntimeEvents.inbound_batch_due_channel(),
     %{
       "batch_id" => batch.id,
       "batch_revision" => batch.batch_revision,
       "due_at" => RuntimeEvents.encode_datetime(batch.available_at)
     }}
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

  defp sort_batch_entries(entries) when is_list(entries) do
    Enum.sort_by(entries, fn entry ->
      {
        Map.get(entry, "provider_time") || Map.get(entry, "sent_at") || "",
        Map.get(entry, "received_at") || Map.get(entry, "sent_at") || "",
        Map.get(entry, "source_entry_id") || ""
      }
    end)
  end

  defp normalize_batch_entries(entries) when is_list(entries) do
    {deduped_by_identity, unkeyed} =
      Enum.reduce(entries, {%{}, []}, fn entry, {deduped, unkeyed} ->
        case batch_entry_identity(entry) do
          nil ->
            {deduped, [entry | unkeyed]}

          identity ->
            {Map.update(deduped, identity, entry, &newer_batch_entry(&1, entry)), unkeyed}
        end
      end)

    deduped_by_identity
    |> Map.values()
    |> Kernel.++(Enum.reverse(unkeyed))
    |> sort_batch_entries()
  end

  defp batch_entry_identity(%{"source_entry_id" => source_entry_id})
       when is_binary(source_entry_id) do
    case String.trim(source_entry_id) do
      "" -> nil
      value -> {:source_entry_id, value}
    end
  end

  defp batch_entry_identity(_entry), do: nil

  defp newer_batch_entry(existing, incoming) do
    cond do
      batch_entry_newer_than?(incoming, existing) ->
        incoming

      batch_entry_newer_than?(existing, incoming) ->
        existing

      batch_entry_content_signature(incoming) != batch_entry_content_signature(existing) ->
        incoming

      true ->
        existing
    end
  end

  defp batch_entry_newer_than?(left, right) do
    case {batch_entry_provider_time(left), batch_entry_provider_time(right)} do
      {%DateTime{} = left_time, %DateTime{} = right_time} ->
        DateTime.compare(left_time, right_time) == :gt

      {%DateTime{}, nil} ->
        true

      _other ->
        false
    end
  end

  defp batch_entry_provider_time(entry) when is_map(entry) do
    parse_datetime(entry["provider_time"])
  end

  defp batch_entry_provider_time(_entry), do: nil

  defp batch_entry_content_signature(entry) when is_map(entry) do
    entry["content_hash"] ||
      {
        entry["text"],
        entry["formatted_content"],
        entry["attachments"],
        entry["links"],
        entry["mentions"],
        entry["reply_to_source_entry_id"],
        entry["reply_to"]
      }
  end

  defp batch_entry_content_signature(entry), do: entry

  defp inbound_batch_entry(fact, mirror_entry, policy, type, now) do
    attrs = Projection.receive_entry_attrs(fact, now)

    %{
      "agent_uid" => fact.agent_uid,
      "binding_name" => fact.binding_name,
      "adapter" => fact.adapter,
      "source_event_id" => fact.source_event_id,
      "signal_channel_id" => fact.signal_channel_id,
      "source_entry_id" => fact.source_entry_id,
      "reply_to_source_entry_id" => Map.get(fact, :reply_to_source_entry_id),
      "reply_to" => Map.get(fact, :reply_to),
      "provider_thread_id" => fact.provider_thread_id,
      "sender_key" => fact.sender_key,
      "text" => fact.text,
      "formatted_content" => fact.formatted_content,
      "attachments" => fact.attachments,
      "links" => fact.links,
      "author" => fact.author,
      "mentions" => fact.mentions,
      "metadata" => Projection.signal_entry_metadata(fact),
      "raw_payload" => fact.raw_payload,
      "provider_time" => datetime_iso8601(fact.provider_time),
      "sent_at" => datetime_iso8601(fact.provider_time) || DateTime.to_iso8601(now),
      "received_at" => DateTime.to_iso8601(now),
      "document_id" => attrs.document_id,
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
      source_event_id: "inbound-batch:#{batch.id}:#{batch.batch_revision + 1}",
      signal_channel_id: batch.signal_channel_id,
      source_entry_id: last_entry["source_entry_id"],
      reply_to_source_entry_id: batch.reply_to_source_entry_id,
      reply_to: batch_reply_to(entries),
      provider_thread_id: unthread_key(batch.provider_thread_id),
      sender_key: batch.requester_sender_key,
      text: merged_entry_text(entries),
      attachments: merged_entry_attachments(entries),
      links: merged_entry_list(entries, "links"),
      author: last_entry["author"] || %{},
      mentions: merged_entry_list(entries, "mentions"),
      metadata: %{
        "source" => "inbound_batch",
        "batch_id" => batch.id,
        "batch_revision" => batch.batch_revision + 1,
        "source_entry_ids" => Enum.map(entries, & &1["source_entry_id"]),
        "source_signal_gateway_entries" =>
          Enum.map(entries, fn entry ->
            %{
              "signal_channel_id" => entry["signal_channel_id"],
              "source_entry_id" => entry["source_entry_id"]
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

  defp unmirrored_batch_entry_results(batch, binding, repo, now) do
    for entry <- batch.entries,
        entry["mirrored"] in [nil, false],
        do: mirror_batch_entry(repo, batch, binding, entry, now)
  end

  defp mirror_unmirrored_batch_entries(repo, batch, binding, now) do
    batch
    |> unmirrored_batch_entry_results(binding, repo, now)
    |> collect_results()
    |> case do
      {:ok, _entries} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp mirror_batch_entry(repo, batch, binding, entry, now) do
    attrs = %{
      agent_uid: batch.agent_uid,
      binding_name: batch.binding_name,
      adapter: entry["adapter"] || binding.adapter,
      source_event_id:
        entry["source_event_id"] || "inbound-batch-entry:#{batch.id}:#{entry["source_entry_id"]}",
      signal_channel_id: entry["signal_channel_id"],
      source_entry_id: entry["source_entry_id"],
      reply_to_source_entry_id: entry["reply_to_source_entry_id"],
      provider_thread_id: entry["provider_thread_id"],
      text: entry["text"],
      formatted_content: entry["formatted_content"] || %{},
      attachments: entry["attachments"] || [],
      links: entry["links"] || [],
      author: entry["author"] || %{},
      mentions: entry["mentions"] || [],
      metadata: entry["metadata"] || %{},
      raw_payload: entry["raw_payload"] || %{},
      provider_time: parse_datetime(entry["provider_time"])
    }

    with {:ok, fact} <- IngressFact.entry(attrs) do
      Projection.mirror_receive_entry(repo, fact, now)
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

  defp reply_target_from_entries(entries) do
    entries
    |> List.last()
    |> case do
      %{} = entry -> entry["reply_to_source_entry_id"]
      _value -> nil
    end
  end

  defp batch_reply_to(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"reply_to" => reply_to} when is_map(reply_to) -> reply_to
      _entry -> nil
    end)
  end

  defp recompute_batch_mode(entries) do
    case Enum.any?(entries, &(&1["explicit"] == true)) do
      true -> "addressed"
      false -> "neutral"
    end
  end

  defp non_bot_mention?(%{} = entry) when is_map_key(entry, "non_bot_mention"),
    do: entry["non_bot_mention"] == true

  defp non_bot_mention?(fact) do
    fact
    |> Map.get(:mentions, [])
    |> Enum.any?(fn mention -> structured_non_bot_mention?(mention, fact.agent_uid) end)
  end

  defp structured_non_bot_mention?(mention, agent_uid) when is_map(mention) do
    structured? =
      truthy?(Map.get(mention, "structured")) ||
        not is_nil(Map.get(mention, "kind"))

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
    case pending_attachment_deadline(entries, now) do
      %DateTime{} = deadline ->
        deadline

      nil ->
        entry = List.last(entries) || %{}
        anchor = attachment_observed_at(entry) || now
        DateTime.add(anchor, addressed_entry_window_ms(entry), :millisecond)
    end
  end

  defp inbound_due_at("neutral", "may_intervene", entries, _batch, now) do
    case pending_attachment_deadline(entries, now) do
      %DateTime{} = deadline ->
        deadline

      nil ->
        min_datetime(
          DateTime.add(now, @ambient_batch_window_ms, :millisecond),
          ambient_hard_cap_at(entries, now)
        )
    end
  end

  defp inbound_due_at("neutral", _policy, entries, _batch, now) do
    case pending_attachment_deadline(entries, now) do
      %DateTime{} = deadline ->
        deadline

      nil ->
        entry = List.last(entries) || %{}
        anchor = attachment_observed_at(entry) || now
        DateTime.add(anchor, neutral_entry_window_ms(entry), :millisecond)
    end
  end

  defp inbound_hard_cap_at(mode, policy, entries, _batch, now) do
    case pending_attachment_deadline(entries, now) do
      %DateTime{} = deadline ->
        deadline

      nil ->
        ambient_hard_cap_at(mode, policy, entries, now)
    end
  end

  defp ambient_hard_cap_at("neutral", "may_intervene", entries, now),
    do: ambient_hard_cap_at(entries, now)

  defp ambient_hard_cap_at(_mode, _policy, _entries, _now), do: nil

  defp ambient_hard_cap_at(entries, now) do
    anchor =
      entries
      |> List.first()
      |> case do
        %{} = entry -> parse_datetime(entry["received_at"]) || now
        _missing -> now
      end

    DateTime.add(anchor, @ambient_hard_cap_ms, :millisecond)
  end

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

  defp neutral_entry_window_ms(entry) do
    if entry_has_attachments?(entry),
      do: @addressed_attachment_window_ms,
      else: @neutral_text_window_ms
  end

  defp pending_attachment_deadline(entries, now) do
    entries
    |> Enum.filter(&(attachment_materialization_state(&1) == "pending"))
    |> Enum.map(fn entry ->
      anchor =
        attachment_observed_at(entry) ||
          parse_datetime(entry["received_at"]) ||
          now

      DateTime.add(anchor, @attachment_materialization_hard_cap_ms, :millisecond)
    end)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp attachment_observed_at(entry) when is_map(entry) do
    entry
    |> get_in(["metadata", "attachment_materialization", "observed_at"])
    |> parse_datetime()
  end

  defp attachment_observed_at(_entry), do: nil

  defp attachment_materialization_state(entry) when is_map(entry),
    do: get_in(entry, ["metadata", "attachment_materialization", "state"])

  defp attachment_materialization_state(_entry), do: nil

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

  defp merged_entry_attachments(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      source_entry_id = entry["source_entry_id"]

      case entry["attachments"] do
        values when is_list(values) ->
          Enum.map(values, &{attachment_dedup_key(&1, source_entry_id), &1})

        _value ->
          []
      end
    end)
    |> Enum.uniq_by(fn {key, _attachment} -> key end)
    |> Enum.map(fn {_key, attachment} -> attachment end)
  end

  defp attachment_dedup_key(%{} = attachment, source_entry_id) do
    {
      attachment["source_message_id"] || source_entry_id,
      attachment["provider_ref"] || attachment["file_key"] || attachment["agent_computer_path"] ||
        attachment["user_files_relative_path"] || attachment["name"] || attachment
    }
  end

  defp attachment_dedup_key(attachment, source_entry_id), do: {source_entry_id, attachment}

  defp entries_text_length(entries) do
    entries
    |> Enum.map(fn entry -> entry["text_length"] || text_length(entry["text"]) end)
    |> Enum.sum()
  end
end
