defmodule Ankole.Authn.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @impl true
  def after?(Ankole.Ash.Transformers.CallerTransaction), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl) do
    strategies = Spark.Dsl.Transformer.get_entities(dsl, [:authn, :strategies])

    dsl = Enum.reduce(strategies, dsl, &add_actions/2)
    {:ok, Transformer.persist(dsl, :authn_strategies, Map.new(strategies, &{&1.name, &1}))}
  end

  defp add_actions(strategy, dsl) do
    Enum.reduce(phases(strategy), dsl, fn {phase, returns, arguments}, dsl ->
      action =
        Transformer.build_entity!(Ash.Resource.Dsl, [:actions], :action,
          name: String.to_atom("#{strategy.name}_#{phase}"),
          returns: returns,
          transaction?: false,
          public?: false,
          run: {Ankole.Authn.Action, strategy: strategy, phase: phase},
          arguments: Enum.map(arguments, &argument/1)
        )

      Transformer.add_entity(dsl, [:actions], action)
    end)
  end

  defp phases(%Ankole.Authn.Strategies.Otp{}) do
    common = [
      {:browser, :map, false},
      {:flow, Ankole.Ash.Types.UUIDv7, true},
      {:source, :string, false}
    ]

    [
      {:request, :map, common ++ [{:email, :string, false}]},
      {:verify, :map,
       common ++ [{:challenge_id, Ankole.Ash.Types.UUIDv7, false}, {:code, :string, false}]}
    ]
  end

  defp phases(%Ankole.Authn.Strategies.Oidc{}) do
    [
      {:authorize, :string, [{:provider_id, :string, false}]},
      {:callback, :map, [{:provider_id, :string, false}, {:code, :string, false}]}
    ]
  end

  defp argument({name, type, allow_nil?}) do
    Transformer.build_entity!(Ash.Resource.Dsl, [:actions, :action], :argument,
      name: name,
      type: type,
      allow_nil?: allow_nil?,
      sensitive?: name == :code
    )
  end
end
