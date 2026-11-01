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
      Ankole.Repo.transact(fn ->
        case record do
          %Ankole.Pod.Page{} ->
            if action in [:edit, :position, :advance_revision] do
              Ankole.Pod.Pages.update_properties_in_tx(record, action, attrs)
            else
              {:ok, node} = Ankole.Files.Nodes.fetch(record.id)

              attrs =
                if action == :begin_purge,
                  do: Map.put(attrs, :purge_started_at, DateTime.utc_now(:microsecond)),
                  else: attrs

              with {:ok, _} <- Ankole.Files.Nodes.update_in_tx(node, action, attrs),
                   do: Ankole.Pod.Pages.fetch(record.id)
            end

          _ ->
            Ankole.Ash.update(record, action, attrs)
        end
      end)

    record
  end

  # Fixture callers make a fresh policy change. Tests of stale snapshots call
  # Pages.set_sharing directly and keep their original token.
  def set_sharing(uid, id, attrs, authority \\ nil) do
    with {:ok, sharing} <- Pages.sharing(Ankole.PrincipalsFixtures.actor_fixture(uid), id) do
      attrs = Map.put_new(attrs, :sharing_version, sharing.sharing_version)
      Pages.set_sharing(Ankole.PrincipalsFixtures.actor_fixture(uid), id, attrs, authority)
    end
  end
end
