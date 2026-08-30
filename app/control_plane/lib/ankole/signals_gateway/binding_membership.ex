defmodule Ankole.SignalsGateway.BindingMembership do
  @moduledoc """
  Host-owned projection of a signal binding's current IM-group membership.

  Provider adapters observe whether their bot-backed binding is joined or left
  and project that observation into a group's metadata; the same adapters read
  it back through `joined?/2` and `all_left?/1` to decide sync and cleanup
  behavior. This is separate from human AuthZ group membership and from
  provider online-presence APIs.
  """

  alias Ankole.SignalsGateway.AdapterContext

  @root_key "signals_gateway"
  @memberships_key "binding_memberships"

  @type state :: :joined | :left

  @doc """
  Projects one binding's current membership into group metadata.
  """
  @spec project(map() | nil, AdapterContext.t(), state(), DateTime.t()) :: map()
  def project(
        metadata,
        %AdapterContext{agent_uid: agent_uid, binding_name: binding_name},
        state,
        now \\ DateTime.utc_now(:microsecond)
      )
      when state in [:joined, :left] do
    agent_uid = String.downcase(agent_uid)
    memberships = memberships(metadata)

    membership = %{
      "agent_uid" => agent_uid,
      "binding_name" => binding_name,
      "state" => Atom.to_string(state),
      "observed_at" => DateTime.to_iso8601(now)
    }

    metadata
    |> map_or_empty()
    |> put_memberships(Map.put(memberships, key(agent_uid, binding_name), membership))
  end

  @doc """
  Marks every known binding membership left at the same observation time.
  """
  @spec mark_all_left(map() | nil, DateTime.t()) :: map()
  def mark_all_left(metadata, now \\ DateTime.utc_now(:microsecond)) do
    observed_at = DateTime.to_iso8601(now)

    updated =
      metadata
      |> memberships()
      |> Map.new(fn {key, membership} ->
        {key,
         membership
         |> map_or_empty()
         |> Map.put("state", "left")
         |> Map.put("observed_at", observed_at)}
      end)

    metadata
    |> map_or_empty()
    |> put_memberships(updated)
  end

  @doc """
  Returns whether one binding has a current joined proof.
  """
  @spec joined?(map() | nil, AdapterContext.t()) :: boolean()
  def joined?(metadata, %AdapterContext{agent_uid: agent_uid, binding_name: binding_name}) do
    joined?(metadata, agent_uid, binding_name)
  end

  @spec joined?(map() | nil, String.t(), String.t()) :: boolean()
  def joined?(metadata, agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    get_in(memberships(metadata), [key(String.downcase(agent_uid), binding_name), "state"]) ==
      "joined"
  end

  @doc """
  Returns the distinct Agent UIDs of the currently joined bindings.
  """
  @spec joined_agent_uids(map() | nil) :: [String.t()]
  def joined_agent_uids(metadata) do
    metadata
    |> memberships()
    |> Enum.filter(fn {_key, membership} ->
      is_map(membership) and Map.get(membership, "state") == "joined"
    end)
    |> Enum.map(fn {_key, membership} -> Map.get(membership, "agent_uid") end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  @doc """
  Returns whether at least one membership is known and all known bindings left.
  """
  @spec all_left?(map() | nil) :: boolean()
  def all_left?(metadata) do
    memberships = memberships(metadata)

    memberships != %{} and
      Enum.all?(memberships, fn {_key, membership} ->
        is_map(membership) and Map.get(membership, "state") == "left"
      end)
  end

  @doc false
  @spec memberships(map() | nil) :: map()
  def memberships(metadata) do
    case get_in(map_or_empty(metadata), [@root_key, @memberships_key]) do
      memberships when is_map(memberships) -> memberships
      _missing_or_invalid -> %{}
    end
  end

  defp put_memberships(metadata, memberships) do
    root = metadata |> Map.get(@root_key) |> map_or_empty()
    Map.put(metadata, @root_key, Map.put(root, @memberships_key, memberships))
  end

  defp key(agent_uid, binding_name), do: "#{agent_uid}|#{binding_name}"

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}
end
