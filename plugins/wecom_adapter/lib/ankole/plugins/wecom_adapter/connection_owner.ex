defmodule Ankole.Plugins.WeComAdapter.ConnectionOwner do
  @moduledoc """
  Per-bot owner for the WeCom AI-bot long-connection client.

  Builds an immutable dispatcher from all active consumers and starts one
  `WeComOpenAPI.Bot.Client`, registered under `{:client, key}` so Outbox and
  AIStream can reach the live connection. A changed consumer set restarts the
  owner so the dispatcher is rebuilt rather than mutated on a live socket.

  The platform allows one connection per bot and kicks the older holder when a
  new one subscribes (`:connection_contended`). Fighting back would kick the
  new holder in a loop, so the owner parks instead: it logs the operator-visible
  conflict, stays alive without a client, and retries once per idle window —
  if the contender is gone the connection resumes, otherwise it gets kicked
  once and parks again.
  """

  use GenServer

  alias Ankole.Logging
  alias Ankole.Plugins.WeComAdapter.Config
  alias Ankole.Plugins.WeComAdapter.Dispatcher

  @registry Ankole.Plugins.WeComAdapter.ConnectionRegistry
  @contended_retry_ms :timer.minutes(30)

  defstruct [
    :key,
    :secret_fingerprint,
    :consumer_fingerprint,
    :consumer_count,
    :config,
    :dispatcher,
    :ws_pid,
    :contended_timer
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    key = Config.connection_key(config)

    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, key}})
  end

  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)

    %{
      id: {__MODULE__, Config.connection_key(config)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec ensure_consumers(GenServer.server(), map(), [map()]) :: {:ok, pid()} | {:error, term()}
  def ensure_consumers(server, config, consumers) do
    GenServer.call(server, {:ensure_consumers, config, consumers})
  end

  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, :status)

  @doc """
  Resolves the live bot client process for a chat config. Outbound paths call
  this per send; a missing or parked connection surfaces as a retryable error.
  """
  @spec bot_client(map()) :: {:ok, pid()} | {:error, :wecom_connection_unavailable}
  def bot_client(config) when is_map(config) do
    key = Config.connection_key(config)

    case Registry.lookup(@registry, {:client, key}) do
      [{pid, _value}] ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :wecom_connection_unavailable}

      [] ->
        {:error, :wecom_connection_unavailable}
    end
  end

  @doc false
  @spec client_name(term()) :: GenServer.name()
  def client_name(key), do: {:via, Registry, {@registry, {:client, key}}}

  @impl true
  def format_status(status) do
    case status do
      %{state: %__MODULE__{} = state} ->
        %{
          status
          | state: %{
              key: state.key,
              secret_fingerprint: short_fingerprint(state.secret_fingerprint),
              consumer_count: state.consumer_count,
              ws_pid: state.ws_pid
            }
        }

      _other ->
        status
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = Keyword.fetch!(opts, :config)
    consumers = Keyword.get(opts, :consumers, [])
    dispatcher = Dispatcher.build(consumers)

    state = %__MODULE__{
      key: Config.connection_key(config),
      secret_fingerprint: Config.secret_fingerprint(config),
      consumer_fingerprint: consumer_fingerprint(consumers),
      consumer_count: length(consumers),
      config: config,
      dispatcher: dispatcher
    }

    with {:ok, state} <- start_client(state) do
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:ensure_consumers, config, consumers}, _from, state) do
    cond do
      Config.connection_key(config) != state.key ->
        {:reply, {:error, :connection_key_mismatch}, state}

      Config.secret_fingerprint(config) != state.secret_fingerprint ->
        {:reply, {:error, :conflicting_bot_secret}, state}

      consumer_fingerprint(consumers) != state.consumer_fingerprint ->
        {:reply, {:error, :consumer_set_changed}, state}

      true ->
        {:reply, {:ok, self()}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       key: state.key,
       consumer_count: state.consumer_count,
       ws_pid: state.ws_pid,
       contended?: not is_nil(state.contended_timer),
       running?: is_pid(state.ws_pid) and Process.alive?(state.ws_pid)
     }, state}
  end

  @impl true
  def handle_info({:EXIT, pid, {:shutdown, :connection_contended}}, %{ws_pid: pid} = state) do
    Logging.error(
      "wecom_adapter.connection_owner.contended",
      "another consumer holds this WeCom bot's long connection (the platform allows one); " <>
        "parked until the next retry window — stop the other consumer or re-save the binding",
      %{connection_key: inspect(state.key), retry_in_ms: @contended_retry_ms}
    )

    timer = Process.send_after(self(), :retry_connect, @contended_retry_ms)
    {:noreply, %{state | ws_pid: nil, contended_timer: timer}}
  end

  def handle_info({:EXIT, pid, reason}, %{ws_pid: pid} = state) do
    Logging.error(
      "wecom_adapter.connection_owner.client_exited",
      "wecom adapter bot client exited",
      %{connection_key: inspect(state.key), reason: inspect(reason)}
    )

    {:stop, reason, %{state | ws_pid: nil}}
  end

  def handle_info(:retry_connect, %{ws_pid: nil} = state) do
    state = %{state | contended_timer: nil}

    case start_client(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  def handle_info(:retry_connect, state), do: {:noreply, %{state | contended_timer: nil}}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp start_client(state) do
    case WeComOpenAPI.Bot.Client.start_link(
           bot_id: Map.fetch!(state.config, "botId"),
           secret: fn -> Map.fetch!(state.config, "secret") end,
           dispatcher: state.dispatcher,
           name: client_name(state.key)
         ) do
      {:ok, pid} -> {:ok, %{state | ws_pid: pid}}
      {:error, _reason} = error -> error
    end
  end

  defp consumer_fingerprint(consumers) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(consumers))
    |> Base.encode16(case: :lower)
  end

  defp short_fingerprint(value) when is_binary(value) and byte_size(value) >= 8,
    do: String.slice(value, 0, 8)

  defp short_fingerprint(_value), do: :redacted
end
