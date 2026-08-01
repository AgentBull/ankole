defmodule Ankole.SignalsGateway.ActorRuntime.SessionWorkspacesTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.SessionWorkspaces
  alias Ecto.Adapters.SQL

  test "database identity starts at 10000" do
    assert %{rows: [["10000"]]} =
             SQL.query!(
               Repo,
               """
               SELECT identity_start
               FROM information_schema.columns
               WHERE table_schema = current_schema()
                 AND table_name = 'actor_session_workspaces'
                 AND column_name = 'id'
               """
             )
  end

  test "allocates one stable model-safe ID per actor session" do
    %{principal: agent} = agent_fixture()

    assert {:ok, first} = SessionWorkspaces.ensure(agent.uid, "signal-channel:lark:first")
    assert first.id >= 10_000
    assert first.id <= 9_007_199_254_740_991

    assert {:ok, repeated} = SessionWorkspaces.ensure(agent.uid, "signal-channel:lark:first")
    assert repeated.id == first.id

    assert {:ok, second} = SessionWorkspaces.ensure(agent.uid, "signal-channel:lark:second")
    assert second.id > first.id
  end
end
