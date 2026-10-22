defmodule Ankole.Brain.ResourceActionsTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.{Claims, SchemaPacks}
  alias Ankole.Brain.Schemas.{SchemaPack, SchemaType, TakeDomainAssignment}

  setup do
    {:ok, _} = SchemaPacks.install_packs([])
    :ok
  end

  test "content and source actions fence stale snapshots and ownership at the database" do
    {:ok, object} =
      Ankole.Brain.create_object(
        %{slug: "notes/action-guard", type: "note", title: "Guard"},
        :system
      )

    {:ok, edited} =
      Ankole.Brain.update_object(
        object.slug,
        %{body: "Current", expected_content_hash: object.content_hash},
        :system
      )

    assert {:error, %Ash.Error.Invalid{errors: [%Ankole.Errors.Invalid.Stale{}]}} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(object, :edit, %{
                 body: "Stale",
                 expected_content_hash: object.content_hash
               })
             end)

    Ankole.DataCase.assert_persisted_equal(
      Repo.get!(Ankole.Brain.Schemas.Object, object.id),
      edited
    )

    {:ok, source} =
      Ankole.Brain.Sources.create(%{kind: "file", upstream_id: "guard-source", name: "Guard"})

    assert {:error, %Ash.Error.Invalid{errors: [%Ankole.Errors.Invalid.Stale{}]}} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(object, :project, %{source_id: source.id, body: "Take over"})
             end)

    {:ok, archived} = Ankole.Brain.archive_source(source.id)

    assert {:error, %Ash.Error.Invalid{errors: [%Ankole.Errors.Invalid.Stale{}]}} =
             Ankole.Ash.update(source, :record_revision, %{upstream_revision: "Too late"})

    Ankole.DataCase.assert_persisted_equal(
      Repo.get!(Ankole.Brain.Schemas.Source, source.id),
      archived
    )
  end

  test "subtype additions merge stored values without replacing first declaration facts" do
    type = Repo.get_by!(SchemaType, name: "note")

    assert {:ok, second} =
             Repo.transact(fn _ ->
               with {:ok, _} <-
                      Ankole.Ash.update(type, :add_subtypes, %{subtypes: ["first", "shared"]}),
                    {:ok, second} <-
                      Ankole.Ash.update(type, :add_subtypes, %{subtypes: ["second", "shared"]}),
                    do: {:ok, second}
             end)

    assert second.subtypes == Enum.uniq(type.subtypes ++ ["first", "shared", "second"])

    assert {:error, _} =
             Repo.transact(fn _ -> Ankole.Ash.update(type, :add_subtypes, %{subtypes: [1]}) end)

    unchanged_fields = SchemaType.__schema__(:fields) -- [:subtypes]
    assert Map.take(second, unchanged_fields) == Map.take(type, unchanged_fields)

    assert {:error, rejected} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(type, :add_subtypes, %{
                 subtypes: [],
                 primitive: "entity",
                 pack_name: "promoted"
               })
             end)

    assert MapSet.new(
             Enum.map(rejected.errors, fn %Ash.Error.Invalid.NoSuchInput{input: input} ->
               input
             end)
           ) ==
             MapSet.new([:primitive, :pack_name])

    Ankole.DataCase.assert_persisted_equal(Repo.reload!(second), second)
  end

  test "promoted pack retries preserve the first installation identity and timestamp" do
    assert {:ok, first} =
             Repo.transact(fn _ -> Ankole.Ash.create(SchemaPack, :ensure_promoted, %{}) end)

    assert {:ok, repeated} =
             Repo.transact(fn _ -> Ankole.Ash.create(SchemaPack, :ensure_promoted, %{}) end)

    assert_persisted_equal(repeated, first)
    assert first.name == "promoted"
    assert first.manifest == %{"name" => "promoted", "promoted" => true}
    assert first.installed_at
  end

  test "Take assignment retries preserve the first provenance and confidence" do
    take = take_fixture()

    attrs = %{
      take_claim_id: take.id,
      domain: "sample",
      pack: "general",
      assignment_provenance: "first",
      confidence: 0.4
    }

    assert {:ok, first} =
             Repo.transact(fn _ ->
               Ankole.Ash.create(TakeDomainAssignment, :assign_once, attrs)
             end)

    assert {:ok, repeated} =
             Repo.transact(fn _ ->
               Ankole.Ash.create(TakeDomainAssignment, :assign_once, %{
                 attrs
                 | assignment_provenance: "later",
                   confidence: 0.9
               })
             end)

    assert_persisted_equal(repeated, first)
    assert first.confidence == 0.4
    assert first.assignment_provenance == "first"
  end

  test "Take assignments cannot reference another tenant's claim" do
    other = create_tenant()

    foreign =
      Repo.with_tenant(other.id, fn ->
        {:ok, _} = SchemaPacks.install_packs([])
        take_fixture()
      end)

    assert {:error, rejected} =
             Repo.transact(fn _ ->
               Ankole.Ash.create(TakeDomainAssignment, :assign_once, %{
                 take_claim_id: foreign.id,
                 domain: "sample",
                 pack: "general"
               })
             end)

    assert Enum.any?(rejected.errors, fn
             %Ash.Error.Changes.InvalidAttribute{private_vars: vars} ->
               vars[:constraint] == "brain_take_domain_assignments_take_claim_id_fkey"

             _ ->
               false
           end)

    assert Repo.aggregate(TakeDomainAssignment, :count) == 0
  end

  test "native subtype storage rejects non-array and non-string values" do
    for json <- ["{}", "[1]", "[null]", "[true]"] do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(
            "UPDATE brain_schema_types SET subtypes = $2::text::jsonb WHERE tenant_id = $1::text::uuid AND name = 'note'",
            [Repo.tenant_id!(), json],
            mode: :savepoint
          )
        end

      assert error.postgres.constraint == "brain_schema_types_subtypes_strings"
    end
  end

  test "review decisions use the stored state and pending terms do not duplicate" do
    alias Ankole.Brain.Schemas.SchemaSuggestion
    %{principal: reviewer} = human_fixture()
    actor = Ankole.ActorRef.from_principal(reviewer)
    attrs = %{kind: :new_type, term: "review-once", evidence_count: 20, rationale: "Evidence"}
    {:ok, proposal} = Ankole.Ash.create(SchemaSuggestion, :suggest, attrs)
    assert {:ok, repeated} = Ankole.Ash.create(SchemaSuggestion, :suggest, attrs)
    assert_persisted_equal(repeated, proposal)

    assert {:ok, rejected} =
             Repo.transact(fn _ -> Ankole.Ash.update(proposal, :reject, %{decided_by: actor}) end)

    assert {:error, error} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(proposal, :approve, %{decided_by: actor})
             end)

    assert Enum.any?(error.errors, &is_struct(&1, Ankole.Errors.Invalid.StatusTransition))
    Ankole.DataCase.assert_persisted_equal(Repo.get!(SchemaSuggestion, proposal.id), rejected)
    assert Repo.aggregate(SchemaSuggestion, :count) == 1
  end

  test "merge proposals preserve the first facts and cannot reverse a review" do
    alias Ankole.Brain.Schemas.MergeSuggestion
    %{principal: reviewer} = human_fixture()
    actor = Ankole.ActorRef.from_principal(reviewer)
    attrs = %{a_slug: "notes/a", b_slug: "notes/b", reason: "First evidence"}
    {:ok, proposal} = Ankole.Ash.create(MergeSuggestion, :suggest, attrs)

    assert {:ok, repeated} =
             Ankole.Ash.create(MergeSuggestion, :suggest, %{attrs | reason: "Later evidence"})

    assert_persisted_equal(repeated, proposal)

    assert {:ok, rejected} =
             Repo.transact(fn _ -> Ankole.Ash.update(proposal, :reject, %{decided_by: actor}) end)

    assert {:error, error} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(proposal, :approve, %{decided_by: actor})
             end)

    assert Enum.any?(error.errors, &is_struct(&1, Ankole.Errors.Invalid.StatusTransition))
    Ankole.DataCase.assert_persisted_equal(Repo.get!(MergeSuggestion, proposal.id), rejected)
  end

  test "a dismissed contradiction preserves the first model verdict on retries" do
    alias Ankole.Brain.Schemas.Contradiction
    {a, b} = fact_pair()

    assert :ok =
             Ankole.Brain.Dreaming.record_contradiction_verdict(
               a.id,
               b.id,
               "no_contradiction",
               0.9,
               %{"axis" => "time", "severity" => "info"}
             )

    original = Repo.get_by!(Contradiction, a_claim_id: a.id, b_claim_id: b.id)
    assert original.status == :dismissed

    assert :ok =
             Ankole.Brain.Dreaming.record_contradiction_verdict(
               a.id,
               b.id,
               "direct_conflict",
               1.0,
               %{"axis" => "other", "severity" => "high"}
             )

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Contradiction, original.id), original)

    assert {:error, error} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(original, :resolve, %{resolution_note: "Late"})
             end)

    assert Enum.any?(error.errors, &is_struct(&1, Ankole.Errors.Invalid.StatusTransition))
    Ankole.DataCase.assert_persisted_equal(Repo.get!(Contradiction, original.id), original)
  end

  defp fact_pair do
    human = human_fixture().principal

    {:ok, object} =
      Ankole.Brain.create_object(
        %{slug: "notes/" <> Ankole.Ecto.UUIDv7.autogenerate(), type: "note", title: "Timeline"},
        human.uid
      )

    attrs = %{
      object_slug: object.slug,
      holder: "people/#{human.uid}",
      claim: "Delivery is in Q3",
      kind: "event",
      audience_scope: "world",
      notability: "medium",
      confidence: 0.8,
      context: "Delivery",
      valid_from: DateTime.utc_now(:microsecond),
      provenance: "test"
    }

    {:ok, %{claim: a}} =
      Ankole.Brain.write_fact(attrs, human.uid, %{options: [embed: false, dedup: false]})

    {:ok, %{claim: b}} =
      Ankole.Brain.write_fact(%{attrs | claim: "Delivery is in Q4"}, human.uid, %{
        options: [embed: false, dedup: false]
      })

    {a, b}
  end

  defp take_fixture do
    human = human_fixture().principal

    {:ok, object} =
      Ankole.Brain.create_object(
        %{slug: "notes/" <> Ankole.Ecto.UUIDv7.autogenerate(), type: "note", title: "Assignment"},
        human.uid
      )

    {:ok, take} =
      Claims.write_take(
        %{
          object_slug: object.slug,
          holder: "people/#{human.uid}",
          claim: "A forecast",
          kind: "prediction",
          weight: 0.6,
          audience_scope: "world",
          provenance: "test"
        },
        human.uid,
        embed: false
      )

    take
  end
end
