defmodule Ankole.Sessions.Fence do
  @moduledoc """
  Serializes driver writes with admission and checks their current epoch.

  Tools prepare domain locks before they hold the shared workspace lock.
  Admission, result recording,
  and finalization hold an exclusive lock, so takeover waits for a tool commit.
  """

  require Ash.Query

  alias Ankole.Signals.Signal
  alias Ankole.Sessions.SessionWorkspace

  def lock_workspace_in_tx(key, lock \\ :update) do
    SessionWorkspace
    |> Ash.Query.filter(agent_uid == ^key.agent_uid and session_id == ^key.session_id)
    |> Ash.Query.lock(lock_clause(lock))
    |> Ankole.Ash.read_one!(lock_identity: {"sessions", {key.agent_uid, key.session_id}})
  end

  def current_in_tx(run) do
    workspace =
      SessionWorkspace
      |> Ash.Query.filter(agent_uid == ^run.agent_uid and session_id == ^run.session_id)
      |> Ankole.Ash.read_one!()

    validate_workspace_in_tx(run, workspace)
  end

  def check_in_tx(run, lock \\ :update) do
    validate_workspace_in_tx(run, lock_workspace_in_tx(run, lock))
  end

  defp validate_workspace_in_tx(run, workspace) do
    case workspace do
      %SessionWorkspace{epoch: epoch} when epoch == run.epoch ->
        check_run_ref(run)

      _stale ->
        {:error, :stale_driver}
    end
  end

  defp check_run_ref(ref) do
    case Ankole.Signals.get_signal!(ref.signal_id) do
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

  defp lock_clause(:share), do: "FOR SHARE"
  defp lock_clause(:update), do: :for_update
end
