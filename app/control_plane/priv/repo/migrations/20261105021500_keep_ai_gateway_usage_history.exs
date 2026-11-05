defmodule Ankole.Repo.Migrations.KeepAIGatewayUsageHistory do
  use Ecto.Migration

  # The usage ledger is history, so deleting the Principal that made a round
  # keeps its row. Like the attribution columns, `subject_uid` then joins its
  # Principal by value, and Principal renames rewrite it.
  def up do
    drop constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_subject_uid_fkey)
  end

  # Rows of deleted Principals remain, so the restored key checks only new rows.
  def down do
    execute("""
    ALTER TABLE ai_gateway_usage_records
      ADD CONSTRAINT ai_gateway_usage_records_subject_uid_fkey
      FOREIGN KEY (tenant_id, subject_uid) REFERENCES principals (tenant_id, uid)
      ON UPDATE CASCADE ON DELETE CASCADE NOT VALID
    """)
  end
end
