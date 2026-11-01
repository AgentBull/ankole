defmodule Ankole.Sessions.TurnRuntimeEnvTest do
  use Ankole.DataCase, async: true

  alias Ankole.Signals.Signal
  alias Ankole.Sessions.TurnRuntimeEnv
  alias Ankole.AgentWorkers.WorkerAuthKey

  import Ankole.PrincipalsFixtures

  @runtime_name "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL"
  @profile_name "ANKOLE_RUNTIME_LARK_PROFILE"

  test "exports only the frozen Human authorization" do
    %{principal: human} = human_fixture()
    assert TurnRuntimeEnv.resolve(authorized(human)) == human_env(human.uid, 1)
  end

  test "service and unreviewed stimuli cannot borrow a Human from sender or data" do
    %{principal: human} = human_fixture()

    for kind <- ["service", "review_required"],
        data <- [nil, false, [], %{"entry" => %{"author" => %{"principal_uid" => human.uid}}}] do
      signal = %Signal{
        producer: :kernel,
        authorization_kind: kind,
        sender_key: human.uid,
        data: data
      }

      assert TurnRuntimeEnv.resolve(signal) == %{}
    end
  end

  test "uses the requester authorization when a batch ends with another author" do
    %{principal: requester} = human_fixture()
    %{principal: last_author} = human_fixture()

    signal = %{
      authorized(requester)
      | data: %{"entry" => %{"author" => %{"principal_uid" => last_author.uid}}}
    }

    assert TurnRuntimeEnv.resolve(signal) == human_env(requester.uid, 1)
  end

  test "does not replace a disabled requester with a batch author" do
    %{principal: requester} = human_fixture()
    %{principal: last_author} = human_fixture()

    signal = %{
      authorized(requester)
      | data: %{"entry" => %{"author" => %{"principal_uid" => last_author.uid}}}
    }

    {:ok, _} = Ankole.PrincipalsFixtures.disable_principal_fixture(requester.uid)
    assert TurnRuntimeEnv.resolve(signal) == %{}
  end

  test "omits missing and non-Human authorization subjects" do
    %{principal: agent} = agent_fixture()

    assert TurnRuntimeEnv.resolve(%Signal{
             producer: :kernel,
             authorization_kind: "human",
             human_uid: agent.uid,
             human_access_version: 1
           }) == %{}

    assert TurnRuntimeEnv.resolve(%Signal{
             producer: :kernel,
             authorization_kind: "human",
             human_uid: Ecto.UUID.generate(),
             human_access_version: 1
           }) == %{}
  end

  test "restoration gives a new stimulus a new profile without reviving stale work" do
    alias Ankole.Principals.HumanAccess
    %{principal: human} = human_fixture()
    old_signal = authorized(human)
    assert TurnRuntimeEnv.resolve(old_signal) == human_env(human.uid, 1)
    assert {:ok, _} = HumanAccess.disable(human.uid, "review", nil, "disable")
    assert TurnRuntimeEnv.resolve(old_signal) == %{}
    [restriction] = HumanAccess.restrictions(human.uid)

    assert {:ok, _} =
             HumanAccess.clear_restriction(human.uid, restriction.id, nil, "verified", "clear")

    assert {:ok, _} =
             HumanAccess.restore(human.uid, nil, "approved", "restore")

    assert TurnRuntimeEnv.resolve(old_signal) == %{}

    assert TurnRuntimeEnv.resolve(%{old_signal | human_access_version: 2}) ==
             human_env(human.uid, 2)
  end

  defp authorized(human),
    do: %Signal{
      producer: :kernel,
      authorization_kind: "human",
      human_uid: human.uid,
      human_access_version: human.access_version,
      sender_key: human.uid
    }

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
