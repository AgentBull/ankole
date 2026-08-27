defmodule Ankole.Brain.Jobs.Tick do
  @moduledoc """
  One-minute scheduler tick for Brain background tasks.

  Oban's cron plugin is static configuration, while `brain.*` cron
  expressions are operator settings. The tick runs every minute, checks the
  configured expressions against the current minute in the system timezone,
  and enqueues the matching task. A disabled Brain schedules nothing.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  alias Ankole.Brain.Config

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Config.enabled?() do
      now = local_now()

      if cron_matches?(Config.self_healing_task_cron(), now) do
        Oban.insert(Ankole.Brain.Jobs.SelfHealing.new(%{}))
      end

      if cron_matches?(Config.dreaming_task_cron(), now) do
        Oban.insert(Ankole.Brain.Jobs.Dreaming.new(%{}))
      end
    end

    :ok
  end

  defp cron_matches?(expression, now) do
    case Crontab.CronExpression.Parser.parse(expression) do
      {:ok, cron} -> Crontab.DateChecker.matches_date?(cron, now)
      {:error, _reason} -> false
    end
  end

  defp local_now do
    timezone =
      case Ankole.AppConfigure.get_by_key("system.timezone") do
        {:ok, timezone} when is_binary(timezone) -> timezone
        _missing -> "Etc/UTC"
      end

    case DateTime.now(timezone) do
      {:ok, datetime} -> DateTime.to_naive(datetime)
      {:error, _reason} -> NaiveDateTime.utc_now()
    end
  end
end
