defmodule Ankole.AgentWorkers.WorkspaceStatusTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.ReconcileJob
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.SessionsCase

  setup do
    %{principal: agent} = agent_fixture()
    %{uid: agent.uid}
  end

  test "absent failures distinguish preparation, retries, and definite rejection", %{uid: uid} do
    assert {:wait, :starting} = AgentWorkers.workspace_status(uid)

    for {kind, expected} <- [
          {"pending", {:wait, :preparing}},
          {"transient", {:wait, :retrying}},
          {"rejected", {:error, {:rejected, "Console-only log"}}}
        ] do
      set_row(uid, AgentWorker.error_fields("Console-only log", kind))
      assert AgentWorkers.workspace_status(uid) == expected
    end
  end

  test "lifecycle age cannot time out a user wait, and pause and replacement take precedence", %{
    uid: uid
  } do
    SessionsCase.provision_worker(uid)
    set_row(uid, state_changed_at: DateTime.add(DateTime.utc_now(), -3600))
    assert {:wait, :starting} = AgentWorkers.workspace_status(uid)

    set_row(uid, AgentWorker.error_fields("Retry error", "transient"))
    assert {:wait, :retrying} = AgentWorkers.workspace_status(uid)
    set_row(uid, state: :paused)
    assert {:wait, :resuming} = AgentWorkers.workspace_status(uid)
    set_row(uid, state: :draining, drain_reason: "rebuild")
    assert {:wait, :replacing} = AgentWorkers.workspace_status(uid)
  end

  test "a connected Worker is usable and admission clears both error fields", %{uid: uid} do
    SessionsCase.provision_worker(uid)
    set_row(uid, AgentWorker.error_fields("Old platform log", "transient"))
    {:ok, row} = SessionsCase.admit_worker(SessionsCase.unique_route(), %{worker_id: uid})
    assert row.last_error == nil and row.last_error_kind == nil
    assert {:ok, usable} = AgentWorkers.workspace_status(uid)
    assert_persisted_equal(usable, row)
    set_row(uid, state: :draining)
    assert {:ok, %{state: :draining}} = AgentWorkers.workspace_status(uid)
  end

  test "missing assignment, inactive Agent, and deleted row return terminal categories", %{
    uid: uid
  } do
    set_row(uid, provider_id: nil)
    assert {:error, :worker_provider_missing} = AgentWorkers.workspace_status(uid)
    {:ok, _} = disable_principal_fixture(uid)
    assert {:error, :agent_not_active} = AgentWorkers.workspace_status(uid)
    set_row(uid, state: :deleting)
    assert {:error, :agent_worker_unavailable} = AgentWorkers.workspace_status(uid)
    Repo.delete!(Repo.get!(AgentWorker, uid))
    assert {:error, :agent_worker_unavailable} = AgentWorkers.workspace_status(uid)
  end

  test "fixing provider configuration clears rejections across tenants before the next call", %{
    uid: uid
  } do
    provider_id = Repo.get!(AgentWorker, uid).provider_id
    other = create_tenant()

    other_uid =
      Repo.with_tenant(other.id, fn ->
        %{principal: agent} = agent_fixture(%{worker_provider_id: provider_id})
        set_row(agent.uid, AgentWorker.error_fields("Rejected config", "rejected"))
        agent.uid
      end)

    set_row(uid, AgentWorker.error_fields("Rejected config", "rejected"))
    Repo.delete_all(Oban.Job)
    assert {:ok, _} = Providers.update(provider_id, %{display_name: "Fixed provider"})

    for agent_uid <- [uid, other_uid] do
      worker = Repo.across_tenants(fn -> Repo.get!(AgentWorker, agent_uid) end)
      assert worker.last_error == nil and worker.last_error_kind == nil
      assert_enqueued(worker: ReconcileJob, args: %{agent_uid: agent_uid})
    end

    assert {:wait, :starting} = AgentWorkers.workspace_status(uid)
  end

  defp set_row(uid, changes),
    do: Repo.update_all(from(w in AgentWorker, where: w.agent_uid == ^uid), set: changes)
end
