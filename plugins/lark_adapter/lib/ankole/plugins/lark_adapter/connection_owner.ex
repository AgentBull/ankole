defmodule Ankole.Plugins.LarkAdapter.ConnectionOwner do
  @moduledoc """
  Per-app owner for the Feishu/Lark long-connection client.
  """

  use GenServer

  require Logger

  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Dispatcher

  @registry Ankole.Plugins.LarkAdapter.ConnectionRegistry

  # Runtime state for one provider app long-connection owner.
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

  @doc """
  Starts an owner registered by provider domain and app id.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    registry = Keyword.get(opts, :registry, @registry)
    key = Config.connection_key(config)

    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {registry, key}})
  end

  @doc """
  Builds a stable child id so one provider app maps to one supervised owner.
  """
  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)

    %{
      id: {__MODULE__, Config.connection_key(config)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Verifies that an existing owner still matches the requested config and consumers.
  """
  @spec ensure_consumers(GenServer.server(), map(), [map()]) :: {:ok, pid()} | {:error, term()}
  def ensure_consumers(server, config, consumers) do
    GenServer.call(server, {:ensure_consumers, config, consumers})
  end

  @doc """
  Returns lightweight runtime status for tests and operator inspection.
  """
  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = Keyword.fetch!(opts, :config)
    consumers = Keyword.get(opts, :consumers, [])
    client_opts = Keyword.get(opts, :client_opts, [])
    client = Config.client(config, client_opts)
    dispatcher = Dispatcher.build(consumers, client: client)
    start_client? = Keyword.get(opts, :start_client?, true)
    ws_client_module = Keyword.get(opts, :ws_client_module, FeishuOpenAPI.WS.Client)

    state = %__MODULE__{
      key: Config.connection_key(config),
      secret_fingerprint: Config.secret_fingerprint(config),
      consumer_fingerprint: consumer_fingerprint(consumers),
      consumer_count: length(consumers),
      consumer_kinds: consumer_kinds(consumers),
      client: client,
      dispatcher: dispatcher,
      ws_client_module: ws_client_module,
      start_client?: start_client?
    }

    with {:ok, state} <- maybe_start_ws(state) do
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:ensure_consumers, config, consumers}, {from_pid, _tag}, state) do
    cond do
      Config.connection_key(config) != state.key ->
        {:reply, {:error, :connection_key_mismatch}, state}

      Config.secret_fingerprint(config) != state.secret_fingerprint ->
        {:reply, {:error, :conflicting_app_secret}, state}

      consumer_fingerprint(consumers) != state.consumer_fingerprint ->
        # A changed consumer set means the dispatcher behavior changed. Restarting
        # the owner is simpler and safer than patching a live websocket callback.
        {:reply, {:error, :consumer_set_changed}, state}

      true ->
        {:reply, {:ok, from_pid_or_self(from_pid, self())}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       key: state.key,
       consumer_count: state.consumer_count,
       consumer_kinds: state.consumer_kinds,
       ws_pid: state.ws_pid,
       running?: is_pid(state.ws_pid) and Process.alive?(state.ws_pid),
       start_client?: state.start_client?
     }, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{ws_pid: pid} = state) do
    Logger.error(
      "lark adapter long-connection client exited key=#{inspect(state.key)} reason=#{inspect(reason)}"
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

  defp consumer_fingerprint(consumers) do
    # The consumer records are internal trusted terms. Hashing the term binary is
    # enough to detect local dispatcher changes without keeping large config copies.
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(consumers))
    |> Base.encode16(case: :lower)
  end

  defp consumer_kinds(consumers) do
    consumers
    |> Enum.map(&Map.get(&1, :kind))
    |> Enum.sort()
  end

  defp from_pid_or_self(pid, self_pid) when pid == self_pid, do: self_pid
  defp from_pid_or_self(_pid, self_pid), do: self_pid
end
