defmodule Ankole.Pod.PagesFixtures do
  @moduledoc false
  alias Ankole.Pod.Pages

  def create_record!(resource, action, attrs) do
    {:ok, record} =
      Ankole.Repo.transact(fn -> Ankole.Ash.create(resource, action, attrs) end)

    record
  end

  def update_record!(record, action, attrs \\ %{}) do
    {:ok, record} =
      Ankole.Repo.transact(fn -> Ankole.Ash.update(record, action, attrs) end)

    record
  end

  # Fixture callers make a fresh policy change. Tests of stale snapshots call
  # Pages.set_sharing directly and keep their original token.
  def set_sharing(uid, id, attrs, authority \\ nil) do
    with {:ok, sharing} <- Pages.sharing(uid, id) do
      attrs = Map.put_new(attrs, :sharing_version, sharing.sharing_version)
      Pages.set_sharing(uid, id, attrs, authority)
    end
  end
end
