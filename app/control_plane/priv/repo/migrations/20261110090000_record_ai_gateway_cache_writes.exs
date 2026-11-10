defmodule Ankole.Repo.Migrations.RecordAIGatewayCacheWrites do
  use Ecto.Migration

  # A usage row records the prompt-cache write portion of the input beside the
  # cache read portion. The column is NULL when the Provider did not report a
  # cache write, which includes every row written before this column existed.
  def change do
    alter table(:ai_gateway_usage_records) do
      add :cache_creation_input_tokens, :bigint
    end

    create constraint(
             :ai_gateway_usage_records,
             :ai_gateway_usage_records_cache_creation_input_tokens_check,
             check: "cache_creation_input_tokens IS NULL OR cache_creation_input_tokens >= 0"
           )
  end
end
