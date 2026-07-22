defmodule Ankole.Brain.Jobs.EnqueueSourceSyncs do
  @moduledoc false

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query, warn: false

  alias Ankole.Brain.Config
  alias Ankole.Brain.Jobs.SyncSource
  alias Ankole.Brain.Schemas.RetainedSource
  alias Ankole.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    with {:ok, %{"enabled" => true, "sync_interval_minutes" => interval}} <- Config.sources(),
         {:ok, now} <- now(args) do
      due_before = DateTime.add(now, -interval, :minute)

      jobs =
        RetainedSource
        |> where([source], source.capture_method != "file")
        |> where([source], is_nil(source.last_synced_at) or source.last_synced_at <= ^due_before)
        |> order_by([source], asc_nulls_first: source.last_synced_at, asc: source.id)
        |> select([source], source.id)
        |> Repo.all()
        |> Enum.map(&SyncSource.new(%{"source_id" => &1}))

      case Oban.insert_all(jobs) do
        inserted when is_list(inserted) -> {:ok, length(inserted)}
        other -> {:error, {:source_sync_enqueue_failed, other}}
      end
    else
      {:ok, %{"enabled" => false}} -> {:ok, 0}
      {:error, _reason} = error -> error
    end
  end

  defp now(%{"now" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_source_sync_time}
    end
  end

  defp now(_args), do: {:ok, DateTime.utc_now(:microsecond)}
end
