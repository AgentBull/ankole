defmodule Ankole.Ash.Extension do
  @moduledoc false
  use Spark.Dsl.Extension,
    transformers: [
      Ankole.Ash.Transformers.TenantUpsertCondition,
      Ankole.Ash.Transformers.StateEctoType,
      Ankole.Ash.Verifiers.Contracts
    ]
end
