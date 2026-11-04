defmodule Ankole.Repo.Migrations.CreateNextStepSuggestions do
  use Ecto.Migration

  # The next steps a personal assistant offered a Human on the chat home. Every
  # row of one menu shares `last_offered_at`, which therefore identifies the
  # latest menu, and `position` keeps the menu's order. `offer_count` counts the
  # menus that offered the step, so a step offered in two menus without being
  # chosen is not offered again.
  def up do
    execute """
    CREATE TABLE next_step_suggestions (
      tenant_id       uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id              uuid NOT NULL,
      human_uid       text NOT NULL,
      title           text NOT NULL CHECK (length(btrim(title)) > 0),
      outcome         text NOT NULL CHECK (length(btrim(outcome)) > 0),
      effort          text NOT NULL CHECK (length(btrim(effort)) > 0),
      why_now         text NOT NULL CHECK (length(btrim(why_now)) > 0),
      ambitious       boolean NOT NULL DEFAULT false,
      position        integer NOT NULL CHECK (position >= 0),
      offer_count     integer NOT NULL CHECK (offer_count >= 1),
      last_offered_at timestamptz NOT NULL,
      chosen_at       timestamptz,
      inserted_at     timestamptz NOT NULL,
      updated_at      timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, id),
      CONSTRAINT next_step_suggestions_human_fkey FOREIGN KEY (tenant_id, human_uid)
        REFERENCES principals (tenant_id, uid) ON UPDATE CASCADE ON DELETE CASCADE
    )
    """

    execute """
    CREATE INDEX next_step_suggestions_menu_index
      ON next_step_suggestions (tenant_id, human_uid, last_offered_at DESC)
    """
  end

  def down do
    execute "DROP TABLE next_step_suggestions"
  end
end
