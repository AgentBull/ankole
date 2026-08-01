defmodule Ankole.SignalsGateway.ActorRuntime.SessionWorkspaces do
  @moduledoc """
  Owns stable numeric Agent Home workspace IDs for actor sessions.

  Allocation uses the actor session advisory lock. Repeated calls for the same
  `{agent_uid, session_id}` return the same PostgreSQL-owned identity.
  """

  alias Ankole.Repo
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkspace

  @type result :: {:ok, ActorSessionWorkspace.t()} | {:error, term()}

  @doc """
  Returns the stable workspace row for one actor session, creating it if needed.
  """
  @spec ensure(String.t(), String.t()) :: result()
  def ensure(agent_uid, session_id) when is_binary(agent_uid) and is_binary(session_id) do
    Repo.transact(fn repo -> ensure_in_tx(repo, agent_uid, session_id) end)
  end

  def ensure(_agent_uid, _session_id), do: {:error, :invalid_actor_session}

  @doc false
  @spec ensure_in_tx(module(), String.t(), String.t()) :: result()
  def ensure_in_tx(repo, agent_uid, session_id)
      when is_binary(agent_uid) and is_binary(session_id) do
    :ok = Actors.lock_actor_session_in_tx(repo, agent_uid, session_id)

    case repo.get_by(ActorSessionWorkspace, agent_uid: agent_uid, session_id: session_id) do
      %ActorSessionWorkspace{} = workspace ->
        {:ok, workspace}

      nil ->
        %ActorSessionWorkspace{}
        |> ActorSessionWorkspace.changeset(%{agent_uid: agent_uid, session_id: session_id})
        |> repo.insert()
    end
  end
end
