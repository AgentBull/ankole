defmodule Ankole.Repo.Migrations.CreateOban do
  # Oban 作业队列（用于定时调度等）。
  # Oban 自带的迁移负责建 oban_jobs / oban_peers 表。
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 1)
  end
end
