defmodule Ankole.Signals.Intake do
  @moduledoc false
  require Ash.Query

  alias Ankole.Signals.Target, as: ExecutionTarget
  alias Ankole.Conversations.{Conversation, Participant}
  alias Ankole.Conversations.Delivery.Interactions
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Principals.{Principal, WorkAccess}
  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.Jobs.EnsureDriver
  alias Ankole.Signals.Signal
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
         {:ok, signals} <- persist(facts),
         :ok <- wake_sessions(signals) do
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
    with {:ok, source} <- required_text(attrs, :source),
         {:ok, producer} <- producer(Ankole.Attrs.get(attrs, :producer)),
         {:ok, id} <- required_text(attrs, :id),
         {:ok, type} <- required_text(attrs, :type),
         {:ok, subject} <- optional_text(attrs, :subject),
         {:ok, occurred_at} <- instant(Ankole.Attrs.get(attrs, :time)),
         {:ok, available_at} <- instant(Ankole.Attrs.get(attrs, :available_at) || occurred_at),
         {:ok, data} <- JSONPayload.normalize(Ankole.Attrs.get(attrs, :data, %{})),
         {:ok, extensions} <-
           JSONPayload.normalize_map(Ankole.Attrs.get(attrs, :extensions) || %{}),
         {:ok, route} <- reply_route(Ankole.Attrs.get(attrs, :reply_route)) do
      sender = Ankole.Attrs.get(attrs, :sender)

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

    with {:ok, created} <-
           facts
           |> Enum.reject(&Map.has_key?(existing, identity(&1)))
           |> Enum.uniq_by(&identity/1)
           |> create_signals() do
      signals = Map.merge(existing, Map.new(created, &{identity(&1), &1}))

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
        {:ok, accepted} -> {:ok, Enum.reverse(accepted)}
        error -> error
      end
    end
  end

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

  defp create_signals([]), do: {:ok, []}

  defp create_signals(facts) do
    {inputs, _last} =
      Enum.map_reduce(facts, last_sequences(facts), fn fact, last ->
        key = {fact.agent_uid, fact.session_id}
        sequence = (Map.fetch!(last, key) || 0) + 1
        {Map.put(fact, :queue_sequence, sequence), Map.put(last, key, sequence)}
      end)

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

  defp reply_route(nil), do: {:ok, %{}}

  defp reply_route(route) when is_map(route) do
    {:ok,
     %{
       reply_binding_name: Ankole.Attrs.get(route, :binding_name),
       conversation_id: Ankole.Attrs.get(route, :conversation_id),
       provider_thread_id: Ankole.Attrs.get(route, :provider_thread_id),
       provider_message_id: Ankole.Attrs.get(route, :provider_message_id)
     }}
  end

  defp reply_route(_route), do: {:error, :invalid_reply_route}

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
    case DateTime.from_iso8601(value) do
      {:ok, instant, _offset} -> {:ok, instant}
      _ -> {:error, :invalid_signal_time}
    end
  end

  defp instant(_), do: {:error, :invalid_signal_time}
end
