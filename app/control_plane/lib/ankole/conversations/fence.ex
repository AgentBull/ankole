defmodule Ankole.Conversations.Fence do
  @moduledoc """
  Serializes driver writes with admission and checks their current epoch.

  Tool transactions hold a shared workspace lock. Admission, result recording,
  and finalization hold an exclusive lock, so takeover waits for a tool commit.
  """

  import Ecto.Query

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkspace

  def check_in_tx(repo, run, lock \\ :update) do
    row =
      ActorSessionWorkspace
      |> where([w], w.agent_uid == ^run.agent_uid and w.session_id == ^run.session_id)
      |> lock_query(lock)
      |> repo.one()

    case row do
      %ActorSessionWorkspace{epoch: epoch} when epoch == run.epoch ->
        check_run_ref_in_tx(repo, run)

      _stale ->
        {:error, :stale_driver}
    end
  end

  def check_run_ref_in_tx(repo, ref) do
    case repo.get(ActorEvent, ref.actor_event_id) do
      %ActorEvent{
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
