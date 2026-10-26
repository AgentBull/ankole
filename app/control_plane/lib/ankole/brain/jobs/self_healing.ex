defmodule Ankole.Brain.Jobs.SelfHealing do
  @moduledoc """
  Oban worker for the Brain Self-healing sweep.
  """

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 1,
    unique: [
      keys: [:tenant_id],
      period: :infinity,
      states: Oban.Job.states() -- [:completed, :cancelled, :discarded]
    ]

  @impl Ankole.Job
  def run(job) do
    if Ankole.Tenants.accepting_work?(Ankole.Repo.tenant_id!()), do: run_active(job), else: :ok
  end

  defp run_active(%Oban.Job{}) do
    {:ok, _report} = Ankole.Brain.SelfHealing.sweep()
    :ok
  end
end
