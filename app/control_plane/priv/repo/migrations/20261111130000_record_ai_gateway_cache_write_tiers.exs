defmodule Ankole.Repo.Migrations.RecordAIGatewayCacheWriteTiers do
  use Ecto.Migration

  # A usage row records the cache-write total beside its 30-minute and 12-hour
  # portions when the Provider reports the split. A column is NULL when the
  # Provider did not report that portion, which includes every row written
  # before these columns existed and Providers that report only the total.
  def change do
    alter table(:ai_gateway_usage_records) do
      add :cache_creation_30m_input_tokens, :bigint
      add :cache_creation_12h_input_tokens, :bigint
    end

    create constraint(
             :ai_gateway_usage_records,
             :ai_gateway_usage_records_cache_creation_30m_input_tokens_check,
             check:
               "cache_creation_30m_input_tokens IS NULL OR cache_creation_30m_input_tokens >= 0"
           )

    create constraint(
             :ai_gateway_usage_records,
             :ai_gateway_usage_records_cache_creation_12h_input_tokens_check,
             check:
               "cache_creation_12h_input_tokens IS NULL OR cache_creation_12h_input_tokens >= 0"
           )
  end
end
