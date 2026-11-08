defmodule Ankole.Connectors.Jobs.RefreshDatabaseCatalog do
  @moduledoc "Rebuilds a database connection's catalog cache after the connection is saved."
  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 3,
    unique: [period: 60, fields: [:args], states: [:available, :scheduled, :retryable]]

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"auth_config_id" => id}}) do
    with {:ok, config} <- Ankole.Connectors.get_auth_config(id),
         {:ok, _} <- Ankole.Connectors.Databases.refresh_config(config) do
      :ok
    else
      # A disabled or removed connection has nothing to cache; a manual refresh repairs it later.
      {:error, reason} when reason in [:connection_disabled, :not_found, :connection_required] ->
        :ok

      error ->
        error
    end
  end
end
