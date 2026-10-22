defmodule AnkoleWeb.AgentWorkerControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SessionsCase

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin lists the Worker of each Agent without its credential or route", %{conn: conn} do
    %{principal: ready_agent} = agent_fixture()
    %{principal: idle_agent} = agent_fixture()
    route = "route-#{System.unique_integer([:positive])}"
    {:ok, _worker} = SessionsCase.admit_worker(route, %{worker_id: ready_agent.uid})

    workers = console_conn(conn) |> get(~p"/api/v1/agent-workers") |> json_response(200)
    workers = workers["workers"]
    by_agent = Map.new(workers, &{&1["agent_uid"], &1})

    assert %{"state" => "ready", "generation" => generation, "image" => image} =
             by_agent[ready_agent.uid]

    assert is_binary(generation) and is_binary(image)
    assert is_binary(by_agent[ready_agent.uid]["last_worker_heartbeat_at"])
    assert %{"state" => "absent", "generation" => nil} = by_agent[idle_agent.uid]

    agent_uids = Enum.map(workers, & &1["agent_uid"])
    assert agent_uids == Enum.sort(agent_uids)

    for worker <- workers, field <- ~w(token_digest transport_route incarnation_id) do
      refute Map.has_key?(worker, field)
    end
  end

  test "missing browser session is rejected", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/agent-workers")
    assert json_response(conn, 401)
  end
end
