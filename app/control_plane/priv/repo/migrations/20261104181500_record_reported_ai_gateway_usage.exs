defmodule Ankole.Repo.Migrations.RecordReportedAIGatewayUsage do
  use Ecto.Migration

  # A usage row records what the Provider reported. A count that the Provider
  # did not report is NULL instead of 0, the cache and reasoning portions get
  # their own columns, and the row names the reported model, the requested and
  # serving model profiles, and the Human that the work served. Like the other
  # attribution columns, the Human reference has no foreign key, so a stale uid
  # can never block quota accounting; Principal renames update it. Rows written
  # before this migration keep their recorded zeros, because the database
  # cannot tell which of them the Provider reported.
  def up do
    alter table(:ai_gateway_usage_records) do
      modify :input_tokens, :bigint, null: true
      modify :output_tokens, :bigint, null: true
      add :cached_input_tokens, :bigint
      add :reasoning_tokens, :bigint
      add :provider_model, :text
      add :model_profile, :text
      add :served_profile, :text
      add :human_uid, :text
    end

    create constraint(
             :ai_gateway_usage_records,
             :ai_gateway_usage_records_cached_input_tokens_check,
             check: "cached_input_tokens IS NULL OR cached_input_tokens >= 0"
           )

    create constraint(
             :ai_gateway_usage_records,
             :ai_gateway_usage_records_reasoning_tokens_check,
             check: "reasoning_tokens IS NULL OR reasoning_tokens >= 0"
           )

    create index(:ai_gateway_usage_records, [:tenant_id, :signal_id],
             where: "signal_id IS NOT NULL"
           )

    create index(:ai_gateway_usage_records, [:tenant_id, :inserted_at])
  end

  def down do
    drop index(:ai_gateway_usage_records, [:tenant_id, :inserted_at])
    drop index(:ai_gateway_usage_records, [:tenant_id, :signal_id])

    drop constraint(
           :ai_gateway_usage_records,
           :ai_gateway_usage_records_reasoning_tokens_check
         )

    drop constraint(
           :ai_gateway_usage_records,
           :ai_gateway_usage_records_cached_input_tokens_check
         )

    execute "UPDATE ai_gateway_usage_records SET input_tokens = 0 WHERE input_tokens IS NULL"
    execute "UPDATE ai_gateway_usage_records SET output_tokens = 0 WHERE output_tokens IS NULL"

    alter table(:ai_gateway_usage_records) do
      remove :human_uid
      remove :served_profile
      remove :model_profile
      remove :provider_model
      remove :reasoning_tokens
      remove :cached_input_tokens
      modify :input_tokens, :bigint, null: false
      modify :output_tokens, :bigint, null: false
    end
  end
end
