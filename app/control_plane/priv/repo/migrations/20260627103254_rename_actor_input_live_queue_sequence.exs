defmodule Ankole.Repo.Migrations.RenameActorInputLiveQueueSequence do
  use Ecto.Migration

  def change do
    execute(
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND table_name = 'actor_inputs'
            AND column_name = 'broker_sequence'
        ) AND NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND table_name = 'actor_inputs'
            AND column_name = 'live_queue_sequence'
        ) THEN
          ALTER TABLE actor_inputs RENAME COLUMN broker_sequence TO live_queue_sequence;
        END IF;

        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND table_name = 'actor_input_deliveries'
            AND column_name = 'broker_sequence'
        ) AND NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND table_name = 'actor_input_deliveries'
            AND column_name = 'live_queue_sequence'
        ) THEN
          ALTER TABLE actor_input_deliveries RENAME COLUMN broker_sequence TO live_queue_sequence;
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_class WHERE relname = 'actor_inputs_actor_sequence_index'
        ) AND NOT EXISTS (
          SELECT 1 FROM pg_class WHERE relname = 'actor_inputs_live_queue_sequence_index'
        ) THEN
          ALTER INDEX actor_inputs_actor_sequence_index RENAME TO actor_inputs_live_queue_sequence_index;
        END IF;
      END $$;
      """,
      """
      DO $$
      BEGIN
        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND table_name = 'actor_inputs'
            AND column_name = 'live_queue_sequence'
        ) AND NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND table_name = 'actor_inputs'
            AND column_name = 'broker_sequence'
        ) THEN
          ALTER TABLE actor_inputs RENAME COLUMN live_queue_sequence TO broker_sequence;
        END IF;

        IF EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND table_name = 'actor_input_deliveries'
            AND column_name = 'live_queue_sequence'
        ) AND NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND table_name = 'actor_input_deliveries'
            AND column_name = 'broker_sequence'
        ) THEN
          ALTER TABLE actor_input_deliveries RENAME COLUMN live_queue_sequence TO broker_sequence;
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_class WHERE relname = 'actor_inputs_live_queue_sequence_index'
        ) AND NOT EXISTS (
          SELECT 1 FROM pg_class WHERE relname = 'actor_inputs_actor_sequence_index'
        ) THEN
          ALTER INDEX actor_inputs_live_queue_sequence_index RENAME TO actor_inputs_actor_sequence_index;
        END IF;
      END $$;
      """
    )

    execute(
      """
      COMMENT ON COLUMN actor_inputs.live_queue_sequence IS
        'Per-session sequence for ordering currently open actor inputs.'
      """,
      """
      COMMENT ON COLUMN actor_inputs.broker_sequence IS
        'Monotonic per-agent-session sequence used for queue ordering.';
      """
    )

    execute(
      """
      COMMENT ON COLUMN actor_input_deliveries.live_queue_sequence IS
        'Live queue sequence copied from actor_inputs.'
      """,
      """
      COMMENT ON COLUMN actor_input_deliveries.broker_sequence IS
        'Per-session input sequence copied from actor_inputs.';
      """
    )
  end
end
