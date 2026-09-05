defmodule Ankole.Brain.ObjectsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Ecto.UUIDv7

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: human} = human_fixture()

    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: "brain-team-#{System.unique_integer([:positive])}",
        display_name: "Brain Team",
        domain: :operator,
        kind: :static
      })

    {:ok, _membership} = AuthZ.add_principal_to_group(human.uid, group.id)

    %{human: human, group: group}
  end

  describe "create_object/3" do
    test "reserves the Agent type and namespace even for system writers", %{human: human} do
      for writer <- [:system, human.uid] do
        assert {:error, {:reserved_object_type, "agent"}} =
                 Objects.create_object(%{slug: "notes/tool", type: "agent"}, writer)

        assert {:error, {:reserved_object_slug, "agents/tool"}} =
                 Objects.create_object(%{slug: "agents/tool", type: "note"}, writer)
      end

      refute "agent" in Objects.installed_type_names()
      refute "agent-skills" in Objects.installed_type_names()

      assert {:error, :invalid_canonical_principal} =
               Objects.ensure_canonical_object_in_tx(Repo, human.uid, :agent, "Forged")

      assert {:error, :invalid_canonical_principal} =
               Objects.ensure_canonical_object_in_tx(
                 Repo,
                 UUIDv7.autogenerate(),
                 :agent,
                 "Forged"
               )

      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      assert {:ok, object} = Objects.get_by_slug("agents/" <> agent.uid)
      assert object.type == "agent"
      assert object.subtype == "internal"

      assert {:error, {:reserved_object_type, "agent"}} =
               Objects.update_object(
                 object.slug,
                 %{subtype: "external", expected_content_hash: object.content_hash},
                 :system
               )

      assert {:ok, updated} =
               Objects.update_object(
                 object.slug,
                 %{
                   body: "This Agent handles research.",
                   expected_content_hash: object.content_hash
                 },
                 agent.uid
               )

      assert updated.body == "This Agent handles research."
    end

    test "Source projections cannot take the Agent namespace" do
      source = %Ankole.Brain.Schemas.Source{id: UUIDv7.autogenerate(), kind: "url"}

      assert {:error, {:reserved_object_slug, "agents/forged"}} =
               Objects.upsert_source_projection(source, %{slug: "agents/forged", type: "media"})
    end

    test "creates an object with chunks per audience scope", %{human: human, group: group} do
      body = """
      Public knowledge about the company.

      {% audience scope="group:#{group.name}" %}
      Team-only findings about the deal.
      {% /audience %}
      """

      assert {:ok, object} =
               Objects.create_object(
                 %{slug: "companies/acme", type: "company", title: "Acme", body: body},
                 human.uid
               )

      assert object.content_hash != nil
      assert object.chunking_signature != nil

      chunks =
        Chunk
        |> where([chunk], chunk.object_id == ^object.id)
        |> order_by([chunk], asc: chunk.chunk_index)
        |> Repo.all()

      assert Enum.map(chunks, & &1.audience_scope) == ["world", "group:#{group.name}"]
      assert Enum.map(chunks, & &1.chunk_index) == [0, 1]
      assert Enum.all?(chunks, &is_nil(&1.embedding))
    end

    test "rejects an undeclared type and lists the installed set", %{human: human} do
      assert {:error, {:unknown_object_type, "spaceship", details}} =
               Objects.create_object(
                 %{slug: "x/y", type: "spaceship", title: "X"},
                 human.uid
               )

      assert "note" in details.installed_types
      assert "company" in details.installed_types
    end

    test "rejects a group scope the writer does not satisfy", %{human: human} do
      {:ok, other_group} =
        AuthZ.create_principal_group(%{
          name: "other-team-#{System.unique_integer([:positive])}",
          display_name: "Other",
          domain: :operator,
          kind: :static
        })

      body = """
      {% audience scope="group:#{other_group.name}" %}
      secret
      {% /audience %}
      """

      assert {:error, {:writer_not_in_scope_group, _name}} =
               Objects.create_object(
                 %{slug: "notes/rejected", type: "note", title: "X", body: body},
                 human.uid
               )
    end

    test "rejects scopes that reference unknown groups or principals", %{human: human} do
      body = """
      {% audience scope="group:missing-group" %}
      x
      {% /audience %}
      """

      assert {:error, {:unknown_scope_group, "missing-group"}} =
               Objects.create_object(
                 %{slug: "notes/a", type: "note", title: "A", body: body},
                 human.uid
               )

      body = """
      {% audience scope="principal:missing-uid" %}
      x
      {% /audience %}
      """

      assert {:error, {:unknown_scope_principal, "missing-uid"}} =
               Objects.create_object(
                 %{slug: "notes/b", type: "note", title: "B", body: body},
                 :system
               )
    end
  end

  describe "update_object/4" do
    test "snapshots the previous body and applies CAS", %{human: human} do
      assert {:ok, object} =
               Objects.create_object(
                 %{slug: "notes/cas", type: "note", title: "CAS", body: "v1"},
                 human.uid
               )

      assert {:error, :content_hash_conflict} =
               Objects.update_object(
                 "notes/cas",
                 %{body: "v2", expected_content_hash: "stale"},
                 human.uid
               )

      assert {:ok, updated} =
               Objects.update_object(
                 "notes/cas",
                 %{body: "v2", expected_content_hash: object.content_hash},
                 human.uid
               )

      assert updated.body == "v2"
      assert updated.content_hash != object.content_hash

      versions =
        ObjectVersion
        |> where([version], version.object_id == ^object.id)
        |> Repo.all()

      assert [version] = versions
      assert version.body == "v1"
      assert version.author_uid == human.uid
    end

    test "chunk positions keep unchanged rows and reset changed ones", %{human: human} do
      body = "First paragraph stays.\n\nSecond paragraph changes."

      assert {:ok, object} =
               Objects.create_object(
                 %{slug: "notes/reconcile", type: "note", title: "R", body: body},
                 human.uid
               )

      # Mark chunk 0 as embedded so we can observe reuse and reset.
      chunk_zero = Repo.get_by!(Chunk, object_id: object.id, chunk_index: 0)

      chunk_zero
      |> Ecto.Changeset.change(
        embedding: Pgvector.new(List.duplicate(0.5, 4096)),
        embedding_signature: "sig",
        embedded_at: DateTime.utc_now(:microsecond)
      )
      |> Repo.update!()

      # The whole body is one chunk (short text merges); rewrite to change
      # its text: position 0 must reset its vector state.
      assert {:ok, _updated} =
               Objects.update_object(
                 "notes/reconcile",
                 %{
                   body: "First paragraph stays.\n\nSecond paragraph is different now.",
                   expected_content_hash: object.content_hash
                 },
                 human.uid
               )

      chunk_zero = Repo.get_by!(Chunk, object_id: object.id, chunk_index: 0)
      assert is_nil(chunk_zero.embedding)
      assert is_nil(chunk_zero.embedding_signature)
    end
  end

  describe "timeline chunks" do
    test "timelines compile after body with their own scope", %{human: human, group: group} do
      assert {:ok, object} =
               Objects.create_object(
                 %{slug: "events/kickoff", type: "event", title: "Kickoff", body: "Overview."},
                 human.uid
               )

      Repo.insert!(%Timeline{
        id: UUIDv7.autogenerate(),
        object_slug: "events/kickoff",
        date: ~D[2026-08-01],
        provenance: "test",
        summary: "Project kicked off",
        detail: "",
        audience_scope: "group:#{group.name}",
        created_at: DateTime.utc_now(:microsecond)
      })

      assert {:ok, _object} = Objects.reconcile_chunks(object)

      chunks =
        Chunk
        |> where([chunk], chunk.object_id == ^object.id)
        |> order_by([chunk], asc: chunk.chunk_index)
        |> Repo.all()

      assert [body_chunk, timeline_chunk] = chunks
      assert body_chunk.content_kind == "body"
      assert timeline_chunk.content_kind == "timeline"
      assert timeline_chunk.audience_scope == "group:#{group.name}"
      assert String.contains?(timeline_chunk.chunk_text, "2026-08-01")
      assert String.contains?(timeline_chunk.chunk_text, "Project kicked off")
    end
  end

  describe "resolve_slug/2 and valid_holder?/2" do
    test "resolves through slug aliases", %{human: human} do
      assert {:ok, _object} =
               Objects.create_object(
                 %{slug: "companies/new-name", type: "company", title: "New"},
                 human.uid
               )

      Repo.insert!(%Ankole.Brain.Schemas.SlugAlias{
        id: UUIDv7.autogenerate(),
        alias_slug: "companies/old-name",
        canonical_slug: "companies/new-name",
        created_at: DateTime.utc_now(:microsecond)
      })

      assert {:ok, object} = Objects.resolve_slug("companies/old-name")
      assert object.slug == "companies/new-name"

      assert Objects.valid_holder?("world")
      assert Objects.valid_holder?("brain")
      assert Objects.valid_holder?("companies/old-name")
      refute Objects.valid_holder?("companies/never-existed")
    end
  end

  describe "resolve_reference/2" do
    setup %{human: human} do
      {:ok, object} =
        Objects.create_object(
          %{slug: "companies/minghu-ai", type: "company", title: "Minghu AI"},
          human.uid
        )

      %{object: object}
    end

    test "resolves an exact slug and a slug-alias redirect", %{object: object} do
      assert {:ok, resolved} = Objects.resolve_reference(object.slug)
      assert resolved.slug == object.slug

      Repo.insert!(%Ankole.Brain.Schemas.SlugAlias{
        id: UUIDv7.autogenerate(),
        alias_slug: "companies/minghu",
        canonical_slug: object.slug,
        created_at: DateTime.utc_now(:microsecond)
      })

      assert {:ok, redirected} = Objects.resolve_reference("companies/minghu")
      assert redirected.slug == object.slug
    end

    test "resolves one natural-language alias and reports alias collisions", %{
      human: human,
      object: object
    } do
      {:ok, _alias} = Ankole.Brain.Links.add_alias(object.slug, "明湖 AI")

      assert {:ok, resolved} = Objects.resolve_reference("明湖 ai")
      assert resolved.slug == object.slug

      {:ok, _other} =
        Objects.create_object(
          %{slug: "companies/minghu-labs", type: "company", title: "Minghu Labs"},
          human.uid
        )

      {:ok, _alias} = Ankole.Brain.Links.add_alias("companies/minghu-labs", "明湖 AI")

      assert {:ambiguous, candidates} = Objects.resolve_reference("明湖 AI")
      assert Enum.map(candidates, & &1.slug) == [object.slug, "companies/minghu-labs"]
    end

    test "excludes soft-deleted targets before deciding alias ambiguity", %{
      human: human,
      object: object
    } do
      alias_text = "Shared company alias"
      assert {:ok, _alias} = Ankole.Brain.Links.add_alias(object.slug, alias_text)

      assert {:ok, other} =
               Objects.create_object(
                 %{slug: "companies/deleted-alias-target", type: "company", title: "Other"},
                 human.uid
               )

      assert {:ok, _alias} = Ankole.Brain.Links.add_alias(other.slug, alias_text)
      assert {:ambiguous, _candidates} = Objects.resolve_reference(alias_text)
      assert {:ok, _deleted} = Objects.soft_delete(other.slug)

      assert {:ok, resolved} = Objects.resolve_reference(alias_text)
      assert resolved.slug == object.slug
    end

    test "falls back to exact titles without guessing from similar text", %{object: object} do
      assert {:ok, resolved} = Objects.resolve_reference("Minghu AI")
      assert resolved.slug == object.slug
      assert {:error, :not_found} = Objects.resolve_reference("Minghu AI company")
      assert {:error, :not_found} = Objects.resolve_reference("zzz completely unrelated qqq")
    end

    test "Chinese titles stay distinct and duplicate exact titles are ambiguous" do
      for {slug, title} <- [{"notes/research", "研究 Skill"}, {"notes/drawing", "绘图 Skill"}] do
        assert {:ok, _object} =
                 Objects.create_object(%{slug: slug, type: "note", title: title}, :system)
      end

      assert {:ok, %{slug: "notes/research"}} = Objects.resolve_reference("研究 Skill")
      assert {:error, :not_found} = Objects.resolve_reference("炒股 Skill")

      assert {:ok, _object} =
               Objects.create_object(
                 %{slug: "notes/other-research", type: "note", title: "研究 Skill"},
                 :system
               )

      assert {:ambiguous, candidates} = Objects.resolve_reference("研究 Skill")
      assert length(candidates) == 2
    end
  end
end
