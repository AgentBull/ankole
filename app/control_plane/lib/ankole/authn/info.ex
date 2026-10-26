defmodule Ankole.Authn.Info do
  @moduledoc false
  use Spark.InfoGenerator, extension: Ankole.Authn, sections: [:authn]

  def run(resource, strategy_name, phase, params, opts \\ []) do
    case strategy(resource, strategy_name) do
      nil ->
        {:error, :unsupported_authentication_strategy}

      strategy ->
        action = String.to_existing_atom("#{strategy.name}_#{phase}")
        Ankole.Ash.run_action(resource, action, params, context: %{authn_options: opts})
    end
  end

  def run_add_on(resource, name, phase, params, opts \\ []) do
    case resource
         |> Spark.Dsl.Extension.get_entities([:authn, :add_ons])
         |> Enum.find(&(&1.name == name)) do
      %{module: {module, module_opts}} ->
        module.call(phase, params, Keyword.merge(module_opts, opts))

      nil ->
        {:error, :unsupported_authentication_add_on}
    end
  end

  def strategy(resource, name),
    do: resource |> Spark.Dsl.Extension.get_persisted(:authn_strategies, %{}) |> Map.get(name)
end
