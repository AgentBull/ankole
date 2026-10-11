defmodule Ankole.SignalsGateway.ActorRuntime.TurnRetry do
  @moduledoc "Owns entry merging before admission and durable revision input after admission."

  import Ecto.Query, warn: false

  import Ankole.SignalsGateway.Utils, only: [parse_datetime: 1, signal_session_id: 1]

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.ReplyDeletion
  alias Ankole.SignalsGateway.Outbox

  @attachment_materialization_hard_cap_ms 4_000

  @doc """
  Retracts one provider source entry from live actor event inside a transaction.
  """
  @spec retract_source_entry_in_tx(module(), map(), term(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def retract_source_entry_in_tx(repo, fact, kind, now) do
    candidates = candidate_events_for_source_entry(fact)

    candidates
    |> select([input], input.session_id)
    |> repo.all()
    |> then(&[fact_session_id(fact) | &1])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&Ankole.SignalsGateway.Actors.lock_actor_session_in_tx(repo, fact.agent_uid, &1))

    candidates
    |> lock("FOR UPDATE")
    |> repo.all()
    |> Enum.map(&retract_source_entry_from_event(repo, &1, fact, kind, now))
    |> Ankole.Attrs.collect_results()
    |> case do
      {:ok, results} ->
        results = Enum.reject(results, &is_nil/1)

        {:ok,
         %{
           results: results,
           canceled_actor_events: Enum.count(results, &(&1.status == :canceled)),
           canceled_actor_event_ids:
             for(%{status: :canceled, actor_event: event} <- results, do: event.id),
           retried_actor_events: Enum.count(results, &(&1.status == :retried))
         }}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Merges a contiguous attachment into the current IM request when it is safe.

  A pending provider attachment fences a live generation before download
  finishes. The same source entry later replaces its pending form and releases
  the ActorEvent when every attachment is materialized or failed.
  """
  @spec merge_attachment_supplement_in_tx(module(), map(), map(), DateTime.t()) ::
          {:ok, :not_supplement | {:consumed, map()} | {:next_turn, atom()}}
          | {:error, term()}
  def merge_attachment_supplement_in_tx(repo, fact, entry, now) do
    :ok =
      Ankole.SignalsGateway.Actors.lock_actor_session_in_tx(
        repo,
        fact.agent_uid,
        fact_session_id(fact)
      )

    case attachment_materialization_state(entry) do
      state when state in ["pending", "complete", "failed"] ->
        case event_for_supplement_source_entry(repo, fact, entry["source_entry_id"]) do
          %ActorEvent{} = event ->
            merge_into_open_event(repo, event, entry, now, true)

          nil ->
            if eligible_new_attachment_supplement?(entry) do
              fact
              |> latest_attachment_supplement_event(repo)
              |> classify_attachment_supplement(repo, fact, entry, now)
            else
              {:ok, :not_supplement}
            end
        end

      _missing ->
        {:ok, :not_supplement}
    end
  end

  @doc false
  @spec refresh_attachment_supplement_in_tx(module(), map(), map(), DateTime.t()) ::
          {:ok, :not_supplement | {:consumed, map()} | {:next_turn, atom()}}
          | {:error, term()}
  def refresh_attachment_supplement_in_tx(repo, fact, entry, now) do
    :ok =
      Ankole.SignalsGateway.Actors.lock_actor_session_in_tx(
        repo,
        fact.agent_uid,
        fact_session_id(fact)
      )

    with state when state in ["pending", "complete", "failed"] <-
           attachment_materialization_state(entry),
         %ActorEvent{} = event <-
           event_for_supplement_source_entry(repo, fact, entry["source_entry_id"]) do
      merge_into_open_event(repo, event, entry, now, true)
    else
      _missing -> {:ok, :not_supplement}
    end
  end

  defp classify_attachment_supplement(nil, _repo, _fact, _entry, _now),
    do: {:ok, :not_supplement}

  defp classify_attachment_supplement(
         %ActorEvent{completed_at: %DateTime{} = completed_at} = event,
         repo,
         _fact,
         entry,
         _now
       ) do
    if latest_session_event?(repo, event) do
      case attachment_observed_at(entry) do
        %DateTime{} = observed_at ->
          if DateTime.compare(completed_at, observed_at) in [:eq, :gt],
            do: {:ok, {:next_turn, :completion_won}},
            else: {:ok, :not_supplement}

        nil ->
          {:ok, :not_supplement}
      end
    else
      {:ok, :not_supplement}
    end
  end

  defp classify_attachment_supplement(
         %ActorEvent{input_state: "open", completed_at: nil} = event,
         repo,
         _fact,
         entry,
         now
       ) do
    if latest_session_event?(repo, event),
      do: merge_into_open_event(repo, event, entry, now, false),
      else: {:ok, :not_supplement}
  end

  defp classify_attachment_supplement(
         %ActorEvent{},
         _repo,
         _fact,
         _entry,
         _now
       ),
       do: {:ok, :not_supplement}

  defp merge_into_open_event(repo, event, entry, now, _refresh?) do
    if event_entry_content_current?(event_entries(event), entry) do
      {:ok, :not_supplement}
    else
      kind =
        if Enum.any?(event_entries(event), &(&1["source_entry_id"] == entry["source_entry_id"])),
          do: "edit",
          else: "supplement"

      with {:ok, event} <- ingress_revision_in_tx(repo, event, kind, entry, now) do
        {:ok, {:consumed, %{status: :input_superseded, actor_event: event}}}
      end
    end
  end

  defp ingress_revision_in_tx(repo, %{last_attempt_at: nil} = event, kind, entry, now),
    do: revise_event_in_tx(repo, event, kind, entry, now)

  defp ingress_revision_in_tx(repo, event, kind, entry, now) do
    revision = %{
      "actor_event_id" => event.id,
      "kind" => kind,
      "entry" => entry,
      "source_entry_id" => entry["source_entry_id"]
    }

    digest = :crypto.hash(:sha256, Ankole.JSON.encode!(revision)) |> Base.encode16(case: :lower)

    Ankole.SignalsGateway.append_actor_event_in_tx(repo, %{
      source_work: event,
      agent_uid: event.agent_uid,
      binding_name: event.binding_name,
      session_id: event.session_id,
      source_event_id: "revision:#{event.id}:#{digest}",
      signal_channel_id: event.signal_channel_id,
      provider_thread_id: event.provider_thread_id,
      source_entry_id: entry["source_entry_id"],
      type: "input.revised",
      available_at: now,
      sender_key: event.sender_key,
      payload:
        event.payload
        |> Map.put("type", "input.revised")
        |> Map.put("time", DateTime.to_iso8601(now))
        |> Map.put("data", %{"revision" => revision, "entry" => entry})
    })
  end

  # The driver calls this only after it has canceled the affected run.
  def revise_event_in_tx(repo, event, kind, entry, now) when kind in ["edit", "supplement"] do
    entries = event_entries(event)

    entries =
      if entries == [], do: List.wrap(get_in(event.payload, ["data", "entry"])), else: entries

    entries = upsert_event_entry(entries, entry)

    event
    |> ActorEvent.changeset(%{
      payload: supplement_payload(event.payload, entries, event.id, now),
      source_entry_id: merged_entry_summary(entries)["source_entry_id"],
      available_at: supplement_available_at(entries, now)
    })
    |> repo.update()
  end

  def revise_event_in_tx(repo, event, "remove", entry, now) do
    case source_entry_retraction(event_entries(event), event, entry["source_entry_id"]) do
      :no_match ->
        {:ok, event}

      :cancel ->
        with {:ok, _} <- commit_reply_deletions(repo, event),
             {:ok, _} <- repo.delete(event),
             do: {:ok, :removed}

      {:replace, entries} ->
        replace_event_entries(repo, event, entries, entry, now)
    end
  end

  defp event_for_supplement_source_entry(repo, fact, source_entry_id)
       when is_binary(source_entry_id) do
    session_id = fact_session_id(fact)

    ActorEvent
    |> where([event], event.agent_uid == ^fact.agent_uid)
    |> where([event], event.binding_name == ^fact.binding_name)
    |> where([event], event.signal_channel_id == ^fact.signal_channel_id)
    |> where([event], event.session_id == ^session_id)
    |> where([event], event.type == "im.message.addressed")
    |> where([event], event.input_state == "open")
    |> where([event], is_nil(event.completed_at))
    |> exact_event_thread(fact.provider_thread_id)
    |> where(
      [event],
      event.source_entry_id == ^source_entry_id or
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements(?->'data'->'entries') AS entry WHERE entry->>'source_entry_id' = ?)",
          event.payload,
          ^source_entry_id
        )
    )
    |> order_by([event], desc: event.queue_sequence)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp event_for_supplement_source_entry(_repo, _fact, _source_entry_id), do: nil

  defp latest_attachment_supplement_event(fact, repo) do
    session_id = fact_session_id(fact)

    ActorEvent
    |> where([event], event.agent_uid == ^fact.agent_uid)
    |> where([event], event.binding_name == ^fact.binding_name)
    |> where([event], event.signal_channel_id == ^fact.signal_channel_id)
    |> where([event], event.session_id == ^session_id)
    |> where([event], event.sender_key == ^fact.sender_key)
    |> where([event], event.type == "im.message.addressed")
    |> exact_event_thread(fact.provider_thread_id)
    |> order_by([event], desc: event.queue_sequence)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp exact_event_thread(query, nil), do: where(query, [event], is_nil(event.provider_thread_id))

  defp exact_event_thread(query, provider_thread_id) do
    where(query, [event], event.provider_thread_id == ^provider_thread_id)
  end

  defp fact_session_id(fact),
    do: Map.get(fact, :session_id) || signal_session_id(fact.signal_channel_id)

  defp latest_session_event?(repo, %ActorEvent{} = event) do
    latest_sequence =
      ActorEvent
      |> where([candidate], candidate.agent_uid == ^event.agent_uid)
      |> where([candidate], candidate.session_id == ^event.session_id)
      |> select([candidate], max(candidate.queue_sequence))
      |> repo.one()

    latest_sequence == event.queue_sequence
  end

  defp supplement_payload(payload, entries, actor_event_id, now) do
    summary = merged_entry_summary(entries)

    payload
    |> replace_payload_entries(entries, summary, nil, now)
    |> put_retry_metadata(actor_event_id, "input_superseded", %{
      "supplement_source_entry_ids" =>
        entries
        |> Enum.filter(
          &(attachment_materialization_state(&1) in ["pending", "complete", "failed"])
        )
        |> Enum.map(& &1["source_entry_id"])
    })
  end

  defp event_entry_content_current?(
         entries,
         %{"source_entry_id" => source_entry_id, "content_hash" => content_hash}
       )
       when is_binary(content_hash) do
    Enum.any?(entries, fn entry ->
      entry["source_entry_id"] == source_entry_id and entry["content_hash"] == content_hash
    end)
  end

  defp event_entry_content_current?(_entries, _entry), do: false

  defp upsert_event_entry(entries, entry) do
    entries
    |> Enum.reject(&(&1["source_entry_id"] == entry["source_entry_id"]))
    |> Kernel.++([entry])
    |> Enum.sort_by(fn value ->
      {
        value["provider_time"] || value["sent_at"] || "",
        value["received_at"] || value["sent_at"] || "",
        value["source_entry_id"] || ""
      }
    end)
  end

  defp supplement_available_at(entries, now) do
    entries
    |> Enum.filter(&(attachment_materialization_state(&1) == "pending"))
    |> Enum.map(fn entry ->
      anchor =
        attachment_observed_at(entry) ||
          parse_datetime(entry["received_at"]) ||
          now

      DateTime.add(anchor, @attachment_materialization_hard_cap_ms, :millisecond)
    end)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> now end)
  end

  defp attachment_observed_at(entry) do
    entry
    |> get_in(["metadata", "attachment_materialization", "observed_at"])
    |> parse_datetime()
  end

  defp attachment_materialization_state(entry),
    do: get_in(entry, ["metadata", "attachment_materialization", "state"])

  # A reply edge names another message as the request context, so the
  # attachment must not join the live turn (SignalsGateway.md, "reply edge
  # prevents this association"). DMs follow the same rule as groups.
  defp eligible_new_attachment_supplement?(entry) do
    entry["non_bot_mention"] != true and is_nil(entry["reply_to_source_entry_id"])
  end

  defp candidate_events_for_source_entry(fact) do
    ActorEvent
    |> where([input], input.agent_uid == ^fact.agent_uid)
    |> where([input], input.binding_name == ^fact.binding_name)
    |> where([input], input.signal_channel_id == ^fact.signal_channel_id)
    |> where([input], input.input_state == "open")
    |> where([input], is_nil(input.completed_at))
    |> maybe_where_thread(fact.provider_thread_id)
    |> where(
      [input],
      input.source_entry_id == ^fact.source_entry_id or
        fragment(
          """
          jsonb_typeof(?->'data'->'entries') = 'array'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(?->'data'->'entries') AS entry
            WHERE entry->>'source_entry_id' = ?
          )
          """,
          input.payload,
          input.payload,
          ^fact.source_entry_id
        )
    )
  end

  defp maybe_where_thread(query, nil), do: query

  defp maybe_where_thread(query, provider_thread_id) do
    where(query, [input], input.provider_thread_id == ^provider_thread_id)
  end

  defp retract_source_entry_from_event(repo, input, fact, _kind, now) do
    entry = %{"source_entry_id" => fact.source_entry_id}

    with {:ok, result} <- ingress_revision_in_tx(repo, input, "remove", entry, now) do
      status = if result == :removed, do: :canceled, else: :retried

      {:ok,
       %{
         status: status,
         actor_event: if(result == :removed, do: input, else: result)
       }}
    end
  end

  defp source_entry_retraction(entries, %ActorEvent{}, source_entry_id)
       when is_list(entries) and entries != [] do
    remaining = Enum.reject(entries, &(&1["source_entry_id"] == source_entry_id))

    cond do
      length(remaining) == length(entries) -> :no_match
      remaining == [] -> :cancel
      true -> {:replace, remaining}
    end
  end

  defp source_entry_retraction(
         _entries,
         %ActorEvent{source_entry_id: direct_entry_id},
         source_entry_id
       )
       when direct_entry_id == source_entry_id,
       do: :cancel

  defp source_entry_retraction(_entries, _input, _source_entry_id), do: :no_match

  # The event row holds the only record of the cards this turn opened, so the
  # channel deletions must be committed before the retraction deletes the row.
  defp commit_reply_deletions(repo, %ActorEvent{} = input) do
    repo
    |> ReplyDeletion.outbox_intents(input.id)
    |> Enum.map(fn intent ->
      intent
      |> Map.merge(%{
        agent_uid: input.agent_uid,
        binding_name: input.binding_name,
        source_actor_event_id: input.id
      })
      |> then(&Outbox.commit_outbox_in_tx(repo, &1))
    end)
    |> Ankole.Attrs.collect_results()
  end

  defp replace_event_entries(repo, input, entries, entry, now) do
    summary = merged_entry_summary(entries)

    payload =
      input.payload
      |> replace_payload_entries(
        entries,
        summary,
        entry["source_entry_id"],
        now
      )

    attrs = %{
      payload: payload,
      source_entry_id: summary["source_entry_id"],
      available_at: now
    }

    input
    |> ActorEvent.changeset(attrs)
    |> repo.update()
  end

  defp replace_payload_entries(payload, entries, summary, removed_source_entry_id, now)
       when is_map(payload) do
    data = Map.get(payload, "data", %{})

    data =
      data
      |> Map.put("entry", summary)
      |> Map.put("entries", entries)
      |> refresh_command()
      |> update_observed_messages(removed_source_entry_id)
      |> update_ambient_batch(entries, now)

    Map.put(payload, "data", data)
  end

  defp replace_payload_entries(_payload, entries, summary, _removed_source_entry_id, _now) do
    %{"data" => %{"entry" => summary, "entries" => entries}}
  end

  defp refresh_command(%{"command" => %{"name" => name} = command} = data) do
    case Ankole.SignalsGateway.Commands.classify(get_in(data, ["entry", "text"])) do
      {:ok, %{"name" => ^name} = current} ->
        Map.put(data, "command", Map.merge(command, current))

      _revised_text ->
        Map.delete(data, "command")
    end
  end

  defp refresh_command(data), do: data

  @doc false
  @spec put_retry_metadata(map(), String.t(), String.t(), map()) :: map()
  def put_retry_metadata(payload, retry_actor_event_id, reason, extra)
      when is_map(payload) do
    entry =
      payload
      |> get_in(["data", "entry"])
      |> case do
        %{} = entry -> entry
        _value -> %{}
      end
      |> Map.merge(extra)
      |> Map.put("retry_of_actor_event_id", retry_actor_event_id)
      |> Map.put("retry_reason", reason)

    data =
      payload
      |> Map.get("data", %{})
      |> Map.put("entry", entry)

    Map.put(payload, "data", data)
  end

  def put_retry_metadata(_payload, retry_actor_event_id, reason, extra) do
    put_retry_metadata(
      %{"data" => %{"entry" => %{}}},
      retry_actor_event_id,
      reason,
      extra
    )
  end

  defp update_observed_messages(data, removed_source_entry_id) do
    Enum.reduce(["observed_messages", "backdrop_messages", "unreplied_messages"], data, fn key,
                                                                                           data ->
      case Map.get(data, key) do
        messages when is_list(messages) ->
          Map.put(
            data,
            key,
            Enum.reject(messages, &(&1["source_entry_id"] == removed_source_entry_id))
          )

        _value ->
          data
      end
    end)
  end

  defp update_ambient_batch(%{"ambient_batch" => batch} = data, entries, now)
       when is_map(batch) do
    batch =
      batch
      |> Map.put("size", length(entries))
      |> Map.put(
        "first_source_entry_id",
        entries |> List.first() |> Map.get("source_entry_id")
      )
      |> Map.put("last_source_entry_id", entries |> List.last() |> Map.get("source_entry_id"))
      |> Map.put("updated_at", DateTime.to_iso8601(now))

    Map.put(data, "ambient_batch", batch)
  end

  defp update_ambient_batch(data, _entries, _now), do: data

  defp merged_entry_summary(entries) do
    entries
    |> List.last()
    |> Kernel.||(%{})
    |> Map.put("text", merged_entry_text(entries))
    |> put_nonempty("attachments", merged_entry_list(entries, "attachments"))
    |> put_nonempty("links", merged_entry_list(entries, "links"))
    |> put_nonempty("mentions", merged_entry_list(entries, "mentions"))
  end

  defp merged_entry_text(entries) do
    entries
    |> Enum.map(& &1["text"])
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.join("\n")
  end

  defp merged_entry_list(entries, key) do
    Enum.flat_map(entries, fn entry ->
      case entry[key] do
        values when is_list(values) -> values
        _value -> []
      end
    end)
  end

  defp put_nonempty(map, _key, []), do: map
  defp put_nonempty(map, key, values), do: Map.put(map, key, values)

  defp event_entries(%ActorEvent{payload: %{"data" => %{"entries" => entries}}})
       when is_list(entries),
       do: entries

  defp event_entries(_input), do: []
end
