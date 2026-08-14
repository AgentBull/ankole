defmodule Ankole.ObservabilityTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Observability
  alias Ankole.Repo

  defmodule OTLPReceiver do
    @moduledoc false

    import Plug.Conn

    def init(test_pid), do: test_pid

    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)
      send(test_pid, {:worker_otlp_request, conn.request_path, Map.new(conn.req_headers), body})
      send_resp(conn, 200, "")
    end
  end

  setup do
    allow_cache_database_access()
    clear_app_configure()

    on_exit(fn ->
      Observability.put_runtime_config_for_test(nil)
      clear_app_configure()
    end)

    :ok
  end

  test "trace export is disabled by default" do
    assert :ok = Observability.ensure_registered()
    assert {:ok, :disabled} = Observability.runtime_config()

    definitions = Map.new(Observability.definitions(), &{&1.key, &1})

    refute definitions["observability.traces.enabled"].encrypted
    refute definitions["observability.traces.provider"].encrypted
    refute definitions["observability.traces.otlp_endpoint"].encrypted
    assert definitions["observability.traces.otlp_headers"].encrypted
  end

  test "enabled export requires a provider and an OTLP endpoint and keeps headers encrypted" do
    definitions = Map.new(Observability.definitions(), &{&1.key, &1})
    enabled = definitions["observability.traces.enabled"]
    provider = definitions["observability.traces.provider"]
    endpoint = definitions["observability.traces.otlp_endpoint"]
    headers = definitions["observability.traces.otlp_headers"]

    assert :ok = Observability.ensure_registered()
    assert {:ok, true} = AppConfigure.put_global(enabled, true)
    assert {:error, :missing_trace_provider} = Observability.runtime_config()

    assert {:ok, "langfuse"} = AppConfigure.put_global(provider, "langfuse")
    assert {:error, :missing_otlp_endpoint} = Observability.runtime_config()

    assert {:ok, "https://cloud.langfuse.com/api/public/otel"} =
             AppConfigure.put_global(endpoint, " https://cloud.langfuse.com/api/public/otel/ ")

    assert {:ok, %{"Authorization" => "Basic secret"}} =
             AppConfigure.put_global(headers, %{"Authorization" => "Basic secret"})

    assert {:ok,
            %{
              provider: Ankole.Observability.Providers.Langfuse,
              endpoint: "https://cloud.langfuse.com/api/public/otel",
              headers: [{"Authorization", "Basic secret"}]
            }} = Observability.runtime_config()

    row = Repo.get_by!(AppConfig, scope: "global", key: headers.key)
    refute inspect(row) =~ "Basic secret"
    assert row.value["type"] == "cipher"
    refute row.value["value"] =~ "Basic secret"
  end

  test "the base endpoint rejects credentials, query parameters, fragments, and a trace path" do
    endpoint =
      Map.fetch!(
        Map.new(Observability.definitions(), &{&1.key, &1}),
        "observability.traces.otlp_endpoint"
      )

    assert {:error, :not_http_endpoint} =
             Ankole.AppConfigure.Schema.validate(
               endpoint.schema,
               "https://user:secret@example.test/otel"
             )

    assert {:error, :not_http_endpoint} =
             Ankole.AppConfigure.Schema.validate(
               endpoint.schema,
               "https://example.test/otel?token=secret"
             )

    assert {:error, :not_http_endpoint} =
             Ankole.AppConfigure.Schema.validate(
               endpoint.schema,
               "https://example.test/otel#traces"
             )

    assert {:error, :trace_signal_path_not_allowed} =
             Ankole.AppConfigure.Schema.validate(
               endpoint.schema,
               "https://example.test/otel/v1/traces/"
             )
  end

  test "worker span batches use the configured OTLP trace endpoint and headers unchanged" do
    server =
      start_supervised!(
        {Bandit, plug: {OTLPReceiver, self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert :ok =
             Observability.put_runtime_config_for_test(%{
               provider: Ankole.Observability.Providers.OpenTelemetry,
               endpoint: "http://127.0.0.1:#{port}/otel",
               headers: [{"authorization", "Bearer worker-secret"}]
             })

    payload = <<10, 3, 1, 2, 3>>
    assert :ok = Observability.export_worker_spans(payload)

    assert_receive {:worker_otlp_request, "/otel/v1/traces", headers, ^payload}
    assert headers["authorization"] == "Bearer worker-secret"
    assert headers["content-type"] == "application/x-protobuf"
  end

  test "worker span batches are silently dropped when trace export is disabled" do
    assert :ok = Observability.put_runtime_config_for_test(nil)
    assert :ok = Observability.export_worker_spans(<<1, 2, 3>>)
  end

  defp clear_app_configure do
    Registry.clear_for_test()
    Cache.clear_for_test()
  end
end
