defmodule Ankole.Repo.Migrations.CreateEditionFixture do
  use Ecto.Migration

  def change do
    create table(:edition_fixture, primary_key: false) do
      add :id, :uuid, primary_key: true
    end
  end
end
