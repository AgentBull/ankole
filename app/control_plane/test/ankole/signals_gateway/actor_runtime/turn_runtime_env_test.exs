defmodule Ankole.SignalsGateway.ActorRuntime.TurnRuntimeEnvTest do
  use Ankole.DataCase, async: true

  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.TurnRuntimeEnv

  import Ankole.PrincipalsFixtures

  @runtime_name "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL"

  test "exports the active human Principal from the normalized event author" do
    %{principal: principal} = human_fixture()

    event = %ActorEvent{
      sender_key: "provider-subject",
      payload: %{"data" => %{"entry" => %{"author" => %{"principal_uid" => principal.uid}}}}
    }

    assert TurnRuntimeEnv.resolve(event) == %{@runtime_name => principal.uid}
  end

  test "uses sender_key only when the event has no normalized author Principal" do
    %{principal: principal} = human_fixture()

    assert TurnRuntimeEnv.resolve(%ActorEvent{sender_key: principal.uid, payload: %{}}) ==
             %{@runtime_name => principal.uid}
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

    assert TurnRuntimeEnv.resolve(event) == %{@runtime_name => requester.uid}
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
end
