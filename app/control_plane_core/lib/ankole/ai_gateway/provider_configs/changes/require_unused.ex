defmodule Ankole.AIGateway.ProviderConfigs.Changes.RequireUnused do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ankole.AIGateway.ProviderConfigs.provider_references(
           Ankole.Repo,
           changeset.data.provider_id
         ) do
      [] ->
        changeset

      references when is_list(references) ->
        Ash.Changeset.add_error(
          changeset,
          Ankole.Errors.Invalid.Rejected.exception(reason: {:provider_in_use, references})
        )

      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          Ankole.Errors.Invalid.Rejected.exception(reason: reason)
        )
    end
  end
end
