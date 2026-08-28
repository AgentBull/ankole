defmodule Ankole.Brain.MergeTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Links
  alias Ankole.Brain.Merge
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.MergeSuggestion
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Brain.Schemas.SlugAlias
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Schemas.Tag
  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Brain.Timelines
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: human} = human_fixture()
    %{human: human}
  end

  defp create_page!(slug, type, title, overrides \\ %{}) do
    attrs = Map.merge(%{slug: slug, type: type, title: title}, overrides)
    {:ok, object} = Objects.create_object(attrs, :system)
    object
  end

  defp pending_pairs do
    MergeSuggestion
    |> where([suggestion], suggestion.status == "pending")
    |> select([suggestion], {suggestion.a_slug, suggestion.b_slug})
    |> Repo.all()
    |> MapSet.new()
  end

  defp mark_managed!(object) do
    source =
      %Source{id: UUIDv7.autogenerate()}
      |> Source.changeset(%{
        upstream_id: "merge-managed-#{System.unique_integer([:positive])}",
        kind: "library",
        name: "Managed merge test",
        default_audience_scope: "world"
      })
      |> Repo.insert!()

    object
    |> Ecto.Changeset.change(managed_by_source_id: source.id)
    |> Repo.update!()
  end

  describe "run_phase/0" do
    test "one shared alias on two live pages of one type yields one pending pair" do
      create_page!("companies/acme", "company", "Acme Corporation")
      create_page!("companies/ac-holdings", "company", "AC Holdings")
      {:ok, _alias} = Links.add_alias("companies/acme", "the acme account")
      {:ok, _alias} = Links.add_alias("companies/ac-holdings", "the acme account")

      assert %{status: :ok, suggested: 1} = Merge.run_phase()

      assert [suggestion] = Repo.all(MergeSuggestion)
      assert suggestion.a_slug == "companies/ac-holdings"
      assert suggestion.b_slug == "companies/acme"
      assert suggestion.status == "pending"
      assert suggestion.reason =~ ~s(shared alias "the acme account")

      # A judged pair never re-suggests: the rerun records nothing new.
      assert %{status: :ok, suggested: 0} = Merge.run_phase()
      assert Repo.aggregate(MergeSuggestion, :count) == 1
    end

    test "near-identical titles of one type yield a pair; other types do not pair" do
      create_page!("companies/hongshan", "company", "Hongshan Cement Group")
      create_page!("companies/hongshan-group", "company", "Hongshan Cement Group Ltd")
      create_page!("projects/hongshan", "project", "Hongshan Cement Group")

      assert %{status: :ok} = Merge.run_phase()

      assert pending_pairs() == MapSet.new([{"companies/hongshan", "companies/hongshan-group"}])

      assert [suggestion] = Repo.all(MergeSuggestion)
      assert suggestion.reason =~ "title similarity"
    end

    test "media pages, deleted pages, and canonical principal pairs stay out" do
      create_page!("media/report-a", "media", "Quarterly Report")
      create_page!("media/report-b", "media", "Quarterly Report")

      create_page!("companies/gone", "company", "Gone Industries")
      create_page!("companies/gone-inc", "company", "Gone Industries Inc")
      {:ok, _object} = Objects.soft_delete("companies/gone-inc")

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

    test "library-managed pages stay out of alias and title candidates" do
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

      assert {:ok, %MergeSuggestion{status: "rejected"}} = Merge.reject(suggestion.id, human.uid)

      assert %{suggested: 0} = Merge.run_phase()
      assert Repo.aggregate(MergeSuggestion, :count) == 1

      assert {:error, :suggestion_not_pending} = Merge.reject(suggestion.id, human.uid)
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
        Claims.write_fact(
          %{
            object_slug: duplicate.slug,
            claim: "Acme renewed the annual contract",
            kind: "event",
            holder: duplicate.slug,
            audience_scope: "world",
            notability: "medium",
            confidence: 0.75,
            valid_from: DateTime.utc_now(:microsecond),
            provenance: "test"
          },
          human.uid
        )

      {:ok, _tag} = Links.add_tag(duplicate.slug, "customer")
      {:ok, _tag} = Links.add_tag(canonical.slug, "customer")

      {:ok, _timeline} =
        Timelines.write_timeline(
          %{
            object_slug: duplicate.slug,
            date: ~D[2026-01-15],
            summary: "Contract signed",
            detail: "",
            provenance: "test",
            audience_scope: "world"
          },
          :system
        )

      {:ok, _link} =
        Links.upsert_link(%{
          from_object_slug: duplicate.slug,
          to_object_slug: "companies/other",
          link_type: "customer_of",
          link_source: "extraction"
        })

      {:ok, _link} =
        Links.upsert_link(%{
          from_object_slug: canonical.slug,
          to_object_slug: duplicate.slug,
          link_type: "relates_to",
          link_source: "extraction"
        })

      assert %{suggested: 1} = Merge.run_phase()
      suggestion = Repo.get_by!(MergeSuggestion, status: "pending")

      %{canonical: canonical, duplicate: duplicate, suggestion: suggestion}
    end

    test "approval merges every attachment into the canonical page and leaves a redirect",
         %{human: human, canonical: canonical, duplicate: duplicate, suggestion: suggestion} do
      assert {:ok, %{status: :merged} = outcome} =
               Merge.approve(suggestion.id, human.uid, %{canonical_slug: canonical.slug})

      assert outcome.canonical_slug == canonical.slug
      assert outcome.merged_slug == duplicate.slug

      # The duplicate page is gone and its slug redirects.
      assert Repo.get_by(Object, slug: duplicate.slug) == nil
      assert {:ok, %Object{slug: "companies/acme"}} = Objects.resolve_slug(duplicate.slug)
      assert Repo.get_by(SlugAlias, alias_slug: duplicate.slug).canonical_slug == canonical.slug

      # Claims follow, including holder attribution.
      assert [claim] = Claim |> where([claim], claim.kind == "event") |> Repo.all()
      assert claim.object_slug == canonical.slug
      assert claim.holder == canonical.slug

      # Tags and aliases land deduplicated on the canonical page.
      assert Tag |> where([tag], tag.tag == "customer") |> Repo.all() |> length() == 1

      alias_norms =
        ObjectAlias
        |> where([alias], alias.object_slug == ^canonical.slug)
        |> select([alias], alias.alias_norm)
        |> Repo.all()
        |> Enum.sort()

      assert alias_norms == ["acme", "acme corp"]

      # The timeline moved and reprojected into the canonical chunk set.
      assert [timeline] = Repo.all(Timeline)
      assert timeline.object_slug == canonical.slug

      assert Chunk
             |> where([chunk], chunk.object_id == ^canonical.id)
             |> where([chunk], chunk.content_kind == "timeline")
             |> Repo.exists?()

      # The outbound edge repointed; the intra-pair edge disappeared.
      links = Repo.all(Ankole.Brain.Schemas.Link)
      assert [edge] = Enum.filter(links, &(&1.link_type == "customer_of"))
      assert edge.from_object_slug == canonical.slug
      assert edge.to_object_slug == "companies/other"
      refute Enum.any?(links, &(&1.link_type == "relates_to"))

      assert Repo.get!(MergeSuggestion, suggestion.id).status == "approved"
    end

    test "approval needs a direction and refuses a duplicate with a written body",
         %{human: human, canonical: canonical, suggestion: suggestion} do
      assert {:error, :canonical_slug_required} = Merge.approve(suggestion.id, human.uid, %{})

      assert {:error, {:canonical_slug_not_in_pair, _slug}} =
               Merge.approve(suggestion.id, human.uid, %{canonical_slug: "companies/other"})

      {:ok, _object} =
        Objects.update_object(
          "companies/acme-corp",
          %{
            body: "Written notes an operator must move by hand.",
            expected_content_hash: Repo.get_by!(Object, slug: "companies/acme-corp").content_hash
          },
          human.uid
        )

      assert {:error, {:merge_body_not_blank, "companies/acme-corp"}} =
               Merge.approve(suggestion.id, human.uid, %{canonical_slug: canonical.slug})

      # The refused suggestion stays pending for a later approval.
      assert Repo.get!(MergeSuggestion, suggestion.id).status == "pending"
    end

    test "approval rejects a managed page in either direction",
         %{human: human, canonical: canonical, duplicate: duplicate, suggestion: suggestion} do
      mark_managed!(canonical)

      assert {:error, {:library_managed, "companies/acme"}} =
               Merge.approve(suggestion.id, human.uid, %{canonical_slug: canonical.slug})

      assert {:error, {:library_managed, "companies/acme"}} =
               Merge.approve(suggestion.id, human.uid, %{canonical_slug: duplicate.slug})

      assert Repo.get!(MergeSuggestion, suggestion.id).status == "pending"
    end
  end

  test "a canonical principal page can absorb a duplicate but never merges away",
       %{human: human} do
    %{principal: alice} = human_fixture()
    canonical_slug = "people/" <> alice.uid

    create_page!("people/alice-doe", "person", "Alice Doe")
    {:ok, _alias} = Links.add_alias(canonical_slug, "alice doe")
    {:ok, _alias} = Links.add_alias("people/alice-doe", "alice doe")

    assert %{suggested: 1} = Merge.run_phase()
    suggestion = Repo.get_by!(MergeSuggestion, status: "pending")

    assert {:error, {:principal_canonical_page, ^canonical_slug}} =
             Merge.approve(suggestion.id, human.uid, %{canonical_slug: "people/alice-doe"})

    assert {:ok, %{status: :merged}} =
             Merge.approve(suggestion.id, human.uid, %{canonical_slug: canonical_slug})

    assert Repo.get_by(Object, slug: "people/alice-doe") == nil
    assert {:ok, %Object{slug: ^canonical_slug}} = Objects.resolve_slug("people/alice-doe")
  end
end
