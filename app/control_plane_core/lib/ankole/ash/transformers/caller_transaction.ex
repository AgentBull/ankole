defmodule Ankole.Ash.Transformers.CallerTransaction do
  @moduledoc """
  Sets the transaction owner of each action.

  A generic action owns its transaction. A create, update, or destroy action
  runs in the transaction of its calling generic action, or as one statement.
  It does not upgrade to an atomic write by itself, and its errors use the
  declared vocabulary of `Ankole.Errors`.
  """
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  @mutations [:create, :update, :destroy]

  def after?(module),
    do:
      module in [
        Ash.Resource.Transformers.DefaultAccept,
        Ash.Resource.Transformers.SetPrimaryActions,
        Ash.Resource.Transformers.SetActionTransactions,
        AshStateMachine.Transformers.AddState
      ]

  def before?(Ankole.Ash.Verifiers.Contracts), do: true
  def before?(_module), do: false

  def transform(dsl) do
    {:ok,
     dsl
     |> Transformer.get_entities([:actions])
     |> Enum.reduce(dsl, fn action, dsl ->
       Transformer.replace_entity(dsl, [:actions], defaults(action), &(&1.name == action.name))
     end)}
  end

  defp defaults(%{type: :action} = action), do: %{action | transaction?: true}

  defp defaults(%{type: type} = action) when type in @mutations do
    action = %{
      action
      | transaction?: false,
        error_handler: action.error_handler || {Ankole.Errors, :shape, []}
    }

    if type == :create, do: action, else: %{action | atomic_upgrade?: false}
  end

  defp defaults(action), do: action
end
