defmodule Ankole.WorkerFiles.Relay do
  @moduledoc """
  One-time relay session between a drive RPC and the Worker that called it.

  File bytes do not travel inside RuntimeFabric. The control-plane Pod that
  serves the RPC opens a relay session, gives the Worker a URL on this Pod
  with a random token, and the Worker moves the bytes over HTTP:

    * `:pull` — the Worker `GET`s the URL and receives the source bytes.
    * `:push` — the Worker `PUT`s the file bytes, and the session's consumer
      process receives them chunk by chunk.

  The URL origin must reach this Pod because the session lives only in this
  process tree. A provider can supply an address that routes to this node;
  otherwise the relay uses this Pod's internal address. A session has one
  method, one byte bound, and one expiry; it
  is consumed by the first accepted request and stops when its owner exits.
  The session and its token exist only in this process, so the token needs no
  signature: the relay compares it with the session's own copy. It is a
  bearer credential; only `AnkoleWeb.WorkerFileRelayController` reads it and
  it must not be logged.
  """

  use GenServer, restart: :temporary

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers

  @registry Ankole.WorkerFiles.RelayRegistry
  @supervisor Ankole.WorkerFiles.RelaySupervisor
  @path_prefix "/internal/runtime-fabric/file-relay"

  @type source :: {:file, Path.t()}

  @type session :: %{
          transfer_id: String.t(),
          method: String.t(),
          max_bytes: pos_integer(),
          expires_at: DateTime.t(),
          source: source() | nil,
          consumer: pid() | nil
        }

  @type consume_error :: :not_found | :invalid_token | :consumed | :expired | :method_mismatch

  @doc """
  Opens a session and returns the URL the Worker must call.

  `attrs` carries `:direction`, `:worker` (a `WorkerRoute` target),
  `:max_bytes`, `:ttl_ms`, `:owner`, and either
  `:source` (pull) or `:consumer` (push).
  """
  @spec open(map()) ::
          {:ok, %{transfer_id: String.t(), url: String.t(), expires_at: DateTime.t()}}
          | {:error, term()}
  def open(%{direction: direction, worker: worker} = attrs)
      when direction in [:pull, :push] do
    with {:ok, endpoints} <- Providers.connection_endpoints(worker.worker_id) do
      open_session(attrs, endpoints["relayOrigin"] || origin())
    end
  end

  defp open_session(%{direction: direction} = attrs, origin) do
    transfer_id = Ecto.UUID.generate()
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), attrs.ttl_ms, :millisecond)
    method = if direction == :pull, do: "GET", else: "PUT"

    session = %{
      transfer_id: transfer_id,
      method: method,
      max_bytes: attrs.max_bytes,
      expires_at: expires_at,
      source: Map.get(attrs, :source),
      consumer: Map.get(attrs, :consumer)
    }

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        @supervisor,
        {__MODULE__, session: session, token: token, owner: Map.get(attrs, :owner, self())}
      )

    url =
      String.trim_trailing(origin, "/") <>
        @path_prefix <> "/" <> transfer_id <> "?token=" <> token

    {:ok, %{transfer_id: transfer_id, url: url, expires_at: expires_at}}
  end

  @doc """
  Verifies one relay request and marks the session consumed.
  """
  @spec consume(String.t(), String.t(), String.t() | nil) ::
          {:ok, session()} | {:error, consume_error()}
  def consume(transfer_id, method, token) when is_binary(transfer_id) and is_binary(method) do
    case Registry.lookup(@registry, transfer_id) do
      [{pid, _value}] ->
        try do
          GenServer.call(pid, {:consume, method, token})
        catch
          :exit, _reason -> {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Stops a session. Relay handlers that still run for it observe the exit.
  """
  @spec close(String.t()) :: :ok
  def close(transfer_id) when is_binary(transfer_id) do
    case Registry.lookup(@registry, transfer_id) do
      [{pid, _value}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns the origin that Workers use to reach this control-plane Pod.
  """
  @spec origin() :: String.t()
  def origin do
    case Application.get_env(:ankole, :runtime_fabric_internal_origin) do
      origin when is_binary(origin) and origin != "" ->
        String.trim_trailing(origin, "/")

      _unset ->
        port = Keyword.get(AnkoleWeb.Endpoint.config(:http) || [], :port, 4000)
        "http://127.0.0.1:#{port}"
    end
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {@registry, session.transfer_id}}
    )
  end

  @impl true
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)
    ttl_ms = max(DateTime.diff(session.expires_at, DateTime.utc_now(), :millisecond), 0)
    Process.send_after(self(), :expire, ttl_ms)

    {:ok, %{session: session, token: Keyword.fetch!(opts, :token), consumed?: false}}
  end

  @impl true
  def handle_call({:consume, method, token}, _from, state) do
    cond do
      not is_binary(token) or not Plug.Crypto.secure_compare(token, state.token) ->
        {:reply, {:error, :invalid_token}, state}

      method != state.session.method ->
        {:reply, {:error, :method_mismatch}, state}

      DateTime.compare(DateTime.utc_now(), state.session.expires_at) == :gt ->
        {:reply, {:error, :expired}, state}

      state.consumed? ->
        {:reply, {:error, :consumed}, state}

      true ->
        {:reply, {:ok, state.session}, %{state | consumed?: true}}
    end
  end

  @impl true
  def handle_info(:expire, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, _ref, :process, _owner, _reason}, state), do: {:stop, :normal, state}

  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn state ->
      %{state | token: "[redacted]", session: Map.put(state.session, :source, :redacted)}
    end)
  end
end
