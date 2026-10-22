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

  def accept(repo, attrs) do
    Ankole.Observability.stage("signal.intake.prepared_in_tx", %{}, fn ->
      accept_in_tx(repo, attrs)
    end)
  end

  defp accept_in_tx(repo, attrs) do
    with {:ok, target} <- resolve_target(Ankole.Attrs.get(attrs, :target)),
         {:ok, facts} <- facts(repo, attrs, target),
         :ok <- Queue.lock_session_in_tx(repo, target.agent_uid, target.session_id),
         {:ok, signal} <- persist(facts),
         {:ok, _} <- Interactions.supersede_older_in_tx(repo, signal, signal.inserted_at),
         :ok <-
           EnsureDriver.enqueue_in_tx(
             repo,
             %{agent_uid: signal.agent_uid, session_id: signal.session_id},
             signal.available_at
           ) do
      {:ok, signal}
    end
  end

  defp resolve_target(%{agent_uid: uid} = target) when is_binary(uid) do
    with {:ok, %Principal{type: :agent, uid: uid}} <- Ankole.Principals.get_principal(uid) do
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
  defp resolve_target({:conversation, _} = target) do
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

  defp resolve_target(_target), do: {:error, :invalid_signal_target}

  defp resolve_conversation(uid, id) do
    case Ankole.Conversations.get_participant(id, uid) do
      {:ok, %Participant{role: :agent}} ->
        {:ok,
         %{agent_uid: uid, session_id: Ankole.Sessions.Key.conversation(id), conversation_id: id}}

      _other ->
        {:error, :conversation_not_found}
    end
  end

  defp facts(repo, attrs, target) do
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
          nil -> WorkAccess.from_sender(repo, sender)
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

  defp persist(attrs) do
    existing =
      Signal
      |> Ash.Query.filter(
        agent_uid == ^attrs.agent_uid and source == ^attrs.source and
          source_event_id == ^attrs.source_event_id
      )
      |> Ankole.Ash.read_one!()

    case existing do
      %Signal{} = signal ->
        same_producer(signal, attrs.producer)

      nil ->
        # The Session advisory lock serializes the sequence allocation.
        sequence =
          (Signal
           |> Ash.Query.filter(agent_uid == ^attrs.agent_uid and session_id == ^attrs.session_id)
           |> Ankole.Ash.max!(:queue_sequence) || 0) + 1

        with {:ok, signal} <-
               Ankole.Ash.create(Signal, :accept, Map.put(attrs, :queue_sequence, sequence),
                 touch_update_defaults?: false
               ) do
          same_producer(signal, attrs.producer)
        end
    end
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
