defmodule Ankole.FunctionRuntimeHelpers do
  @moduledoc false
  import ExUnit.Assertions
  alias Ankole.FunctionRuntime.{EndpointPool, HTTP}

  def saturate(lane \\ :route) do
    isolate_runtime(lane)
    {:ok, endpoint, lease} = EndpointPool.checkout()
    source = "export default {'GET /':()=>true}"
    digest = :crypto.hash(:sha256, source <> "\n[]") |> Base.encode16(case: :lower)

    assert {:ok, 204, _} =
             HTTP.at(
               endpoint,
               :put,
               "/v1/applet/code/" <> digest,
               %{source: source, env: %{}},
               5_000
             )

    if lane == :action,
      do: Ankole.AppConfigure.put_global_by_key("pod.applet.action_runtime_url", endpoint.url)

    {endpoint, lease, reserve(endpoint, digest, lane, [])}
  end

  def release({endpoint, lease, ids}) do
    Enum.each(ids, fn id ->
      assert {:ok, 204, _} =
               HTTP.at(endpoint, :delete, "/v1/applet/invocations/" <> id, %{}, 5_000)
    end)

    EndpointPool.release(lease)
  end

  # Saturation belongs to this test's replica; other OS partitions and the
  # developer's running app continue using the shared devkit service.
  defp isolate_runtime(lane) do
    original = :sys.get_state(EndpointPool)
    container = "ankole-function-capacity-" <> Ash.UUIDv7.generate()
    image = System.get_env("ANKOLE_FUNCTION_RUNTIME_TEST_IMAGE", "ankole-function-runtime:dev")
    token = Application.fetch_env!(:ankole, :function_runtime) |> Keyword.fetch!(:token)

    # An action saturation test must leave room for route-lane package inspection.
    concurrency = if lane == :action, do: 32, else: 1

    docker!([
      "run",
      "--detach",
      "--rm",
      "--pull=never",
      "--name",
      container,
      "--publish",
      "127.0.0.1::9000",
      "--env",
      "ANKOLE_FUNCTION_RUNTIME_TOKEN=" <> token,
      "--env",
      "ANKOLE_FUNCTION_RUNTIME_MAX_CONCURRENCY=#{concurrency}",
      image,
      "start",
      "--main-service",
      "/opt/ankole/function_runtime/main",
      "--port",
      "9000"
    ])

    ExUnit.Callbacks.on_exit(fn ->
      :sys.replace_state(EndpointPool, &%{&1 | uri: original.uri, endpoints: original.endpoints})
      docker!(["rm", "--force", container])
    end)

    url = "http://" <> docker!(["port", container, "9000/tcp"])
    uri = URI.parse(url)

    endpoint = %{
      ip: {127, 0, 0, 1},
      host: uri.host,
      port: uri.port,
      scheme: :http,
      url: url,
      cooldown: System.monotonic_time(:millisecond)
    }

    assert Enum.any?(1..100, fn _ ->
             Process.sleep(50)
             match?({:ok, 200, _}, HTTP.at(endpoint, :get, "/_internal/health", %{}, 500))
           end)

    :sys.replace_state(EndpointPool, &%{&1 | uri: uri, endpoints: %{endpoint.ip => endpoint}})
  end

  defp docker!(args) do
    {output, status} = System.cmd("docker", args, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end

  defp reserve(endpoint, digest, lane, ids) when length(ids) < 256 do
    id = Ash.UUIDv7.generate()

    query =
      URI.encode_query(%{
        run_id: id,
        lane: lane,
        tenant_id: Ankole.Repo.tenant_id!(),
        page_id: "capacity",
        revision: 1,
        sha256: digest,
        timeout_ms: 60_000,
        memory_mb: 64
      })

    case HTTP.at(endpoint, :get, "/v1/applet/invoke?" <> query, %{}, 5_000) do
      {:ok, 204, _} -> reserve(endpoint, digest, lane, [id | ids])
      {:ok, 503, _} -> ids
      other -> flunk("Function runtime preflight failed: #{inspect(other)}")
    end
  end
end
