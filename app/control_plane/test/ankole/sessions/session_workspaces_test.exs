defmodule Ankole.Sessions.SessionWorkspacesTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Repo
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

    assert {:ok, repeated} = Ankole.SessionsCase.ensure_workspace(agent.uid, "manual:first")
    assert repeated.id == first.id

    assert {:ok, second} = Ankole.SessionsCase.ensure_workspace(agent.uid, "manual:second")
    assert second.id > first.id
  end
end
