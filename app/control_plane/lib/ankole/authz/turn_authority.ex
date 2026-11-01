defmodule Ankole.AuthZ.TurnAuthority do
  @moduledoc "Checks that the instruction authorizing a write is still live."
  alias Ankole.Sessions.{JobTurnRef, RunRef}
  alias Ankole.AutomationJobs.AttemptRef

  def validate(nil), do: :ok

  def validate({ref, uid})
      when (is_struct(ref, RunRef) or is_struct(ref, JobTurnRef)) and ref.agent_uid == uid,
      do: :ok

  def validate({%AttemptRef{agent_uid: uid}, uid}), do: :ok

  def validate(_), do: {:error, :worker_not_assigned_to_turn}
  def authorize_in_tx(nil), do: :ok

  def authorize_in_tx({%AttemptRef{} = ref, uid}) do
    with {:ok, _actor} <-
           Ankole.AutomationJobs.authorize_attempt_actor_in_tx(ref, %{worker_id: uid}),
         do: :ok
  end

  def authorize_in_tx({ref, uid}) do
    case Ankole.AgentWorkers.WorkerRouteAuth.authorize_turn_in_tx(ref, uid, :write, lock: true) do
      {:ok, :authorized} -> :ok
      error -> error
    end
  end
end
