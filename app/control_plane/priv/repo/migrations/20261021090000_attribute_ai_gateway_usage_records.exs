defmodule Ankole.Repo.Migrations.AttributeAIGatewayUsageRecords do
  use Ecto.Migration

  # Each counted provider round records the Session, Signal, and Background
  # Agent Job attempt that caused it, so usage can be summed per Job or per
  # Session instead of by time window. The columns are nullable: an in-process
  # or external round has no such identity.
  def change do
    alter table(:ai_gateway_usage_records) do
      add :session_id, :text
      add :signal_id, :uuid
      add :job_id, :bigint
      add :attempt, :integer
    end

    create constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_job_id_check,
             check: "job_id IS NULL OR job_id > 0"
           )

    create constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_attempt_check,
             check: "attempt IS NULL OR attempt >= 0"
           )

    create index(:ai_gateway_usage_records, [:job_id], where: "job_id IS NOT NULL")

    create index(:ai_gateway_usage_records, [:session_id, :inserted_at],
             where: "session_id IS NOT NULL"
           )
  end
end
