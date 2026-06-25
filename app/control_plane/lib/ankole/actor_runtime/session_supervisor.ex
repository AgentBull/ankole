defmodule Ankole.ActorRuntime.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for per-actor session controllers.

  One `SessionController` is spawned on demand per `{agent_uid, session_id}`
  actor key and named in the `ActorDirectory` Registry. Using a dynamic
  supervisor lets actors come and go at runtime without a static child list, and
  makes each controller its own failure unit: one crashing controller (or one
  misbehaving actor) is isolated and restarted without touching the others.
  """

  use DynamicSupervisor

  alias Ankole.ActorRuntime.SessionController

  @doc """
  Starts the dynamic supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Ensures the controller for an actor key is running.

  Idempotent get-or-start: two concurrent wakeups for the same actor race to
  start the controller, and the loser gets `{:already_started, pid}` from the
  Registry-unique name. Both callers treat that as success and return the live
  pid, so callers never have to coordinate who starts the actor.
  """
  @spec ensure_session_controller(map()) :: {:ok, pid()} | {:error, term()}
  def ensure_session_controller(actor_key) do
    case DynamicSupervisor.start_child(__MODULE__, {SessionController, actor_key}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def init(_opts) do
    # :one_for_one — controllers are independent. One actor's crash must not
    # restart unrelated actors' controllers.
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
