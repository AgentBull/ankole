defmodule Ankole.Repo.Migrations.KeepBrowserConsoleLoginPurpose do
  use Ecto.Migration

  def change do
    alter table(:browser_authentications) do
      add :console_authenticated, :boolean, null: false, default: false
    end
  end
end
