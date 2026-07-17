defmodule AnkoleWeb.AuthZJSON do
  @moduledoc """
  Shared JSON serializers for AuthZ console REST API responses.
  """

  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.Principals.Principal

  def group_json(%Group{} = group, summaries \\ %{}) do
    summary = Map.get(summaries, group.id, %{})

    %{
      id: group.id,
      name: group.name,
      display_name: group.display_name,
      domain: Atom.to_string(group.domain),
      kind: Atom.to_string(group.kind),
      built_in: group.built_in,
      computed_condition: group.computed_condition,
      description: group.description,
      member_count: Map.get(summary, :member_count, 0),
      grant_count: Map.get(summary, :grant_count, 0),
      inserted_at: DateTime.to_iso8601(group.inserted_at),
      updated_at: DateTime.to_iso8601(group.updated_at)
    }
  end

  def member_json(%{membership: %Membership{} = membership, principal: %Principal{} = principal}) do
    principal
    |> principal_ref_json()
    |> Map.put(:member_since, DateTime.to_iso8601(membership.inserted_at))
  end

  def member_json(%Principal{} = principal) do
    principal
    |> principal_ref_json()
    |> Map.put(:member_since, nil)
  end

  def principal_ref_json(%Principal{} = principal) do
    %{
      uid: principal.uid,
      type: Atom.to_string(principal.type),
      status: Atom.to_string(principal.status),
      display_name: principal.display_name,
      avatar_url: principal.avatar_url
    }
  end

  def grant_json(%Grant{} = grant) do
    %{
      id: grant.id,
      principal_uid: grant.principal_uid,
      group_id: grant.group_id,
      resource_pattern: grant.resource_pattern,
      action: grant.action,
      condition: grant.condition,
      description: grant.description,
      inserted_at: DateTime.to_iso8601(grant.inserted_at),
      updated_at: DateTime.to_iso8601(grant.updated_at)
    }
  end
end
