defmodule Ankole.Ash.Transformers.DomainDefaults do
  @moduledoc """
  Gives each domain code interface function the tenant of the calling process.

  A define gets `default_options: &Ankole.Ash.default_options/0` and only the
  action functions; Principal/AuthZ owns the authorization checks. A define
  that sets its own default options is rejected: the caller passes other
  options at the call.
  """
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @default_functions [:subject, :can, :can?, :action, :action!]

  def transform(dsl) do
    dsl
    |> Transformer.get_entities([:resources])
    |> Enum.reduce_while({:ok, dsl}, fn reference, {:ok, dsl} ->
      case Enum.find(reference.definitions, &own_options?/1) do
        nil ->
          reference = %{reference | definitions: Enum.map(reference.definitions, &defaults/1)}

          {:cont,
           {:ok,
            Transformer.replace_entity(
              dsl,
              [:resources],
              reference,
              &(&1.resource == reference.resource)
            )}}

        define ->
          {:halt,
           {:error,
            Spark.Error.DslError.exception(
              module: Transformer.get_persisted(dsl, :module),
              path: [:resources, :resource, :define, define.name],
              message: "a define receives its options from Ankole.Ash.default_options/0"
            )}}
      end
    end)
  end

  defp own_options?(%Ash.Resource.Interface{default_options: options}), do: options != []
  defp own_options?(_definition), do: false

  defp defaults(%Ash.Resource.Interface{} = define) do
    functions =
      if define.functions == @default_functions, do: [:action, :action!], else: define.functions

    %{define | default_options: &Ankole.Ash.default_options/0, functions: functions}
  end

  defp defaults(definition), do: definition
end
