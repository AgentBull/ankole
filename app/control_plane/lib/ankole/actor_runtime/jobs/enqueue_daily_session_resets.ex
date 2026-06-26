defmodule Ankole.ActorRuntime.Jobs.EnqueueDailySessionResets do
  @moduledoc """
  Control-plane cron job that appends due `session.reset_due` actor inputs.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias Ankole.ActorRuntime

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case ActorRuntime.enqueue_daily_session_resets() do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
