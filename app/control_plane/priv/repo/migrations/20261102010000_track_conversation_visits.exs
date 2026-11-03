defmodule Ankole.Repo.Migrations.TrackConversationVisits do
  use Ecto.Migration

  def change do
    alter table(:conversation_participants) do
      add :last_visited_at, :utc_datetime_usec
    end
  end
end
