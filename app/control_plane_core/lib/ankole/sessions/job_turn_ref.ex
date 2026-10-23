defmodule Ankole.Sessions.JobTurnRef do
  @moduledoc "The durable Job attempt fence. Driver replacement does not change this reference."
  @enforce_keys [:agent_uid, :session_id, :signal_id, :job_id, :attempt]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
  alias Ankole.RuntimeFabric.V1, as: Proto
  require Ankole.ModelIntegerID

  def from_proto(%Proto.JobTurnRef{signal_id: id, job_id: job, attempt: attempt}, uid)
      when id != "" and job > 0 and attempt > 0 do
    {:ok,
     %__MODULE__{
       agent_uid: uid,
       session_id: session_id(job),
       signal_id: id,
       job_id: job,
       attempt: attempt
     }}
  end

  def from_proto(_, _uid), do: {:error, :invalid_job_turn_ref}

  # The same key as `Ankole.BackgroundAgentJobs.job_session_id/1`. A Job
  # resource argument holds this struct, so this module calls no domain module.
  defp session_id(job) when Ankole.ModelIntegerID.valid?(job), do: Ankole.Sessions.Key.job(job)

  def to_proto(ref),
    do: %Proto.JobTurnRef{
      signal_id: ref.signal_id,
      job_id: ref.job_id,
      attempt: ref.attempt
    }
end
