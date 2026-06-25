defmodule Ankole.ActorRuntime.SessionController do
  @moduledoc """
  Serial process for one `{agent_uid, session_id}` actor key.

  This GenServer is the in-memory serialization point for one actor: by funneling
  that actor's scheduling work through a single process, the common path never
  has two turns racing for the same actor key. It is an optimization for
  reasoning, not the correctness boundary — durable database fences (turn and
  delivery rows) remain the real guard, so a controller crash or restart cannot
  corrupt an actor's state.
  """

  use GenServer

  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.ActorDirectory
  alias Ankole.ActorRuntime.SessionSupervisor

  # Processing one ready batch can drive an LLM turn end to end, so the
  # caller-side call timeout is generous (30s) to avoid spurious exits while the
  # actor does real work. The DB fences still bound correctness if it does run long.
  @call_timeout 30_000

  @doc """
  Starts a controller for one actor key.
  """
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(actor_key) do
    actor_key = normalize_actor_key(actor_key)
    GenServer.start_link(__MODULE__, actor_key, name: ActorDirectory.via(actor_key))
  end

  @doc """
  Ensures the controller exists and asks it to process ready input.

  One controller serializes scheduling for one actor key. Database fences still
  protect correctness, but this keeps common-path concurrency easy to reason
  about.
  """
  @spec process_ready(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def process_ready(actor_key, opts \\ []) do
    actor_key = normalize_actor_key(actor_key)

    with {:ok, _pid} <- SessionSupervisor.ensure_session_controller(actor_key) do
      GenServer.call(ActorDirectory.via(actor_key), {:process_ready, opts}, @call_timeout)
    end
  end

  @impl true
  def init(actor_key), do: {:ok, %{actor_key: actor_key}}

  @impl true
  def handle_call({:process_ready, opts}, _from, state) do
    {:reply, ActorRuntime.process_ready_inputs_for_actor(state.actor_key, opts), state}
  end

  # Accept both atom-keyed (internal) and string-keyed (decoded JSON) actor keys,
  # and downcase the agent uid so a single actor always maps to one Registry name
  # and one controller — case differences in the uid must not fork the actor into
  # two serial processes. Must match ActorDirectory.key/1's normalization exactly.
  defp normalize_actor_key(%{agent_uid: agent_uid, session_id: session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  defp normalize_actor_key(%{"agent_uid" => agent_uid, "session_id" => session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)
end
