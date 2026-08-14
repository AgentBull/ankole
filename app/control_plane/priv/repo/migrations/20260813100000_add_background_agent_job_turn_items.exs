defmodule Ankole.Repo.Migrations.AddBackgroundAgentJobTurnItems do
  use Ecto.Migration

  def change do
    create table(:background_agent_job_turn_items, primary_key: false) do
      add(
        :turn_id,
        references(:background_agent_job_turns, type: :uuid, on_delete: :delete_all),
        primary_key: true,
        null: false
      )

      add(:position, :integer, primary_key: true, null: false)
      add(:revision, :integer, null: false)
      add(:item_key, :text, null: false)
      add(:item, :map, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:background_agent_job_turn_items, [:turn_id, :item_key],
        name: :background_agent_job_turn_items_item_key_index
      )
    )

    create(
      constraint(
        :background_agent_job_turn_items,
        :baj_turn_items_position_nonnegative,
        check: "position >= 0"
      )
    )

    create(
      constraint(
        :background_agent_job_turn_items,
        :baj_turn_items_revision_nonnegative,
        check: "revision >= 0"
      )
    )

    create(
      constraint(
        :background_agent_job_turn_items,
        :baj_turn_items_item_key_present,
        check: "length(btrim(item_key)) > 0"
      )
    )

    create(
      constraint(
        :background_agent_job_turn_items,
        :baj_turn_items_item_check,
        check: """
        jsonb_typeof(item) = 'object' AND
        jsonb_typeof(item->'type') = 'string'
        """
      )
    )
  end
end
