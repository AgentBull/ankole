defmodule Ankole.Brain.Schemas.Timeline.Actions do
  @moduledoc """
  Runs the generic actions of `Ankole.Brain.Schemas.Timeline`.
  """
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context), do: action(input.action.name, input, context)

  defp action(:write_timeline, %{arguments: args}, _context) do
    args.attrs
    |> Ankole.Brain.Timelines.write_timeline_in_tx(args.writer, args.options)
    |> Ankole.Errors.wrap()
  end
end
