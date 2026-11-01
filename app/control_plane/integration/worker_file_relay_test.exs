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
      Repo.get_by!(AgentWorker, agent_uid: agent.uid)
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

  test "the real Worker relays only the prefix of an online file larger than 16 KiB", %{
    worker: worker
  } do
    root = Path.join(System.tmp_dir!(), "worker-prefix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    content = String.duplicate("text before UTF-8 boundary\n", 2_000)
    File.write!(Path.join(root, "large.txt"), content)

    assert {:ok, %{url: url, transfer_id: id}} =
             Relay.open(%{
               worker: worker,
               direction: :push,
               consumer: self(),
               max_bytes: 16_384,
               ttl_ms: 60_000
             })

    relay_module = Path.expand("../../agent_computer/src/lanes/file/relay.ts", __DIR__)

    script = """
    import { pushFile } from #{Jason.encode!(relay_module)};
    const result = await pushFile({agentHomeRoot: #{Jason.encode!(root)}}, {
      transferId: #{Jason.encode!(id)}, url: #{Jason.encode!(url)},
      homeRelativePath: 'large.txt', maxBytes: 16384n, prefixBytes: 16384n
    });
    console.log(JSON.stringify(result));
    """

    request = Task.async(fn -> System.cmd("bun", ["--eval", script], stderr_to_stdout: true) end)
    assert_receive {:relay_opened, ^id, relay, 16_384}, 5_000
    assert receive_body(id, relay, []) == binary_part(content, 0, 16_384)
    assert {result, 0} = Task.await(request, 5_000)
    assert Jason.decode!(String.trim(result)) == %{"size" => 16_384}
  end

  @tag timeout: 180_000
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
