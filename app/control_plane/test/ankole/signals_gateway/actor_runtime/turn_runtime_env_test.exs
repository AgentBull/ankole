defmodule Ankole.SignalsGateway.ActorRuntime.TurnRuntimeEnvTest do
  use Ankole.DataCase, async: true

  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.TurnRuntimeEnv

  import Ankole.PrincipalsFixtures

  @runtime_name "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL"
  @version_name "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_ACCESS_VERSION"

  test "exports the active human Principal from the normalized event author" do
    %{principal: principal} = human_fixture()

    event = %ActorEvent{
      sender_key: "provider-subject",
      payload: %{"data" => %{"entry" => %{"author" => %{"principal_uid" => principal.uid}}}}
    }

    assert TurnRuntimeEnv.resolve(event) == %{
             @runtime_name => principal.uid,
             @version_name => "1"
           }
  end

  test "uses sender_key only when the event has no normalized author Principal" do
    %{principal: principal} = human_fixture()

    assert TurnRuntimeEnv.resolve(%ActorEvent{sender_key: principal.uid, payload: %{}}) ==
             %{@runtime_name => principal.uid, @version_name => "1"}
  end

  test "prefers the Turn requester over the last author in a multi-user batch" do
    %{principal: requester} = human_fixture()
    %{principal: last_author} = human_fixture()

    event = %ActorEvent{
      sender_key: requester.uid,
      payload: %{
        "data" => %{
          "entry" => %{"author" => %{"principal_uid" => last_author.uid}}
        }
      }
    }

    assert TurnRuntimeEnv.resolve(event) == %{
             @runtime_name => requester.uid,
             @version_name => "1"
           }
  end

  test "does not replace an ineligible requester with the last batch author" do
    %{principal: requester} = human_fixture()
    %{principal: last_author} = human_fixture()

    assert {:ok, %Principal{}} =
             requester
             |> Principal.status_changeset(%{status: :disabled})
             |> Repo.update()

    event = %ActorEvent{
      sender_key: requester.uid,
      payload: %{
        "data" => %{
          "entry" => %{"author" => %{"principal_uid" => last_author.uid}}
        }
      }
    }

    assert TurnRuntimeEnv.resolve(event) == %{}
  end

  test "omits missing, non-human, and disabled Principals" do
    %{principal: agent} = agent_fixture()
    %{principal: disabled} = human_fixture()

    assert {:ok, %Principal{}} =
             disabled
             |> Principal.status_changeset(%{status: :disabled})
             |> Repo.update()

    assert TurnRuntimeEnv.resolve(%ActorEvent{sender_key: "missing", payload: %{}}) == %{}
    assert TurnRuntimeEnv.resolve(%ActorEvent{sender_key: agent.uid, payload: %{}}) == %{}
    assert TurnRuntimeEnv.resolve(%ActorEvent{sender_key: disabled.uid, payload: %{}}) == %{}
    assert TurnRuntimeEnv.resolve(%ActorEvent{payload: %{}}) == %{}
  end

  test "exports the new access version only after reviewed restoration" do
    alias Ankole.Principals.HumanAccess
    %{principal: human} = human_fixture()
    event = %ActorEvent{sender_key: human.uid, payload: %{}}
    assert TurnRuntimeEnv.resolve(event)[@version_name] == "1"
    assert {:ok, _} = HumanAccess.disable(human.uid, "review", nil, "disable")
    assert TurnRuntimeEnv.resolve(event) == %{}
    [restriction] = HumanAccess.restrictions(human.uid)

    assert {:ok, _} =
             HumanAccess.clear_restriction(human.uid, restriction.id, nil, "verified", "clear")

    assert {:ok, review} = Ankole.AuthZ.restoration_review(human.uid)

    assert {:ok, _} =
             HumanAccess.restore(human.uid, review.fingerprint, nil, "approved", "restore")

    assert TurnRuntimeEnv.resolve(event) == %{@runtime_name => human.uid, @version_name => "2"}
  end

  test "reads only the canonical current sender runtime value" do
    assert TurnRuntimeEnv.current_sender_principal_uid(%{@runtime_name => "principal-1"}) ==
             "principal-1"

    assert TurnRuntimeEnv.current_sender_principal_uid(%{@runtime_name => ""}) == nil
    assert TurnRuntimeEnv.current_sender_principal_uid(%{"other" => "principal-1"}) == nil
    assert TurnRuntimeEnv.current_sender_principal_uid(nil) == nil
  end
end
