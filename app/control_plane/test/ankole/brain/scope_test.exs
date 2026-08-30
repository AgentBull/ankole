defmodule Ankole.Brain.ScopeTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.Brain.Scope

  setup do
    %{principal: member_a} = human_fixture()
    %{principal: member_b} = human_fixture()
    %{principal: outsider} = human_fixture()

    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: "scope-team-#{System.unique_integer([:positive])}",
        display_name: "Scope Team",
        domain: :operator,
        kind: :static
      })

    {:ok, _membership} = AuthZ.add_principal_to_group(member_a.uid, group.id)
    {:ok, _membership} = AuthZ.add_principal_to_group(member_b.uid, group.id)

    %{group: group, member_a: member_a, member_b: member_b, outsider: outsider}
  end

  describe "satisfied_by_all?/2" do
    test "world satisfies every recipient set", context do
      assert Scope.satisfied_by_all?("world", [context.member_a.uid, context.outsider.uid])
    end

    test "a principal scope requires every recipient to be that principal", context do
      scope = Scope.principal(context.member_a.uid)

      assert Scope.satisfied_by_all?(scope, [context.member_a.uid])
      refute Scope.satisfied_by_all?(scope, [context.member_a.uid, context.member_b.uid])
    end

    test "a group scope requires every recipient to be a current member", context do
      scope = Scope.group(context.group.name)

      assert Scope.satisfied_by_all?(scope, [context.member_a.uid, context.member_b.uid])
      refute Scope.satisfied_by_all?(scope, [context.member_a.uid, context.outsider.uid])
      refute Scope.satisfied_by_all?(scope, ["not-a-principal"])
    end

    test "an unknown group or malformed scope satisfies nobody", context do
      refute Scope.satisfied_by_all?("group:missing-group", [context.member_a.uid])
      refute Scope.satisfied_by_all?("company", [context.member_a.uid])
    end
  end
end
