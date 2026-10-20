defmodule Ankole.Sessions.Workspaces do
  @moduledoc """
  Owns stable numeric Agent Home workspace IDs for Sessions.

  Allocation uses the Session advisory lock. Repeated calls for the same
  `{agent_uid, session_id}` return the same PostgreSQL-owned identity.
  """

  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.SessionWorkspace

  @type result :: {:ok, SessionWorkspace.t()} | {:error, term()}

  @doc false
  @spec ensure_in_tx(module(), String.t(), String.t()) :: result()
  def ensure_in_tx(repo, agent_uid, session_id)
      when is_binary(agent_uid) and is_binary(session_id) do
    :ok = Queue.lock_session_in_tx(repo, agent_uid, session_id)

    case repo.get_by(SessionWorkspace, agent_uid: agent_uid, session_id: session_id) do
      %SessionWorkspace{} = workspace ->
        {:ok, workspace}

      nil ->
        %SessionWorkspace{}
        |> SessionWorkspace.changeset(%{
          agent_uid: agent_uid,
          session_id: session_id,
          conversation_id: conversation_id(session_id)
        })
        |> repo.insert()
    end
  end

  defp conversation_id(key) do
    case Ankole.Sessions.Key.parse(key) do
      {:conversation, id} ->
        if Ankole.Repo.get_by(Ankole.Conversations.Conversation, id: id), do: id

      _ ->
        nil
    end
  end
end
