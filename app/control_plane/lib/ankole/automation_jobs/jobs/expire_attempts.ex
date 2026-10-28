defmodule Ankole.AutomationJobs.Jobs.ExpireAttempts do
  @moduledoc """
  Fails running automation attempts that passed the `ExecuteRun` RPC deadline.

  The Oban job of a run normally records this result. A node can stop during
  the last permitted Oban attempt, and Oban then discards the job. This sweep
  is the recovery owner of such a run.
  """

  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 1

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def run(_job) do
    (&Ankole.AutomationJobs.expire_attempts/0)
    |> Ankole.Tenants.map_all()
    |> Ankole.Tenants.fanout_result()
  end
end
