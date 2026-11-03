defmodule Ankole.Brain.MergeTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Links
  alias Ankole.Brain.Merge
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.MergeSuggestion
  alias Ankole.Brain.Schemas.Page, as: Object
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Brain.Schemas.SlugAlias
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Brain.Timelines
  alias Ankole.Repo

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: human} = human_fixture()
    %{human: human}
  end

  defp create_page!(slug, type, title, overrides \\ %{}) do
    attrs = Map.merge(%{slug: slug, type: type, title: title}, overrides)
    {:ok, object} = Ankole.Brain.create_object(attrs, :system)
    object
  end

  defp pending_pairs do
    MergeSuggestion
    |> where([suggestion], suggestion.status == :pending)
    |> select([suggestion], {suggestion.a_slug, suggestion.b_slug})
    |> Repo.all()
    |> MapSet.new()
  end

  defp mark_managed!(object) do
    {:ok, source} =
      Ankole.Ash.create(Source, :register, %{
        upstream_id: "merge-managed-#{System.unique_integer([:positive])}",
        kind: "library",
        name: "Managed merge test",
        default_source_node_id: Ankole.Brain.Scope.world()
      })

    {:ok, _} =
      Ankole.Repo.transact_top_level(fn ->
        properties = Repo.get_by!(Ankole.Pod.Page, id: object.id)

        Ankole.Ash.update(properties, :sync_upstream, %{
          upstream_state: %{"source_id" => source.id}
        })
      end)
  end

  describe "run_phase/0" do
    test "restricted Brain pages sharing Principal names remain ordinary merge candidates", %{
      human: human
    } do
      other = human_fixture().principal
      actor = actor_fixture(human)

      category = Ankole.BrainFixtures.category_fixture(human.uid, "people")

      {:ok, folder} =
        Ankole.Pod.Pages.create(actor, %{
          type: :knowledge,
          parent_id: category.id,
          title: "Private contacts",
          inherit_permissions: false
        })

      for uid <- [human.uid, other.uid] do
        assert {:ok, _} =
                 Ankole.Pod.Pages.create(actor, %{
                   type: :knowledge,
                   parent_id: folder.id,
                   title: uid,
                   metadata: %{"entity_type" => "person", "aliases" => ["Same private contact"]}
                 })
      end

      assert %{suggested: 1} = Merge.run_phase()
    end

    test "one tenant's recorded pair does not suppress another tenant's same-slug candidates" do
      seed_pair = fn ->
        create_page!("companies/acme", "company", "Acme")
        create_page!("companies/ac-holdings", "company", "Acme Holdings")
        {:ok, _} = Links.add_alias("companies/acme", "same account")
        {:ok, _} = Links.add_alias("companies/ac-holdings", "same account")
      end

      seed_pair.()
      assert %{suggested: 1} = Merge.run_phase()
      assert [recorded] = Repo.all(MergeSuggestion)

      other = Ankole.DataCase.create_tenant()

      Repo.with_tenant(other.id, fn ->
        {:ok, _} = SchemaPacks.install_packs([])
        seed_pair.()
        assert %{suggested: 1} = Merge.run_phase()
        assert [separate] = Repo.all(MergeSuggestion)
        assert separate.id != recorded.id
        refute {separate.a_slug, separate.b_slug} == {recorded.a_slug, recorded.b_slug}
      end)

      assert [retained] = Repo.all(MergeSuggestion)
      assert retained.id == recorded.id
    end

    test "one shared alias on two live pages of one type yields one pending pair" do
      create_page!("companies/acme", "company", "Acme Corporation")
      create_page!("companies/ac-holdings", "company", "AC Holdings")
      {:ok, _alias} = Links.add_alias("companies/acme", "the acme account")
      {:ok, _alias} = Links.add_alias("companies/ac-holdings", "the acme account")

      assert %{status: :ok, suggested: 1} = Merge.run_phase()

      assert [suggestion] = Repo.all(MergeSuggestion)

      assert MapSet.new([suggestion.a_slug, suggestion.b_slug]) ==
               MapSet.new([
                 elem(Objects.get_by_slug("companies/ac-holdings"), 1).id,
                 elem(Objects.get_by_slug("companies/acme"), 1).id
               ])

      assert suggestion.status == :pending
      assert suggestion.reason =~ ~s(shared alias "the acme account")

      # A judged pair never re-suggests: the rerun records nothing new.
      assert %{status: :ok, suggested: 0} = Merge.run_phase()
      assert Repo.aggregate(MergeSuggestion, :count) == 1
    end

    test "similar or identical titles do not establish object identity" do
      create_page!("companies/hongshan", "company", "Hongshan Cement Group")
      create_page!("companies/hongshan-group", "company", "Hongshan Cement Group Ltd")
      create_page!("projects/hongshan", "project", "Hongshan Cement Group")
      create_page!("notes/research", "note", "研究 Skill")
      create_page!("notes/drawing", "note", "绘图 Skill")
      create_page!("notes/another-research", "note", "研究 Skill")

      assert %{status: :ok} = Merge.run_phase()

      assert pending_pairs() == MapSet.new()
    end

    test "media pages, deleted pages, and canonical principal pairs stay out" do
      create_page!("media/report-a", "media", "Quarterly Report")
      create_page!("media/report-b", "media", "Quarterly Report")
      {:ok, _alias} = Links.add_alias("media/report-a", "report")
      {:ok, _alias} = Links.add_alias("media/report-b", "report")

      create_page!("companies/gone", "company", "Gone Industries")
      create_page!("companies/gone-inc", "company", "Gone Industries Inc")
      {:ok, _alias} = Links.add_alias("companies/gone", "gone")
      {:ok, _alias} = Links.add_alias("companies/gone-inc", "gone")
      {:ok, _object} = Ankole.Brain.soft_delete_object("companies/gone-inc")

      %{principal: first} = human_fixture()
      %{principal: second} = human_fixture()
      {:ok, _alias} = Links.add_alias("people/" <> first.uid, "zhang wei")
      {:ok, _alias} = Links.add_alias("people/" <> second.uid, "zhang wei")

      assert %{status: :ok, suggested: 0} = Merge.run_phase()
      assert Repo.aggregate(MergeSuggestion, :count) == 0
    end

    test "scan advances beyond a 200-pair Principal prefix and prior suggestions" do
      shared_alias = "merge scan progression"

      Enum.each(0..20, fn _index ->
        %{principal: principal} = human_fixture()
        {:ok, _alias} = Links.add_alias("people/" <> principal.uid, shared_alias)
      end)

      Enum.each(Enum.with_index(?a..?u), fn {letter, index} ->
        suffix = index |> Integer.to_string() |> String.pad_leading(2, "0")
        slug = "projects/progression-#{suffix}"
        title = String.duplicate(<<letter::utf8>>, 20)
        create_page!(slug, "project", title)
        {:ok, _alias} = Links.add_alias(slug, shared_alias)
      end)

      assert [50, 50, 50, 50, 10] ==
               Enum.map(1..5, fn _iteration -> Merge.run_phase().suggested end)

      assert Repo.aggregate(MergeSuggestion, :count) == 210
    end

    test "library-managed pages stay out of alias candidates" do
      managed = create_page!("companies/managed-acme", "company", "Managed Acme")
      create_page!("companies/ordinary-acme", "company", "Managed Acme Ltd")
      mark_managed!(managed)

      {:ok, _alias} = Links.add_alias("companies/managed-acme", "managed acme")
      {:ok, _alias} = Links.add_alias("companies/ordinary-acme", "managed acme")

      assert %{status: :ok, suggested: 0} = Merge.run_phase()
      assert Repo.aggregate(MergeSuggestion, :count) == 0
    end

    test "a rejected pair is not suggested again", %{human: human} do
      create_page!("companies/acme", "company", "Acme Corporation")
      create_page!("companies/ac-holdings", "company", "AC Holdings")
      {:ok, _alias} = Links.add_alias("companies/acme", "acme")
      {:ok, _alias} = Links.add_alias("companies/ac-holdings", "acme")

      assert %{suggested: 1} = Merge.run_phase()
      assert [suggestion] = Repo.all(MergeSuggestion)

      assert {:ok, %MergeSuggestion{status: :rejected}} =
               Ankole.Brain.reject_merge(suggestion.id, Ankole.ActorRef.from_principal(human))

      assert %{suggested: 0} = Merge.run_phase()
      assert Repo.aggregate(MergeSuggestion, :count) == 1

      assert {:error, :suggestion_not_pending} =
               Ankole.Errors.reason(
                 Ankole.Brain.reject_merge(suggestion.id, Ankole.ActorRef.from_principal(human))
               )
    end
  end

  describe "approve/3" do
    setup %{human: human} do
      canonical = create_page!("companies/acme", "company", "Acme Corporation")
      duplicate = create_page!("companies/acme-corp", "company", "Acme Corp")
      create_page!("companies/other", "company", "Other Co")

      {:ok, _alias} = Links.add_alias(canonical.slug, "acme")
      {:ok, _alias} = Links.add_alias(duplicate.slug, "acme")
      {:ok, _alias} = Links.add_alias(duplicate.slug, "acme corp")

      {:ok, _result} =
        Ankole.Brain.write_fact(
          %{
            subject_page_id: duplicate.id,
            claim: "Acme renewed the annual contract",
            kind: "event",
            holder: duplicate.slug,
            source_node_id: Ankole.Brain.Scope.world(),
            notability: "medium",
            confidence: 0.75,
            valid_from: DateTime.utc_now(:microsecond),
            provenance: "test"
          },
          human.uid
        )

      {:ok, _timeline} =
        Timelines.write_timeline(
          %{
            subject_page_id: duplicate.id,
            date: ~D[2026-01-15],
            summary: "Contract signed",
            detail: "",
            provenance: "test",
            source_node_id: Ankole.Brain.Scope.world()
          },
          :system
        )

      {:ok, _link} =
        Links.upsert_link(%{
          from_page_id: duplicate.id,
          to_page_id: elem(Objects.get_by_slug("companies/other"), 1).id,
          link_type: "customer_of",
          link_source: "extraction"
        })

      {:ok, _link} =
        Links.upsert_link(%{
          from_page_id: canonical.id,
          to_page_id: duplicate.id,
          link_type: "relates_to",
          link_source: "extraction"
        })

      assert %{suggested: 1} = Merge.run_phase()
      suggestion = Repo.get_by!(MergeSuggestion, status: :pending)

      %{canonical: canonical, duplicate: duplicate, suggestion: suggestion}
    end

    test "approval merges every attachment into the canonical page and leaves a redirect",
         %{human: human, canonical: canonical, duplicate: duplicate, suggestion: suggestion} do
      assert {:ok, %{status: :merged} = outcome} =
               Ankole.Brain.approve_merge(suggestion.id, Ankole.ActorRef.from_principal(human), %{
                 attrs: %{
                   canonical_page_id: canonical.slug
                 }
               })

      assert outcome.canonical_page_id == canonical.id
      assert outcome.merged_slug == duplicate.slug

      assert Repo.get_by!(Object, slug: duplicate.slug).deleted_at
      assert {:ok, %Object{slug: "companies/acme"}} = Objects.resolve_slug(duplicate.slug)
      assert Repo.get_by(SlugAlias, alias_slug: duplicate.slug).canonical_page_id == canonical.id

      assert [claim] = Claim |> where([claim], claim.kind == "event") |> Repo.all()
      assert claim.subject_page_id == canonical.id
      assert claim.holder == canonical.slug

      alias_norms =
        ObjectAlias
        |> where([alias], alias.subject_page_id == ^canonical.id)
        |> select([alias], alias.alias_norm)
        |> Repo.all()
        |> Enum.sort()

      assert alias_norms == ["acme", "acme corp"]

      assert [timeline] = Repo.all(Timeline)
      assert timeline.subject_page_id == canonical.id

      assert Chunk
             |> where([chunk], chunk.page_id == ^canonical.id)
             |> where([chunk], chunk.content_kind == :timeline)
             |> Repo.exists?()

      links = Repo.all(Ankole.Brain.Schemas.Link)
      assert [edge] = Enum.filter(links, &(&1.link_type == "customer_of"))
      assert edge.from_page_id == canonical.id
      assert edge.to_page_id == elem(Objects.get_by_slug("companies/other"), 1).id
      refute Enum.any?(links, &(&1.link_type == "relates_to"))

      assert Repo.get!(MergeSuggestion, suggestion.id).status == :approved
    end

    test "merge concatenates structured bodies and retains restorable metadata", %{
      human: human,
      canonical: canonical,
      duplicate: duplicate,
      suggestion: suggestion
    } do
      assert {:error, :canonical_page_id_required} =
               Ankole.Errors.reason(
                 Ankole.Brain.approve_merge(
                   suggestion.id,
                   Ankole.ActorRef.from_principal(human),
                   %{attrs: %{}}
                 )
               )

      {:ok, _} =
        Ankole.Brain.update_object(
          canonical.id,
          %{body: "Canonical overview", meta: %{"summary" => "canonical", "tags" => ["first"]}},
          :system
        )

      {:ok, _} =
        Ankole.Brain.update_object(
          duplicate.id,
          %{body: "Duplicate details", meta: %{"tags" => ["second"]}},
          :system
        )

      assert {:ok, %{status: :merged}} =
               Ankole.Brain.approve_merge(suggestion.id, Ankole.ActorRef.from_principal(human), %{
                 attrs: %{canonical_page_id: canonical.id}
               })

      assert {:ok, merged} = Objects.get_by_slug(canonical.id)
      assert merged.body =~ "Canonical overview"
      assert merged.body =~ "Duplicate details"
      assert merged.meta["summary"] == "canonical"
      assert Enum.sort(merged.meta["tags"]) == ["first", "second"]

      snapshots =
        Repo.all(
          from snapshot in Ankole.Pod.PageSnapshot, where: snapshot.page_id == ^canonical.id
        )

      assert Enum.any?(snapshots, &(&1.metadata["tags"] == ["first"]))
      assert Enum.any?(snapshots, &(&1.content =~ "Duplicate details"))
    end

    test "approval rejects a managed page in either direction",
         %{human: human, canonical: canonical, duplicate: duplicate, suggestion: suggestion} do
      mark_managed!(canonical)

      assert {:error, {:library_managed, "companies/acme"}} =
               Ankole.Errors.reason(
                 Ankole.Brain.approve_merge(
                   suggestion.id,
                   Ankole.ActorRef.from_principal(human),
                   %{
                     attrs: %{
                       canonical_page_id: canonical.slug
                     }
                   }
                 )
               )

      assert {:error, {:library_managed, "companies/acme"}} =
               Ankole.Errors.reason(
                 Ankole.Brain.approve_merge(
                   suggestion.id,
                   Ankole.ActorRef.from_principal(human),
                   %{
                     attrs: %{
                       canonical_page_id: duplicate.slug
                     }
                   }
                 )
               )

      assert Repo.get!(MergeSuggestion, suggestion.id).status == :pending
    end
  end

  test "merging restricted Brain duplicates preserves shared historical paths", %{human: human} do
    actor = actor_fixture(human)

    {:ok, shared} =
      Ankole.BrainFixtures.page_fixture_result(
        %{slug: "companies/acme", type: "company", title: "Shared Acme"},
        human.uid
      )

    assert {:ok, _} = Ankole.Pod.Pages.Tree.rename(actor, shared.id, "Shared Acme")

    category = Ankole.BrainFixtures.category_fixture(human.uid, "companies")

    {:ok, folder} =
      Ankole.Pod.Pages.create(actor, %{
        type: :knowledge,
        parent_id: category.id,
        title: "Private accounts",
        inherit_permissions: false
      })

    private_pages =
      for title <- ["acme", "ac-holdings"] do
        {:ok, page} =
          Ankole.Pod.Pages.create(actor, %{
            type: :knowledge,
            parent_id: folder.id,
            title: title,
            metadata: %{"entity_type" => "company", "aliases" => ["private account"]}
          })

        page
      end

    [_duplicate, canonical] = private_pages
    assert %{suggested: 1} = Merge.run_phase()
    suggestion = Repo.get_by!(MergeSuggestion, status: :pending)

    assert {:ok, %{status: :merged}} =
             Ankole.Brain.approve_merge(suggestion.id, Ankole.ActorRef.from_principal(human), %{
               attrs: %{canonical_page_id: canonical.id}
             })

    assert {:ok, %{id: id}} = Objects.resolve_slug("companies/acme")
    assert id == shared.id
  end

  test "a canonical principal page can absorb a duplicate but never merges away",
       %{human: human} do
    %{principal: alice} = human_fixture()
    canonical_slug = "people/" <> alice.uid

    create_page!("people/alice-doe", "person", "Alice Doe")
    {:ok, _alias} = Links.add_alias(canonical_slug, "alice doe")
    {:ok, _alias} = Links.add_alias("people/alice-doe", "alice doe")

    assert %{suggested: 1} = Merge.run_phase()
    suggestion = Repo.get_by!(MergeSuggestion, status: :pending)

    assert {:error, {:principal_canonical_page, ^canonical_slug}} =
             Ankole.Errors.reason(
               Ankole.Brain.approve_merge(suggestion.id, Ankole.ActorRef.from_principal(human), %{
                 attrs: %{
                   canonical_page_id: "people/alice-doe"
                 }
               })
             )

    assert {:ok, %{status: :merged}} =
             Ankole.Brain.approve_merge(suggestion.id, Ankole.ActorRef.from_principal(human), %{
               attrs: %{
                 canonical_page_id: canonical_slug
               }
             })

    assert Repo.get_by!(Object, slug: "people/alice-doe").deleted_at
    assert {:ok, %Object{slug: ^canonical_slug}} = Objects.resolve_slug("people/alice-doe")
  end
end
