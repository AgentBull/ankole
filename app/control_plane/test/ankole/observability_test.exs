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

    payload = worker_payload()
    assert :ok = Observability.export_worker_spans(payload)

    assert_receive {:worker_otlp_request, "/otel/v1/traces", headers, ^payload}
    assert headers["authorization"] == "Bearer worker-secret"
    assert headers["content-type"] == "application/x-protobuf"
  end

  test "Langfuse maps worker facts once at the OTLP export boundary" do
    body = export_worker_payload(Ankole.Observability.Providers.Langfuse)
    agent = worker_span_attributes(body, "invoke_agent codex")
    tool = worker_span_attributes(body, "execute_tool skill_view")

    assert agent["langfuse.observation.type"] == "agent"
    assert agent["langfuse.observation.input"] == ~s("inspect the PDF skill")
    assert agent["langfuse.observation.output"] == ~s("skill loaded")
    assert agent["session.id"] == "session-1"
    refute Map.has_key?(agent, "ankole.agent.input")
    refute Map.has_key?(agent, "ankole.agent.output")

    assert tool["langfuse.observation.type"] == "tool"
    assert tool["langfuse.observation.input"] == ~s({"name":"pdf"})
    assert tool["langfuse.observation.output"] == ~s("loaded PDF skill")
    assert tool["gen_ai.tool.name"] == "skill_view"
    refute Map.has_key?(tool, "gen_ai.tool.call.arguments")
    refute Map.has_key?(tool, "gen_ai.tool.call.result")
    refute Enum.any?(Map.keys(tool), &String.starts_with?(&1, "langsmith."))
  end

  test "LangSmith maps the same worker facts without Langfuse attributes" do
    body = export_worker_payload(Ankole.Observability.Providers.LangSmith)
    agent = worker_span_attributes(body, "invoke_agent codex")
    tool = worker_span_attributes(body, "execute_tool skill_view")

    assert agent["langsmith.span.kind"] == "chain"
    assert agent["gen_ai.prompt"] == ~s("inspect the PDF skill")
    assert agent["gen_ai.completion"] == ~s("skill loaded")
    refute Map.has_key?(agent, "ankole.agent.input")
    refute Map.has_key?(agent, "ankole.agent.output")

    assert tool["langsmith.span.kind"] == "tool"
    assert tool["gen_ai.prompt"] == ~s({"name":"pdf"})
    assert tool["gen_ai.completion"] == ~s("loaded PDF skill")
    refute Map.has_key?(tool, "gen_ai.tool.call.arguments")
    refute Map.has_key?(tool, "gen_ai.tool.call.result")
    refute Enum.any?(Map.keys(tool), &String.starts_with?(&1, "langfuse."))
  end

  test "a vendor adapter rejects malformed worker OTLP before export" do
    assert :ok =
             Observability.put_runtime_config_for_test(%{
               provider: Ankole.Observability.Providers.Langfuse,
               endpoint: "http://127.0.0.1:1/otel",
               headers: []
             })

    assert {:error, :invalid_otlp_payload} = Observability.export_worker_spans(<<1, 2, 3>>)
  end

  test "worker span batches are silently dropped when trace export is disabled" do
    assert :ok = Observability.put_runtime_config_for_test(nil)
    assert :ok = Observability.export_worker_spans(<<1, 2, 3>>)
  end

  defp clear_app_configure do
    Registry.clear_for_test()
    Cache.clear_for_test()
  end

  defp export_worker_payload(provider) do
    server =
      start_supervised!(
        {Bandit, plug: {OTLPReceiver, self()}, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    assert :ok =
             Observability.put_runtime_config_for_test(%{
               provider: provider,
               endpoint: "http://127.0.0.1:#{port}/otel",
               headers: []
             })

    assert :ok = Observability.export_worker_spans(worker_payload())
    assert_receive {:worker_otlp_request, "/otel/v1/traces", _headers, body}
    body
  end

  defp worker_payload do
    request = %{
      resource_spans: [
        %{
          resource: %{attributes: []},
          scope_spans: [
            %{
              scope: %{name: "ankole-worker"},
              spans: [
                worker_span("invoke_agent codex", <<1::128>>, <<1::64>>, [
                  string_attribute("gen_ai.operation.name", "invoke_agent"),
                  string_attribute("ankole.agent.input", ~s("inspect the PDF skill")),
                  string_attribute("ankole.agent.output", ~s("skill loaded")),
                  string_attribute("session.id", "session-1")
                ]),
                worker_span("execute_tool skill_view", <<1::128>>, <<2::64>>, [
                  string_attribute("gen_ai.operation.name", "execute_tool"),
                  string_attribute("gen_ai.tool.name", "skill_view"),
                  string_attribute("gen_ai.tool.call.arguments", ~s({"name":"pdf"})),
                  string_attribute("gen_ai.tool.call.result", ~s("loaded PDF skill")),
                  string_attribute("session.id", "session-1")
                ])
              ]
            }
          ]
        }
      ]
    }

    :opentelemetry_exporter_trace_service_pb.encode_msg(
      request,
      :export_trace_service_request
    )
  end

  defp worker_span(name, trace_id, span_id, attributes) do
    %{
      trace_id: trace_id,
      span_id: span_id,
      name: name,
      kind: :SPAN_KIND_INTERNAL,
      start_time_unix_nano: 1,
      end_time_unix_nano: 2,
      attributes: attributes
    }
  end

  defp string_attribute(key, value) do
    %{key: key, value: %{value: {:string_value, value}}}
  end

  defp worker_span_attributes(body, name) do
    decoded =
      :opentelemetry_exporter_trace_service_pb.decode_msg(
        body,
        :export_trace_service_request
      )

    spans =
      for resource <- decoded.resource_spans,
          scope <- resource.scope_spans,
          span <- scope.spans,
          span.name == name,
          do: span

    assert [span] = spans

    Map.new(span.attributes, fn attribute ->
      {attribute.key, elem(attribute.value.value, 1)}
    end)
  end
end
