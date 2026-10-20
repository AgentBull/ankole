defmodule Ankole.Sessions.Jobs.EnqueueDailySessionResets do
  @moduledoc """
  Control-plane cron job that appends due `session.reset_due` Signals.
  """

  use Ankole.Job,
    tenancy: :site,
    queue: :default,
    max_attempts: 3

  alias Ankole.Sessions.SessionReset

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def run(_job) do
    Ankole.Tenants.map_active(fn -> do_perform() end)
    |> Ankole.Tenants.fanout_result()
  end

  defp do_perform() do
    case SessionReset.enqueue_daily_session_resets() do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
