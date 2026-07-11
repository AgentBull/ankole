defmodule Ankole.Plugins.SlackAdapter.ConnectionOwner do
  @moduledoc false

  use GenServer

  alias Ankole.Logging
  alias Ankole.Plugins.SlackAdapter.{Config, Dispatcher}

  @registry Ankole.Plugins.SlackAdapter.ConnectionRegistry

  defstruct [
    :key,
    :secret_fingerprint,
    :consumer_fingerprint,
    :consumer_count,
    :consumer_kinds,
    :client,
    :dispatcher,
    :ws_pid,
    :ws_client_module,
    start_client?: true
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    registry = Keyword.get(opts, :registry, @registry)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {registry, Config.connection_key(config)}}
    )
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Config.connection_key(Keyword.fetch!(opts, :config))},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec ensure_consumers(GenServer.server(), map(), [map()]) :: {:ok, pid()} | {:error, term()}
  def ensure_consumers(server, config, consumers),
    do: GenServer.call(server, {:ensure_consumers, config, consumers})

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def format_status(%{state: %__MODULE__{} = state} = status) do
    %{
      status
      | state: %{
          key: state.key,
          consumer_count: state.consumer_count,
          consumer_kinds: state.consumer_kinds,
          ws_pid: state.ws_pid
        }
    }
  end

  def format_status(status), do: status

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)
    consumers = Keyword.get(opts, :consumers, [])
    client = Config.client(config, Keyword.get(opts, :client_opts, []))

    state = %__MODULE__{
      key: Config.connection_key(config),
      secret_fingerprint: Config.secret_fingerprint(config),
      consumer_fingerprint: fingerprint(consumers),
      consumer_count: length(consumers),
      consumer_kinds: consumers |> Enum.map(&Map.get(&1, :kind)) |> Enum.sort(),
      client: client,
      dispatcher: Dispatcher.build(consumers, client: client),
      ws_client_module: Keyword.get(opts, :ws_client_module, SlackOpenAPI.SocketMode.Client),
      start_client?: Keyword.get(opts, :start_client?, true)
    }

    maybe_start_ws(state)
  end

  @impl true
  def handle_call({:ensure_consumers, config, consumers}, _from, state) do
    result =
      cond do
        Config.connection_key(config) != state.key ->
          {:error, :connection_key_mismatch}

        Config.secret_fingerprint(config) != state.secret_fingerprint ->
          {:error, :conflicting_app_secret}

        fingerprint(consumers) != state.consumer_fingerprint ->
          {:error, :consumer_set_changed}

        true ->
          {:ok, self()}
      end

    {:reply, result, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       key: state.key,
       consumer_count: state.consumer_count,
       consumer_kinds: state.consumer_kinds,
       ws_pid: state.ws_pid,
       running?: is_pid(state.ws_pid) and Process.alive?(state.ws_pid)
     }, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{ws_pid: pid} = state) do
    Logging.error(
      "slack_adapter.connection_owner.client_exited",
      "Slack Socket Mode client exited",
      %{connection_key: inspect(state.key), reason: inspect(reason)}
    )

    {:stop, reason, %{state | ws_pid: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp maybe_start_ws(%{start_client?: false} = state), do: {:ok, state}

  defp maybe_start_ws(state) do
    case state.ws_client_module.start_link(client: state.client, dispatcher: state.dispatcher) do
      {:ok, pid} -> {:ok, %{state | ws_pid: pid}}
      {:error, _reason} = error -> error
    end
  end

  defp fingerprint(consumers) do
    :sha256 |> :crypto.hash(:erlang.term_to_binary(consumers)) |> Base.encode16(case: :lower)
  end
end
