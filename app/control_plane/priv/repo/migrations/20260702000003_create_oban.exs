defmodule Ankole.Repo.Migrations.CreateOban do
  # Oban owns its queue schema; Ankole uses it for scheduled work and background retries.
  # Keeping this as the upstream migration avoids hand-copying Oban table details.
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 1)
  end
end
