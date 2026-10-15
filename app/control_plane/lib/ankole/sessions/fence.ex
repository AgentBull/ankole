defmodule Ankole.Sessions.Fence do
  @moduledoc """
  Serializes driver writes with admission and checks their current epoch.

  Tool transactions hold a shared workspace lock. Admission, result recording,
  and finalization hold an exclusive lock, so takeover waits for a tool commit.
  """

  import Ecto.Query

  alias Ankole.Signals.Signal
  alias Ankole.Sessions.SessionWorkspace

  def lock_workspace_in_tx(repo, key, lock \\ :update) do
    SessionWorkspace
    |> where([w], w.agent_uid == ^key.agent_uid and w.session_id == ^key.session_id)
    |> lock_query(lock)
    |> repo.one()
  end

  def check_in_tx(repo, run, lock \\ :update) do
    case lock_workspace_in_tx(repo, run, lock) do
      %SessionWorkspace{epoch: epoch} when epoch == run.epoch ->
        check_run_ref_in_tx(repo, run)

      _stale ->
        {:error, :stale_driver}
    end
  end

  def check_run_ref_in_tx(repo, ref) do
    case repo.get(Signal, ref.signal_id) do
      %Signal{
        agent_uid: agent_uid,
        session_id: session_id,
        input_state: "open",
        completed_at: nil
      }
      when agent_uid == ref.agent_uid and session_id == ref.session_id ->
        :ok

      _closed ->
        {:error, :run_closed}
    end
  end

  defp lock_query(query, :share), do: lock(query, "FOR SHARE")
  defp lock_query(query, :update), do: lock(query, "FOR UPDATE")
end
