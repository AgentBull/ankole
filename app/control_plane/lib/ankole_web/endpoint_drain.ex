defmodule AnkoleWeb.EndpointDrain do
  @moduledoc """
  Tracks HTTP readiness and delays Endpoint shutdown during graceful draining.

  Started immediately after `AnkoleWeb.Endpoint` at the tail of
  `Ankole.Supervisor`, this process marks the node ready once every control-plane
  subsystem and HTTP listener is up, and terminates first when the BEAM receives
  `SIGTERM`. Flipping readiness to `:draining` and pausing before `Endpoint`
  stops lets Kubernetes EndpointSlices, `ingress-nginx`, and external health
  probes stop routing new requests while in-flight requests finish cleanly.
  """

  use GenServer

  @state_key {__MODULE__, :state}
  @lifecycle_topic "ankole:node_lifecycle"

  @type status :: :starting | :ready | :draining

  @doc false
  @spec default_state_key() :: {module(), :state}
  def default_state_key, do: @state_key

  @doc false
  @spec lifecycle_topic() :: String.t()
  def lifecycle_topic, do: @lifecycle_topic

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    drain_delay_ms = resolve_drain_delay_ms(opts)

    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: max(drain_delay_ms + 5_000, 5_000),
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Returns the current node readiness state."
  @spec status(term()) :: status()
  def status(state_key \\ @state_key) do
    :persistent_term.get(state_key, :starting)
  end

  @doc "Whether this node is ready to receive newly routed traffic."
  @spec ready?(term()) :: boolean()
  def ready?(state_key \\ @state_key), do: status(state_key) == :ready

  @doc "Whether this node has begun graceful shutdown draining."
  @spec draining?(term()) :: boolean()
  def draining?(state_key \\ @state_key), do: status(state_key) == :draining

  @doc false
  @spec call_health_plug(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call_health_plug(conn, state_key \\ @state_key)

  def call_health_plug(%Plug.Conn{method: method, path_info: ["_internal", "health"]} = conn, key)
      when method in ["GET", "HEAD"] do
    case status(key) do
      :ready -> send_health_json(conn, 200, ~s({"status":"ok"}))
      :draining -> send_health_json(conn, 503, ~s({"status":"draining"}))
      :starting -> send_health_json(conn, 503, ~s({"status":"starting"}))
    end
  end

  def call_health_plug(%Plug.Conn{method: method, path_info: ["_internal", "live"]} = conn, _key)
      when method in ["GET", "HEAD"] do
    send_health_json(conn, 200, ~s({"status":"ok"}))
  end

  def call_health_plug(conn, _key), do: conn

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state_key = Keyword.get(opts, :state_key, @state_key)
    :persistent_term.put(state_key, :ready)

    {:ok,
     %{
       state_key: state_key,
       drain_delay_ms: resolve_drain_delay_ms(opts)
     }}
  end

  @impl true
  def terminate(_reason, %{state_key: state_key, drain_delay_ms: drain_delay_ms}) do
    :persistent_term.put(state_key, :draining)
    notify_draining(state_key)

    if drain_delay_ms > 0 do
      Process.sleep(drain_delay_ms)
    end

    :ok
  end

  defp notify_draining(state_key) do
    if is_pid(Process.whereis(Ankole.PubSub)) do
      Phoenix.PubSub.broadcast(
        Ankole.PubSub,
        @lifecycle_topic,
        {:endpoint_draining, state_key, node()}
      )
    end
  rescue
    _ -> :ok
  end

  defp resolve_drain_delay_ms(opts) do
    opts
    |> Keyword.get(
      :drain_delay_ms,
      Application.get_env(:ankole, :endpoint_drain_delay_ms, 0)
    )
    |> max(0)
  end

  defp send_health_json(%Plug.Conn{method: "HEAD"} = conn, code, _body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(code, "")
    |> Plug.Conn.halt()
  end

  defp send_health_json(conn, code, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(code, body)
    |> Plug.Conn.halt()
  end
end
