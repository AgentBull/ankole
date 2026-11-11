defmodule Ankole.Repo.Migrations.RecordAIGatewayCapabilityUsage do
  use Ecto.Migration

  # A usage row names the capability that the provider call served. A call that
  # is not a language-model round also records what it produced as a `unit` and
  # a `quantity`, such as one image, and the cost when the Provider reports one.
  # Every row written before these columns existed is a language-model round.
  def change do
    alter table(:ai_gateway_usage_records) do
      add :capability, :text, null: false, default: "llm"
      add :unit, :text
      add :quantity, :bigint
      add :provider_cost, :decimal
    end

    create constraint(
             :ai_gateway_usage_records,
             :ai_gateway_usage_records_capability_check,
             check: "capability IN ('llm', 'image_generate', 'decision')"
           )

    create constraint(
             :ai_gateway_usage_records,
             :ai_gateway_usage_records_quantity_check,
             check: "(unit IS NULL AND quantity IS NULL) OR (unit IN ('image') AND quantity >= 0)"
           )

    create constraint(
             :ai_gateway_usage_records,
             :ai_gateway_usage_records_provider_cost_check,
             check: "provider_cost IS NULL OR provider_cost >= 0"
           )
  end
end
