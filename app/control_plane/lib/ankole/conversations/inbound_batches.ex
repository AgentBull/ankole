defmodule Ankole.Conversations.InboundBatches do
  import Ankole.Attrs,
    only: [
      collect_results: 1,
      datetime_iso8601: 1,
      parse_datetime: 1,
      structured_mention?: 2,
      truthy?: 1
    ]

  @moduledoc false

  require Ash.Query

  alias Ankole.Signals.Signal

  import Ankole.Conversations.MessageInput,
    only: [
      pending_attachment_deadline: 2,
      attachment_observed_at: 1,
      merged_entry_text: 1,
      merged_entry_list: 2
    ]

  alias Ankole.Conversations.Envelope
  alias Ankole.Conversations.InputRevisions
  alias Ankole.Conversations.InboundBatch
  alias Ankole.Conversations.Observation
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.ExternalMessageRef

  @addressed_text_window_ms 1_000
  @neutral_text_window_ms 600
  @addressed_attachment_window_ms 1_200
  @addressed_long_text_window_ms 2_000
  @addressed_long_text_threshold 3_000
  @addressed_text_budget 4_000
  @addressed_text_hard_cap 8_000
  @addressed_max_entries 8
  @ambient_batch_window_ms 15_000
  @ambient_hard_cap_ms 5 * 60 * 1_000

  @doc false
  @spec finalize_inbound_batch_by_id(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def finalize_inbound_batch_by_id(batch_id, opts \\ []) when is_binary(batch_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Ankole.Repo.transact_top_level(
      fn -> finalize_due_in_tx(batch_id, now) end,
      after_commit: &Envelope.publish_committed/1
    )
  end

  @doc false
  def finalize_due_in_tx(batch_id, now) do
    case lock_inbound_batch_by_id(batch_id) do
      nil ->
        {:error, :inbound_batch_not_found}

      %InboundBatch{batch_state: :open} = batch ->
        if DateTime.after?(batch.available_at, now),
          do: {:ok, %{status: :not_due, available_at: batch.available_at}},
          else: finalize_inbound_batch_in_tx(batch, now)

      batch ->
        {:ok, %{status: :already_finalized, inbound_batch: batch}}
    end
  end

  @spec entry_snapshot(String.t(), String.t(), String.t(), String.t()) :: map() | nil
  def entry_snapshot(
        agent_uid,
        binding_name,
        conversation_id,
        provider_message_id
      )
      when is_binary(agent_uid) and is_binary(binding_name) and is_binary(conversation_id) and
             is_binary(provider_message_id) do
    case observed_entry_batch(agent_uid, binding_name, conversation_id, provider_message_id) do
      %InboundBatch{entries: entries} -> find_entry(entries, provider_message_id)
      nil -> nil
    end
  end

  # A previously ignored but actually observed quote becomes part of the
  # shared history before the replying message links to it.
  def promote_reference_in_tx(binding, fact, now) do
    provider_id = Map.get(fact, :reply_to_provider_message_id)

    if is_binary(provider_id) and
         is_nil(Ankole.Conversations.External.get_message(fact.conversation_id, provider_id)) do
      case observed_entry_batch(
             binding.agent_uid,
             binding.name,
             fact.conversation_id,
             provider_id
           ) do
        %InboundBatch{} = batch ->
          entry = find_entry(batch.entries, provider_id)
          with {:ok, _} <- mirror_batch_entry(batch, binding, entry, now), do: :ok

        nil ->
          :ok
      end
    else
      :ok
    end
  end

  defp observed_entry_batch(agent_uid, binding_name, conversation_id, provider_id) do
    InboundBatch
    |> Ash.Query.filter(
      agent_uid == ^agent_uid and binding_name == ^binding_name and
        conversation_id == ^conversation_id and
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS entry WHERE entry->>'provider_message_id' = ?)",
          entries,
          ^provider_id
        )
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ankole.Ash.read_one!()
  end

  def apply_im_entry_policy(binding, fact, policy, type, now) do
    with :ok <- lock_in_tx(fact),
         %Conversation{} = channel <- conversation(fact.conversation_id) do
      batch = open_inbound_batch(fact)

      case mirrored_outside_open_batch?(fact, batch) do
        true ->
          with {:ok, mirror_entry} <- maybe_mirror_im_entry(fact, policy, type, now),
               source_entry <- inbound_batch_entry(fact, mirror_entry, policy, type, now),
               {:ok, supplement} <-
                 maybe_apply_live_attachment_supplement(
                   batch,
                   fact,
                   source_entry,
                   now
                 ),
               {:ok, result} <-
                 route_finalized_duplicate_or_attachment_supplement(
                   supplement,
                   batch,
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
             |> Map.put(:conversation, channel)
             |> maybe_put_result(:message_observation, mirror_entry)}
          end

        false ->
          with {:ok, mirror_entry} <- maybe_mirror_im_entry(fact, policy, type, now),
               source_entry <- inbound_batch_entry(fact, mirror_entry, policy, type, now),
               {:ok, supplement} <-
                 maybe_apply_live_attachment_supplement(
                   batch,
                   fact,
                   source_entry,
                   now
                 ),
               {:ok, result} <-
                 route_after_live_attachment_supplement(
                   supplement,
                   batch,
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
             |> Map.put(:conversation, channel)
             |> maybe_put_result(:message_observation, mirror_entry)}
          end
      end
    else
      nil -> {:error, :conversation_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp mirrored_outside_open_batch?(fact, batch) do
    not batch_contains_source_entry?(batch, fact.provider_message_id) and
      ExternalMessageRef
      |> Ash.Query.filter(
        conversation_id == ^fact.conversation_id and
          provider_message_id == ^fact.provider_message_id
      )
      |> Ankole.Ash.exists?() and
      finalized_batch_contains_source_entry?(fact)
  end

  defp finalized_batch_contains_source_entry?(fact) do
    InboundBatch
    |> Ash.Query.filter(
      agent_uid == ^fact.agent_uid and binding_name == ^fact.binding_name and
        conversation_id == ^fact.conversation_id and batch_state == :finalized and
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS entry WHERE entry->>'provider_message_id' = ?)",
          entries,
          ^fact.provider_message_id
        )
    )
    |> Ankole.Ash.exists?()
  end

  defp batch_contains_source_entry?(%InboundBatch{entries: entries}, provider_message_id) do
    Enum.any?(entries, &(&1["provider_message_id"] == provider_message_id))
  end

  defp batch_contains_source_entry?(nil, _provider_message_id), do: false

  defp find_entry(entries, provider_message_id),
    do: Enum.find(entries, &(&1["provider_message_id"] == provider_message_id))

  defp maybe_put_result(result, _key, nil), do: result
  defp maybe_put_result(result, key, value), do: Map.put(result, key, value)

  defp maybe_apply_live_attachment_supplement(
         nil,
         fact,
         source_entry,
         now
       ) do
    InputRevisions.merge_attachment_supplement_in_tx(fact, source_entry, now)
  end

  defp maybe_apply_live_attachment_supplement(
         %InboundBatch{},
         fact,
         source_entry,
         now
       ) do
    InputRevisions.refresh_attachment_supplement_in_tx(fact, source_entry, now)
  end

  defp route_finalized_duplicate_or_attachment_supplement(
         :not_supplement,
         batch,
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
         binding,
         channel,
         fact,
         source_entry,
         policy,
         type,
         now
       ) do
    batch
    |> maybe_finalize_due_batch(now)
    |> maybe_finalize_reply_boundary(fact, now)
    |> route_inbound_batch_entry(
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
         _binding,
         _channel,
         fact,
         _source_entry,
         _policy,
         _type,
         now
       ) do
    with {:ok, mirror_entry} <- Ankole.Conversations.External.observe_entry_in_tx(fact, now) do
      {:ok, Map.put(result, :message_observation, mirror_entry)}
    end
  end

  defp route_after_live_attachment_supplement(
         {:next_turn, reason},
         nil,
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
         binding,
         channel,
         fact,
         source_entry,
         _policy,
         _type,
         now
       ) do
    source_entry = Map.put(source_entry, "explicit", true)

    with {:ok, closed} <- finalize_inbound_batch_in_tx(batch, now),
         {:ok, result} <-
           append_addressed_inbound_entry(
             nil,
             binding,
             channel,
             fact,
             source_entry,
             :ignore,
             now
           ) do
      {:ok,
       result
       |> merge_finalized_signals(closed)
       |> Map.put(:input_supersession_fallback, reason)}
    end
  end

  defp maybe_mirror_im_entry(fact, policy, type, now) do
    case should_mirror_im_entry?(policy, type) do
      true -> Ankole.Conversations.External.observe_entry_in_tx(fact, now)
      false -> {:ok, nil}
    end
  end

  defp should_mirror_im_entry?(_policy, "conversation.message.addressed"), do: true
  defp should_mirror_im_entry?(:record_only, _type), do: true
  defp should_mirror_im_entry?(:may_intervene, _type), do: true
  defp should_mirror_im_entry?(_policy, _type), do: false

  defp maybe_finalize_due_batch(nil, _now) do
    {:ok, %{inbound_batch: nil, finalized_signals: []}}
  end

  defp maybe_finalize_due_batch(%InboundBatch{available_at: available_at} = batch, now) do
    case DateTime.compare(available_at, now) do
      :gt ->
        {:ok, %{inbound_batch: batch, finalized_signals: []}}

      _ready ->
        with {:ok, result} <- finalize_inbound_batch_in_tx(batch, now) do
          {:ok, %{inbound_batch: nil, finalized_signals: finalized_signals(result)}}
        end
    end
  end

  defp maybe_finalize_reply_boundary(
         {:ok, %{inbound_batch: nil} = state},
         _fact,
         _now
       ),
       do: {:ok, state}

  defp maybe_finalize_reply_boundary(
         {:ok, %{inbound_batch: %InboundBatch{} = batch} = state},
         fact,
         now
       ) do
    reply_to_provider_message_id = Map.get(fact, :reply_to_provider_message_id)

    if batch.reply_to_provider_message_id == reply_to_provider_message_id do
      {:ok, state}
    else
      with {:ok, finalized} <- finalize_inbound_batch_in_tx(batch, now) do
        events =
          (state.finalized_signals ++ finalized_signals(finalized))
          |> Enum.uniq_by(& &1.id)

        {:ok, %{state | inbound_batch: nil, finalized_signals: events}}
      end
    end
  end

  defp maybe_finalize_reply_boundary({:error, _reason} = error, _fact, _now),
    do: error

  defp route_inbound_batch_entry(
         {:ok, %{inbound_batch: batch, finalized_signals: finalized_events}},
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
             binding,
             channel,
             fact,
             entry,
             policy,
             type,
             now
           ) do
      {:ok, put_finalized_signals(result, finalized_events)}
    end
  end

  defp route_inbound_batch_entry(
         batch,
         binding,
         channel,
         fact,
         entry,
         policy,
         "conversation.message.addressed",
         now
       ) do
    append_addressed_inbound_entry(batch, binding, channel, fact, entry, policy, now)
  end

  defp route_inbound_batch_entry(batch, binding, channel, fact, entry, policy, _type, now) do
    append_neutral_inbound_entry(batch, binding, channel, fact, entry, policy, now)
  end

  defp append_addressed_inbound_entry(nil, _binding, _channel, fact, entry, policy, now)
       when is_map(entry) do
    create_inbound_batch(fact, policy, :addressed, [entry], now)
    |> inbound_result(:accepted)
  end

  defp append_addressed_inbound_entry(
         %InboundBatch{mode: :addressed} = batch,
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
        update_inbound_batch(batch, [entry], now)
        |> inbound_result(:accepted)

      true ->
        with {:ok, closed} <- finalize_inbound_batch_in_tx(batch, now),
             {:ok, result} <-
               append_addressed_inbound_entry(
                 nil,
                 binding,
                 channel,
                 fact,
                 entry,
                 policy,
                 now
               ) do
          {:ok, merge_finalized_signals(result, closed)}
        end
    end
  end

  defp append_addressed_inbound_entry(
         %InboundBatch{mode: :neutral} = batch,
         binding,
         channel,
         fact,
         entry,
         policy,
         now
       ) do
    {prefix, tail} = split_addressable_tail(batch.entries, entry)
    addressed_entries = Enum.map(tail, &admit_same_sender_entry(&1, entry)) ++ [entry]

    case prefix do
      [] ->
        batch
        |> upgrade_neutral_batch_to_addressed(addressed_entries, policy, now)
        |> inbound_result(:accepted)

      [_ | _] ->
        with {:ok, closed_prefix} <-
               close_or_replace_neutral_prefix(batch, prefix, tail, now),
             {:ok, result} <-
               append_addressed_inbound_entry(
                 nil,
                 binding,
                 channel,
                 fact,
                 addressed_entries,
                 policy,
                 now
               ) do
          {:ok, put_finalized_signals(result, closed_prefix.finalized_signals)}
        end
    end
  end

  defp append_addressed_inbound_entry(
         nil,
         _binding,
         _channel,
         fact,
         entries,
         policy,
         now
       )
       when is_list(entries) do
    create_inbound_batch(fact, policy, :addressed, entries, now)
    |> inbound_result(:accepted)
  end

  defp append_neutral_inbound_entry(nil, _binding, _channel, fact, entry, policy, now) do
    create_inbound_batch(fact, policy, :neutral, [entry], now)
    |> inbound_result(neutral_status(policy))
  end

  defp append_neutral_inbound_entry(
         %InboundBatch{mode: :neutral} = batch,
         _binding,
         _channel,
         _fact,
         entry,
         policy,
         now
       ) do
    batch
    |> update_inbound_batch([entry], now)
    |> inbound_result(neutral_status(policy))
  end

  defp append_neutral_inbound_entry(
         %InboundBatch{mode: :addressed} = batch,
         binding,
         channel,
         fact,
         entry,
         policy,
         now
       ) do
    requester = Enum.find(batch.entries, &(&1["sender_key"] == batch.requester_sender_key))
    same_sender? = requester != nil and same_entry_sender?(requester, entry)
    entry = if same_sender?, do: admit_same_sender_entry(entry, requester), else: entry

    cond do
      same_sender? and addressable_neutral_entry?(entry) and
          not addressed_batch_full?(batch.entries, entry) ->
        batch
        |> update_inbound_batch([entry], now)
        |> inbound_result(:accepted)

      same_sender? and addressable_neutral_entry?(entry) ->
        with {:ok, closed} <- finalize_inbound_batch_in_tx(batch, now),
             {:ok, result} <-
               create_inbound_batch(fact, policy, :addressed, [entry], now)
               |> inbound_result(:accepted) do
          {:ok, merge_finalized_signals(result, closed)}
        end

      true ->
        with {:ok, closed} <- finalize_inbound_batch_in_tx(batch, now),
             {:ok, result} <-
               append_neutral_inbound_entry(nil, binding, channel, fact, entry, policy, now) do
          {:ok, merge_finalized_signals(result, closed)}
        end
    end
  end

  defp close_or_replace_neutral_prefix(batch, prefix, [] = _tail, now) do
    Ankole.Ash.update(batch, :replace_prefix, %{entries: prefix})
    |> case do
      {:ok, updated} ->
        with {:ok, result} <- finalize_inbound_batch_in_tx(updated, now) do
          {:ok, %{tail: [], finalized_signals: finalized_signals(result)}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp close_or_replace_neutral_prefix(batch, prefix, tail, now) do
    Ankole.Ash.update(batch, :replace_prefix, %{entries: prefix})
    |> case do
      {:ok, updated} -> finalize_inbound_batch_in_tx(updated, now)
      {:error, _reason} = error -> error
    end
    |> case do
      {:ok, result} ->
        {:ok, %{tail: tail, finalized_signals: finalized_signals(result)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp inbound_result({:ok, %InboundBatch{} = batch}, status) do
    {:ok, %{status: status, inbound_batch: batch}}
  end

  defp inbound_result({:error, _reason} = error, _status), do: error

  defp merge_finalized_signals(result, finalized_result) when is_map(result) do
    put_finalized_signals(result, finalized_signals(finalized_result))
  end

  defp put_finalized_signals(result, []), do: result

  defp put_finalized_signals(result, events) when is_map(result) and is_list(events) do
    existing = Map.get(result, :finalized_signals, [])

    events =
      (existing ++ events)
      |> Enum.uniq_by(& &1.id)

    Map.put(result, :finalized_signals, events)
  end

  defp finalized_signals(%{signal: %Signal{} = event}), do: [event]
  defp finalized_signals(_result), do: []

  defp neutral_status(:record_only), do: :recorded
  defp neutral_status(:may_intervene), do: :recorded
  defp neutral_status(:ignore), do: :ignored

  defp lock_inbound_batch_by_id(batch_id) do
    InboundBatch
    |> Ash.Query.filter(id == ^batch_id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  defp finalize_inbound_batch_in_tx(%InboundBatch{entries: []} = batch, _now) do
    cancel_inbound_batch(batch)
  end

  defp finalize_inbound_batch_in_tx(%InboundBatch{mode: :addressed} = batch, now) do
    with {:ok, append_result} <-
           append_batch_signal(batch, "conversation.message.addressed", now) do
      finalize_batch_signal_append(batch, append_result)
    end
  end

  defp finalize_inbound_batch_in_tx(%InboundBatch{mode: :neutral} = batch, now) do
    case batch.policy do
      :may_intervene ->
        with {:ok, append_result} <-
               append_batch_signal(batch, "im.message.may_intervene", now) do
          finalize_batch_signal_append(batch, append_result)
        end

      _no_signal ->
        with {:ok, closed} <-
               Ankole.Ash.update(batch, :finalize, %{}) do
          {:ok, %{status: :ignored, inbound_batch: closed}}
        end
    end
  end

  defp finalize_batch_signal_append(
         %InboundBatch{} = batch,
         %Signal{} = signal
       ) do
    with {:ok, closed} <-
           Ankole.Ash.update(batch, :finalize, %{}) do
      {:ok, %{status: :accepted, signal: signal, inbound_batch: closed}}
    end
  end

  defp cancel_inbound_batch(batch, extra_attrs \\ %{}) do
    with {:ok, closed} <- Ankole.Ash.update(batch, :cancel, extra_attrs) do
      {:ok, %{status: :canceled, inbound_batch: closed}}
    end
  end

  def remove_pending_inbound_entry(fact, now) do
    fact
    |> pending_inbound_batches_for_lifecycle()
    |> Enum.map(&remove_entry_from_inbound_batch(&1, fact, now))
    |> collect_results()
    |> case do
      {:ok, results} -> {:ok, Enum.reject(results, &is_nil/1)}
      {:error, _reason} = error -> error
    end
  end

  defp pending_inbound_batches_for_lifecycle(fact) do
    InboundBatch
    |> Ash.Query.filter(
      agent_uid == ^fact.agent_uid and binding_name == ^fact.binding_name and
        conversation_id == ^fact.conversation_id and batch_state == :open
    )
    |> maybe_where_thread(fact.provider_thread_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!()
  end

  defp maybe_where_thread(query, nil), do: query

  defp maybe_where_thread(query, provider_thread_id) do
    thread = thread_key(provider_thread_id)
    Ash.Query.filter(query, provider_thread_id == ^thread)
  end

  defp remove_entry_from_inbound_batch(%InboundBatch{} = batch, fact, now) do
    entries =
      batch.entries
      |> Enum.reject(&(&1["provider_message_id"] == fact.provider_message_id))
      |> sort_batch_entries()

    cond do
      length(entries) == length(batch.entries) ->
        {:ok, nil}

      entries == [] ->
        with {:ok, %{inbound_batch: closed}} <-
               cancel_inbound_batch(batch, %{entries: []}) do
          {:ok, closed}
        end

      true ->
        mode = recompute_batch_mode(entries)

        Ankole.Ash.update(batch, :revise, %{
          mode: mode,
          entries: entries,
          reply_to_provider_message_id: reply_target_from_entries(entries),
          requester_sender_key: requester_sender_key(mode, entries),
          available_at: inbound_due_at(mode, batch.policy, entries, batch, now)
        })
        |> notify_inbound_batch_deadline()
    end
  end

  defp append_batch_signal(batch, type, now) do
    with {:ok, binding} <- batch_binding(batch),
         {:ok, channel} <- batch_channel(batch),
         :ok <- mirror_unmirrored_batch_entries(batch, binding, now) do
      fact = batch_signal_fact(batch, channel, type, now)
      Envelope.accept(binding, fact, type, channel, nil, now)
    end
  end

  defp batch_binding(%InboundBatch{binding_name: name} = batch)
       when is_binary(name) and name != "" do
    case Ankole.Signals.get_binding!(batch.agent_uid, name) do
      nil -> {:error, :binding_not_found}
      binding -> {:ok, binding}
    end
  end

  defp batch_binding(%InboundBatch{}), do: {:error, :binding_not_found}

  defp batch_channel(%InboundBatch{} = batch) do
    case conversation(batch.conversation_id) do
      %Conversation{} = channel -> {:ok, channel}
      nil -> {:error, :conversation_not_found}
    end
  end

  defp conversation(id),
    do: Conversation |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()

  defp create_inbound_batch(fact, policy, mode, entries, now) do
    entries = normalize_batch_entries(entries)

    attrs = %{
      agent_uid: fact.agent_uid,
      binding_name: fact.binding_name,
      session_id:
        Map.get(fact, :session_id) || Ankole.Sessions.Key.conversation(fact.conversation_id),
      conversation_id: fact.conversation_id,
      provider_thread_id: thread_key(fact.provider_thread_id),
      reply_to_provider_message_id: Map.get(fact, :reply_to_provider_message_id),
      mode: mode,
      policy: policy,
      requester_sender_key: requester_sender_key(mode, entries),
      entries: entries,
      available_at: inbound_due_at(mode, policy, entries, nil, now)
    }

    Ankole.Ash.create(InboundBatch, :open, attrs)
    |> notify_inbound_batch_deadline()
  end

  defp update_inbound_batch(%InboundBatch{} = batch, new_entries, now) do
    existing_entries = normalize_batch_entries(batch.entries)
    entries = normalize_batch_entries(existing_entries ++ new_entries)

    if entries == batch.entries do
      {:ok, batch}
    else
      Ankole.Ash.update(batch, :revise, %{
        entries: entries,
        requester_sender_key: requester_sender_key(batch.mode, entries),
        available_at: inbound_due_at(batch.mode, batch.policy, entries, batch, now)
      })
      |> notify_inbound_batch_deadline()
    end
  end

  defp upgrade_neutral_batch_to_addressed(%InboundBatch{} = batch, entries, policy, now) do
    entries = normalize_batch_entries(entries)

    Ankole.Ash.update(batch, :revise, %{
      entries: entries,
      mode: :addressed,
      policy: policy,
      requester_sender_key: requester_sender_key(:addressed, entries),
      available_at: inbound_due_at(:addressed, policy, entries, batch, now)
    })
    |> notify_inbound_batch_deadline()
  end

  defp notify_inbound_batch_deadline({:ok, %InboundBatch{} = batch}) do
    with :ok <-
           Ankole.Conversations.Jobs.InboundBatchFinalize.schedule_in_tx(
             %{batch_id: batch.id},
             batch.available_at
           ) do
      {:ok, batch}
    end
  end

  defp notify_inbound_batch_deadline(result), do: result

  defp open_inbound_batch(fact) do
    thread = thread_key(fact.provider_thread_id)

    InboundBatch
    |> Ash.Query.filter(
      agent_uid == ^fact.agent_uid and binding_name == ^fact.binding_name and
        conversation_id == ^fact.conversation_id and provider_thread_id == ^thread and
        batch_state == :open
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ankole.Ash.read_one!()
  end

  defp sort_batch_entries(entries) when is_list(entries) do
    Enum.sort_by(entries, fn entry ->
      {
        Map.get(entry, "provider_time") || Map.get(entry, "sent_at") || "",
        Map.get(entry, "received_at") || Map.get(entry, "sent_at") || "",
        Map.get(entry, "provider_message_id") || ""
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

  defp batch_entry_identity(%{"provider_message_id" => provider_message_id})
       when is_binary(provider_message_id) do
    case String.trim(provider_message_id) do
      "" -> nil
      value -> {:provider_message_id, value}
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
        entry["reply_to_provider_message_id"],
        entry["reply_to"]
      }
  end

  defp batch_entry_content_signature(entry), do: entry

  defp inbound_batch_entry(fact, mirror_entry, policy, type, now) do
    attachments = if mirror_entry, do: mirror_entry.message.attachments, else: fact.attachments
    document_id = if mirror_entry, do: mirror_entry.message.id, else: nil

    content_hash =
      if mirror_entry,
        do: mirror_entry.external_ref.content_hash,
        else: Ankole.Attrs.digest([fact.text, fact.attachments])

    %{
      "agent_uid" => fact.agent_uid,
      "binding_name" => fact.binding_name,
      "adapter" => fact.adapter,
      "source_event_id" => fact.source_event_id,
      "conversation_id" => fact.conversation_id,
      "provider_message_id" => fact.provider_message_id,
      "reply_to_provider_message_id" => Map.get(fact, :reply_to_provider_message_id),
      "reply_to" => Map.get(fact, :reply_to),
      "provider_thread_id" => fact.provider_thread_id,
      "sender_key" => fact.sender_key,
      "text" => fact.text,
      "formatted_content" => fact.formatted_content,
      "attachments" => attachments,
      "links" => fact.links,
      "author" => fact.author,
      "mentions" => fact.mentions,
      "metadata" => fact.metadata || %{},
      "raw_payload" => fact.raw_payload,
      "provider_time" => datetime_iso8601(fact.provider_time),
      "sent_at" => datetime_iso8601(fact.provider_time) || DateTime.to_iso8601(now),
      "received_at" => DateTime.to_iso8601(now),
      "message_id" => document_id,
      "content_hash" => content_hash,
      "explicit" => type == "conversation.message.addressed",
      "policy" => Atom.to_string(policy),
      "mirrored" => not is_nil(mirror_entry),
      "addressable_neutral" => addressable_neutral_fact?(fact, type),
      "non_bot_mention" => non_bot_mention?(fact),
      "text_length" => text_length(fact.text)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp batch_signal_fact(%InboundBatch{} = batch, channel, type, now) do
    entries = batch.entries
    last_entry = List.last(entries) || %{}

    %{
      agent_uid: batch.agent_uid,
      binding_name: batch.binding_name,
      session_id: batch.session_id,
      source_event_id: "inbound-batch:#{batch.id}:#{batch.batch_revision + 1}",
      conversation_id: batch.conversation_id,
      provider_conversation_id: channel.provider_conversation_id,
      provider_message_id: last_entry["provider_message_id"],
      reply_to_provider_message_id: batch.reply_to_provider_message_id,
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
        "provider_message_ids" => Enum.map(entries, & &1["provider_message_id"]),
        "source_messages" =>
          Enum.map(entries, fn entry ->
            %{message: %{id: message_id}} =
              Ankole.Conversations.External.get_message(
                batch.conversation_id,
                entry["provider_message_id"]
              )

            %{
              "conversation_id" => batch.conversation_id,
              "message_id" => message_id,
              "provider_message_id" => entry["provider_message_id"]
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

  defp unmirrored_batch_entry_results(batch, binding, now) do
    for entry <- batch.entries,
        entry["mirrored"] in [nil, false],
        do: mirror_batch_entry(batch, binding, entry, now)
  end

  defp mirror_unmirrored_batch_entries(batch, binding, now) do
    batch
    |> unmirrored_batch_entry_results(binding, now)
    |> collect_results()
    |> case do
      {:ok, _entries} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp mirror_batch_entry(batch, binding, entry, now) do
    attrs = %{
      agent_uid: batch.agent_uid,
      binding_name: batch.binding_name,
      adapter: entry["adapter"] || binding.adapter,
      source_event_id:
        entry["source_event_id"] ||
          "inbound-batch-entry:#{batch.id}:#{entry["provider_message_id"]}",
      conversation_id: entry["conversation_id"],
      provider_message_id: entry["provider_message_id"],
      reply_to_provider_message_id: entry["reply_to_provider_message_id"],
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

    with {:ok, fact} <- Observation.entry(attrs) do
      Ankole.Conversations.External.observe_entry_in_tx(fact, now)
    end
  end

  defp split_addressable_tail(entries, addressed_entry) do
    {tail_reversed, prefix_reversed} =
      entries
      |> Enum.reverse()
      |> Enum.split_while(fn entry ->
        same_entry_sender?(entry, addressed_entry) and addressable_neutral_entry?(entry)
      end)

    {Enum.reverse(prefix_reversed), Enum.reverse(tail_reversed)}
  end

  # Ignored entries have no Principal admission. Match their provider subject to
  # the admitted sender before moving that same sender's tail into an addressed
  # batch; the ignored prefix must remain free of identity side effects.
  defp same_entry_sender?(left, right) do
    left_author = left["author"] || %{}
    right_author = right["author"] || %{}
    principal_uid = left_author["principal_uid"]

    (is_binary(principal_uid) and principal_uid == right_author["principal_uid"]) or
      (entry_provider(left) == entry_provider(right) and
         Enum.any?(entry_subjects(left_author), &(&1 in entry_subjects(right_author))))
  end

  defp entry_provider(entry) do
    author = entry["author"] || %{}
    author["provider"] || get_in(author, ["metadata", "provider"]) || entry["binding_name"]
  end

  defp entry_subjects(author) do
    [author["platform_subject"] | List.wrap(author["platform_subject_alternates"])]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp admit_same_sender_entry(entry, admitted) do
    entry
    |> Map.put("sender_key", admitted["sender_key"])
    |> Map.update!("author", fn author ->
      Map.merge(author, Map.take(admitted["author"], ["principal_uid", "human_access_version"]))
    end)
  end

  defp addressable_neutral_fact?(fact, type) do
    type != "conversation.message.addressed" and fact.channel_kind == :im_group and
      not non_bot_mention?(fact)
  end

  defp addressable_neutral_entry?(entry), do: entry["addressable_neutral"] == true

  defp reply_target_from_entries(entries) do
    entries
    |> List.last()
    |> case do
      %{} = entry -> entry["reply_to_provider_message_id"]
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
      true -> :addressed
      false -> :neutral
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

  defp inbound_due_at(:addressed, _policy, entries, _batch, now) do
    case pending_attachment_deadline(entries, now) do
      %DateTime{} = deadline ->
        deadline

      nil ->
        entry = List.last(entries) || %{}
        anchor = attachment_observed_at(entry) || now
        DateTime.add(anchor, addressed_entry_window_ms(entry), :millisecond)
    end
  end

  defp inbound_due_at(:neutral, :may_intervene, entries, _batch, now) do
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

  defp inbound_due_at(:neutral, _policy, entries, _batch, now) do
    case pending_attachment_deadline(entries, now) do
      %DateTime{} = deadline ->
        deadline

      nil ->
        entry = List.last(entries) || %{}
        anchor = attachment_observed_at(entry) || now
        DateTime.add(anchor, neutral_entry_window_ms(entry), :millisecond)
    end
  end

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

  defp entry_has_attachments?(entry) do
    case entry["attachments"] do
      [_ | _] -> true
      _value -> false
    end
  end

  defp requester_sender_key(:addressed, entries) do
    entries
    |> List.last()
    |> case do
      %{} = entry -> entry["sender_key"]
      _value -> nil
    end
  end

  defp requester_sender_key(_mode, _entries), do: nil

  defp merged_entry_attachments(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      provider_message_id = entry["provider_message_id"]

      case entry["attachments"] do
        values when is_list(values) ->
          Enum.map(values, &{attachment_dedup_key(&1, provider_message_id), &1})

        _value ->
          []
      end
    end)
    |> Enum.uniq_by(fn {key, _attachment} -> key end)
    |> Enum.map(fn {_key, attachment} -> attachment end)
  end

  defp attachment_dedup_key(%{} = attachment, provider_message_id) do
    {
      attachment["source_message_id"] || provider_message_id,
      attachment["provider_ref"] || attachment["file_key"] || attachment["blob_ref"] ||
        attachment["name"] || attachment
    }
  end

  defp attachment_dedup_key(attachment, provider_message_id),
    do: {provider_message_id, attachment}

  defp entries_text_length(entries) do
    entries
    |> Enum.map(fn entry -> entry["text_length"] || text_length(entry["text"]) end)
    |> Enum.sum()
  end

  def lock_in_tx(%InboundBatch{} = batch) do
    key =
      Enum.join(
        [
          "inbound_batch",
          batch.agent_uid,
          batch.binding_name,
          batch.conversation_id,
          batch.provider_thread_id
        ],
        "|"
      )

    Ankole.AdvisoryLock.lock!(Ankole.Repo, key)
    :ok
  end

  def lock_in_tx(fact) do
    key =
      Enum.join(
        [
          "inbound_batch",
          fact.agent_uid,
          fact.binding_name,
          fact.conversation_id,
          thread_key(fact.provider_thread_id)
        ],
        "|"
      )

    Ankole.AdvisoryLock.lock!(Ankole.Repo, key)
    :ok
  end

  defp min_datetime(%DateTime{} = left, %DateTime{} = right) do
    case DateTime.compare(left, right) do
      :gt -> right
      _other -> left
    end
  end

  defp text_length(text) when is_binary(text), do: String.length(text)

  defp text_length(_text), do: 0

  defp thread_key(nil), do: ""

  defp thread_key(value) when is_binary(value), do: value

  defp thread_key(value), do: to_string(value)

  defp unthread_key(""), do: nil

  defp unthread_key(value), do: value
end
