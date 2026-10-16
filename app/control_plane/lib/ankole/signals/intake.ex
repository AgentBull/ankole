defmodule Ankole.Signals.Intake do
  @moduledoc false
  import Ecto.Query

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
    with {:ok, target} <- resolve_target(repo, value(attrs, :target)),
         {:ok, facts} <- facts(repo, attrs, target),
         :ok <- Queue.lock_session_in_tx(repo, target.agent_uid, target.session_id),
         {:ok, signal} <- persist(repo, facts),
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

  defp resolve_target(repo, %{agent_uid: uid} = target) when is_binary(uid) do
    with %Principal{type: :agent, uid: uid} <- repo.get(Principal, String.downcase(uid)) do
      case ExecutionTarget.parse(target) do
        {:session, key} -> {:ok, %{agent_uid: uid, session_id: key}}
        {:conversation, id} -> resolve_conversation(repo, uid, id)
        :error -> {:error, :invalid_signal_target}
      end
    else
      _ -> {:error, :agent_not_found}
    end
  end

  defp resolve_target(repo, {:conversation, _} = target) do
    with {:conversation, id} <- ExecutionTarget.parse(target),
         %Principal{uid: uid} <-
           repo.one(
             from(c in Conversation,
               join: participant in Participant,
               on: participant.conversation_id == c.id and participant.role == :agent,
               join: agent in Principal,
               on: agent.uid == participant.principal_uid and agent.type == :agent,
               where: c.id == ^id and c.kind == :native,
               select: agent
             )
           ) do
      resolve_conversation(repo, uid, id)
    else
      _ -> {:error, :conversation_not_found}
    end
  end

  defp resolve_target(_repo, _target), do: {:error, :invalid_signal_target}

  defp resolve_conversation(repo, uid, id) do
    if repo.exists?(
         from(p in Participant,
           where: p.conversation_id == ^id and p.role == :agent and p.principal_uid == ^uid
         )
       ) do
      {:ok,
       %{agent_uid: uid, session_id: Ankole.Sessions.Key.conversation(id), conversation_id: id}}
    else
      {:error, :conversation_not_found}
    end
  end

  defp facts(repo, attrs, target) do
    with {:ok, source} <- required_text(attrs, :source),
         {:ok, producer} <- producer(value(attrs, :producer)),
         {:ok, id} <- required_text(attrs, :id),
         {:ok, type} <- required_text(attrs, :type),
         {:ok, subject} <- optional_text(attrs, :subject),
         {:ok, occurred_at} <- instant(value(attrs, :time)),
         {:ok, available_at} <- instant(value(attrs, :available_at) || occurred_at),
         {:ok, data} <- JSONPayload.normalize(Map.get(attrs, :data, Map.get(attrs, "data", %{}))),
         {:ok, extensions} <- JSONPayload.normalize_map(value(attrs, :extensions) || %{}),
         {:ok, route} <- reply_route(value(attrs, :reply_route)) do
      sender = value(attrs, :sender)

      authorization =
        case value(attrs, :authorization) do
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
         message_id: value(attrs, :message_id),
         conversation_id: target[:conversation_id] || route[:conversation_id],
         ambient_asked_message_id: value(attrs, :ambient_asked_message_id)
       })}
    end
  end

  defp persist(repo, attrs) do
    key = Map.take(attrs, [:agent_uid, :source, :source_event_id])

    case repo.get_by(Signal, key) do
      %Signal{} = signal ->
        same_producer(signal, attrs.producer)

      nil ->
        sequence =
          repo.one(
            from(s in Signal,
              where: s.agent_uid == ^attrs.agent_uid and s.session_id == ^attrs.session_id,
              select: coalesce(max(s.queue_sequence), 0) + 1
            )
          )

        with {:ok, _} <-
               %Signal{}
               |> Signal.changeset(Map.put(attrs, :queue_sequence, sequence))
               |> repo.insert(
                 on_conflict: :nothing,
                 conflict_target: [:tenant_id, :agent_uid, :source, :source_event_id]
               ),
             %Signal{} = signal <- repo.get_by(Signal, key) do
          same_producer(signal, attrs.producer)
        else
          {:error, _} = error -> error
          _ -> {:error, :signal_not_found}
        end
    end
  end

  defp same_producer(%Signal{producer: producer} = signal, producer), do: {:ok, signal}
  defp same_producer(_signal, _producer), do: {:error, :signal_producer_conflict}

  defp reply_route(nil), do: {:ok, %{}}

  defp reply_route(route) when is_map(route) do
    {:ok,
     %{
       reply_binding_name: value(route, :binding_name),
       conversation_id: value(route, :conversation_id),
       provider_thread_id: value(route, :provider_thread_id),
       provider_message_id: value(route, :provider_message_id)
     }}
  end

  defp reply_route(_route), do: {:error, :invalid_reply_route}

  defp producer(nil), do: {:ok, :external}
  defp producer(value) when value in [:kernel, "kernel"], do: {:ok, :kernel}
  defp producer(value) when value in [:external, "external"], do: {:ok, :external}
  defp producer(_value), do: {:error, :invalid_signal_producer}

  defp required_text(attrs, key) do
    case value(attrs, key) do
      text when is_binary(text) ->
        if String.valid?(text) and String.trim(text) != "" and not String.contains?(text, <<0>>),
          do: {:ok, text},
          else: {:error, :invalid_signal}

      _ ->
        {:error, :invalid_signal}
    end
  end

  defp optional_text(attrs, key) do
    if is_nil(value(attrs, key)), do: {:ok, nil}, else: required_text(attrs, key)
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
  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
