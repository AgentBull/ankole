defmodule Ankole.Brain.Jobs.Dreaming do
  @moduledoc """
  Oban worker for the daily Dreaming round.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: Oban.Job.states() -- [:completed, :cancelled, :discarded]]

  alias Ankole.Logging

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, report} = Ankole.Brain.Dreaming.run()

    # The per-phase report is the only record of skipped or failed phases:
    # one phase failing every night inside a completed round must not stay
    # invisible to operators.
    Logging.info("brain.dreaming.round_report", "dreaming round finished", %{report: report})

    failed =
      for {phase, %{status: :failed} = outcome} <- report do
        {phase, outcome[:error]}
      end

    if failed != [] do
      Logging.warning("brain.dreaming.phases_failed", "dreaming phases failed", %{
        failed: Map.new(failed)
      })
    end

    :ok
  end
end
