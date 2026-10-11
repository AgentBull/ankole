defmodule AnkoleWeb.WorkerFileRelayControllerTest do
  use AnkoleWeb.ConnCase, async: true

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.WorkerFiles.Relay

  test "a pull serves the source once to the token of its session", %{conn: conn} do
    source = Path.join(System.tmp_dir!(), "relay-source-#{System.unique_integer([:positive])}")
    File.write!(source, "relayed bytes")
    on_exit(fn -> File.rm(source) end)

    {:ok, %{transfer_id: transfer_id, url: url}} =
      open(direction: :pull, source: {:file, source}, max_bytes: 1024)

    path = "/internal/runtime-fabric/file-relay/#{transfer_id}"

    assert %{status: 404} =
             get(conn, "/internal/runtime-fabric/file-relay/#{Ecto.UUID.generate()}")

    assert %{status: 401} = get(conn, path <> "?token=forged")
    assert %{status: 405} = put(conn, url)

    assert %{status: 200, resp_body: "relayed bytes"} = get(conn, url)
    assert %{status: 409} = get(conn, url)
  end

  test "a push refuses a body over its bound before it reads the body", %{conn: conn} do
    {:ok, %{url: url}} = open(direction: :push, consumer: self(), max_bytes: 4)

    assert %{status: 413} =
             conn
             |> put_req_header("content-type", "application/octet-stream")
             |> put_req_header("content-length", "10")
             |> put(url, "0123456789")

    refute_received {:relay_opened, _transfer_id, _relay, _size}
  end

  test "a push needs the length of its body", %{conn: conn} do
    {:ok, %{url: url}} = open(direction: :push, consumer: self(), max_bytes: 4)

    assert %{status: 411} = put(conn, url)
  end

  defp open(attrs) do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

    worker = %{
      Ankole.Repo.get!(AgentWorker, agent.uid)
      | incarnation_id: "incarnation-relay",
        transport_route: "route-relay"
    }

    attrs
    |> Map.new()
    |> Map.merge(%{worker: AgentWorkers.target(worker), ttl_ms: 60_000})
    |> Relay.open()
  end
end
