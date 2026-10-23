defmodule Ankole.Setup.Operations do
  @moduledoc """
  The generic action that completes the first setup in one transaction.

  The root claim, the Brain schema packs, and the completed flag commit
  together. The resource keeps no rows.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Setup, operations: true

  actions do
    action :complete, :term do
      argument(:principal_uid, :term, allow_nil?: false)
      argument(:brain_packs, {:array, :string}, default: [])

      run(fn %{arguments: args}, _context ->
        Ankole.Repo
        |> Ankole.Setup.Completion.complete_in_tx(args.principal_uid, args.brain_packs)
        |> Ankole.Errors.wrap()
      end)
    end
  end
end
