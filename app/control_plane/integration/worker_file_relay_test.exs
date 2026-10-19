defmodule Ankole.WorkerFileRelayIntegrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.WorkerFiles.Relay

  setup do
    server = start_supervised!({Bandit, plug: AnkoleWeb.Endpoint, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    previous = Application.get_env(:ankole, :runtime_fabric_internal_origin)
    Application.put_env(:ankole, :runtime_fabric_internal_origin, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ankole, :runtime_fabric_internal_origin, previous),
        else: Application.delete_env(:ankole, :runtime_fabric_internal_origin)
    end)

    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

    worker = %{
      Repo.get!(AgentWorker, agent.uid)
      | incarnation_id: "incarnation-relay-http",
        transport_route: "route-relay-http"
    }

    %{worker: AgentWorkers.target(worker)}
  end

  test "the issuing node serves a pull once over its actual internal URL", %{worker: worker} do
    source = Path.join(System.tmp_dir!(), "relay-http-#{System.unique_integer([:positive])}")
    File.write!(source, "relayed over HTTP")
    on_exit(fn -> File.rm(source) end)

    assert {:ok, %{url: url}} =
             Relay.open(%{
               worker: worker,
               direction: :pull,
               source: {:file, source},
               max_bytes: 1024,
               ttl_ms: 60_000
             })

    assert URI.parse(url).host == "127.0.0.1"
    assert %{status: 200, body: "relayed over HTTP"} = Req.get!(url, retry: false)
    assert %{status: 409} = Req.get!(url, retry: false)
  end

  test "the issuing node delivers a push to its consumer with chunk acknowledgements", %{
    worker: worker
  } do
    body = :binary.copy("relay bytes", 24_000)

    assert {:ok, %{url: url, transfer_id: id}} =
             Relay.open(%{
               worker: worker,
               direction: :push,
               consumer: self(),
               max_bytes: byte_size(body),
               ttl_ms: 60_000
             })

    request =
      Task.async(fn ->
        Req.put!(url,
          body: body,
          headers: [{"content-type", "application/octet-stream"}],
          retry: false
        )
      end)

    assert_receive {:relay_opened, ^id, relay, size}, 5_000
    assert size == byte_size(body)
    assert receive_body(id, relay, []) == body
    assert %{status: 200} = Task.await(request, 5_000)
  end

  @tag timeout: 180_000
  test "a full mapped sync batch above the ordinary upload limit crosses the real HTTP relay" do
    allow_cache_database_access()
    Ankole.AppConfigure.Cache.clear_for_test()
    context = Ankole.PodSyncFixtures.binding_attempt_fixture()
    initial_version = Repo.get!(Ankole.Pod.DbTable, context.table.id).data_version
    expected_version = initial_version + 1
    route = "sync-large-relay-#{System.unique_integer([:positive])}"
    value = :binary.copy("x", 900_000)
    rows = for id <- 1..200, do: %{external_id: "record-#{id}", data: %{"title" => value}}
    json = Torque.encode!(rows)
    assert byte_size(json) > Ankole.WorkerFiles.max_transfer_bytes()
    Ankole.WorkerFilesFake.start!(route, files: %{"sync.json" => json}, http: true)
    worker = %{Repo.get!(AgentWorker, context.agent) | state: "ready", transport_route: route}
    target = AgentWorkers.target(worker)

    assert {:error, %{"code" => "file_too_large"}} =
             Ankole.WorkerFiles.stream("sync.json", worker: target)

    request = %Ankole.RuntimeFabric.V1.PodSyncRequest{
      binding_id: context.binding.id,
      automation_job_run_id: to_string(context.run.id),
      attempt_id: context.run.attempt_id,
      records_home_relative_path: "sync.json",
      cursor_json: "{\"page\":1}"
    }

    assert {:ok, %{"result" => %{changed_ids: ids, data_version: ^expected_version}}} =
             Ankole.Pod.RPCBroker.handle_sync(context.agent, request, %{
               route: route,
               worker_id: context.agent,
               request_id: "large-sync"
             })

    assert length(ids) == 200
    assert Repo.aggregate(Ankole.Pod.DbRecord, :count) == 200
    assert %{cursor: %{"page" => 1}} = Repo.get!(Ankole.Pod.DbSyncBinding, context.binding.id)
    assert Ankole.WorkerFiles.max_transfer_bytes() == 100 * 1024 * 1024
  end

  defp receive_body(id, relay, chunks) do
    receive do
      {:relay_chunk, ^id, chunk} ->
        assert byte_size(chunk) <= 64 * 1024
        send(relay, {:relay_ack, id})
        receive_body(id, relay, [chunk | chunks])

      {:relay_done, ^id} ->
        chunks |> Enum.reverse() |> IO.iodata_to_binary()
    after
      5_000 -> flunk("relay did not deliver its body")
    end
  end
end
