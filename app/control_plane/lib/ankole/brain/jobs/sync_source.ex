defmodule Ankole.Brain.Jobs.SyncSource do
  @moduledoc false

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [fields: [:args, :worker], keys: [:source_id], period: 3_600, states: :incomplete]

  alias Ankole.Brain.SourceSync

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) when is_binary(source_id) do
    case SourceSync.sync(source_id) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_source_sync_job}
end
