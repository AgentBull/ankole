defmodule Ankole.Logging.JSONFormatterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ankole.Logging.JSONFormatter

  @formatter_config %{
    environment: "test",
    labels: %{
      "service" => "ankole-control-plane",
      "component" => "control-plane",
      "runtime" => "beam"
    }
  }

  test "failure diagnostics retain call sites without function arguments or exception messages" do
    secret = "diagnostic-secret-should-not-escape"

    try do
      :erlang.binary_to_integer(secret)
    rescue
      error in ArgumentError ->
        assert inspect(__STACKTRACE__) =~ secret
        fields = Ankole.Logging.failure_fields(:error, error, __STACKTRACE__)
        assert fields.failure == "Elixir.ArgumentError"
        assert fields.stacktrace =~ ":erlang.binary_to_integer/1"
        assert fields.stacktrace =~ "json_formatter_test.exs:"
        refute inspect(fields) =~ secret
    else
      _ -> flunk("Expected an invalid integer error")
    end
  end

  test "application startup attaches the Phoenix request log handler" do
    assert Enum.any?(
             :telemetry.list_handlers([:phoenix, :endpoint, :stop]),
             &(&1.id == AnkoleWeb.RequestLogger)
           )
  end

  test "raw caught failures share classification without disclosing their reason" do
    secret = "caught-secret-should-not-escape"

    for {kind, expected} <- [error: "Elixir.ErlangError", exit: "exit", throw: "throw"] do
      try do
        :erlang.raise(kind, secret, [])
      catch
        ^kind, reason ->
          fields = Ankole.Logging.failure_fields(kind, reason, __STACKTRACE__)
          assert fields.failure == expected
          refute inspect(fields) =~ secret
      end
    end
  end

  test "attachment replaces a handler from an earlier application start" do
    assert :ok = AnkoleWeb.RequestLogger.attach()
    assert :ok = AnkoleWeb.RequestLogger.attach()

    assert 1 ==
             Enum.count(
               :telemetry.list_handlers([:phoenix, :endpoint, :stop]),
               &(&1.id == AnkoleWeb.RequestLogger)
             )
  end

  test "a Phoenix endpoint request emits one completion log" do
    log =
      capture_log([format: "$metadata$message\n", metadata: [:event]], fn ->
        conn = AnkoleWeb.ConnCase.build_conn()

        response =
          Phoenix.ConnTest.dispatch(conn, AnkoleWeb.Endpoint, :get, "/api/v1/agents", nil)

        assert response.status == 401
      end)

    assert length(Regex.scan(~r/event=http\.request\.completed/, log)) == 1
    assert log =~ "http request completed"
  end

  test "formats a structured JSON entry without level aliases" do
    entry =
      format(%{
        level: :notice,
        msg: {:string, "worker ready sent"},
        meta: %{
          time: 1_700_000_000_000_000,
          event: :worker_ready_sent,
          labels: %{component: "runtime-fabric"},
          worker_id: "worker-1"
        }
      })

    refute Map.has_key?(entry, "level")
    assert entry["severity"] == "NOTICE"
    assert entry["message"] == "worker ready sent"
    assert entry["time"] == "2023-11-14T22:13:20.000000Z"
    assert entry["event"] == "worker_ready_sent"
    assert entry["worker_id"] == "worker-1"

    assert entry["labels"] == %{
             "service" => "ankole-control-plane",
             "component" => "runtime-fabric",
             "runtime" => "beam",
             "environment" => "test"
           }
  end

  test "capability tokens cannot escape through plain messages or nested report fields" do
    for token <- ["wh_test-secret_123", "%77%68%5Ftest%2Dsecret_123"] do
      entry =
        format(%{
          level: :info,
          msg: {:string, "POST /webhooks/#{token}?mode=sync"},
          meta: %{payload: %{request: %{path: "/webhooks/#{token}"}, status: 400}}
        })

      refute Jason.encode!(entry) =~ token
      assert entry["severity"] == "INFO"
      assert entry["status"] == 400
      assert entry["message"] =~ "?mode=sync"
    end
  end

  test "promotes operation, http_request, insert_id, and trace fields" do
    entry =
      format(%{
        level: :error,
        msg: {:string, "request failed"},
        meta: %{
          event: "http.request.completed",
          operation: %{id: "rpc-1", producer: "ankole-control-plane/runtime-fabric-rpc"},
          http_request: %{"requestMethod" => "GET", "status" => 503},
          insert_id: "insert-1",
          trace: "projects/p/traces/t",
          span_id: "span-1",
          trace_sampled: true,
          rpc_request_id: "rpc-1"
        }
      })

    assert entry["severity"] == "ERROR"

    assert entry["operation"] == %{
             "id" => "rpc-1",
             "producer" => "ankole-control-plane/runtime-fabric-rpc"
           }

    assert entry["http_request"] == %{"requestMethod" => "GET", "status" => 503}
    assert entry["insert_id"] == "insert-1"
    assert entry["trace"] == "projects/p/traces/t"
    assert entry["span_id"] == "span-1"
    assert entry["trace_sampled"] == true
    assert entry["rpc_request_id"] == "rpc-1"
  end

  test "formats string special metadata keys" do
    entry =
      format(%{
        level: :notice,
        msg: {:string, "runtime fabric started"},
        meta: %{
          "labels" => %{component: "runtime-fabric"},
          "operation" => %{id: "rpc-1", producer: "runtime-fabric"},
          event: "runtime.fabric.started",
          payload: %{"signal_id" => "event-1"}
        }
      })

    assert entry["severity"] == "NOTICE"
    assert entry["event"] == "runtime.fabric.started"
    assert entry["signal_id"] == "event-1"
    assert entry["labels"]["component"] == "runtime-fabric"

    assert entry["operation"] == %{
             "id" => "rpc-1",
             "producer" => "runtime-fabric"
           }
  end

  test "payload fields cannot override the logging contract or emit old compatibility fields" do
    entry =
      format(%{
        level: :info,
        msg: {:string, "real message"},
        meta: %{
          event: "contract.event",
          payload: %{
            "severity" => "ERROR",
            "level" => 50,
            "severity_text" => "ERROR",
            "severity_number" => 17,
            "message" => "fake message",
            "time" => "2000-01-01T00:00:00Z",
            "event" => "fake.event",
            "logging.googleapis.com/labels" => %{"component" => "old"},
            "logging.googleapis.com/operation" => %{"id" => "old"},
            "logging.googleapis.com/insertId" => "old",
            "worker_id" => "worker-1"
          }
        }
      })

    assert entry["severity"] == "INFO"
    assert entry["message"] == "real message"
    assert entry["event"] == "contract.event"
    assert entry["worker_id"] == "worker-1"
    refute Map.has_key?(entry, "level")
    refute Map.has_key?(entry, "severity_text")
    refute Map.has_key?(entry, "severity_number")
    refute Enum.any?(Map.keys(entry), &String.starts_with?(&1, "logging.googleapis.com/"))
  end

  test "drops console formatter metadata from Ecto logs" do
    entry =
      format(%{
        level: :debug,
        msg: {:string, "QUERY OK source=\"app_configurations\" db=1.9ms"},
        meta: %{
          ansi_color: :cyan,
          source: "app_configurations",
          query: "SELECT a0.\"scope\" FROM \"app_configurations\" AS a0 []"
        }
      })

    refute Map.has_key?(entry, "ansi_color")
    assert entry["source"] == "app_configurations"
    assert entry["query"] =~ "SELECT"
  end

  test "uses Logger's human-readable translation for Erlang reports" do
    entry =
      format(%{
        level: :notice,
        msg:
          {:report,
           %{
             label: {:application_controller, :exit},
             report: [application: :ankole, exited: :stopped, type: :temporary],
             elixir_translation: ["Application ", "ankole", " exited: " | ":stopped"]
           }},
        meta: %{
          error_logger: %{
            report_cb: "&:application_controller.format_log/1",
            tag: :info_report,
            type: :std_info
          }
        }
      })

    assert entry["message"] == "Application ankole exited: :stopped"
    assert entry["error_logger"]["tag"] == "info_report"
  end

  test "Phoenix request logger emits http_request with error severity for 5xx" do
    conn =
      :get
      |> Plug.Test.conn("/boom")
      |> Map.put(:host, "ankole.test")
      |> Map.put(:port, 443)
      |> Map.put(:scheme, :https)
      |> Map.put(:status, 503)
      |> Plug.Conn.put_req_header("user-agent", "curl/8")
      |> Plug.Conn.put_resp_header("x-request-id", "request-1")

    duration = System.convert_time_unit(125, :millisecond, :native)

    {level, fields} = AnkoleWeb.RequestLogger.build_log(%{duration: duration}, %{conn: conn})

    entry =
      format(%{
        level: level,
        msg: {:string, "http request completed"},
        meta: Map.put(fields, :event, "http.request.completed")
      })

    assert entry["severity"] == "ERROR"
    assert entry["event"] == "http.request.completed"
    assert entry["request_id"] == "request-1"
    assert entry["duration_ms"] == 125
    assert entry["http_request"]["requestMethod"] == "GET"
    assert entry["http_request"]["requestURL"] == "https://ankole.test/boom"
    assert entry["http_request"]["remoteIP"] == "127.0.0.1"
    assert entry["http_request"]["status"] == 503
    assert entry["http_request"]["userAgent"] == "curl/8"
  end

  test "Phoenix request logger keeps a slow successful AI request at info" do
    conn =
      :post
      |> Plug.Test.conn("/api/v1/ai-gateway/responses")
      |> Map.put(:host, "ankole.test")
      |> Map.put(:status, 200)
      |> Map.put(:private, %{phoenix_route: "/api/v1/ai-gateway/responses"})

    duration = System.convert_time_unit(65, :second, :native)

    {level, fields} = AnkoleWeb.RequestLogger.build_log(%{duration: duration}, %{conn: conn})

    assert level == :info
    assert fields.duration_ms == 65_000
    assert fields.route == "/api/v1/ai-gateway/responses"
    assert fields.http_request["latency"] == "65.000000s"

    routed_conn =
      :get
      |> Plug.Test.conn("/.internal-apis/pod/pages/123")
      |> Map.put(:host, "ankole.test")
      |> Map.put(:status, 200)
      |> Plug.Conn.put_private(:phoenix_router, AnkoleWeb.Router)

    assert {:info, %{route: "/.internal-apis/pod/pages/:id"}} =
             AnkoleWeb.RequestLogger.build_log(%{duration: 0}, %{conn: routed_conn})
  end

  test "Phoenix request logger never emits callback capability tokens" do
    conn =
      :post
      |> Plug.Test.conn("/webhooks/v1/event-callbacks/wh_secret-capability-token")
      |> Map.put(:host, "ankole.test")
      |> Map.put(:status, 204)

    {level, fields} = AnkoleWeb.RequestLogger.build_log(%{duration: 0}, %{conn: conn})

    assert level == :info
    assert fields.route == "/webhooks/v1/event-callbacks/[REDACTED]"

    assert fields.http_request["requestURL"] ==
             "http://ankole.test/webhooks/v1/event-callbacks/[REDACTED]"

    refute inspect(fields) =~ "wh_secret-capability-token"
  end

  defp format(event) do
    event
    |> JSONFormatter.format(@formatter_config)
    |> IO.iodata_to_binary()
    |> decode_log()
  end

  defp decode_log(log) do
    log
    |> String.trim()
    |> Ankole.JSON.decode!()
  end
end
