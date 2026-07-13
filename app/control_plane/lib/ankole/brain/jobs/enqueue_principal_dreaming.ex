defmodule Ankole.Brain.Jobs.EnqueuePrincipalDreaming do
  @moduledoc """
  Enqueues each enabled principal's once-daily Stage B run in installation time.

  The cron poll is deliberately minute-granular because each principal may
  override its local run time. Date-scoped Oban uniqueness makes delayed polls
  safe and prevents a completed run from being enqueued again that day.
  """

  import Ecto.Query, warn: false

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.Brain.Config
  alias Ankole.Brain.Jobs.CuratePrincipal
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SystemConfig

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now = parse_now(Map.get(args, "now"))

    with {:ok, timezone} <- installation_timezone(),
         {:ok, local_now} <- DateTime.shift_zone(now, timezone) do
      Principal
      |> where([principal], principal.status == :active)
      |> order_by([principal], asc: principal.uid)
      |> select([principal], principal.uid)
      |> Repo.all()
      |> Enum.reduce_while(:ok, fn uid, :ok ->
        case maybe_enqueue(uid, local_now, timezone) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp maybe_enqueue(uid, local_now, timezone) do
    with {:ok, %{"enabled" => true} = config} <- Config.dreaming(uid),
         {:ok, scheduled_time} <- Time.from_iso8601(config["schedule_local_time"] <> ":00") do
      if Time.compare(DateTime.to_time(local_now), scheduled_time) in [:eq, :gt] do
        date = local_now |> DateTime.to_date() |> Date.to_iso8601()

        case %{"principal_uid" => uid, "local_date" => date, "timezone" => timezone}
             |> CuratePrincipal.new()
             |> Oban.insert() do
          {:ok, _job} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        :ok
      end
    else
      {:ok, %{"enabled" => false}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp installation_timezone do
    case SystemConfig.timezone() do
      {:ok, timezone} -> {:ok, timezone}
      {:error, _reason} -> {:ok, SystemConfig.default_timezone()}
    end
  end

  defp parse_now(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> DateTime.utc_now(:microsecond)
    end
  end

  defp parse_now(_value), do: DateTime.utc_now(:microsecond)
end
