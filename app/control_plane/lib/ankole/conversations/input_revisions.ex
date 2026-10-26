defmodule Ankole.Conversations.InputRevisions do
  @moduledoc "Merges queued input and admits revision Signals after a turn has started."

  alias Ankole.Signals.Signal
  alias Ankole.Conversations.MessageInput
  alias Ankole.Conversations.Delivery.Deletion

  @doc """
  Retracts one provider source entry from live Signal inside a transaction.
  """
  @spec retract_source_entry_in_tx(map(), term(), DateTime.t()) ::
          {:ok, map()} | {:error, term()}
  def retract_source_entry_in_tx(fact, kind, now) do
    fact
    |> candidate_events_for_source_entry()
    |> Enum.map(& &1.session_id)
    |> then(&[fact_session_id(fact) | &1])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&Ankole.Signals.lock_target_in_tx(%{agent_uid: fact.agent_uid, session_id: &1}))

    # The Session locks are held, so the candidates do not change before their row lock.
    ids = fact |> candidate_events_for_source_entry() |> Enum.map(& &1.id)

    Ankole.Signals.lock_signals_in_tx([id: [in: ids], status: [in: [:queued, :running]]],
      sort: [id: :asc]
    )
    |> Enum.map(&retract_source_entry_from_event(&1, fact, kind, now))
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
  @spec merge_attachment_supplement_in_tx(map(), map(), DateTime.t()) ::
          {:ok, :not_supplement | {:consumed, map()} | {:next_turn, atom()}}
          | {:error, term()}
  def merge_attachment_supplement_in_tx(fact, entry, now) do
    :ok =
      Ankole.Signals.lock_target_in_tx(%{
        agent_uid: fact.agent_uid,
        session_id: fact_session_id(fact)
      })

    case MessageInput.attachment_materialization_state(entry) do
      state when state in ["pending", "complete", "failed"] ->
        case event_for_supplement_source_entry(fact, entry["provider_message_id"]) do
          %Signal{} = event ->
            merge_into_open_event(event, entry, now, true)

          nil ->
            if eligible_new_attachment_supplement?(entry) do
              fact
              |> latest_attachment_supplement_event()
              |> classify_attachment_supplement(fact, entry, now)
            else
              {:ok, :not_supplement}
            end
        end

      _missing ->
        {:ok, :not_supplement}
    end
  end

  @doc false
  @spec refresh_attachment_supplement_in_tx(map(), map(), DateTime.t()) ::
          {:ok, :not_supplement | {:consumed, map()} | {:next_turn, atom()}}
          | {:error, term()}
  def refresh_attachment_supplement_in_tx(fact, entry, now) do
    :ok =
      Ankole.Signals.lock_target_in_tx(%{
        agent_uid: fact.agent_uid,
        session_id: fact_session_id(fact)
      })

    with state when state in ["pending", "complete", "failed"] <-
           MessageInput.attachment_materialization_state(entry),
         %Signal{} = event <-
           event_for_supplement_source_entry(fact, entry["provider_message_id"]) do
      merge_into_open_event(event, entry, now, true)
    else
      _missing -> {:ok, :not_supplement}
    end
  end

  defp classify_attachment_supplement(nil, _fact, _entry, _now),
    do: {:ok, :not_supplement}

  defp classify_attachment_supplement(
         %Signal{status: :completed, completed_at: completed_at} = event,
         _fact,
         entry,
         _now
       ) do
    if latest_session_event?(event) do
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
         %Signal{status: live_status} = event,
         _fact,
         entry,
         now
       )
       when live_status in [:queued, :running] do
    if latest_session_event?(event),
      do: merge_into_open_event(event, entry, now, false),
      else: {:ok, :not_supplement}
  end

  defp classify_attachment_supplement(
         %Signal{},
         _fact,
         _entry,
         _now
       ),
       do: {:ok, :not_supplement}

  defp merge_into_open_event(event, entry, now, _refresh?) do
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

      with {:ok, event} <- ingress_revision_in_tx(event, kind, entry, now) do
        {:ok, {:consumed, %{status: :input_superseded, signal: event}}}
      end
    end
  end

  defp merge_queued_input_in_tx(event, kind, entry, now) do
    case MessageInput.revised_input_attrs(event, kind, entry, now) do
      :no_match ->
        {:ok, event}

      :cancel ->
        with {:ok, _} <- Deletion.commit_source_in_tx(event),
             :ok <- Ankole.Signals.remove_signal(event),
             do: {:ok, :removed}

      {:update, attrs} ->
        Ankole.Signals.revise_input_signal(event, attrs)
    end
  end

  defp ingress_revision_in_tx(%{last_attempt_at: nil} = event, kind, entry, now),
    do: merge_queued_input_in_tx(event, kind, entry, now)

  defp ingress_revision_in_tx(event, kind, entry, now) do
    revision = %{
      "signal_id" => event.id,
      "kind" => kind,
      "entry" => entry,
      "provider_message_id" => entry["provider_message_id"]
    }

    digest = :crypto.hash(:sha256, Ankole.JSON.encode!(revision)) |> Base.encode16(case: :lower)

    Ankole.Signals.accept_in_tx(%{
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

  # The caller holds the Session lock, so the selected Signal stays current
  # until its row lock.
  defp event_for_supplement_source_entry(fact, provider_message_id)
       when is_binary(provider_message_id) do
    filter =
      [
        agent_uid: fact.agent_uid,
        reply_binding_name: fact.binding_name,
        conversation_id: fact.conversation_id,
        session_id: fact_session_id(fact),
        type: "conversation.message.addressed",
        status: [in: [:queued, :running]]
      ] ++ exact_event_thread(fact.provider_thread_id)

    Ankole.Signals.list_signals!(query: [filter: filter, sort: [queue_sequence: :desc]])
    |> Enum.find(&source_entry?(&1, provider_message_id))
    |> case do
      %Signal{id: id} ->
        Ankole.Signals.lock_signals_in_tx([id: id] ++ filter) |> List.first()

      nil ->
        nil
    end
  end

  defp event_for_supplement_source_entry(_fact, _provider_message_id), do: nil

  defp latest_attachment_supplement_event(fact) do
    filter =
      [
        agent_uid: fact.agent_uid,
        reply_binding_name: fact.binding_name,
        conversation_id: fact.conversation_id,
        session_id: fact_session_id(fact),
        sender_key: fact.sender_key,
        type: "conversation.message.addressed"
      ] ++ exact_event_thread(fact.provider_thread_id)

    Ankole.Signals.lock_signals_in_tx(filter, sort: [queue_sequence: :desc], limit: 1)
    |> List.first()
  end

  defp exact_event_thread(nil), do: [provider_thread_id: [is_nil: true]]
  defp exact_event_thread(provider_thread_id), do: [provider_thread_id: provider_thread_id]

  # The Signal names the provider entry directly or as one entry of its batch.
  defp source_entry?(%Signal{} = signal, provider_message_id) do
    entries = if is_map(signal.data), do: signal.data["entries"]

    signal.provider_message_id == provider_message_id or
      (is_list(entries) and
         Enum.any?(entries, &(is_map(&1) and &1["provider_message_id"] == provider_message_id)))
  end

  defp fact_session_id(fact),
    do: Map.get(fact, :session_id) || Ankole.Sessions.Key.conversation(fact.conversation_id)

  defp latest_session_event?(%Signal{} = event) do
    case Ankole.Signals.list_signals!(
           query: [
             filter: [agent_uid: event.agent_uid, session_id: event.session_id],
             sort: [queue_sequence: :desc],
             limit: 1,
             select: [:queue_sequence]
           ]
         ) do
      [%Signal{queue_sequence: sequence}] -> sequence == event.queue_sequence
      [] -> false
    end
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

  # The open Signals that name the provider entry of the fact.
  defp candidate_events_for_source_entry(fact) do
    filter =
      [
        agent_uid: fact.agent_uid,
        reply_binding_name: fact.binding_name,
        conversation_id: fact.conversation_id,
        status: [in: [:queued, :running]]
      ] ++ thread_filter(fact.provider_thread_id)

    [query: [filter: filter]]
    |> Ankole.Signals.list_signals!()
    |> Enum.filter(&source_entry?(&1, fact.provider_message_id))
  end

  defp thread_filter(nil), do: []
  defp thread_filter(provider_thread_id), do: [provider_thread_id: provider_thread_id]

  defp retract_source_entry_from_event(input, fact, _kind, now) do
    entry = %{"provider_message_id" => fact.provider_message_id}

    with {:ok, result} <- ingress_revision_in_tx(input, "remove", entry, now) do
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
