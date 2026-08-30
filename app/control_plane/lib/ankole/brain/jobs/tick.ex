defmodule Ankole.Brain.Jobs.Tick do
  @moduledoc """
  One-minute scheduler tick for Brain background tasks.

  Oban's cron plugin is static configuration, while `brain.*` cron
  expressions are operator settings. The tick runs every minute, checks the
  configured expressions against its insertion minute in the system timezone,
  and enqueues the matching task. A disabled Brain schedules nothing.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.Brain.Config
  alias Ankole.SystemConfig
  alias Ankole.TimeZone

  @impl Oban.Worker
  def perform(%Oban.Job{inserted_at: inserted_at}) do
    if Config.enabled?() do
      with {:ok, scheduled_minute} <- local_scheduled_minute(inserted_at),
           :ok <-
             enqueue_if_matches(
               Config.self_healing_task_cron(),
               scheduled_minute,
               Ankole.Brain.Jobs.SelfHealing
             ),
           :ok <-
             enqueue_if_matches(
               Config.dreaming_task_cron(),
               scheduled_minute,
               Ankole.Brain.Jobs.Dreaming
             ) do
        :ok
      end
    else
      :ok
    end
  end

  defp cron_matches?(expression, now) do
    case Crontab.CronExpression.Parser.parse(expression) do
      {:ok, cron} -> Crontab.DateChecker.matches_date?(cron, now)
      {:error, _reason} -> false
    end
  end

  defp enqueue_if_matches(expression, scheduled_minute, worker) do
    if cron_matches?(expression, scheduled_minute) do
      case Oban.insert(worker.new(%{})) do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp local_scheduled_minute(%DateTime{} = inserted_at) do
    with {:ok, timezone} <- SystemConfig.timezone(),
         {:ok, datetime} <- TimeZone.shift(inserted_at, timezone) do
      {:ok, DateTime.to_naive(datetime)}
    end
  end

  defp local_scheduled_minute(_missing), do: {:error, :missing_inserted_at}
end
