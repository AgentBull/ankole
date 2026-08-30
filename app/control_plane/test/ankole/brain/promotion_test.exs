defmodule Ankole.Brain.PromotionTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Promotion
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim, as: ClaimRow
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Timelines
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: human} = human_fixture()
    %{human: human}
  end

  defp pending_suggestion(kind, term, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        SchemaSuggestion,
        Map.merge(
          %{
            id: UUIDv7.autogenerate(),
            kind: kind,
            term: term,
            evidence_count: 100,
            rationale: "test evidence",
            status: "pending",
            created_at: DateTime.utc_now(:microsecond)
          },
          attrs
        )
      )
    )
  end

  describe "approve/3 new_type" do
    test "retypes tagged objects with referencing rows and keeps old slugs resolvable", %{
      human: human
    } do
      {:ok, _note} =
        Objects.create_object(
          %{slug: "notes/reconciliation-q2", type: "note", title: "Q2 reconciliation"},
          human.uid
        )

      {:ok, _peer} =
        Objects.create_object(
          %{slug: "companies/acme", type: "company", title: "Acme"},
          human.uid
        )

      # The migration target carries every slug-referencing row kind at once:
      # a tag (the selection join), a claim, a timeline, and a link.
      {:ok, _tag} = Links.add_tag("notes/reconciliation-q2", "reconciliation")

      {:ok, _fact} =
        Claims.write_fact(
          %{
            object_slug: "notes/reconciliation-q2",
            claim: "Q2 reconciliation closed with zero variance",
            kind: "event",
            holder: "world",
            audience_scope: "world",
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
            object_slug: "notes/reconciliation-q2",
            date: ~D[2026-06-30],
            summary: "Reconciliation closed",
            provenance: "test",
            audience_scope: "world"
          },
          human.uid
        )

      {:ok, _link} =
        Links.upsert_link(%{
          from_object_slug: "notes/reconciliation-q2",
          to_object_slug: "companies/acme",
          link_type: "relates_to"
        })

      suggestion = pending_suggestion("new_type", "reconciliation")

      assert {:ok, %{status: :type_created, type: "reconciliation", migrated: 1}} =
               Promotion.approve(suggestion.id, human.uid)

      assert %SchemaType{primitive: "concept", slug_prefix: "reconciliations/"} =
               Repo.get_by(SchemaType, name: "reconciliation")

      # The old slug resolves through the redirect and lands on the new type.
      assert {:ok, migrated} = Objects.resolve_slug("notes/reconciliation-q2")
      assert migrated.slug == "reconciliations/reconciliation-q2"
      assert migrated.type == "reconciliation"

      # Referencing rows followed the rename atomically.
      assert [%ClaimRow{object_slug: "reconciliations/reconciliation-q2"}] = Repo.all(ClaimRow)

      assert Repo.all(Ankole.Brain.Schemas.Timeline)
             |> Enum.map(& &1.object_slug) == ["reconciliations/reconciliation-q2"]

      assert Repo.all(Ankole.Brain.Schemas.Link)
             |> Enum.map(& &1.from_object_slug) == ["reconciliations/reconciliation-q2"]

      assert Repo.get_by(SchemaSuggestion, id: suggestion.id).status == "approved"
    end
  end

  describe "approve/3 new_subtype and reject/2" do
    test "adds the term to the target type's subtype suggestions", %{human: human} do
      suggestion = pending_suggestion("new_subtype", "retainer", %{target_type: "document"})

      assert {:ok, %{status: :subtype_added, type: "document", subtype: "retainer"}} =
               Promotion.approve(suggestion.id, human.uid)

      assert "retainer" in Repo.get_by(SchemaType, name: "document").subtypes
    end

    test "rejection keeps the record and refuses a second decision", %{human: human} do
      suggestion = pending_suggestion("new_type", "retainer")

      assert {:ok, %SchemaSuggestion{status: "rejected"}} =
               Promotion.reject(suggestion.id, human.uid)

      assert {:error, :suggestion_not_pending} = Promotion.approve(suggestion.id, human.uid)
    end
  end
end
