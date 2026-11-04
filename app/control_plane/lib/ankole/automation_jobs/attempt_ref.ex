defmodule Ankole.AutomationJobs.AttemptRef do
  @moduledoc "The live execution fence of one Function Runtime Action attempt."
  @enforce_keys [:job_id, :run_id, :attempt_id]
  defstruct [:job_id, :run_id, :attempt_id, :principal_uid]

  @type t :: %__MODULE__{
          job_id: pos_integer(),
          run_id: pos_integer(),
          attempt_id: String.t(),
          principal_uid: String.t()
        }
end
