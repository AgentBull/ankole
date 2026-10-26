defmodule Ankole.Authn.Verifier do
  @moduledoc false
  use Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    strategies = Spark.Dsl.Verifier.get_entities(dsl, [:authn, :strategies])
    names = Enum.map(strategies, & &1.name)
    add_ons = Spark.Dsl.Verifier.get_entities(dsl, [:authn, :add_ons])
    add_on_names = Enum.map(add_ons, & &1.name)

    if length(names) == length(Enum.uniq(names)) and
         length(add_on_names) == length(Enum.uniq(add_on_names)) do
      :ok
    else
      {:error,
       Spark.Error.DslError.exception(
         module: Spark.Dsl.Verifier.get_persisted(dsl, :module),
         path: [:authn, :strategies],
         message: "authentication strategy and add-on names must be unique"
       )}
    end
  end
end
