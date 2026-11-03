defmodule Ankole.Brain.PromotionTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
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
    {:ok, suggestion} =
      Ankole.Ash.create(
        SchemaSuggestion,
        :suggest,
        Map.merge(
          %{
            id: UUIDv7.autogenerate(),
            kind: kind,
            term: term,
            evidence_count: 100,
            rationale: "test evidence",
            created_at: DateTime.utc_now(:microsecond)
          },
          attrs
        )
      )

    suggestion
  end

  describe "approve/3 new_type" do
    test "cannot promote an Agent type or take the Agent namespace", %{human: human} do
      suggestion = pending_suggestion("new_type", "agent")

      assert {:error, {:reserved_object_type, "agent"}} =
               Ankole.Errors.reason(
                 Ankole.Brain.approve_promotion(
                   suggestion.id,
                   Ankole.ActorRef.from_principal(human)
                 )
               )

      suggestion = pending_suggestion("new_type", "persona")

      assert {:error, {:reserved_object_slug_prefix, "agents/"}} =
               Ankole.Errors.reason(
                 Ankole.Brain.approve_promotion(
                   suggestion.id,
                   Ankole.ActorRef.from_principal(human),
                   %{
                     attrs: %{
                       slug_prefix: "agents/"
                     }
                   }
                 )
               )
    end

    test "tag promotion does not retype canonical Agents", %{human: human} do
      %{principal: agent} = agent_fixture(%{owner_principal_uid: human.uid})
      slug = "agents/" <> agent.uid

      {:ok, _tag} =
        Ankole.Repo.insert(%Ankole.Brain.Schemas.Tag{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          subject_page_id: elem(Objects.get_by_slug(slug), 1).id,
          tag: "research",
          created_at: DateTime.utc_now(:microsecond)
        })

      suggestion = pending_suggestion("new_type", "research")

      assert {:ok, %{migrated: 0}} =
               Ankole.Brain.approve_promotion(
                 suggestion.id,
                 Ankole.ActorRef.from_principal(human)
               )

      assert {:ok, %{type: "agent"}} = Objects.get_by_slug(slug)
    end

    test "retypes tagged pages without moving their directories or rewriting graph identity", %{
      human: human
    } do
      {:ok, note} =
        Ankole.Brain.create_object(
          %{slug: "notes/reconciliation-q2", type: "note", title: "Q2 reconciliation"},
          :system
        )

      {:ok, peer} =
        Ankole.Brain.create_object(
          %{slug: "companies/acme", type: "company", title: "Acme"},
          :system
        )

      # The migration target carries every slug-referencing row kind at once:
      # a tag (the selection join), a claim, a timeline, and a link.
      {:ok, _tag} =
        Ankole.Repo.insert(%Ankole.Brain.Schemas.Tag{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          subject_page_id: note.id,
          tag: "reconciliation",
          created_at: DateTime.utc_now(:microsecond)
        })

      {:ok, _fact} =
        Ankole.Brain.write_fact(
          %{
            subject_page_id: note.id,
            claim: "Q2 reconciliation closed with zero variance",
            kind: "event",
            holder: "world",
            source_node_id: Ankole.Brain.Scope.world(),
            notability: "medium",
            confidence: 0.75,
            valid_from: DateTime.utc_now(:microsecond),
            provenance: "test"
          },
          :system
        )

      {:ok, _timeline} =
        Timelines.write_timeline(
          %{
            subject_page_id: note.id,
            date: ~D[2026-06-30],
            summary: "Reconciliation closed",
            provenance: "test",
            source_node_id: Ankole.Brain.Scope.world()
          },
          :system
        )

      {:ok, _link} =
        Links.upsert_link(%{
          from_page_id: note.id,
          to_page_id: peer.id,
          link_type: "relates_to"
        })

      suggestion = pending_suggestion("new_type", "reconciliation")

      assert {:ok, %{status: :type_created, type: "reconciliation", migrated: 1}} =
               Ankole.Brain.approve_promotion(
                 suggestion.id,
                 Ankole.ActorRef.from_principal(human)
               )

      assert %SchemaType{primitive: "concept", slug_prefix: "reconciliations/"} =
               Repo.get_by(SchemaType, name: "reconciliation")

      # Classification changes metadata while the page stays in its chosen directory.
      assert {:ok, migrated} = Objects.resolve_slug("notes/reconciliation-q2")
      assert migrated.slug == note.slug
      assert migrated.type == "reconciliation"

      # Every attached record keeps the same immutable page identity.
      assert Enum.map(Repo.all(ClaimRow), & &1.subject_page_id) == [note.id]

      assert Repo.all(Ankole.Brain.Schemas.Timeline)
             |> Enum.map(& &1.subject_page_id) == [note.id]

      assert Repo.all(Ankole.Brain.Schemas.Link)
             |> Enum.map(& &1.from_page_id) == [note.id]

      assert Repo.get_by(SchemaSuggestion, id: suggestion.id).status == :approved
    end
  end

  describe "approve/3 new_subtype and reject/2" do
    test "Agent subtypes cannot be extended", %{human: human} do
      suggestion = pending_suggestion("new_subtype", "external", %{target_type: "agent"})

      assert {:error, {:reserved_object_type, "agent"}} =
               Ankole.Errors.reason(
                 Ankole.Brain.approve_promotion(
                   suggestion.id,
                   Ankole.ActorRef.from_principal(human)
                 )
               )
    end

    test "adds the term to the target type's subtype suggestions", %{human: human} do
      suggestion = pending_suggestion("new_subtype", "retainer", %{target_type: "document"})

      assert {:ok, %{status: :subtype_added, type: "document", subtype: "retainer"}} =
               Ankole.Brain.approve_promotion(
                 suggestion.id,
                 Ankole.ActorRef.from_principal(human)
               )

      assert "retainer" in Repo.get_by(SchemaType, name: "document").subtypes
    end

    test "rejection keeps the record and refuses a second decision", %{human: human} do
      suggestion = pending_suggestion("new_type", "retainer")

      assert {:ok, %SchemaSuggestion{status: :rejected}} =
               Ankole.Brain.reject_promotion(suggestion.id, Ankole.ActorRef.from_principal(human))

      assert {:error, :suggestion_not_pending} =
               Ankole.Errors.reason(
                 Ankole.Brain.approve_promotion(
                   suggestion.id,
                   Ankole.ActorRef.from_principal(human)
                 )
               )
    end
  end
end
