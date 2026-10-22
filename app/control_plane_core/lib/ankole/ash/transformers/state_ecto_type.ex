defmodule Ankole.Ash.Transformers.StateEctoType do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(AshStateMachine.Transformers.AddState), do: true
  def after?(_), do: false
  def before?(Ash.Resource.Transformers.AttributesByName), do: true
  def before?(_), do: false

  def transform(dsl) do
    if Transformer.get_entities(dsl, [:state_machine, :transitions]) == [] do
      {:ok, dsl}
    else
      name = Transformer.get_option(dsl, [:state_machine], :state_attribute, :state)
      attribute = Ash.Resource.Info.attribute(dsl, name)
      attribute = %{attribute | type: Ankole.Ash.Types.State}
      {:ok, Transformer.replace_entity(dsl, [:attributes], attribute, &(&1.name == name))}
    end
  end
end
