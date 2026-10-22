defmodule Ankole.Repo.Migrations.ConstrainSessionJournalObjects do
  use Ecto.Migration

  def change do
    create constraint(:session_round_states, :session_round_states_pages_object,
             check: "jsonb_typeof(pages) = 'object'"
           )

    create constraint(:session_round_states, :session_round_states_results_object,
             check: "jsonb_typeof(results) = 'object'"
           )
  end
end
