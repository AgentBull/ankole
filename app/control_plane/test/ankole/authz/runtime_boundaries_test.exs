defmodule Ankole.AuthZ.RuntimeBoundariesTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.Brain.Scope
  alias Ankole.Conversations.Native
  alias Ankole.Sessions.{Tool, Tools}

  test "guest world exclusion applies to enumeration, direct disclosure, and writes" do
    member = human_fixture().principal
    guest = human_fixture(%{membership: :guest}).principal

    assert {:ok, member_scopes} = Scope.accessible_scopes(member.uid)
    assert "world" in member_scopes
    assert Scope.satisfied_by?("world", member.uid)

    assert {:ok, guest_scopes} = Scope.accessible_scopes(guest.uid)
    refute "world" in guest_scopes
    assert Scope.principal(guest.uid) in guest_scopes
    refute Scope.satisfied_by?("world", guest.uid)
    refute Scope.satisfied_by_all?("world", [member.uid, guest.uid])
    assert {:error, :forbidden} = Scope.validate_writable("world", guest.uid)
  end

  test "Console administration does not grant chat or tool execution" do
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal
    assert {:ok, _} = first_site_admin_fixture(human.uid)

    attrs = %{
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      agent_uid: agent.uid,
      text: "Review this page."
    }

    assert {:error, {:forbidden, "chat"}} =
             Native.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), attrs)

    grant(human.uid, "agent:#{agent.uid}", "chat")
    assert {:ok, _} = Native.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), attrs)

    run = %{
      kind: :main,
      agent_uid: agent.uid,
      event: %{authorization_kind: "human", human_uid: human.uid}
    }

    assert {:error, {:forbidden, "invoke"}} =
             Tools.authorize_call(run, "kubectl", %{"op" => "get"})

    grant(
      human.uid,
      "agent:#{agent.uid}:tool:kubectl",
      "invoke",
      ~s(context.request.args.op == "get")
    )

    assert :ok = Tools.authorize_call(run, "kubectl", %{"op" => "get"})

    assert {:error, {:forbidden, "invoke"}} =
             Tools.authorize_call(run, "kubectl", %{"op" => "delete"})

    assert {:error, {:forbidden, "invoke"}} = Tools.authorize_call(run, "shell", %{"op" => "get"})
  end

  test "tool authorization sees normalized arguments before dispatch" do
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal

    tool =
      Tools.Session.declarations()
      |> Enum.find(&(&1["name"] == "clarify"))
      |> Tool.new(Tools.Session)

    run = %{
      kind: :main,
      agent_uid: agent.uid,
      event: %{authorization_kind: "human", human_uid: human.uid},
      tools: [tool]
    }

    grant(
      human.uid,
      "agent:#{agent.uid}:tool:clarify",
      "invoke",
      ~s(context.request.args.question == "Choose")
    )

    call = %{"name" => "clarify", "arguments" => ~s({"question":"  Choose  "})}
    assert {:ok, ^tool, %{"question" => "Choose"}} = Tools.prepare(run, call)

    refused = %{call | "arguments" => ~s({"question":"Other"})}
    assert {:error, %{failure_kind: "forbidden"}} = Tools.prepare(run, refused)
  end

  defp grant(uid, resource, action, condition \\ "true") do
    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: uid,
               resource_pattern: resource,
               action: action,
               condition: condition
             })

    grant
  end
end
