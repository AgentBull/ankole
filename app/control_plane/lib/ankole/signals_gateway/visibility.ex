defmodule Ankole.SignalsGateway.Visibility do
  @moduledoc """
  Named queries for channels whose mirrored history is visible to a principal.

  Provider adapters project current binding membership into a host-owned fact.
  Brain search and dreaming use this query instead of interpreting provider
  metadata or inventing slightly different channel-permission rules.
  """

  import Ecto.Query, warn: false

  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Channel

  @doc """
  Returns every currently visible channel for a principal.

  For agents, IM-group visibility requires a joined host membership fact for a
  currently enabled and available binding. Human visibility follows current
  AuthZ group membership. Historical actor events retain DMs and channels whose
  provider has no IM-group membership predicate, but never retain an IM group
  after its current membership proof disappears.
  """
  @spec visible_channels(String.t(), keyword()) :: [Channel.t()]
  def visible_channels(principal_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid) do
      ids =
        joined_agent_group_channel_ids(repo, principal_uid) ++
          member_group_channel_ids(repo, principal_uid) ++
          observed_non_group_channel_ids(repo, principal_uid)

      Channel
      |> where([channel], channel.id in ^Enum.uniq(ids))
      |> order_by([channel], asc: channel.id)
      |> repo.all()
    else
      {:error, _reason} -> []
    end
  end

  @doc "Returns true when a joined binding isolates one group from shared memory."
  @spec confidential_channel?(String.t(), String.t(), keyword()) :: boolean()
  def confidential_channel?(principal_uid, channel_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid) do
      Channel
      |> join(:inner, [channel], group in Group, on: group.id == channel.principal_group_id)
      |> join(:inner, [_channel, _group], binding in Binding,
        on: binding.agent_uid == ^principal_uid
      )
      |> where(
        [channel, _group, _binding],
        channel.id == ^channel_id and channel.kind == :im_group
      )
      |> where(
        [_channel, _group, binding],
        binding.enabled == true and is_nil(binding.unavailable_reason) and
          binding.confidential_memory == true
      )
      |> where(
        [_channel, group, binding],
        fragment(
          "?->'signals_gateway'->'binding_memberships'->(? || '|' || ?)->>'state' = 'joined'",
          group.metadata,
          ^principal_uid,
          binding.name
        )
      )
      |> repo.exists?()
    else
      {:error, _reason} -> false
    end
  end

  defp joined_agent_group_channel_ids(repo, principal_uid) do
    Channel
    |> join(:inner, [channel], group in Group, on: group.id == channel.principal_group_id)
    |> join(:inner, [_channel, _group], binding in Binding,
      on: binding.agent_uid == ^principal_uid
    )
    |> where([channel, group, _binding], channel.kind == :im_group and group.domain == :im_group)
    |> where(
      [_channel, _group, binding],
      binding.enabled == true and is_nil(binding.unavailable_reason)
    )
    |> where(
      [_channel, group, binding],
      fragment(
        "?->'signals_gateway'->'binding_memberships'->(? || '|' || ?)->>'state' = 'joined'",
        group.metadata,
        ^principal_uid,
        binding.name
      )
    )
    |> select([channel, _group, _binding], channel.id)
    |> distinct(true)
    |> repo.all()
  end

  defp member_group_channel_ids(repo, principal_uid) do
    Channel
    |> join(:inner, [channel], membership in Membership,
      on: membership.group_id == channel.principal_group_id
    )
    |> join(:inner, [_channel, membership], principal in Principal,
      on: principal.uid == membership.principal_uid
    )
    |> where(
      [_channel, membership, principal],
      membership.principal_uid == ^principal_uid and principal.type == :human
    )
    |> select([channel, _membership, _principal], channel.id)
    |> distinct(true)
    |> repo.all()
  end

  defp observed_non_group_channel_ids(repo, principal_uid) do
    ActorEvent
    |> join(:inner, [event], channel in Channel, on: channel.id == event.signal_channel_id)
    |> where([event], event.agent_uid == ^principal_uid)
    |> where([event], not is_nil(event.signal_channel_id))
    |> where([_event, channel], channel.kind != :im_group)
    |> select([event, _channel], event.signal_channel_id)
    |> distinct(true)
    |> repo.all()
  end
end
