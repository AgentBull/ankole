defmodule Ankole.Authn.Action do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, opts, _context) do
    Ankole.Authn.Strategy.action(
      Keyword.fetch!(opts, :strategy),
      opts[:phase],
      input.arguments,
      input.context[:authn_options] || []
    )
    |> Ankole.Errors.wrap()
  end
end
