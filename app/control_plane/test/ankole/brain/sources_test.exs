defmodule Ankole.Brain.SourcesTest do
  use Ankole.DataCase, async: true

  alias Ankole.Brain.Sources
  alias Ankole.Repo

  test "strict creation rejects a duplicate while idempotent registration reuses it" do
    attrs = %{
      kind: "url",
      upstream_id: "https://example.com/source",
      name: "First name",
      default_audience_scope: "world"
    }

    assert {:ok, first} = Sources.create(attrs)
    assert {:error, %Ecto.Changeset{}} = Sources.create(attrs)

    assert {:ok, reused} =
             attrs
             |> Map.put(:name, "Later name")
             |> Map.put(:default_audience_scope, "principal:someone")
             |> Sources.get_or_create()

    assert reused.id == first.id
    assert reused.name == first.name
    assert reused.default_audience_scope == first.default_audience_scope
  end

  test "archive is idempotent and keeps the first timestamp" do
    assert {:ok, source} =
             Sources.create(%{
               kind: "file",
               upstream_id: "/tmp/source.txt",
               name: "Source"
             })

    assert {:ok, first} = Sources.archive(source.id)
    assert {:ok, second} = Sources.archive(source.id)
    assert second.archived_at == first.archived_at
  end

  test "active locks and revision writes share the Source lifecycle" do
    assert {:ok, source} =
             Sources.get_or_create(%{
               kind: "library",
               upstream_id: "library",
               name: "Library"
             })

    assert {:ok, locked} =
             Repo.transact(fn repo -> Sources.lock_active(repo, source) end)

    assert locked.id == source.id

    assert {:ok, revised} = Sources.record_revision(Repo, source, "revision-1")
    assert revised.upstream_revision == "revision-1"
    assert %DateTime{} = revised.last_sync_at

    assert {:ok, archived} = Sources.archive(source.id)
    assert {:error, :source_archived} = Repo.transact(&Sources.lock_active(&1, archived))
  end
end
