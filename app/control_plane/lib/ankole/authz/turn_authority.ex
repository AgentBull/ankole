defmodule Ankole.AuthZ.TurnAuthority do
  @moduledoc "Checks that the instruction authorizing a write is still live."
  alias Ankole.Sessions.{JobTurnRef, RunRef}
  alias Ankole.AutomationJobs.AttemptRef

  def validate(nil), do: :ok

  def validate({ref, uid})
      when (is_struct(ref, RunRef) or is_struct(ref, JobTurnRef)) and ref.agent_uid == uid,
      do: :ok

  def validate({%AttemptRef{agent_uid: uid}, uid}), do: :ok
  def validate({%AttemptRef{agent_uid: nil, principal_uid: uid}, uid}), do: :ok

  def validate(_), do: {:error, :worker_not_assigned_to_turn}

  @doc """
  Checks the live instruction inside the committing transaction.

  `:before_fence` runs after lower-ranked admission locks and before the final
  Signal or Automation Run lock, so callers can acquire Job locks in order.
  Its writes roll back if the fence check or the caller's later write fails.
  """
  def authorize_in_tx(authority, opts \\ [])
  def authorize_in_tx(nil, opts), do: before_fence(opts)

  def authorize_in_tx({%AttemptRef{agent_uid: nil} = ref, uid}, opts) do
    with :ok <- before_fence(opts),
         {:ok, _actor} <-
           Ankole.AutomationJobs.authorize_attempt_actor_in_tx(ref, %{principal_uid: uid}),
         do: :ok
  end

  def authorize_in_tx({%AttemptRef{} = ref, uid}, opts) do
    with :ok <- before_fence(opts),
         {:ok, _actor} <-
           Ankole.AutomationJobs.authorize_attempt_actor_in_tx(ref, %{worker_id: uid}),
         do: :ok
  end

  def authorize_in_tx({ref, uid}, opts) do
    case Ankole.AgentWorkers.WorkerRouteAuth.authorize_turn_in_tx(
           ref,
           uid,
           :write,
           Keyword.put(opts, :lock, true)
         ) do
      {:ok, :authorized} -> :ok
      error -> error
    end
  end

  defp before_fence(opts), do: Keyword.get(opts, :before_fence, fn -> :ok end).()
end
