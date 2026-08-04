defmodule AnkoleWeb.AgentComputerWorkerControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin lists workers ordered newest first", %{conn: conn} do
    %{worker_id: older_id} =
      insert_worker!(%{status: "ready", inserted_at_diff_seconds: -120})

    %{worker_id: newer_id} =
      insert_worker!(%{status: "stale", inserted_at_diff_seconds: -30})

    conn = bearer_conn(conn) |> get(~p"/api/v1/agent-computer-workers")

    assert %{"workers" => [first, second]} = json_response(conn, 200)
    assert first["worker_id"] == newer_id
    assert first["status"] == "stale"
    refute Map.has_key?(first, "transport_route")

    assert second["worker_id"] == older_id
    assert second["status"] == "ready"
    refute Map.has_key?(second, "transport_route")

    assert is_binary(first["inserted_at"])
    assert is_binary(first["updated_at"])
  end

  test "listing workers does not leak transport_route", %{conn: conn} do
    %{worker_id: worker_id} = insert_worker!(%{status: "ready", inserted_at_diff_seconds: -5})

    conn = bearer_conn(conn) |> get(~p"/api/v1/agent-computer-workers")

    [worker] = json_response(conn, 200)["workers"]
    assert worker["worker_id"] == worker_id
    refute Map.has_key?(worker, "transport_route")
  end

  test "missing bearer token is rejected", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/agent-computer-workers")
    assert json_response(conn, 401)
  end

  defp bearer_conn(conn) do
    conn
    |> active_admin_conn()
    |> post(~p"/.internal-apis/oauth/token", %{
      "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
    |> then(fn access_token ->
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("content-type", "application/json")
    end)
  end

  defp active_admin_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("worker-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end

  defp insert_worker!(opts) do
    now = DateTime.utc_now(:microsecond)
    offset = opts[:inserted_at_diff_seconds] || 0
    stamp = DateTime.add(now, offset, :second)
    route = "route-#{System.unique_integer([:positive])}"
    worker_id = "worker-#{System.unique_integer([:positive])}"

    worker =
      %AgentComputerWorker{
        worker_id: worker_id,
        incarnation_id: Ecto.UUID.generate(),
        status: opts[:status] || "ready",
        version: "test",
        capacity: %{"available_turn_slots" => 4, "max_turns" => 9},
        load: %{"active_turns" => 1},
        transport_route: route,
        last_worker_heartbeat_at: stamp,
        started_at: stamp,
        inserted_at: stamp,
        updated_at: stamp,
        metadata: %{"runtime" => "test"}
      }
      |> Ecto.Changeset.change()
      |> Repo.insert!()

    %{worker_id: worker.worker_id, transport_route: route, row: worker}
  end
end
