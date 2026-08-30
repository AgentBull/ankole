defmodule Ankole.Brain.Jobs.ApplySkillLessons do
  @moduledoc """
  Applies one succeeded reflection job's proposed lessons.

  Enqueued inside the job's terminal-commit transaction and executed after
  it, so a bad reflection output can never block the job's own status
  transition. Idempotent: a stamped job is a no-op, and duplicate adds fall
  on the Library's normalized-equality gate.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:job_id],
      states: Oban.Job.states() -- [:completed, :cancelled, :discarded]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"job_id" => job_id}}) do
    Ankole.Brain.SkillLessons.apply_reflection_output(job_id)
  end
end
