defmodule Ankole.SignalsGateway.BindingMembershipTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.BindingMembership

  @joined_at ~U[2026-07-13 01:00:00.000000Z]
  @left_at ~U[2026-07-13 02:00:00.000000Z]

  test "projects multiple providers into one host-owned membership shape" do
    lark = context("agent-a", "lark-main", "lark")
    teams = context("agent-b", "teams-main", "teams")

    metadata =
      %{"provider_note" => "preserved"}
      |> BindingMembership.project(lark, :joined, @joined_at)
      |> BindingMembership.project(teams, :joined, @joined_at)

    assert metadata["provider_note"] == "preserved"
    assert BindingMembership.joined?(metadata, lark)
    assert BindingMembership.joined?(metadata, teams)

    assert %{
             "agent_uid" => "agent-a",
             "binding_name" => "lark-main",
             "state" => "joined",
             "observed_at" => "2026-07-13T01:00:00.000000Z"
           } = BindingMembership.memberships(metadata)["agent-a|lark-main"]

    refute Map.has_key?(metadata, "lark_im")
    refute Map.has_key?(metadata, "teams_im")
  end

  test "one binding can leave without revoking another binding in the group" do
    first = context("agent-a", "primary", "slack")
    second = context("agent-b", "secondary", "slack")

    metadata =
      %{}
      |> BindingMembership.project(first, :joined, @joined_at)
      |> BindingMembership.project(second, :joined, @joined_at)
      |> BindingMembership.project(first, :left, @left_at)

    refute BindingMembership.joined?(metadata, first)
    assert BindingMembership.joined?(metadata, second)
    refute BindingMembership.all_left?(metadata)

    all_left = BindingMembership.mark_all_left(metadata, @left_at)
    assert BindingMembership.all_left?(all_left)
    refute BindingMembership.joined?(all_left, second)
  end

  defp context(agent_uid, binding_name, adapter) do
    AdapterContext.new(
      agent_uid: agent_uid,
      binding_name: binding_name,
      adapter: adapter,
      user_name: adapter
    )
  end
end
