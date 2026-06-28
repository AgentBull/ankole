defmodule Ankole.ActorRuntime.ActorDirectory do
  @moduledoc """
  Registry naming for per-actor session controllers.
  """

  @doc """
  Returns the Registry child spec for actor session names.
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Returns the Registry via tuple for an actor key.
  """
  @spec via(map()) :: {:via, Registry, {module(), {String.t(), String.t()}}}
  def via(actor_key), do: {:via, Registry, {__MODULE__, key(actor_key)}}

  @doc """
  Normalizes an actor key to the runtime registry key.
  """
  @spec key(map()) :: {String.t(), String.t()}
  def key(%{agent_uid: agent_uid, session_id: session_id}) do
    {normalize_uid(agent_uid), session_id}
  end

  def key(%{"agent_uid" => agent_uid, "session_id" => session_id}) do
    {normalize_uid(agent_uid), session_id}
  end

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)
end
