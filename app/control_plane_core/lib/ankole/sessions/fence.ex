defmodule Ankole.Sessions.Fence do
  @moduledoc """
  Serializes driver writes with admission and checks their current epoch.

  Tools prepare domain locks before they hold the shared workspace lock.
  Admission, result recording,
  and finalization hold an exclusive lock, so takeover waits for a tool commit.
  """

  import Ecto.Query

  alias Ankole.Signals.Signal
  alias Ankole.Sessions.SessionWorkspace

  def lock_workspace_in_tx(repo, key, lock \\ :update) do
    SessionWorkspace
    |> where([w], w.agent_uid == ^key.agent_uid and w.session_id == ^key.session_id)
    |> lock_query(lock)
    |> repo.one(lock_identity: {"sessions", {key.agent_uid, key.session_id}})
  end

  def current_in_tx(repo, run) do
    workspace =
      repo.get_by(SessionWorkspace, agent_uid: run.agent_uid, session_id: run.session_id)

    validate_workspace_in_tx(repo, run, workspace)
  end

  def check_in_tx(repo, run, lock \\ :update) do
    validate_workspace_in_tx(repo, run, lock_workspace_in_tx(repo, run, lock))
  end

  defp validate_workspace_in_tx(repo, run, workspace) do
    case workspace do
      %SessionWorkspace{epoch: epoch} when epoch == run.epoch ->
        check_run_ref_in_tx(repo, run)

      _stale ->
        {:error, :stale_driver}
    end
  end

  defp check_run_ref_in_tx(repo, ref) do
    case repo.get(Signal, ref.signal_id) do
      %Signal{
        agent_uid: agent_uid,
        session_id: session_id,
        status: live_status
      }
      when live_status in [:queued, :running] and
             (agent_uid == ref.agent_uid and session_id == ref.session_id) ->
        :ok

      _closed ->
        {:error, :run_closed}
    end
  end

  defp lock_query(query, :share), do: lock(query, "FOR SHARE")
  defp lock_query(query, :update), do: lock(query, "FOR UPDATE")
end
