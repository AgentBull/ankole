defmodule BullX.Repo.Migrations.CreateGatewayInfrastructure do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)

    execute("CREATE TYPE gateway_outbound_op AS ENUM ('send', 'edit')")
    execute("CREATE TYPE gateway_outbound_status AS ENUM ('pending', 'running', 'terminalizing')")
    execute("CREATE TYPE gateway_stream_strategy AS ENUM ('native', 'post_edit', 'buffered')")

    execute(
      "CREATE TYPE gateway_stream_status AS ENUM ('active', 'terminalizing', 'succeeded', 'failed', 'cancelled')"
    )

    execute("CREATE TYPE gateway_delivery_receipt_status AS ENUM ('succeeded', 'dead_lettered')")

    execute("""
    CREATE UNLOGGED TABLE gateway_outbound_dispatches (
      delivery_id uuid NOT NULL,
      generation integer NOT NULL,
      op gateway_outbound_op NOT NULL,
      status gateway_outbound_status NOT NULL,
      adapter text NOT NULL,
      channel_id text NOT NULL,
      scope_id text NOT NULL,
      delivery jsonb NOT NULL,
      terminal_outcome jsonb,
      attempts integer NOT NULL DEFAULT 0,
      next_attempt_at timestamptz(6) NOT NULL,
      locked_by text,
      locked_at timestamptz(6),
      inserted_at timestamptz(6) NOT NULL,
      updated_at timestamptz(6) NOT NULL,
      PRIMARY KEY (delivery_id, generation)
    )
    """)

    create index(:gateway_outbound_dispatches, [:status, :next_attempt_at])
    create index(:gateway_outbound_dispatches, [:adapter, :channel_id, :scope_id])

    execute("""
    CREATE UNLOGGED TABLE gateway_stream_sessions (
      stream_id uuid NOT NULL PRIMARY KEY,
      delivery_id uuid NOT NULL,
      generation integer NOT NULL,
      adapter text NOT NULL,
      channel_id text NOT NULL,
      scope_id text NOT NULL,
      strategy gateway_stream_strategy NOT NULL,
      status gateway_stream_status NOT NULL,
      last_seq bigint NOT NULL DEFAULT 0,
      terminal_outcome jsonb,
      expires_at timestamptz(6) NOT NULL,
      inserted_at timestamptz(6) NOT NULL,
      updated_at timestamptz(6) NOT NULL
    )
    """)

    create unique_index(:gateway_stream_sessions, [:delivery_id, :generation])
    create index(:gateway_stream_sessions, [:status, :expires_at])
    create index(:gateway_stream_sessions, [:adapter, :channel_id, :scope_id])

    execute("""
    CREATE UNLOGGED TABLE gateway_stream_chunks (
      stream_id uuid NOT NULL,
      seq bigint NOT NULL,
      chunk jsonb NOT NULL,
      inserted_at timestamptz(6) NOT NULL,
      expires_at timestamptz(6) NOT NULL,
      PRIMARY KEY (stream_id, seq)
    )
    """)

    create index(:gateway_stream_chunks, [:expires_at])

    create table(:gateway_delivery_receipts, primary_key: false) do
      add :delivery_id, :uuid, primary_key: true
      add :generation, :integer, primary_key: true
      add :adapter, :text, null: false
      add :channel_id, :text, null: false
      add :scope_id, :text, null: false
      add :terminal_status, :gateway_delivery_receipt_status, null: false
      add :outcome_signal_id, :uuid, null: false
      add :dead_letter_id, :uuid
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:gateway_delivery_receipts, [:adapter, :channel_id, :scope_id])
    create index(:gateway_delivery_receipts, [:dead_letter_id])

    create table(:gateway_dead_letters, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :delivery_id, :uuid, null: false
      add :adapter, :text, null: false
      add :channel_id, :text, null: false
      add :scope_id, :text, null: false
      add :thread_id, :text
      add :delivery, :map
      add :summary, :map, null: false
      add :last_error, :map, null: false
      add :attempts_total, :integer, null: false
      add :replayable, :boolean, null: false
      add :replay_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gateway_dead_letters, [:delivery_id])
    create index(:gateway_dead_letters, [:adapter, :channel_id, :scope_id])

    create constraint(
             :gateway_dead_letters,
             :gateway_dead_letters_replayable_snapshot,
             check:
               "(replayable AND delivery IS NOT NULL) OR ((NOT replayable) AND delivery IS NULL)"
           )
  end

  def down do
    drop constraint(:gateway_dead_letters, :gateway_dead_letters_replayable_snapshot)
    drop table(:gateway_dead_letters)
    drop table(:gateway_delivery_receipts)
    execute("DROP TABLE gateway_stream_chunks")
    execute("DROP TABLE gateway_stream_sessions")
    execute("DROP TABLE gateway_outbound_dispatches")
    execute("DROP TYPE gateway_delivery_receipt_status")
    execute("DROP TYPE gateway_stream_status")
    execute("DROP TYPE gateway_stream_strategy")
    execute("DROP TYPE gateway_outbound_status")
    execute("DROP TYPE gateway_outbound_op")

    Oban.Migration.down(version: 1)
  end
end
