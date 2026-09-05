defmodule Ankole.SignalsGateway.ActorRuntime.SessionController do
  @moduledoc """
  Serial process for one `{agent_uid, session_id}` actor key.

  This GenServer is the in-memory serialization point for one actor: by funneling
  that actor's scheduling work through a single process, the common path never
  has two turns racing for the same actor key. It is an optimization for
  reasoning, not the correctness boundary — durable database fences (turn and
  delivery rows) remain the real guard, so a controller crash or restart cannot
  corrupt an actor's state.
  """

  use GenServer, restart: :transient

  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime
  alias Ankole.SignalsGateway.ActorRuntime.ActorLane
  alias Ankole.SignalsGateway.ActorRuntime.Common
  alias Ankole.SignalsGateway.ActorRuntime.ActorDirectory
  alias Ankole.SignalsGateway.ActorRuntime.SessionSupervisor
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle

  # Processing one ready batch can drive a worker run end to end, so the
  # caller-side call timeout is generous (30s) to avoid spurious exits while the
  # actor does real work. The DB fences still bound correctness if it does run long.
  @call_timeout 30_000
  @idle_timeout :timer.minutes(5)
  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Starts a controller for one actor key.
  """
  @spec start_link(actor_key()) :: GenServer.on_start()
  def start_link(actor_key) do
    actor_key = Common.normalize_actor_key(actor_key)
    GenServer.start_link(__MODULE__, actor_key, name: ActorDirectory.via(actor_key))
  end

  @doc """
  Ensures the controller exists and asks it to process one ready event.

  One controller serializes scheduling for one actor key. Database fences still
  protect correctness, but this keeps common-path concurrency easy to reason
  about.
  """
  @spec process_ready(actor_key(), keyword()) :: {:ok, map()} | {:error, term()}
  def process_ready(actor_key, opts \\ []) do
    actor_key = Common.normalize_actor_key(actor_key)
    call_ready(actor_key, opts, 1)
  end

  defp call_ready(actor_key, opts, retries) do
    with {:ok, pid} <- SessionSupervisor.ensure_session_controller(actor_key) do
      try do
        GenServer.call(pid, {:process_ready, opts}, @call_timeout)
      catch
        :exit, {reason, {GenServer, :call, _args}}
        when reason in [:normal, :noproc] and retries > 0 ->
          call_ready(actor_key, opts, retries - 1)
      end
    end
  end

  @doc """
  Queues one authenticated worker turn envelope on its actor's serial process.

  This is asynchronous so transport remains available while a domain callback
  uses the RPC or worker-file lane. Messages forwarded by the one inbound
  dispatcher retain their wire order for a given actor controller.
  """
  @spec dispatch_inbound(actor_key(), String.t(), map()) :: :ok | {:error, term()}
  def dispatch_inbound(actor_key, route, envelope)
      when is_map(actor_key) and is_binary(route) and is_map(envelope) do
    actor_key = Common.normalize_actor_key(actor_key)

    with {:ok, _pid} <- SessionSupervisor.ensure_session_controller(actor_key) do
      GenServer.cast(ActorDirectory.via(actor_key), {:dispatch_inbound, route, envelope})
    end
  end

  @impl true
  def init(actor_key), do: {:ok, %{actor_key: actor_key}, @idle_timeout}

  @impl true
  def handle_call({:process_ready, opts}, _from, state) do
    {:reply, ActorRuntime.process_ready_event_for_actor(state.actor_key, opts), state,
     @idle_timeout}
  end

  @impl true
  def handle_cast({:dispatch_inbound, route, envelope}, state) do
    ActorLane.handle(envelope, route)
    {:noreply, state, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    # All production Turn starts run on this controller. A live delivery keeps
    # it alive while accepted/progress casts can matter; terminal writes use
    # the independent RPC lane. A queued ready call can retry a normal exit.
    if TurnLifecycle.live_delivery_for_session?(Repo, state.actor_key) do
      {:noreply, state, @idle_timeout}
    else
      {:stop, :normal, state}
    end
  end
end
