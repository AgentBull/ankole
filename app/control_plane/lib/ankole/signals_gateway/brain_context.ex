defmodule Ankole.SignalsGateway.BrainContext do
  @moduledoc """
  Derives the Brain execution context of one AIGateway request.

  A request from a Worker Turn carries `metadata.actor_event_id`. This module
  is the one place that interprets that value for memory: the event must belong
  to the request subject, and it supplies the disclosure recipients, the default
  write scope, the channel parent, and the write fence exactly as the Turn's
  conversation defines them. A request without an actor event runs as the
  subject alone: open disclosure to the subject's own knowledge boundary, the
  subject's principal scope as the default write scope, and the subject's
  canonical page as the parent fallback.

  Disclosure follows the Agent's `group_memory_disclosure_mode`: relaxed mode
  checks only the asker; strict mode adds every present member of the channels
  the Turn delivers into, and an unresolved recipient set discloses nothing.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Access
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Tools.Context
  alias Ankole.Principals.Agent
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.Schedule.Delivery
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry

  @live_activation_statuses ["starting", "active", "draining"]

  @doc """
  Builds the context for a subject and the public request metadata.
  """
  @spec build(String.t(), map() | nil) :: {:ok, Context.t()} | {:error, term()}
  def build(subject_uid, metadata) when is_binary(subject_uid) do
    case actor_event_id(metadata) do
      nil -> subject_context(subject_uid)
      actor_event_id -> turn_context(subject_uid, actor_event_id)
    end
  end

  @doc "Returns the actor event id a request declares, or nil."
  @spec actor_event_id(map() | nil) :: String.t() | nil
  def actor_event_id(%{"actor_event_id" => id}) when is_binary(id) and id != "", do: id
  def actor_event_id(_metadata), do: nil

  defp subject_context(subject_uid) do
    {:ok,
     %Context{
       querier_uid: subject_uid,
       disclosure: Access.open_disclosure(),
       default_write_scope: {:ok, Scope.principal(subject_uid)},
       channel_id: nil,
       participant_uids: [subject_uid],
       parent_fallback: page_fallback(subject_uid),
       holder_default: holder_default(subject_uid),
       write_fence: nil
     }}
  end

  defp turn_context(subject_uid, actor_event_id) do
    with {:ok, event} <- owned_event(subject_uid, actor_event_id) do
      channel_id = event.signal_channel_id

      {:ok,
       %Context{
         querier_uid: subject_uid,
         disclosure: event_disclosure(event, agent_disclosure_mode(subject_uid)),
         default_write_scope: derived_conversation_scope(event, subject_uid),
         channel_id: channel_id,
         participant_uids: participant_uids(event),
         parent_fallback:
           if(is_binary(channel_id),
             do: {:channel, channel_id},
             else: page_fallback(subject_uid)
           ),
         holder_default: "agents/" <> subject_uid,
         write_fence: fn -> live_turn_fence(subject_uid, event.id) end
       }}
    end
  end

  defp owned_event(subject_uid, actor_event_id) do
    case Ecto.UUID.cast(actor_event_id) do
      {:ok, id} ->
        case Repo.get(ActorEvent, id) do
          %ActorEvent{agent_uid: ^subject_uid} = event -> {:ok, event}
          %ActorEvent{} -> {:error, :actor_event_not_owned}
          nil -> {:error, :actor_event_not_found}
        end

      :error ->
        {:error, :actor_event_not_found}
    end
  end

  # A write from a superseded turn must not land. The HTTP path cannot name
  # the Worker transport route, so the fence covers the activation facts the
  # request does carry: the event must still be the current event of a live
  # activation of this Agent.
  defp live_turn_fence(agent_uid, actor_event_id) do
    live? =
      ActorSessionActivation
      |> where([activation], activation.agent_uid == ^agent_uid)
      |> where([activation], activation.current_actor_event_id == ^actor_event_id)
      |> where([activation], activation.status in @live_activation_statuses)
      |> Repo.exists?()

    if live?, do: :ok, else: {:error, :turn_not_live}
  end

  # The pack's participant is the event author, as the Worker reported it.
  defp participant_uids(%ActorEvent{payload: payload}) do
    case get_in(payload || %{}, ["data", "entry", "author", "principal_uid"]) do
      uid when is_binary(uid) and uid != "" -> [uid]
      _missing -> []
    end
  end

  defp page_fallback(subject_uid) do
    case Scope.canonical_slug(subject_uid) do
      {:ok, slug} -> {:page, slug}
      {:error, _reason} = error -> error
    end
  end

  defp holder_default(subject_uid) do
    case Scope.canonical_slug(subject_uid) do
      {:ok, slug} -> slug
      {:error, _reason} -> nil
    end
  end

  # Disclosure

  # Relaxed mode is asker-only by contract. A Turn without an asker always
  # uses strict disclosure because its final text can still go to a channel.
  defp event_disclosure(%ActorEvent{sender_key: asker}, :relaxed) when is_binary(asker) do
    %{mode: :relaxed, asker_uid: asker, present_uids: []}
  end

  defp event_disclosure(%ActorEvent{} = event, _mode) do
    asker = event.sender_key

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

  defp disclosure_channels(%ActorEvent{} = event) do
    with {:ok, channel_ids} <- disclosure_channel_ids(event) do
      channels =
        Channel
        |> where([channel], channel.id in ^channel_ids)
        |> Repo.all()

      if length(channels) == length(channel_ids),
        do: {:ok, channels},
        else: {:error, :disclosure_channel_not_found}
    end
  end

  defp disclosure_channel_ids(%ActorEvent{} = event) do
    case ActorEvent.scheduled_delivery_snapshot(event) do
      %{} = delivery ->
        with {:ok, targets} <- Delivery.targets(delivery, event.binding_name) do
          {:ok, targets |> Enum.map(& &1["signal_channel_id"]) |> Enum.uniq()}
        end

      _no_scheduled_delivery ->
        {:ok, List.wrap(event.signal_channel_id)}
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

  defp strict_channel_recipient_uids(%Channel{kind: :im_group} = channel, _asker) do
    with {:ok, recipients} <- channel_group_member_uids(channel),
         true <- recipients != [] do
      {:ok, recipients}
    else
      false -> {:error, :empty_group_recipient_set}
      {:error, _reason} = error -> error
    end
  end

  defp strict_channel_recipient_uids(%Channel{kind: :im_dm}, asker) when is_binary(asker),
    do: {:ok, [asker]}

  defp strict_channel_recipient_uids(%Channel{kind: :im_dm, id: channel_id}, nil) do
    case human_speaker_uids(channel_id) do
      [] -> {:error, :empty_dm_recipient_set}
      recipients -> {:ok, recipients}
    end
  end

  defp strict_channel_recipient_uids(%Channel{}, _asker), do: {:ok, []}

  defp channel_group_member_uids(%Channel{kind: :im_group, principal_group_id: group_id})
       when is_binary(group_id),
       do: group_member_uids(group_id)

  defp channel_group_member_uids(%Channel{kind: :im_group}),
    do: {:error, :group_recipient_set_unavailable}

  defp im_channel?(%Channel{kind: kind}), do: kind in [:im_dm, :im_group]

  defp closed_disclosure, do: %{mode: :strict, asker_uid: nil, present_uids: []}

  defp human_speaker_uids(channel_id) do
    Entry
    |> join(:inner, [entry], principal in Principal,
      on: principal.uid == fragment("?->>'principal_uid'", entry.author)
    )
    |> where([entry, _principal], entry.signal_channel_id == ^channel_id)
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

  # Default write scope

  # The conversation's audience is the default write scope, mirroring the
  # Signals-processing defaults: a DM learns for its asker, a member-backed
  # group learns for its member Group. Everything else, scheduled turns and
  # non-IM channels, falls back to the Agent's own principal scope. `world` is
  # an explicit model choice, never a default: the derived default also
  # bounds how far a poisoned claim or misjudged source can reach.
  defp derived_conversation_scope(%ActorEvent{} = event, agent_uid) do
    channel = event.signal_channel_id && Repo.get(Channel, event.signal_channel_id)

    case channel do
      %Channel{kind: :im_group, principal_group_id: group_id} when is_binary(group_id) ->
        case Ankole.AuthZ.get_principal_group(group_id) do
          {:ok, group} -> {:ok, Scope.group(group.name)}
          {:error, :not_found} -> {:error, :im_group_without_member_group}
        end

      %Channel{kind: :im_group} ->
        # No member Group means no derivable group audience. An explicit
        # scope is the way through, so the error names the real blocker.
        {:error, :im_group_without_member_group}

      %Channel{kind: :im_dm} when is_binary(event.sender_key) ->
        {:ok, Scope.principal(event.sender_key)}

      _other ->
        {:ok, Scope.principal(agent_uid)}
    end
  end
end
