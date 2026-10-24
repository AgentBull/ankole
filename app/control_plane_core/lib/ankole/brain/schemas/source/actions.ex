defmodule Ankole.Brain.Schemas.Source.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Brain.Schemas.Source`.
  """
  use Ash.Resource.Actions.Implementation

  alias Ankole.Brain.Schemas.Source

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:console_register, %{arguments: args}, _context),
    do:
      Ankole.Brain.Console.result(
        Ankole.Brain.SourceLearning.register_source(args),
        Source
      )

  defp action(:console_learn, %{arguments: args}, _context) do
    with {:ok, _result} <-
           Ankole.Brain.Console.result(
             Ankole.Brain.SourceLearning.enqueue_learn(args.source_id),
             Source
           ),
         do: :ok
  end

  defp action(:archive_source, %{arguments: args}, _context) do
    Ankole.Brain.Console.result(
      Ankole.Brain.Sources.archive_in_tx(args.source_id),
      Source
    )
  end

  defp action(:update_default_scope, %{arguments: args}, _context) do
    args.source_id
    |> Ankole.Brain.Sources.update_default_scope_in_tx(args[:scope])
    |> Ankole.Brain.Console.result(Source)
  end
end
