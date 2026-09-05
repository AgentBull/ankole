defmodule Ankole.Brain.RelationsTest do
  use Ankole.DataCase, async: true

  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Brain.Timelines

  setup do
    assert {:ok, _} = SchemaPacks.install_packs([])

    for slug <- ["notes/relation-source", "notes/relation-target"] do
      assert {:ok, _} =
               Objects.create_object(
                 %{slug: slug, type: "note", title: slug, body: "A note."},
                 :system
               )
    end

    :ok
  end

  test "repeated edges, tags, and aliases report a duplicate instead of an unstored ID" do
    attrs = %{from_object_slug: "notes/relation-source", to_object_slug: "notes/relation-target"}
    assert {:ok, %{id: id}} = Links.upsert_link(attrs)
    assert is_binary(id)
    assert {:ok, :duplicate} = Links.upsert_link(attrs)
    assert {:ok, %{id: _}} = Links.add_tag("notes/relation-source", "tag")
    assert {:ok, :duplicate} = Links.add_tag("notes/relation-source", "tag")
    assert {:ok, %{id: _}} = Links.add_alias("notes/relation-source", "alias")
    assert {:ok, :duplicate} = Links.add_alias("notes/relation-source", "alias")
  end

  test "reconciliation and delayed embeddings cannot restore an old body" do
    assert {:ok, old} = Objects.get_by_slug("notes/relation-source")
    old_chunk = Repo.get_by!(Chunk, object_id: old.id, chunk_index: 0)

    assert {:ok, _} =
             Objects.update_object(
               old.slug,
               %{body: "The current body.", expected_content_hash: old.content_hash},
               :system
             )

    assert {:ok, current} = Objects.reconcile_chunks(old)
    assert current.body == "The current body."
    chunk = Repo.get_by!(Chunk, object_id: old.id, chunk_index: 0)
    assert chunk.chunk_text == "The current body."

    vector = Pgvector.new(List.duplicate(0.5, 4096))
    assert {:ok, :stale} = Objects.record_chunk_embedding(old_chunk, {:ok, vector, "old-model"})
    assert {:ok, :updated} = Objects.record_chunk_embedding(chunk, {:ok, vector, "current-model"})

    assert {:ok, :stale} =
             Objects.record_chunk_embedding(chunk, {:error, "late failure", "old-model"})

    embedded = Repo.get!(Chunk, chunk.id)
    assert embedded.embedding_signature == "current-model"
    assert embedded.embedding != nil
    assert embedded.embedding_error == nil
  end

  test "a repeated timeline returns the persisted row and its original detail" do
    attrs = %{
      object_slug: "notes/relation-source",
      date: ~D[2026-09-05],
      summary: "Event",
      provenance: "test",
      audience_scope: "world",
      detail: "Original"
    }

    assert {:ok, first} = Timelines.write_timeline(attrs, :system)

    assert {:ok, repeated} =
             Timelines.write_timeline(%{attrs | detail: "Ignored duplicate"}, :system)

    assert repeated.id == first.id
    assert repeated.detail == "Original"
    assert Repo.get!(Timeline, repeated.id).detail == "Original"
  end
end
