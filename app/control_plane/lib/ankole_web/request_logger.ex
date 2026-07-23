defmodule AnkoleWeb.RequestLogger do
  @moduledoc """
  Emits one structured request log for completed Phoenix requests.
  """

  use GenServer

  alias Ankole.Logging

  @handler_id __MODULE__
  @event [:phoenix, :endpoint, :stop]

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, %{})
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(@event, measurements, %{conn: conn}, _config) do
    {level, fields} = build_log(measurements, %{conn: conn})

    case level do
      :error -> Logging.error("http.request.completed", "http request completed", fields)
      :warning -> Logging.warning("http.request.completed", "http request completed", fields)
      :info -> Logging.info("http.request.completed", "http request completed", fields)
    end
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  @spec build_log(map(), %{conn: Plug.Conn.t()}) :: {:info | :warning | :error, map()}
  def build_log(measurements, %{conn: conn}) do
    duration_us = duration_us(measurements)
    duration_ms = div(duration_us, 1_000)
    status = conn.status || 0

    fields = %{
      http_request: http_request(conn, status, duration_us),
      request_id: request_id(conn),
      route: route(conn),
      duration_ms: duration_ms
    }

    {request_level(status), fields}
  end

  defp http_request(conn, status, duration_us) do
    %{
      "requestMethod" => conn.method,
      "requestURL" => request_url(conn),
      "status" => status,
      "latency" => latency(duration_us),
      "remoteIP" => remote_ip(conn.remote_ip),
      "userAgent" => req_header(conn, "user-agent"),
      "protocol" => conn_adapter(conn)
    }
  end

  defp request_level(status) when status >= 500, do: :error
  defp request_level(status) when status in [401, 403, 429], do: :warning
  defp request_level(_status), do: :info

  defp duration_us(%{duration: duration}) when is_integer(duration) do
    System.convert_time_unit(duration, :native, :microsecond)
  end

  defp duration_us(_measurements), do: 0

  defp latency(duration_us) do
    seconds = duration_us / 1_000_000
    :erlang.float_to_binary(seconds, decimals: 6) <> "s"
  end

  defp request_url(conn) do
    scheme = conn.scheme |> to_string()
    host = conn.host || "unknown"
    port = conn.port || default_port(conn.scheme)
    path = conn.request_path || "/"

    "#{scheme}://#{host}#{port_fragment(conn.scheme, port)}#{path}"
  end

  defp port_fragment(:http, 80), do: ""
  defp port_fragment(:https, 443), do: ""
  defp port_fragment(_scheme, port), do: ":#{port}"

  defp default_port(:https), do: 443
  defp default_port(_scheme), do: 80

  defp remote_ip(nil), do: nil

  defp remote_ip(ip) when is_tuple(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  end

  defp remote_ip(value), do: to_string(value)

  defp req_header(conn, name) do
    conn
    |> Plug.Conn.get_req_header(name)
    |> List.first()
  end

  defp conn_adapter(%{adapter: {adapter, _state}}) when is_atom(adapter),
    do: Atom.to_string(adapter)

  defp conn_adapter(_conn), do: nil

  defp request_id(conn), do: List.first(Plug.Conn.get_resp_header(conn, "x-request-id"))

  defp route(conn) do
    conn.private[:phoenix_route] || conn.request_path
  end
end
