defmodule Ankole.Brain.Jobs.CuratePrincipal do
  @moduledoc false

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: 172_800,
      keys: [:principal_uid, :local_date],
      states: :all
    ]

  alias Ankole.Brain

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"principal_uid" => principal_uid}})
      when is_binary(principal_uid) do
    case Brain.run_dreaming(principal_uid) do
      {:ok, %{status: :already_running}} -> {:snooze, 60}
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_principal_dreaming_job}
end
