defmodule Ankole.Logging.JSONFormatterTest do
  use ExUnit.Case, async: true

  alias Ankole.Logging.JSONFormatter

  @formatter_config %{
    environment: "test",
    labels: %{
      "service" => "ankole-control-plane",
      "component" => "control-plane",
      "runtime" => "beam"
    }
  }

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
          payload: %{"actor_event_id" => "event-1"}
        }
      })

    assert entry["severity"] == "NOTICE"
    assert entry["event"] == "runtime.fabric.started"
    assert entry["actor_event_id"] == "event-1"
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
        msg: {:string, "QUERY OK source=\"app_configure\" db=1.9ms"},
        meta: %{
          ansi_color: :cyan,
          source: "app_configure",
          query: "SELECT a0.\"scope\" FROM \"app_configure\" AS a0 []"
        }
      })

    refute Map.has_key?(entry, "ansi_color")
    assert entry["source"] == "app_configure"
    assert entry["query"] =~ "SELECT"
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
    assert entry["http_request"]["requestUrl"] == "https://ankole.test/boom"
    assert entry["http_request"]["status"] == 503
    assert entry["http_request"]["userAgent"] == "curl/8"
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
