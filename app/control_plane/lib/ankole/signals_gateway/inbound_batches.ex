defmodule Ankole.SignalsGateway.InboundBatches do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Actors.ActorInput
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorInputEnvelope
  alias Ankole.SignalsGateway.InboundBatch
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SignalsGateway.SignalBinding
  alias Ankole.SignalsGateway.SignalChannel
  alias Ankole.SignalsGateway.SignalEntry

  import Ankole.SignalsGateway.Utils,
    only: [
      collect_results: 1,
      datetime_iso8601: 1,
      fetch_value: 2,
      min_datetime: 2,
      parse_datetime: 1,
      signal_session_id: 1,
      structured_mention?: 2,
      text_length: 1,
      thread_key: 1,
      truthy?: 1,
      unthread_key: 1
    ]

  @addressed_text_window_ms 600
  @addressed_attachment_window_ms 1_200
  @addressed_long_text_window_ms 2_000
  @addressed_long_text_threshold 3_000
  @addressed_text_budget 4_000
  @addressed_text_hard_cap 8_000
  @addressed_max_entries 8
  @ambient_batch_window_ms 15_000
  @ambient_hard_cap_ms 5 * 60 * 1_000

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

  def apply_im_entry_policy(repo, binding, fact, policy, type, now) do
    with :ok <- Projection.lock_inbound_batch(repo, fact),
         {:ok, channel} <- Projection.upsert_channel(repo, fact, now),
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

  defp maybe_put_result(result, _key, nil), do: result
  defp maybe_put_result(result, key, value), do: Map.put(result, key, value)

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
      with :ok <- Projection.lock_inbound_batch(repo, batch),
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
      ActorInputEnvelope.append_actor_input(binding, fact, type, channel, nil, now)
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
    attrs = Projection.receive_entry_attrs(fact, now)

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
      "metadata" => Projection.signal_entry_metadata(fact),
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

  defp unmirrored_batch_entry_results(entries, repo, now) do
    for entry <- entries,
        entry["mirrored"] in [nil, false],
        do: mirror_batch_entry(repo, entry, now)
  end

  defp mirror_unmirrored_batch_entries(repo, entries, now) do
    entries
    |> unmirrored_batch_entry_results(repo, now)
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
end
