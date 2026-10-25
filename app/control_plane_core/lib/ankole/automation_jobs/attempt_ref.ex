defmodule Ankole.AutomationJobs.AttemptRef do
  @moduledoc "The live execution fence of one Automation Job attempt."
  @enforce_keys [:job_id, :run_id, :attempt_id, :agent_uid]
  defstruct [:job_id, :run_id, :attempt_id, :agent_uid]

  @type t :: %__MODULE__{
          job_id: pos_integer(),
          run_id: pos_integer(),
          attempt_id: String.t(),
          agent_uid: String.t()
        }

  def from_request(%{job_id: job_id, run_id: run_id, attempt_id: attempt_id}, agent_uid) do
    with {:ok, job_id} <- Ankole.ModelIntegerID.parse(job_id),
         {:ok, run_id} <- Ankole.ModelIntegerID.parse(run_id),
         {:ok, attempt_id} <- Ecto.UUID.cast(attempt_id) do
      {:ok,
       %__MODULE__{job_id: job_id, run_id: run_id, attempt_id: attempt_id, agent_uid: agent_uid}}
    else
      _ -> {:error, :automation_job_attempt_not_active}
    end
  end

  def from_request(_, _), do: {:error, :automation_job_attempt_not_active}
end
