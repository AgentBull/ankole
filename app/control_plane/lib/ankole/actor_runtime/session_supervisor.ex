defmodule Ankole.ActorRuntime.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for per-actor session controllers.
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
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
