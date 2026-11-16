defmodule Ankole.Signals.Intake do
  @moduledoc false
  require Ash.Expr
  require Ash.Query

  alias Ankole.Signals.Target, as: ExecutionTarget
  alias Ankole.Conversations.{Conversation, Participant}
  alias Ankole.Conversations.Delivery.Interactions
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.{Principal, WorkAccess}
  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.Jobs.EnsureDriver
  alias Ankole.Signals.{Coalesce, Signal}
  alias Ankole.Errors.Invalid.Stale

  def accept(attrs) do
    with {:ok, [signal]} <- accept_all([attrs]), do: {:ok, signal}
  end

  @doc """
  Accepts a list of stimuli in the caller's transaction.

  The function locks every target Session in order before it reads or writes a
  Signal row. One query reads the existing Signals and one bulk insert writes
  the new Signals. The result has one Signal for each input, in the input order.
  """
  def accept_all([]), do: {:ok, []}

  def accept_all(attrs_list) do
    Ankole.Observability.stage("signal.intake.prepared_in_tx", %{}, fn ->
      accept_all_in_tx(attrs_list)
    end)
  end

  defp accept_all_in_tx(attrs_list) do
    with {:ok, facts} <- all_facts(attrs_list),
         :ok <- Queue.lock_sessions_in_tx(Enum.map(facts, &{&1.agent_uid, &1.session_id})),
         {:ok, signals, extra_wakes} <- persist(facts),
         :ok <- wake_sessions(signals ++ extra_wakes) do
      {:ok, signals}
    end
  end

  # An Agent target reads its Principal one time for each Agent in the list.
  defp all_facts(attrs_list) do
    attrs_list
    |> Enum.reduce_while({:ok, [], %{}}, fn attrs, {:ok, facts, principals} ->
      target = Ankole.Attrs.get(attrs, :target)
      {principal, principals} = agent_principal(target, principals)

      with {:ok, target} <- resolve_target(target, principal),
           {:ok, fact} <- facts(attrs, target) do
        {:cont, {:ok, [fact | facts], principals}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, facts, _principals} -> {:ok, Enum.reverse(facts)}
      error -> error
    end
  end

  defp agent_principal(%{agent_uid: uid}, principals) when is_binary(uid) do
    case principals do
      %{^uid => principal} ->
        {principal, principals}

      %{} ->
        principal = Ankole.Principals.get_principal(uid)
        {principal, Map.put(principals, uid, principal)}
    end
  end

  defp agent_principal(_target, principals), do: {nil, principals}

  defp wake_sessions(signals) do
    signals
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce_while(:ok, fn signal, :ok ->
      with {:ok, _} <- Interactions.supersede_older_in_tx(signal, signal.inserted_at),
           :ok <-
             EnsureDriver.enqueue_in_tx(
               %{agent_uid: signal.agent_uid, session_id: signal.session_id},
               signal.available_at
             ) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp resolve_target(%{agent_uid: uid} = target, principal) when is_binary(uid) do
    with {:ok, %Principal{type: :agent, uid: uid}} <- principal do
      case ExecutionTarget.parse(target) do
        {:session, key} -> {:ok, %{agent_uid: uid, session_id: key}}
        {:conversation, id} -> resolve_conversation(uid, id)
        :error -> {:error, :invalid_signal_target}
      end
    else
      _ -> {:error, :agent_not_found}
    end
  end

  # A native conversation has one Agent participant: the Agent of the target.
  defp resolve_target({:conversation, _} = target, nil) do
    with {:conversation, id} <- ExecutionTarget.parse(target),
         {:ok, %Conversation{kind: :native}} <- Ankole.Conversations.get_conversation(id),
         {:ok, [%Participant{principal_uid: uid}]} <-
           Ankole.Conversations.list_participants(
             query: [filter: [conversation_id: id, role: :agent]]
           ),
         {:ok, %Principal{type: :agent}} <- Ankole.Principals.get_principal(uid) do
      resolve_conversation(uid, id)
    else
      _ -> {:error, :conversation_not_found}
    end
  end

  defp resolve_target(_target, _principal), do: {:error, :invalid_signal_target}

  defp resolve_conversation(uid, id) do
    case Ankole.Conversations.get_participant(id, uid) do
      {:ok, %Participant{role: :agent}} ->
        {:ok,
         %{agent_uid: uid, session_id: Ankole.Sessions.Key.conversation(id), conversation_id: id}}

      _other ->
        {:error, :conversation_not_found}
    end
  end

  defp facts(attrs, target) do
    received_at = DateTime.utc_now(:microsecond)

    with {:ok, source} <- required_text(attrs, :source),
         {:ok, producer} <- producer(Ankole.Attrs.get(attrs, :producer)),
         {:ok, id} <- required_text(attrs, :id),
         {:ok, type} <- required_text(attrs, :type),
         {:ok, subject} <- optional_text(attrs, :subject),
         {:ok, occurred_at} <- instant(Ankole.Attrs.get(attrs, :time)),
         {:ok, available_at} <- instant(Ankole.Attrs.get(attrs, :available_at) || occurred_at),
         {:ok, data} <- JSONPayload.normalize(Ankole.Attrs.get(attrs, :data, %{})),
         {:ok, raw_extensions} <-
           JSONPayload.normalize_map(Ankole.Attrs.get(attrs, :extensions) || %{}),
         {:ok, internal_extensions} <-
           JSONPayload.normalize_map(Ankole.Attrs.get(attrs, :internal_extensions) || %{}),
         {:ok, route} <- reply_route(Ankole.Attrs.get(attrs, :reply_route), target.agent_uid) do
      sender = Ankole.Attrs.get(attrs, :sender)

      extensions =
        raw_extensions
        |> Map.drop(["ankole_routine", "ankole_coalesce"])
        |> Map.merge(internal_extensions)

      authorization =
        case Ankole.Attrs.get(attrs, :authorization) do
          nil -> WorkAccess.from_sender(sender)
          snapshot -> WorkAccess.fields(snapshot)
        end

      {:ok,
       Map.merge(target, authorization)
       |> Map.merge(route)
       |> Map.merge(%{
         producer: producer,
         source: source,
         source_event_id: id,
         type: type,
         subject: subject,
         occurred_at: occurred_at,
         available_at: available_at,
         received_at: received_at,
         coalesce_spec: Ankole.Attrs.get(attrs, :coalesce_spec),
         data: data,
         extensions: extensions,
         sender_key: sender,
         message_id: Ankole.Attrs.get(attrs, :message_id),
         conversation_id: target[:conversation_id] || route[:conversation_id],
         ambient_asked_message_id: Ankole.Attrs.get(attrs, :ambient_asked_message_id)
       })}
    end
  end

  # The Session advisory locks serialize the sequence allocation. One read finds
  # the existing Signals and one insert writes the new Signals.
  defp persist(facts) do
    existing = existing_signals(facts)

    new_facts =
      facts
      |> Enum.reject(&Map.has_key?(existing, identity(&1)))
      |> Enum.uniq_by(&identity/1)

    {coalesce_facts, plain_facts} = Enum.split_with(new_facts, &(not is_nil(&1.coalesce_spec)))

    with {:ok, resolved_new, extra_wakes} <- persist_new_facts(plain_facts, coalesce_facts) do
      signals = Map.merge(existing, resolved_new)

      facts
      |> Enum.reduce_while({:ok, []}, fn fact, {:ok, accepted} ->
        with {:ok, signal} <- Map.fetch(signals, identity(fact)),
             {:ok, signal} <- same_producer(signal, fact.producer) do
          {:cont, {:ok, [signal | accepted]}}
        else
          :error -> {:halt, {:error, Stale.exception(resource: Signal, filter: nil)}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, accepted} -> {:ok, Enum.reverse(accepted), extra_wakes}
        error -> error
      end
    end
  end

  defp persist_new_facts([], []), do: {:ok, %{}, []}

  defp persist_new_facts(plain_facts, []) do
    with {:ok, created} <- create_signals(plain_facts) do
      {:ok, Map.new(created, &{identity(&1), &1}), []}
    end
  end

  defp persist_new_facts(plain_facts, coalesce_facts) do
    last_seq = last_sequences(plain_facts ++ coalesce_facts)
    {plain_inputs, last_seq} = allocate_sequences(plain_facts, last_seq)

    with {:ok, plain_created} <- insert_signal_inputs(plain_inputs),
         {:ok, coalesced_map, extra_wakes} <- persist_coalesced_facts(coalesce_facts, last_seq) do
      {:ok, Map.merge(Map.new(plain_created, &{identity(&1), &1}), coalesced_map), extra_wakes}
    end
  end

  defp persist_coalesced_facts(coalesce_facts, last_seq) do
    open_by_slot =
      coalesce_facts
      |> lock_open_coalesce_candidates()
      |> Enum.reject(&Coalesce.sealed?/1)
      |> Enum.sort_by(& &1.queue_sequence, :asc)
      |> Enum.reduce(%{}, fn sig, acc ->
        case sig.extensions do
          %{"ankole_coalesce" => %{"binding_id" => bid, "group_key" => gkey}}
          when is_binary(bid) and is_binary(gkey) ->
            Map.put(acc, {sig.agent_uid, sig.session_id, bid, gkey}, sig)

          _ ->
            acc
        end
      end)

    coalesce_facts
    |> Enum.reduce_while({:ok, open_by_slot, last_seq, %{}, []}, fn fact,
                                                                    {:ok, open_map, seq_map,
                                                                     resolved, wakes} ->
      spec = fact.coalesce_spec
      slot = {fact.agent_uid, fact.session_id, spec.binding_id, spec.group_key}
      envelope = Coalesce.envelope_from_fact(fact)

      case apply_coalesce_fact(
             Map.get(open_map, slot),
             fact,
             spec,
             slot,
             envelope,
             open_map,
             seq_map,
             wakes
           ) do
        {:ok, signal, next_open_map, next_seq_map, next_wakes} ->
          {:cont,
           {:ok, next_open_map, next_seq_map, Map.put(resolved, identity(fact), signal),
            next_wakes}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _open_map, _seq_map, resolved, wakes} -> {:ok, resolved, Enum.reverse(wakes)}
      error -> error
    end
  end

  defp apply_coalesce_fact(nil, fact, spec, slot, envelope, open_map, seq_map, wakes) do
    open_new_coalesce_signal(fact, spec, slot, envelope, open_map, seq_map, wakes)
  end

  defp apply_coalesce_fact(open, fact, spec, slot, envelope, open_map, seq_map, wakes) do
    if Coalesce.compatible_open_batch?(open, spec) do
      case Coalesce.try_append(open, envelope, spec, fact.received_at) do
        {:appended, updated_ext, available_at} ->
          with {:ok, updated} <-
                 Ankole.Signals.revise_input_signal(open, %{
                   extensions: updated_ext,
                   available_at: available_at
                 }) do
            next_open =
              if Coalesce.sealed?(updated),
                do: Map.delete(open_map, slot),
                else: Map.put(open_map, slot, updated)

            {:ok, updated, next_open, seq_map, wakes}
          end

        {:overflow, sealed_ext, sealed_available_at} ->
          with {:ok, sealed} <-
                 Ankole.Signals.revise_input_signal(open, %{
                   extensions: sealed_ext,
                   available_at: sealed_available_at
                 }) do
            open_new_coalesce_signal(
              fact,
              spec,
              slot,
              envelope,
              Map.delete(open_map, slot),
              seq_map,
              [sealed | wakes]
            )
          end
      end
    else
      with {:ok, _sealed} <-
             Ankole.Signals.revise_input_signal(open, %{
               extensions: Coalesce.seal_extensions(open)
             }) do
        open_new_coalesce_signal(
          fact,
          spec,
          slot,
          envelope,
          Map.delete(open_map, slot),
          seq_map,
          wakes
        )
      end
    end
  end

  defp open_new_coalesce_signal(fact, spec, slot, envelope, open_map, seq_map, wakes) do
    {meta, available_at} = Coalesce.initial_batch(spec, envelope, fact.received_at)
    session_key = {fact.agent_uid, fact.session_id}
    sequence = (Map.fetch!(seq_map, session_key) || 0) + 1

    input =
      fact
      |> strip_transient_fact_fields()
      |> Map.put(:queue_sequence, sequence)
      |> Map.put(:available_at, available_at)
      |> Map.put(:extensions, Map.put(fact.extensions || %{}, "ankole_coalesce", meta))

    with {:ok, created} <-
           Ankole.Ash.create(Signal, :accept, input, touch_update_defaults?: false) do
      next_open =
        if Coalesce.sealed?(created),
          do: Map.delete(open_map, slot),
          else: Map.put(open_map, slot, created)

      {:ok, created, next_open, Map.put(seq_map, session_key, sequence), wakes}
    end
  end

  defp lock_open_coalesce_candidates(coalesce_facts) do
    session_filter =
      coalesce_facts
      |> Enum.map(&{&1.agent_uid, &1.session_id})
      |> Enum.uniq()
      |> Enum.reduce(Ash.Expr.expr(false), fn {uid, sid}, expr ->
        Ash.Expr.expr(^expr or (agent_uid == ^uid and session_id == ^sid))
      end)

    Signal
    |> Ash.Query.filter(^session_filter)
    |> Ash.Query.filter(status == :queued and is_nil(last_attempt_at))
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {:rows, "signals", :id})
  end

  defp strip_transient_fact_fields(fact), do: Map.drop(fact, [:coalesce_spec, :received_at])

  defp identity(fact), do: {fact.agent_uid, fact.source, fact.source_event_id}

  defp existing_signals(facts) do
    identities = Enum.map(facts, &identity/1)
    agent_uids = identities |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    sources = identities |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    source_event_ids = identities |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

    Signal
    |> Ash.Query.filter(
      agent_uid in ^agent_uids and source in ^sources and source_event_id in ^source_event_ids
    )
    |> Ankole.Ash.read!()
    |> Map.new(&{identity(&1), &1})
    |> Map.take(identities)
  end

  defp create_signals(facts) do
    {inputs, _last} = allocate_sequences(facts, last_sequences(facts))
    insert_signal_inputs(inputs)
  end

  defp allocate_sequences(facts, last_seq) do
    Enum.map_reduce(facts, last_seq, fn fact, last ->
      key = {fact.agent_uid, fact.session_id}
      sequence = (Map.fetch!(last, key) || 0) + 1

      input =
        fact
        |> strip_transient_fact_fields()
        |> Map.put(:queue_sequence, sequence)

      {input, Map.put(last, key, sequence)}
    end)
  end

  defp insert_signal_inputs([]), do: {:ok, []}

  defp insert_signal_inputs(inputs) do
    Ankole.Ash.create_all(inputs, Signal, :accept,
      touch_update_defaults?: false,
      return_skipped_upsert?: true
    )
  end

  # Each read uses the last index entry of one Session.
  defp last_sequences(facts) do
    facts
    |> Enum.map(&{&1.agent_uid, &1.session_id})
    |> Enum.uniq()
    |> Map.new(fn {agent_uid, session_id} = key ->
      {key,
       Signal
       |> Ash.Query.filter(agent_uid == ^agent_uid and session_id == ^session_id)
       |> Ankole.Ash.max!(:queue_sequence)}
    end)
  end

  defp same_producer(%Signal{producer: producer} = signal, producer), do: {:ok, signal}
  defp same_producer(_signal, _producer), do: {:error, :signal_producer_conflict}

  defp reply_route(nil, _uid), do: {:ok, %{}}

  defp reply_route(route, uid) when is_map(route) do
    binding_id = Ankole.Attrs.get(route, :binding_id)
    name = Ankole.Attrs.get(route, :binding_name)

    binding_id =
      if is_nil(binding_id) and is_binary(name) do
        case Ankole.Signals.get_agent_binding!(uid, name) do
          nil -> nil
          binding -> binding.id
        end
      else
        binding_id
      end

    {:ok,
     %{
       reply_binding_id: binding_id,
       reply_binding_name: Ankole.Attrs.get(route, :binding_name),
       conversation_id: Ankole.Attrs.get(route, :conversation_id),
       provider_thread_id: Ankole.Attrs.get(route, :provider_thread_id),
       provider_message_id: Ankole.Attrs.get(route, :provider_message_id)
     }}
  end

  defp reply_route(_route, _uid), do: {:error, :invalid_reply_route}

  defp producer(nil), do: {:ok, :external}
  defp producer(value) when value in [:kernel, "kernel"], do: {:ok, :kernel}
  defp producer(value) when value in [:external, "external"], do: {:ok, :external}
  defp producer(_value), do: {:error, :invalid_signal_producer}

  defp required_text(attrs, key) do
    case Ankole.Attrs.get(attrs, key) do
      text when is_binary(text) ->
        if String.valid?(text) and String.trim(text) != "" and not String.contains?(text, <<0>>),
          do: {:ok, text},
          else: {:error, :invalid_signal}

      _ ->
        {:error, :invalid_signal}
    end
  end

  defp optional_text(attrs, key) do
    if is_nil(Ankole.Attrs.get(attrs, key)), do: {:ok, nil}, else: required_text(attrs, key)
  end

  defp instant(nil), do: {:ok, DateTime.utc_now(:microsecond)}
  defp instant(%DateTime{} = instant), do: {:ok, instant}

  defp instant(value) when is_binary(value) do
    case Ankole.Attrs.parse_datetime(value) do
      %DateTime{} = instant -> {:ok, instant}
      _ -> {:error, :invalid_signal_time}
    end
  end

  defp instant(_), do: {:error, :invalid_signal_time}
end
