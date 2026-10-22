defmodule Ankole.Ash.TopLevel do
  @moduledoc """
  Requires a generic action to be the top-level call.

  A generic action owns its transaction. When it starts inside another
  transaction, its failure would roll back the outer transaction, and its
  after-commit work would run before the outer commit. Composition inside a
  transaction uses the `_in_tx` functions of the owning domain.
  """
  use Ash.Resource.Preparation

  @impl true
  def supports(_opts), do: [Ash.ActionInput]

  @impl true
  def prepare(input, _opts, _context) do
    Ash.ActionInput.before_transaction(input, fn input ->
      if Ankole.Repo.in_transaction?() do
        raise Ankole.Errors.Framework.NestedOperation,
          resource: input.resource,
          action: input.action.name
      end

      input
    end)
  end
end
