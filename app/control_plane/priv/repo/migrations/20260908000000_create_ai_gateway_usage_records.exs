defmodule Ankole.Repo.Migrations.CreateAIGatewayUsageRecords do
  use Ecto.Migration

  def change do
    create table(:ai_gateway_usage_records, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :subject_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :origin, :text, null: false
      add :model, :text, null: false
      add :input_tokens, :bigint, null: false
      add :output_tokens, :bigint, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_origin_check,
             check: "origin IN ('agent', 'codex')"
           )

    create constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_input_tokens_check,
             check: "input_tokens >= 0"
           )

    create constraint(:ai_gateway_usage_records, :ai_gateway_usage_records_output_tokens_check,
             check: "output_tokens >= 0"
           )

    create index(:ai_gateway_usage_records, [:subject_uid, :inserted_at])
  end
end
