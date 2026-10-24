defmodule Ankole.Brain.ClaimsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  require Ash.Query

  alias Ankole.Brain.Claims
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: human} = human_fixture()

    {:ok, object} =
      Ankole.Brain.create_object(
        %{slug: "companies/acme", type: "company", title: "Acme"},
        human.uid
      )

    %{human: human, object: object}
  end

  defp fact_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        object_slug: "companies/acme",
        claim: "Acme raised a Series B round",
        kind: "event",
        holder: "world",
        audience_scope: "world",
        notability: "medium",
        confidence: 0.75,
        valid_from: DateTime.utc_now(:microsecond),
        provenance: "test conversation"
      },
      overrides
    )
  end

  test "platform attribution survives superseding and removal of its author tenant", %{
    tenant: tenant
  } do
    other = Ankole.DataCase.create_tenant()
    author = Repo.with_tenant(other.id, fn -> human_fixture().principal end)
    reference = Ankole.ActorRef.from_principal(author)
    Repo.put_tenant_id(tenant.id)

    assert {:ok, %{claim: original}} =
             Ankole.Brain.write_fact(fact_attrs(), :system, %{options: [author: reference]})

    assert {:ok, replacement} =
             Ankole.Brain.supersede_claim(original.id, %{claim: "A corrected fact"}, :system, %{
               author: reference
             })

    assert replacement.author == reference

    Repo.with_tenant(other.id, fn ->
      Repo.delete!(author)
      Repo.delete_all(Ankole.Brain.Schemas.Object)
      # Tenant creation also initializes Space grants and its all-humans group.
      # Remove those fixture rows before testing attribution without its tenant.
      Repo.delete_all(Ankole.AuthZ.Grant)
      Repo.delete_all(Ankole.AuthZ.Group)
    end)

    Repo.delete!(other)
    assert Repo.get!(Claim, replacement.id).author == reference
  end

  describe "write_fact/3" do
    test "writes a degraded fact without an embedding model", %{human: human} do
      assert {:ok, %{claim: claim, status: :inserted}} =
               Ankole.Brain.write_fact(fact_attrs(), human.uid)

      assert claim.claim_type == :fact
      assert claim.author == Ankole.ActorRef.from_principal(human)
      assert is_nil(claim.embedding)
      assert is_nil(claim.embedding_signature)
    end

    test "semantic dedup compares only the same embedding signature", %{human: human} do
      {:ok, vector} = Ash.Vector.new([1.0 | List.duplicate(0.0, 4095)])

      assert {:ok, %{claim: first, status: :inserted}} =
               Ankole.Brain.write_fact(
                 fact_attrs(%{claim: "Acme opened its Singapore office"}),
                 human.uid,
                 %{options: [embedding: {vector, "model-a"}]}
               )

      assert {:ok, %{claim: second, status: :inserted}} =
               Ankole.Brain.write_fact(
                 fact_attrs(%{claim: "Acme closed its Singapore office"}),
                 human.uid,
                 %{options: [embedding: {vector, "model-b"}]}
               )

      assert Repo.get!(Ankole.Brain.Schemas.Claim, first.id).expired_at == nil

      assert {:ok, %{claim: duplicate, status: :duplicate}} =
               Ankole.Brain.write_fact(
                 fact_attrs(%{claim: "Acme closed its Singapore office"}),
                 human.uid,
                 %{options: [embedding: {vector, "model-b"}]}
               )

      assert duplicate.id == second.id
    end

    test "persists integer confidence endpoints as floats", %{human: human} do
      for confidence <- [0, 1] do
        assert {:ok, %{claim: claim, status: :inserted}} =
                 Ankole.Brain.write_fact(
                   fact_attrs(%{
                     claim: "Confidence endpoint #{confidence}",
                     confidence: confidence
                   }),
                   human.uid
                 )

        assert Repo.get!(Claim, claim.id).confidence === confidence * 1.0
      end
    end

    test "stored PostgreSQL vectors load and participate in semantic dedup", %{human: human} do
      values = [0.1, 0.2 | List.duplicate(0.0, 4094)]
      {:ok, vector} = Ash.Vector.new(values)

      assert {:ok, %{claim: original}} =
               Ankole.Brain.write_fact(fact_attrs(), human.uid, %{options: [embed: false]})

      # Store a native vector without the application codec, as in an imported database.
      Repo.query!(
        """
        UPDATE brain_claims
        SET embedding = $1::text::vector,
            embedding_signature = 'stored-model', embedded_at = now()
        WHERE id = $2::text::uuid
        """,
        ["[" <> Enum.join(values, ",") <> "]", original.id]
      )

      stored = Claim |> Ash.Query.filter(id == ^original.id) |> Ankole.Ash.read_one!()
      assert Ash.Vector.to_list(stored.embedding) == Ash.Vector.to_list(vector)
      assert Repo.get!(Claim, original.id).embedding == stored.embedding

      assert {:ok, %{claim: duplicate, status: :duplicate}} =
               Ankole.Brain.write_fact(fact_attrs(), human.uid, %{
                 options: [embedding: {vector, "stored-model"}]
               })

      assert duplicate.id == original.id
    end

    test "rejects off-grid confidence", %{human: human} do
      assert {:error, {:off_weight_grid, :confidence}} =
               Ankole.Errors.reason(
                 Ankole.Brain.write_fact(fact_attrs(%{confidence: 0.42}), human.uid)
               )

      assert {:error, {:out_of_range, :confidence}} =
               Ankole.Errors.reason(
                 Ankole.Brain.write_fact(fact_attrs(%{confidence: 1.2}), human.uid)
               )
    end

    test "rejects invalid kind, notability, and holder", %{human: human} do
      assert {:error, {:invalid_fact_kind, "opinion", _kinds}} =
               Ankole.Errors.reason(
                 Ankole.Brain.write_fact(fact_attrs(%{kind: "opinion"}), human.uid)
               )

      assert {:error, {:invalid_notability, "extreme", _values}} =
               Ankole.Errors.reason(
                 Ankole.Brain.write_fact(fact_attrs(%{notability: "extreme"}), human.uid)
               )

      assert {:error, {:unresolvable_holder, "people/ghost"}} =
               Ankole.Errors.reason(
                 Ankole.Brain.write_fact(fact_attrs(%{holder: "people/ghost"}), human.uid)
               )
    end

    test "rejects group scopes the writer does not satisfy", %{human: human} do
      {:ok, group} =
        Ankole.AuthZ.create_principal_group(%{
          name: "claims-team-#{System.unique_integer([:positive])}",
          display_name: "Team",
          domain: :operator,
          kind: :static
        })

      assert {:error, {:writer_not_in_scope_group, _name}} =
               Ankole.Errors.reason(
                 Ankole.Brain.write_fact(
                   fact_attrs(%{audience_scope: "group:#{group.name}"}),
                   human.uid
                 )
               )

      # A system path validates existence only.
      assert {:ok, %{status: :inserted}} =
               Ankole.Brain.write_fact(
                 fact_attrs(%{audience_scope: "group:#{group.name}"}),
                 :system
               )
    end

    test "content gates reject junk", %{human: human} do
      assert {:error, :blank_claim} =
               Ankole.Errors.reason(
                 Ankole.Brain.write_fact(fact_attrs(%{claim: "  "}), human.uid)
               )

      assert {:error, {:claim_too_long, _limit}} =
               Ankole.Errors.reason(
                 Ankole.Brain.write_fact(
                   fact_attrs(%{claim: String.duplicate("a b ", 1000)}),
                   human.uid
                 )
               )

      assert {:error, :claim_garbled} =
               Ankole.Errors.reason(
                 Ankole.Brain.write_fact(
                   fact_attrs(%{claim: String.duplicate("!", 64)}),
                   human.uid
                 )
               )
    end
  end

  describe "write_take/3 and lifecycle" do
    test "persists integer weight endpoints as floats", %{human: human} do
      for weight <- [0, 1] do
        assert {:ok, take} =
                 Claims.write_take(
                   %{
                     object_slug: "companies/acme",
                     claim: "Weight endpoint #{weight}",
                     kind: "bet",
                     holder: "people/#{human.uid}",
                     audience_scope: "world",
                     weight: weight,
                     provenance: "analysis session"
                   },
                   human.uid
                 )

        assert Repo.get!(Claim, take.id).weight === weight * 1.0
      end
    end

    test "writes an active take with open kind", %{human: human} do
      assert {:ok, take} =
               Claims.write_take(
                 %{
                   object_slug: "companies/acme",
                   claim: "Acme will win the enterprise segment",
                   kind: "bet",
                   holder: "people/#{human.uid}",
                   audience_scope: "world",
                   weight: 0.65,
                   provenance: "analysis session"
                 },
                 human.uid
               )

      assert take.active == true
      assert take.claim_type == :take
    end

    test "resolution is immutable and outcome must match quality", %{human: human} do
      {:ok, take} =
        Claims.write_take(
          %{
            object_slug: "companies/acme",
            claim: "Acme closes the deal this quarter",
            kind: "bet",
            holder: "people/#{human.uid}",
            audience_scope: "world",
            weight: 0.6,
            provenance: "chat"
          },
          human.uid
        )

      assert {:error, :resolution_outcome_required} =
               Ankole.Errors.reason(
                 Ankole.Brain.resolve_take(take.id, %{resolved_quality: "correct"}, human.uid)
               )

      assert {:ok, resolved} =
               Ankole.Brain.resolve_take(
                 take.id,
                 %{resolved_quality: "correct", resolved_outcome: true},
                 human.uid
               )

      assert resolved.resolved_quality == "correct"
      assert resolved.active == false

      assert {:error, :already_resolved} =
               Ankole.Errors.reason(
                 Ankole.Brain.resolve_take(
                   take.id,
                   %{resolved_quality: "incorrect", resolved_outcome: false},
                   human.uid
                 )
               )
    end

    test "supersede replaces and expires the old fact", %{human: human} do
      {:ok, %{claim: original}} = Ankole.Brain.write_fact(fact_attrs(), human.uid)

      assert {:ok, replacement} =
               Ankole.Brain.supersede_claim(
                 original.id,
                 %{claim: "Acme raised a Series B round of 20M USD"},
                 human.uid
               )

      original = Repo.get!(Ankole.Brain.Schemas.Claim, original.id)
      assert original.superseded_by == replacement.id
      assert original.expired_at != nil

      assert {:error, :already_superseded} =
               Ankole.Errors.reason(
                 Ankole.Brain.supersede_claim(original.id, %{claim: "again"}, human.uid)
               )
    end

    test "expire_fact and deactivate_take leave history", %{human: human} do
      {:ok, %{claim: fact}} = Ankole.Brain.write_fact(fact_attrs(), human.uid)
      assert {:ok, expired} = Ankole.Brain.expire_fact(fact.id)
      assert expired.expired_at != nil

      {:ok, take} =
        Claims.write_take(
          %{
            object_slug: "companies/acme",
            claim: "A take to deactivate",
            kind: "take",
            holder: "world",
            audience_scope: "world",
            weight: 0.5,
            provenance: "chat"
          },
          human.uid
        )

      assert {:ok, inactive} = Ankole.Brain.deactivate_take(take.id)
      assert inactive.active == false
    end
  end
end
