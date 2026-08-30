defmodule Ankole.Brain.SourcesTest do
  use Ankole.DataCase, async: true

  alias Ankole.Brain.Sources
  alias Ankole.Brain.Schemas.Object
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

  test "archive withdraws only pages owned by a Library Source" do
    suffix = System.unique_integer([:positive])

    assert {:ok, library_source} =
             Sources.create(%{
               kind: "library",
               upstream_id: "library-#{suffix}",
               name: "Library"
             })

    assert {:ok, file_source} =
             Sources.create(%{
               kind: "file",
               upstream_id: "/tmp/source-#{suffix}.txt",
               name: "File"
             })

    now = DateTime.utc_now(:microsecond)

    page =
      Repo.insert!(%Object{
        slug: "concepts/source-archive-#{suffix}",
        type: "concept",
        title: "Source archive",
        body: "Managed body",
        meta: %{},
        emotional_weight: 0.0,
        managed_by_source_id: library_source.id,
        created_at: now,
        updated_at: now
      })

    assert {:ok, _archived_file} = Sources.archive(file_source.id)
    assert Repo.get!(Object, page.id).deleted_at == nil

    assert {:ok, _archived_library} = Sources.archive(library_source.id)
    assert Repo.get!(Object, page.id).deleted_at != nil
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
