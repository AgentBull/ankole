defmodule Ankole.Brain.ObjectsTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  import Ankole.BrainFixtures
  alias Ankole.Brain.{Objects, Links}
  alias Ankole.Pod.{Knowledge, Pages}

  setup do
    {:ok, _} = Ankole.Brain.SchemaPacks.install_packs([])
    :ok
  end

  test "learning an existing entity cannot replace the team's saved knowledge" do
    attrs = %{slug: "companies/review-acme", title: "Acme", body: "Human-approved terms."}
    assert {:ok, page} = Ankole.Brain.create_object(attrs, :system)

    assert {:error, {:slug_taken, "companies/review-acme"}} =
             Ankole.Brain.create_object(%{attrs | body: "A model's new guess."}, :system)

    assert {:ok, unchanged} = Objects.get_by_slug(page.id)
    assert unchanged.body == page.body
    assert unchanged.revision == page.revision
  end

  test "knowledge paths resolve from AnkoleBrain without collisions with business or private pages" do
    human = human_fixture().principal
    actor = actor_fixture(human)

    {:ok, entity} =
      Ankole.Brain.create_object(
        %{slug: "companies/path-acme", title: "Acme", body: "Shared business facts."},
        :system
      )

    for attrs <- [%{}, %{private_owner_uid: human.uid}] do
      {:ok, folder} = Pages.create(actor, Map.merge(attrs, %{type: :doc, title: "companies"}))

      {:ok, _other} =
        Pages.create(actor, %{
          type: :doc,
          parent_id: folder.id,
          title: "path-acme",
          xml: "<page><p>Unrelated page with the same relative path.</p></page>"
        })
    end

    for path <- ["companies/path-acme", "/AnkoleBrain/companies/path-acme", entity.id] do
      assert {:ok, %{id: id}} = Objects.get_by_slug(path)
      assert id == entity.id
    end
  end

  test "the adapter writes Pod content, business metadata and tags through one revision" do
    %{principal: human} = human_fixture()

    assert {:ok, page} =
             page_fixture_result(
               %{
                 slug: "notes/adapter",
                 title: "Adapter",
                 type: "note",
                 body: "First body",
                 tags: ["research"]
               },
               human.uid
             )

    assert {:ok, %{page: pod, content: content}} = Knowledge.read_in_tx(page.id)
    assert pod.metadata["entity_type"] == "note"
    assert pod.metadata["tags"] == ["research"]
    assert content.plain_text == "First body"
    assert Links.tags_for_object(page.id) == ["research"]

    assert {:ok, changed} =
             Ankole.Brain.update_object(
               page.id,
               %{body: "Second body", base_revision: pod.revision},
               human.uid
             )

    assert changed.revision == pod.revision + 1

    assert {:error, _} =
             Ankole.Brain.update_object(
               page.id,
               %{body: "Stale body", base_revision: pod.revision},
               human.uid
             )

    assert {:ok, %{body: "Second body"}} = Objects.get_by_slug(page.id)
  end

  test "metadata aliases and tags project on ordinary Pod saves" do
    %{principal: human} = human_fixture()

    {:ok, page} =
      page_fixture_result(%{slug: "companies/acme", title: "Acme", body: "Company."}, human.uid)

    {:ok, pod} = Pages.fetch(page.id)
    {:ok, parsed} = Ankole.Kernel.knowledge_parse("Company.")

    assert {:ok, _} =
             Knowledge.write(actor_fixture(human), page.id, pod.revision, parsed.xml, %{
               "aliases" => [" ACME  Group "],
               "tags" => ["customer"]
             })

    assert Links.lookup_alias("acme group") == [page.id]
    assert Links.tags_for_object(page.id) == ["customer"]
    {:ok, pod} = Pages.fetch(page.id)

    assert {:ok, _} =
             Knowledge.write(actor_fixture(human), page.id, pod.revision, parsed.xml, %{})

    assert Links.lookup_alias("acme group") == []
    assert Links.tags_for_object(page.id) == []
  end

  test "name collisions resolve explicitly and external people are not legal Principal pages" do
    {:ok, first} =
      page_fixture_result(
        %{slug: "people/alice-doe", title: "Alice", body: "External expert."},
        :system
      )

    {:ok, second} =
      page_fixture_result(
        %{slug: "people/alice-roe", title: "Alice", body: "Another expert."},
        :system
      )

    refute Objects.canonical_principal_page?(first.id)
    assert {:ambiguous, candidates} = Objects.resolve_reference("Alice")
    assert MapSet.new(Enum.map(candidates, & &1.id)) == MapSet.new([first.id, second.id])
  end

  test "adding the same name to canonical and external people preserves both pages" do
    %{principal: human} = human_fixture()

    {:ok, external} =
      Ankole.Brain.create_object(
        %{slug: "people/alice-doe", type: "person", title: "Alice Doe"},
        :system
      )

    assert external.slug == "people/alice-doe"
    assert {:ok, %{slug: "people/alice-doe"}} = Objects.get_by_slug(external.id)
    assert {:ok, _} = Objects.get_by_slug("people/alice-doe")
    assert {:ok, _} = Links.add_alias("people/" <> human.uid, "alice doe")
    assert {:ok, %{slug: "people/alice-doe"}} = Objects.get_by_slug(external.id)
    assert {:ok, current} = Objects.get_by_slug("people/alice-doe")
    assert current.id == external.id
    assert {:ok, _} = Links.add_alias("people/alice-doe", "alice doe")
  end

  test "a matching path in a private space is not the Principal's canonical page" do
    human = human_fixture().principal
    actor = actor_fixture(human)

    {:ok, folder} =
      Pages.create(actor, %{type: :doc, title: "people", private_owner_uid: human.uid})

    {:ok, page} = Pages.create(actor, %{type: :doc, parent_id: folder.id, title: human.uid})

    assert Objects.canonical_principal_page?("people/" <> human.uid)
    refute Objects.canonical_principal_page?(page.id)
  end
end
