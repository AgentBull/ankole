defmodule Ankole.Repo.Migrations.V0622Baseline do
  @moduledoc false

  use Ecto.Migration

  @baseline_path Path.join(__DIR__, "v0622_baseline.sql")
  @external_resource @baseline_path
  @baseline_sql File.read!(@baseline_path)

  def up do
    execute(fn ->
      repo().query!(@baseline_sql, [], query_type: :text, timeout: :infinity)
    end)
  end

  def down do
    raise Ecto.MigrationError,
      message: "the v0.62.2 fresh-install baseline cannot be reversed"
  end
end
