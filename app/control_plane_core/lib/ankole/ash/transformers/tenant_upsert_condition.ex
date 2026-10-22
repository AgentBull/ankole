defmodule Ankole.Ash.Transformers.TenantUpsertCondition do
  @moduledoc false
  use Spark.Dsl.Transformer
  import Ash.Expr
  alias Spark.Dsl.Transformer

  def after?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def after?(_), do: false

  def transform(dsl) do
    if Transformer.get_persisted(dsl, :ankole_tenancy) == :tenant do
      Enum.reduce(Transformer.get_entities(dsl, [:actions]), {:ok, dsl}, fn
        %{type: :create, upsert?: true} = action, {:ok, dsl} ->
          condition = expr(tenant_id == ^tenant())

          condition =
            if is_nil(action.upsert_condition),
              do: condition,
              else: expr(^action.upsert_condition and ^condition)

          {:ok,
           Transformer.replace_entity(
             dsl,
             [:actions],
             %{action | upsert_condition: condition},
             &(&1.name == action.name)
           )}

        _, result ->
          result
      end)
    else
      {:ok, dsl}
    end
  end
end
