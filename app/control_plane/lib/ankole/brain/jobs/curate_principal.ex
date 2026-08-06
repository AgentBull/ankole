defmodule Ankole.Brain.Jobs.CuratePrincipal do
  @moduledoc false

  use Oban.Worker,
    queue: :default,
    max_attempts: 20,
    unique: [
      period: :infinity,
      keys: [:principal_uid],
      states: :incomplete
    ]

  alias Ankole.Brain

  @max_backoff_seconds 3_600

  # The cap keeps a persistently failing batch at bounded hourly retries
  # instead of letting the default `attempt^4` growth push the chain days
  # out while its unique key suppresses every fresh enqueue.
  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    min(attempt ** 4 + 15, @max_backoff_seconds)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"principal_uid" => principal_uid}})
      when is_binary(principal_uid) do
    case Brain.run_dreaming(principal_uid) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_principal_dreaming_job}
end
