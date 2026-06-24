defmodule Ankole.ActorRuntime.SessionController do
  @moduledoc """
  Serial process for one `{agent_uid, session_id}` actor key.
  """

  use GenServer

  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.ActorDirectory
  alias Ankole.ActorRuntime.SessionSupervisor

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

  defp normalize_actor_key(%{agent_uid: agent_uid, session_id: session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  defp normalize_actor_key(%{"agent_uid" => agent_uid, "session_id" => session_id}) do
    %{agent_uid: normalize_uid(agent_uid), session_id: session_id}
  end

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)
end
