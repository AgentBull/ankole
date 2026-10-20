defmodule Ankole.Brain.RequestContext do
  @moduledoc """
  Builds a trusted Brain context at the Session runtime boundary.

  Runtime metadata names an owned Signal. Frozen authorization facts and
  canonical Message authors determine request attribution. Room facts determine
  disclosure recipients and the default write scope. The context is passed as
  a typed internal option; public AIGateway caller metadata does not grant it.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Access
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Tools.Context
  alias Ankole.Principals.Agent
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.Schedule.Delivery
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.{Conversation, Message, Participant}

  @doc """
  Builds the context from an owned runtime Signal reference.
  """
  @spec build(String.t(), map() | nil) :: {:ok, Context.t()} | {:error, term()}
  def build(subject_uid, metadata) when is_binary(subject_uid) do
    case signal_id(metadata) do
      nil -> subject_context(subject_uid)
      signal_id -> turn_context(subject_uid, signal_id)
    end
  end

  @doc "Returns the Signal id a request declares, or nil."
  @spec signal_id(map() | nil) :: String.t() | nil
  def signal_id(%{"signal_id" => id}) when is_binary(id) and id != "", do: id
  def signal_id(_metadata), do: nil

  defp subject_context(subject_uid), do: {:ok, Context.for_subject(subject_uid)}

  defp turn_context(subject_uid, signal_id) do
    with {:ok, event} <- owned_event(subject_uid, signal_id) do
      conversation_id = event_conversation_id(event)

      {:ok,
       %Context{
         querier_uid: subject_uid,
         disclosure: event_disclosure(event, agent_disclosure_mode(subject_uid)),
         default_write_scope: derived_conversation_scope(event, subject_uid),
         conversation_id: conversation_id,
         # A remember call without a holder files the claim on the Agent's own
         # page, so the Agent's card joins the pack like the speaker's.
         participant_uids: Enum.uniq(participant_uids(event) ++ [subject_uid]),
         parent_fallback:
           if(is_binary(conversation_id),
             do: {:conversation, conversation_id},
             else: page_fallback(subject_uid)
           ),
         holder_default: Scope.principal_page_slug(:agent, subject_uid),
         write_fence: fn -> live_turn_fence(subject_uid, event.id) end
       }}
    end
  end

  defp owned_event(subject_uid, signal_id) do
    case Ecto.UUID.cast(signal_id) do
      {:ok, id} ->
        case Repo.get(Signal, id) do
          %Signal{agent_uid: ^subject_uid} = event -> {:ok, event}
          %Signal{} -> {:error, :signal_not_owned}
          nil -> {:error, :signal_not_found}
        end

      :error ->
        {:error, :signal_not_found}
    end
  end

  # Hosted writes require an open input owned by this Agent. Their operation
  # owners define deduplication across Response retries; this is not a Driver
  # epoch or Worker route fence.
  defp live_turn_fence(agent_uid, signal_id) do
    live? =
      Repo.exists?(
        from e in Signal,
          where:
            e.id == ^signal_id and e.agent_uid == ^agent_uid and e.input_state == "open" and
              is_nil(e.completed_at)
      )

    if live?, do: :ok, else: {:error, :turn_not_live}
  end

  defp participant_uids(%Signal{} = event) do
    author =
      if event.message_id && event_conversation_id(event),
        do:
          Repo.one(
            from m in Message,
              where:
                m.id == ^event.message_id and m.conversation_id == ^event_conversation_id(event),
              select: m.author_uid
          )

    Enum.filter([asker_uid(event), author], &is_binary/1) |> Enum.uniq()
  end

  defp asker_uid(%Signal{
         authorization_kind: "human",
         human_uid: uid,
         human_access_version: version
       })
       when is_binary(uid) and is_integer(version), do: uid

  defp asker_uid(_event), do: nil

  defp event_conversation_id(%Signal{conversation_id: id}) when is_binary(id), do: id

  defp event_conversation_id(%Signal{session_id: key}) do
    case Ankole.Sessions.Key.parse(key) do
      {:conversation, id} -> id
      _ -> nil
    end
  end

  defp page_fallback(subject_uid) do
    case Scope.canonical_slug(subject_uid) do
      {:ok, slug} -> {:page, slug}
      {:error, _reason} = error -> error
    end
  end

  # Relaxed mode is asker-only by contract. A Turn without an asker always
  # uses strict disclosure because its final text can still go to a channel.
  defp event_disclosure(%Signal{} = event, :relaxed) do
    case asker_uid(event) do
      nil -> event_disclosure(event, :strict)
      asker -> %{mode: :relaxed, asker_uid: asker, present_uids: []}
    end
  end

  defp event_disclosure(%Signal{} = event, _mode) do
    asker = asker_uid(event)

    with {:ok, channels} <- disclosure_channels(event),
         {:ok, present_uids} <- strict_present_uids(channels, asker) do
      if is_nil(asker) and not Enum.any?(channels, &im_channel?/1) do
        Access.open_disclosure()
      else
        %{mode: :strict, asker_uid: asker, present_uids: present_uids}
      end
    else
      {:error, _unresolved_recipient_set} -> closed_disclosure()
    end
  end

  defp disclosure_channels(%Signal{} = event) do
    with {:ok, conversation_ids} <- disclosure_conversation_ids(event) do
      channels =
        Conversation
        |> where([channel], channel.id in ^conversation_ids)
        |> Repo.all()

      if length(channels) == length(conversation_ids),
        do: {:ok, channels},
        else: {:error, :disclosure_channel_not_found}
    end
  end

  defp disclosure_conversation_ids(%Signal{} = event) do
    case if(event.type != "cron.fire" or Ankole.Sessions.Scheduled.produced_signal?(event),
           do: Signal.scheduled_delivery_snapshot(event)
         ) do
      %{} = delivery ->
        with {:ok, targets} <- Delivery.targets(delivery, event.reply_binding_name) do
          {:ok, targets |> Enum.map(& &1["conversation_id"]) |> Enum.uniq()}
        end

      _no_scheduled_delivery ->
        {:ok, List.wrap(event_conversation_id(event))}
    end
  end

  defp strict_present_uids(channels, asker) do
    Enum.reduce_while(channels, {:ok, []}, fn channel, {:ok, acc} ->
      case strict_channel_recipient_uids(channel, asker) do
        {:ok, recipients} -> {:cont, {:ok, recipients ++ acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, recipients} -> {:ok, Enum.uniq(recipients)}
      {:error, _reason} = error -> error
    end)
  end

  defp strict_channel_recipient_uids(
         %Conversation{kind: :external, external_kind: :im_group} = channel,
         _asker
       ) do
    with {:ok, recipients} <- channel_group_member_uids(channel),
         true <- recipients != [] do
      {:ok, recipients}
    else
      false -> {:error, :empty_group_recipient_set}
      {:error, _reason} = error -> error
    end
  end

  defp strict_channel_recipient_uids(%Conversation{kind: :external, external_kind: :im_dm}, asker)
       when is_binary(asker),
       do: {:ok, [asker]}

  defp strict_channel_recipient_uids(
         %Conversation{kind: :external, external_kind: :im_dm, id: conversation_id},
         nil
       ) do
    case human_speaker_uids(conversation_id) do
      [] -> {:error, :empty_dm_recipient_set}
      recipients -> {:ok, recipients}
    end
  end

  defp strict_channel_recipient_uids(%Conversation{kind: :native, id: id}, _asker) do
    recipients =
      Repo.all(from p in Participant, where: p.conversation_id == ^id, select: p.principal_uid)

    if recipients == [], do: {:error, :empty_native_recipient_set}, else: {:ok, recipients}
  end

  defp strict_channel_recipient_uids(%Conversation{}, _asker), do: {:ok, []}

  defp channel_group_member_uids(%Conversation{
         external_kind: :im_group,
         principal_group_id: group_id
       })
       when is_binary(group_id),
       do: group_member_uids(group_id)

  defp channel_group_member_uids(%Conversation{external_kind: :im_group}),
    do: {:error, :group_recipient_set_unavailable}

  defp im_channel?(%Conversation{kind: :native}), do: true
  defp im_channel?(%Conversation{external_kind: kind}), do: kind in [:im_dm, :im_group]

  defp closed_disclosure, do: %{mode: :strict, asker_uid: nil, present_uids: []}

  defp human_speaker_uids(conversation_id) do
    Message
    |> join(:inner, [entry], principal in Principal, on: principal.uid == entry.author_uid)
    |> where([entry, _principal], entry.conversation_id == ^conversation_id)
    |> where([_entry, principal], principal.type == :human)
    |> select([_entry, principal], principal.uid)
    |> distinct(true)
    |> Repo.all()
  end

  defp agent_disclosure_mode(agent_uid) do
    case Repo.get(Agent, agent_uid) do
      %Agent{group_memory_disclosure_mode: mode} -> mode
      nil -> :strict
    end
  end

  defp group_member_uids(group_id) do
    case Ankole.AuthZ.list_group_members(group_id) do
      {:ok, members} -> {:ok, Enum.map(members, & &1.principal.uid)}
      {:error, _missing_or_computed} = error -> error
    end
  end

  # The conversation's audience is the default write scope, mirroring the
  # Signals-processing defaults: a DM learns for its asker, a member-backed
  # group learns for its member Group. Everything else, scheduled turns and
  # non-IM channels, falls back to the Agent's own principal scope. `world` is
  # an explicit model choice, never a default: the derived default also
  # bounds how far a poisoned claim or misjudged source can reach.
  defp derived_conversation_scope(%Signal{} = event, agent_uid) do
    channel =
      event_conversation_id(event) && Repo.get_by(Conversation, id: event_conversation_id(event))

    asker = asker_uid(event)

    case channel do
      %Conversation{kind: :native, created_by: uid} when is_binary(uid) ->
        {:ok, Scope.principal(uid)}

      %Conversation{kind: :external, external_kind: :im_group, principal_group_id: group_id} ->
        Scope.member_group_scope(group_id)

      %Conversation{kind: :external, external_kind: :im_dm} when is_binary(asker) ->
        {:ok, Scope.principal(asker)}

      _other ->
        {:ok, Scope.principal(agent_uid)}
    end
  end
end
