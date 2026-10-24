defmodule Ankole.Brain.SourcesTest do
  use Ankole.DataCase, async: true

  alias Ankole.Brain.Sources
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Repo

  test "recording an extraction watermark keeps Source list ordering" do
    assert {:ok, source} =
             Sources.create(%{kind: "conversation", upstream_id: "channel-1", name: "Channel"})

    boundary = {~U[2026-08-20 10:00:00.123456Z], 9}
    assert :ok = Sources.record_extraction_watermark(source, boundary)
    current = Repo.get!(Source, source.id)
    assert Sources.extraction_watermark(current) == 9
    assert current.updated_at == source.updated_at
  end

  test "a channel watermark is absent until a Source records its complete boundary" do
    assert Sources.conversation_extraction_watermark("channel-1") == nil

    assert {:ok, source} =
             Sources.create(%{kind: "conversation", upstream_id: "channel-1", name: "Channel"})

    assert Sources.conversation_extraction_watermark("channel-1") == nil
    boundary = {~U[2026-08-20 10:00:00.123456Z], 9}
    assert :ok = Sources.record_extraction_watermark(source, boundary)
    assert Sources.conversation_extraction_watermark("channel-1") == 9
  end

  test "strict creation rejects a duplicate while idempotent registration reuses it" do
    attrs = %{
      kind: "url",
      upstream_id: "https://example.com/source",
      name: "First name",
      default_audience_scope: "world"
    }

    assert {:ok, first} = Sources.create(attrs)
    assert {:error, %Ash.Error.Invalid{errors: errors}} = Sources.create(attrs)

    assert [
             %Ash.Error.Changes.InvalidAttribute{field: :kind, message: "has already been taken"} =
               duplicate
           ] = errors

    assert duplicate.private_vars[:constraint] == "brain_sources_kind_upstream_key"
    assert duplicate.private_vars[:constraint_type] == :unique

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

    assert {:ok, first} = Ankole.Brain.archive_source(source.id)
    assert {:ok, second} = Ankole.Brain.archive_source(source.id)
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

    {:ok, page} =
      Repo.transact(fn ->
        Ankole.Ash.create(Object, :create_projection, %{
          slug: "concepts/source-archive-#{suffix}",
          type: "concept",
          title: "Source archive",
          body: "Managed body",
          meta: %{},
          managed_by_source_id: library_source.id,
          created_at: now,
          updated_at: now
        })
      end)

    assert {:ok, _archived_file} = Ankole.Brain.archive_source(file_source.id)
    assert Repo.get!(Object, page.id).deleted_at == nil

    assert {:ok, _archived_library} = Ankole.Brain.archive_source(library_source.id)
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
             Repo.transact(fn -> Sources.lock_active(source) end)

    assert locked.id == source.id

    assert {:ok, revised} = Sources.record_revision(source, "revision-1")
    assert revised.upstream_revision == "revision-1"
    assert %DateTime{} = revised.last_sync_at

    assert {:ok, archived} = Ankole.Brain.archive_source(source.id)
    assert {:error, :source_archived} = Repo.transact(fn -> Sources.lock_active(archived) end)
  end
end
