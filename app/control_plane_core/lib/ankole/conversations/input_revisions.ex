defmodule Ankole.Conversations.InputRevisions do
  @moduledoc "Merges queued input and admits revision Signals after a turn has started."

  import Ecto.Query, warn: false

  alias Ankole.Signals.Signal
  alias Ankole.Conversations.MessageInput
  alias Ankole.Conversations.Delivery.Deletion

  @doc """
  Retracts one provider source entry from live Signal inside a transaction.
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
    |> Enum.each(
      &Ankole.Signals.lock_target_in_tx(repo, %{agent_uid: fact.agent_uid, session_id: &1})
    )

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
           canceled_signals: Enum.count(results, &(&1.status == :canceled)),
           canceled_signal_ids: for(%{status: :canceled, signal: event} <- results, do: event.id),
           retried_signals: Enum.count(results, &(&1.status == :retried))
         }}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Merges a contiguous attachment into the current IM request when it is safe.

  A pending provider attachment fences a live generation before download
  finishes. The same source entry later replaces its pending form and releases
  the Signal when every attachment is materialized or failed.
  """
  @spec merge_attachment_supplement_in_tx(module(), map(), map(), DateTime.t()) ::
          {:ok, :not_supplement | {:consumed, map()} | {:next_turn, atom()}}
          | {:error, term()}
  def merge_attachment_supplement_in_tx(repo, fact, entry, now) do
    :ok =
      Ankole.Signals.lock_target_in_tx(repo, %{
        agent_uid: fact.agent_uid,
        session_id: fact_session_id(fact)
      })

    case MessageInput.attachment_materialization_state(entry) do
      state when state in ["pending", "complete", "failed"] ->
        case event_for_supplement_source_entry(repo, fact, entry["provider_message_id"]) do
          %Signal{} = event ->
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
      Ankole.Signals.lock_target_in_tx(repo, %{
        agent_uid: fact.agent_uid,
        session_id: fact_session_id(fact)
      })

    with state when state in ["pending", "complete", "failed"] <-
           MessageInput.attachment_materialization_state(entry),
         %Signal{} = event <-
           event_for_supplement_source_entry(repo, fact, entry["provider_message_id"]) do
      merge_into_open_event(repo, event, entry, now, true)
    else
      _missing -> {:ok, :not_supplement}
    end
  end

  defp classify_attachment_supplement(nil, _repo, _fact, _entry, _now),
    do: {:ok, :not_supplement}

  defp classify_attachment_supplement(
         %Signal{completed_at: %DateTime{} = completed_at} = event,
         repo,
         _fact,
         entry,
         _now
       ) do
    if latest_session_event?(repo, event) do
      case MessageInput.attachment_observed_at(entry) do
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
         %Signal{input_state: "open", completed_at: nil} = event,
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
         %Signal{},
         _repo,
         _fact,
         _entry,
         _now
       ),
       do: {:ok, :not_supplement}

  defp merge_into_open_event(repo, event, entry, now, _refresh?) do
    if event_entry_content_current?(MessageInput.input_entries(event), entry) do
      {:ok, :not_supplement}
    else
      kind =
        if Enum.any?(
             MessageInput.input_entries(event),
             &(&1["provider_message_id"] == entry["provider_message_id"])
           ),
           do: "edit",
           else: "supplement"

      with {:ok, event} <- ingress_revision_in_tx(repo, event, kind, entry, now) do
        {:ok, {:consumed, %{status: :input_superseded, signal: event}}}
      end
    end
  end

  defp merge_queued_input_in_tx(repo, event, kind, entry, now) do
    case MessageInput.revised_input_attrs(event, kind, entry, now) do
      :no_match ->
        {:ok, event}

      :cancel ->
        with {:ok, _} <- Deletion.commit_source_in_tx(repo, event),
             {:ok, _} <- repo.delete(event),
             do: {:ok, :removed}

      {:update, attrs} ->
        event |> Signal.changeset(attrs) |> repo.update()
    end
  end

  defp ingress_revision_in_tx(repo, %{last_attempt_at: nil} = event, kind, entry, now),
    do: merge_queued_input_in_tx(repo, event, kind, entry, now)

  defp ingress_revision_in_tx(repo, event, kind, entry, now) do
    revision = %{
      "signal_id" => event.id,
      "kind" => kind,
      "entry" => entry,
      "provider_message_id" => entry["provider_message_id"]
    }

    digest = :crypto.hash(:sha256, Ankole.JSON.encode!(revision)) |> Base.encode16(case: :lower)

    Ankole.Signals.accept_in_tx(repo, %{
      producer: :kernel,
      source: "control-plane://input-revisions",
      id: "revision:#{event.id}:#{digest}",
      type: "input.revised",
      subject: event.id,
      time: now,
      data: %{"revision" => revision, "entry" => entry},
      target: %{agent_uid: event.agent_uid, session_id: event.session_id},
      authorization: Ankole.Principals.WorkAccess.fields(event),
      sender: event.sender_key,
      reply_route: %{
        binding_name: event.reply_binding_name,
        conversation_id: event.conversation_id,
        provider_thread_id: event.provider_thread_id,
        provider_message_id: entry["provider_message_id"]
      }
    })
  end

  defp event_for_supplement_source_entry(repo, fact, provider_message_id)
       when is_binary(provider_message_id) do
    session_id = fact_session_id(fact)

    Signal
    |> where([event], event.agent_uid == ^fact.agent_uid)
    |> where([event], event.reply_binding_name == ^fact.binding_name)
    |> where([event], event.conversation_id == ^fact.conversation_id)
    |> where([event], event.session_id == ^session_id)
    |> where([event], event.type == "conversation.message.addressed")
    |> where([event], event.input_state == "open")
    |> where([event], is_nil(event.completed_at))
    |> exact_event_thread(fact.provider_thread_id)
    |> where(
      [event],
      event.provider_message_id == ^provider_message_id or
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements(?->'entries') AS entry WHERE entry->>'provider_message_id' = ?)",
          event.data,
          ^provider_message_id
        )
    )
    |> order_by([event], desc: event.queue_sequence)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp event_for_supplement_source_entry(_repo, _fact, _provider_message_id), do: nil

  defp latest_attachment_supplement_event(fact, repo) do
    session_id = fact_session_id(fact)

    Signal
    |> where([event], event.agent_uid == ^fact.agent_uid)
    |> where([event], event.reply_binding_name == ^fact.binding_name)
    |> where([event], event.conversation_id == ^fact.conversation_id)
    |> where([event], event.session_id == ^session_id)
    |> where([event], event.sender_key == ^fact.sender_key)
    |> where([event], event.type == "conversation.message.addressed")
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
    do: Map.get(fact, :session_id) || Ankole.Sessions.Key.conversation(fact.conversation_id)

  defp latest_session_event?(repo, %Signal{} = event) do
    latest_sequence =
      Signal
      |> where([candidate], candidate.agent_uid == ^event.agent_uid)
      |> where([candidate], candidate.session_id == ^event.session_id)
      |> select([candidate], max(candidate.queue_sequence))
      |> repo.one()

    latest_sequence == event.queue_sequence
  end

  defp event_entry_content_current?(
         entries,
         %{"provider_message_id" => provider_message_id, "content_hash" => content_hash}
       )
       when is_binary(content_hash) do
    Enum.any?(entries, fn entry ->
      entry["provider_message_id"] == provider_message_id and
        entry["content_hash"] == content_hash
    end)
  end

  defp event_entry_content_current?(_entries, _entry), do: false

  # A reply edge names another message as the request context, so the
  # attachment must not join the live turn (Conversations.md, "reply edge
  # prevents this association"). DMs follow the same rule as groups.
  defp eligible_new_attachment_supplement?(entry) do
    entry["non_bot_mention"] != true and is_nil(entry["reply_to_provider_message_id"])
  end

  defp candidate_events_for_source_entry(fact) do
    Signal
    |> where([input], input.agent_uid == ^fact.agent_uid)
    |> where([input], input.reply_binding_name == ^fact.binding_name)
    |> where([input], input.conversation_id == ^fact.conversation_id)
    |> where([input], input.input_state == "open")
    |> where([input], is_nil(input.completed_at))
    |> maybe_where_thread(fact.provider_thread_id)
    |> where(
      [input],
      input.provider_message_id == ^fact.provider_message_id or
        fragment(
          """
          jsonb_typeof(?->'entries') = 'array'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(?->'entries') AS entry
            WHERE entry->>'provider_message_id' = ?
          )
          """,
          input.data,
          input.data,
          ^fact.provider_message_id
        )
    )
  end

  defp maybe_where_thread(query, nil), do: query

  defp maybe_where_thread(query, provider_thread_id) do
    where(query, [input], input.provider_thread_id == ^provider_thread_id)
  end

  defp retract_source_entry_from_event(repo, input, fact, _kind, now) do
    entry = %{"provider_message_id" => fact.provider_message_id}

    with {:ok, result} <- ingress_revision_in_tx(repo, input, "remove", entry, now) do
      status = if result == :removed, do: :canceled, else: :retried

      {:ok,
       %{
         status: status,
         signal: if(result == :removed, do: input, else: result)
       }}
    end
  end

  # The event row holds the only record of the cards this turn opened, so the
  # channel deletions must be committed before the retraction deletes the row.
end
