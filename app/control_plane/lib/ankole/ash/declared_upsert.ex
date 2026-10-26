defmodule Ankole.Ash.DeclaredUpsert do
  @moduledoc """
  Keeps a tenant upsert on the fields and the tenant condition of its action.

  AshPostgres sends an upsert without `Ankole.Repo.insert_all/3`, so the Repo
  cannot scope its conflict update. `Ankole.Ash.Transformers.TenantUpsertCondition`
  declares the tenant condition, and this change rejects a call that replaces
  that condition, adds fields, or adds atomics.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    private = changeset.context[:private] || %{}

    if private[:upsert?] do
      unless changeset.action.upsert? and
               private[:upsert_condition] == changeset.action.upsert_condition and
               valid_upsert_fields?(private[:upsert_fields], changeset.action.upsert_fields) and
               changeset.atomics == [] and
               changeset.create_atomics == [] do
        raise ArgumentError,
              "tenant upserts require the declared fields and tenant condition without atomics"
      end
    end

    changeset
  end

  defp valid_upsert_fields?([], []), do: true

  defp valid_upsert_fields?(fields, declared),
    do: is_list(fields) and fields != [] and Enum.all?(fields, &(&1 in declared))
end
