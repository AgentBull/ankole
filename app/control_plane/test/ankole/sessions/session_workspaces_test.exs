defmodule Ankole.Sessions.SessionWorkspacesTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Repo
  alias Ankole.Sessions.SessionWorkspace
  alias Ecto.Adapters.SQL

  test "database identity starts at 10000" do
    assert %{rows: [["10000"]]} =
             SQL.query!(
               Repo,
               """
               SELECT identity_start
               FROM information_schema.columns
               WHERE table_schema = current_schema()
                 AND table_name = 'sessions'
                 AND column_name = 'id'
               """
             )
  end

  test "allocates one stable model-safe ID per Session" do
    %{principal: agent} = agent_fixture()

    assert {:ok, first} = Ankole.SessionsCase.ensure_workspace(agent.uid, "manual:first")
    assert first.id >= 10_000
    assert first.id <= 9_007_199_254_740_991
    assert first.kind == :named
    assert first.name == "manual:first"
    assert first.session_id == first.name

    assert {:ok, repeated} = Ankole.SessionsCase.ensure_workspace(agent.uid, "manual:first")
    assert repeated.id == first.id

    assert {:ok, second} = Ankole.SessionsCase.ensure_workspace(agent.uid, "manual:second")
    assert second.id > first.id
  end

  test "PostgreSQL prevents a caller from replacing the generated transport key" do
    %{principal: agent} = agent_fixture()
    assert {:ok, workspace} = Ankole.SessionsCase.ensure_workspace(agent.uid, "manual:generated")

    assert {:error, %Postgrex.Error{postgres: %{code: :generated_always}}} =
             SQL.query(
               Repo,
               "UPDATE sessions SET session_id = $1 WHERE id = $2 AND tenant_id = $3::text::uuid",
               ["job:10000", workspace.id, Repo.tenant_id!()]
             )
  end

  test "epoch advancement is an action on the locked workspace" do
    %{principal: agent} = agent_fixture()
    assert {:ok, workspace} = Ankole.SessionsCase.ensure_workspace(agent.uid, "manual:epoch")

    assert {:ok, advanced} =
             Repo.transact(fn repo ->
               key = %{agent_uid: agent.uid, session_id: workspace.session_id}
               locked = Ankole.Sessions.Fence.lock_workspace_in_tx(repo, key)
               Ankole.Ash.update(locked, :advance_epoch, %{})
             end)

    assert advanced.epoch == workspace.epoch + 1
    assert advanced.id == workspace.id
    assert advanced.session_id == workspace.session_id
    assert Repo.get!(SessionWorkspace, workspace.id).epoch == advanced.epoch
  end

  test "a reserved transport key cannot create a Session without its typed owner" do
    %{principal: agent} = agent_fixture()
    key = Ankole.Sessions.Key.job(9_007_199_254_740_990)

    assert {:error, :session_owner_not_found} =
             Ankole.SessionsCase.ensure_workspace(agent.uid, key)

    refute Repo.get_by(SessionWorkspace, agent_uid: agent.uid, session_id: key)
  end

  test "epoch advancement uses the stored value when a caller retains an older snapshot" do
    %{principal: agent} = agent_fixture()

    assert {:ok, workspace} =
             Ankole.SessionsCase.ensure_workspace(agent.uid, "manual:epoch-snapshot")

    assert {:ok, {first, second}} =
             Repo.transact(fn repo ->
               locked = Ankole.Sessions.Fence.lock_workspace_in_tx(repo, workspace)

               with {:ok, first} <- Ankole.Ash.update(locked, :advance_epoch, %{}),
                    {:ok, second} <- Ankole.Ash.update(locked, :advance_epoch, %{}) do
                 {:ok, {first, second}}
               end
             end)

    assert first.epoch == workspace.epoch + 1
    assert second.epoch == first.epoch + 1
    assert Repo.get!(SessionWorkspace, workspace.id).epoch == second.epoch
  end

  test "PostgreSQL rejects an owner kind with two references" do
    %{principal: agent} = agent_fixture()

    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :check_violation, constraint: "sessions_owner_check"}
            }} =
             SQL.query(
               Repo,
               """
               INSERT INTO sessions
                 (tenant_id, agent_uid, kind, name, background_job_id, epoch, inserted_at, updated_at)
               VALUES ($1::text::uuid, $2, 'named', 'manual:invalid', 10000, 0, now(), now())
               """,
               [Repo.tenant_id!(), agent.uid]
             )
  end
end
