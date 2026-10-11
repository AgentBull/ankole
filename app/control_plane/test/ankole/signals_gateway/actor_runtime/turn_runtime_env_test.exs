defmodule Ankole.SignalsGateway.ActorRuntime.TurnRuntimeEnvTest do
  use Ankole.DataCase, async: true

  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.TurnRuntimeEnv
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey

  import Ankole.PrincipalsFixtures

  @runtime_name "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL"
  @profile_name "ANKOLE_RUNTIME_LARK_PROFILE"

  test "exports the active human Principal from the normalized event author" do
    %{principal: principal} = human_fixture()

    event = %ActorEvent{
      sender_key: "provider-subject",
      payload: %{"data" => %{"entry" => %{"author" => %{"principal_uid" => principal.uid}}}}
    }

    assert TurnRuntimeEnv.resolve(event) == human_env(principal.uid, 1)
  end

  test "uses sender_key only when the event has no normalized author Principal" do
    %{principal: principal} = human_fixture()

    assert TurnRuntimeEnv.resolve(%ActorEvent{sender_key: principal.uid, payload: %{}}) ==
             human_env(principal.uid, 1)
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

    assert TurnRuntimeEnv.resolve(event) == human_env(requester.uid, 1)
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

  test "changes the Lark profile only after reviewed restoration" do
    alias Ankole.Principals.HumanAccess
    %{principal: human} = human_fixture()
    event = %ActorEvent{sender_key: human.uid, payload: %{}}
    assert TurnRuntimeEnv.resolve(event) == human_env(human.uid, 1)
    assert {:ok, _} = HumanAccess.disable(human.uid, "review", nil, "disable")
    assert TurnRuntimeEnv.resolve(event) == %{}
    [restriction] = HumanAccess.restrictions(human.uid)

    assert {:ok, _} =
             HumanAccess.clear_restriction(human.uid, restriction.id, nil, "verified", "clear")

    assert {:ok, review} = Ankole.AuthZ.restoration_review(human.uid)

    assert {:ok, _} =
             HumanAccess.restore(human.uid, review.fingerprint, nil, "approved", "restore")

    assert TurnRuntimeEnv.resolve(event) == human_env(human.uid, 2)
  end

  test "names the Lark profile byte for byte as the Worker did before" do
    # Computed with the former Worker code: `ankole-u-` and the base64url
    # HMAC-SHA256 of the identity, keyed with the installation key.
    assert TurnRuntimeEnv.lark_profile("worker-secret", "human-alice", 1) ==
             "ankole-u-ua-czUjC-GGMM5BAg-Kfip_pfRS6mPEuQ23AIE5h6EA"

    assert TurnRuntimeEnv.lark_profile("worker-secret", "human-alice", 2) ==
             "ankole-u-QWn2bkOEC6Av4ZhcK0yYIvrRdgFFxSD00JccXhV_f3Q"

    assert TurnRuntimeEnv.lark_profile("worker-secret", "human-bob", 1) ==
             "ankole-u-IhXPvK8PMtK4SSP5GDnOGf9Y130C4iJovRzq9fO6CD8"

    assert TurnRuntimeEnv.lark_profile("other-worker-secret", "human-alice", 1) ==
             "ankole-u-GJi4AvNXSfa4DaOfrvPgcJctPx4FsOqiHGjKEoAeT7I"
  end

  test "reads only the canonical current sender runtime value" do
    assert TurnRuntimeEnv.current_sender_principal_uid(%{@runtime_name => "principal-1"}) ==
             "principal-1"

    assert TurnRuntimeEnv.current_sender_principal_uid(%{@runtime_name => ""}) == nil
    assert TurnRuntimeEnv.current_sender_principal_uid(%{"other" => "principal-1"}) == nil
    assert TurnRuntimeEnv.current_sender_principal_uid(nil) == nil
  end

  defp human_env(uid, version) do
    %{
      @runtime_name => uid,
      @profile_name => TurnRuntimeEnv.lark_profile(WorkerAuthKey.ensure!(), uid, version)
    }
  end
end
