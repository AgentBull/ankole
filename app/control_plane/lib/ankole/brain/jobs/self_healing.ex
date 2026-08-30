defmodule Ankole.Brain.Jobs.SelfHealing do
  @moduledoc """
  Oban worker for the Brain Self-healing sweep.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: Oban.Job.states() -- [:completed, :cancelled, :discarded]]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, _report} = Ankole.Brain.SelfHealing.sweep()
    :ok
  end
end
