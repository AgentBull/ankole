defmodule Ankole.Ash.ProcessTenant do
  @moduledoc "Requires the action tenant to match the calling process."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    check!(changeset)
    check_changes!(changeset)

    changeset
  end

  defp check_changes!(changeset) do
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
  end

  defp valid_upsert_fields?([], []), do: true

  defp valid_upsert_fields?(fields, declared),
    do: is_list(fields) and fields != [] and Enum.all?(fields, &(&1 in declared))

  @impl true
  def atomic(changeset, _opts, _context) do
    check!(changeset)
    :ok
  end

  def check!(subject) do
    if Map.get(subject.action, :multitenancy, :enforce) == :allow_global do
      unless Ankole.Repo.across_tenants?(),
        do: raise(ArgumentError, "global reads require Repo.across_tenants/1")
    else
      tenant = Ankole.Repo.tenant_id!()

      unless subject.tenant == tenant,
        do: raise(ArgumentError, "action tenant does not match the selected tenant")
    end
  end
end

defmodule Ankole.Ash.ProcessTenant.Preparation do
  @moduledoc false
  use Ash.Resource.Preparation

  @impl true
  def supports(_opts), do: [Ash.Query, Ash.ActionInput]

  @impl true
  def prepare(query, _opts, _context) do
    Ankole.Ash.ProcessTenant.check!(query)
    query
  end
end
