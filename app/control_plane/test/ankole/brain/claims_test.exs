defmodule Ankole.Brain.ClaimsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: human} = human_fixture()

    {:ok, object} =
      Objects.create_object(
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

  describe "write_fact/3" do
    test "writes a degraded fact without an embedding model", %{human: human} do
      assert {:ok, %{claim: claim, status: :inserted}} =
               Claims.write_fact(fact_attrs(), human.uid)

      assert claim.claim_type == "fact"
      assert claim.author_uid == human.uid
      assert is_nil(claim.embedding)
      assert is_nil(claim.embedding_signature)
    end

    test "semantic dedup compares only the same embedding signature", %{human: human} do
      vector =
        [1.0 | List.duplicate(0.0, 4095)]
        |> Pgvector.new()

      assert {:ok, %{claim: first, status: :inserted}} =
               Claims.write_fact(
                 fact_attrs(%{claim: "Acme opened its Singapore office"}),
                 human.uid,
                 embedding: {vector, "model-a"}
               )

      assert {:ok, %{claim: second, status: :inserted}} =
               Claims.write_fact(
                 fact_attrs(%{claim: "Acme closed its Singapore office"}),
                 human.uid,
                 embedding: {vector, "model-b"}
               )

      assert Repo.get!(Ankole.Brain.Schemas.Claim, first.id).expired_at == nil

      assert {:ok, %{claim: duplicate, status: :duplicate}} =
               Claims.write_fact(
                 fact_attrs(%{claim: "Acme closed its Singapore office"}),
                 human.uid,
                 embedding: {vector, "model-b"}
               )

      assert duplicate.id == second.id
    end

    test "rejects off-grid confidence", %{human: human} do
      assert {:error, {:off_weight_grid, :confidence}} =
               Claims.write_fact(fact_attrs(%{confidence: 0.42}), human.uid)

      assert {:error, {:out_of_range, :confidence}} =
               Claims.write_fact(fact_attrs(%{confidence: 1.2}), human.uid)
    end

    test "rejects invalid kind, notability, and holder", %{human: human} do
      assert {:error, {:invalid_fact_kind, "opinion", _kinds}} =
               Claims.write_fact(fact_attrs(%{kind: "opinion"}), human.uid)

      assert {:error, {:invalid_notability, "extreme", _values}} =
               Claims.write_fact(fact_attrs(%{notability: "extreme"}), human.uid)

      assert {:error, {:unresolvable_holder, "people/ghost"}} =
               Claims.write_fact(fact_attrs(%{holder: "people/ghost"}), human.uid)
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
               Claims.write_fact(
                 fact_attrs(%{audience_scope: "group:#{group.name}"}),
                 human.uid
               )

      # A system path validates existence only.
      assert {:ok, %{status: :inserted}} =
               Claims.write_fact(
                 fact_attrs(%{audience_scope: "group:#{group.name}"}),
                 :system
               )
    end

    test "content gates reject junk", %{human: human} do
      assert {:error, :blank_claim} = Claims.write_fact(fact_attrs(%{claim: "  "}), human.uid)

      assert {:error, {:claim_too_long, _limit}} =
               Claims.write_fact(fact_attrs(%{claim: String.duplicate("a b ", 1000)}), human.uid)

      assert {:error, :claim_garbled} =
               Claims.write_fact(fact_attrs(%{claim: String.duplicate("!", 64)}), human.uid)
    end

    test "reserves the internal provenance prefix", %{human: human} do
      assert {:error, :reserved_provenance_prefix} =
               Claims.write_fact(
                 fact_attrs(%{provenance: "ankole-brain-internal:fake"}),
                 human.uid
               )
    end
  end

  describe "write_take/3 and lifecycle" do
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
      assert take.claim_type == "take"
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
               Claims.resolve_take(take.id, %{resolved_quality: "correct"}, human.uid)

      assert {:ok, resolved} =
               Claims.resolve_take(
                 take.id,
                 %{resolved_quality: "correct", resolved_outcome: true},
                 human.uid
               )

      assert resolved.resolved_quality == "correct"
      assert resolved.active == false

      assert {:error, :already_resolved} =
               Claims.resolve_take(
                 take.id,
                 %{resolved_quality: "incorrect", resolved_outcome: false},
                 human.uid
               )
    end

    test "supersede replaces and expires the old fact", %{human: human} do
      {:ok, %{claim: original}} = Claims.write_fact(fact_attrs(), human.uid)

      assert {:ok, replacement} =
               Claims.supersede_claim(
                 original.id,
                 %{claim: "Acme raised a Series B round of 20M USD"},
                 human.uid
               )

      original = Repo.get!(Ankole.Brain.Schemas.Claim, original.id)
      assert original.superseded_by == replacement.id
      assert original.expired_at != nil

      assert {:error, :already_superseded} =
               Claims.supersede_claim(original.id, %{claim: "again"}, human.uid)
    end

    test "expire_fact and deactivate_take leave history", %{human: human} do
      {:ok, %{claim: fact}} = Claims.write_fact(fact_attrs(), human.uid)
      assert {:ok, expired} = Claims.expire_fact(fact.id)
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

      assert {:ok, inactive} = Claims.deactivate_take(take.id)
      assert inactive.active == false
    end
  end

  describe "extraction terminals" do
    test "writes and finds idempotency terminals per version token", %{human: human} do
      channel = insert_channel!()

      assert Claims.extraction_terminal(channel.id, "token-1") == nil

      boundary_at = DateTime.utc_now(:microsecond)

      assert {:ok, terminal} =
               Claims.write_extraction_terminal(channel.id, "token-1", :complete,
                 boundary: {boundary_at, "entry-9"}
               )

      assert terminal.claim == "EXTRACTION_COMPLETE"
      assert terminal.valid_from == boundary_at
      assert terminal.context == "entry-9"
      assert String.starts_with?(terminal.provenance, Claims.internal_provenance_prefix())

      found = Claims.extraction_terminal(channel.id, "token-1")
      assert found.id == terminal.id

      assert Claims.extraction_terminal(channel.id, "token-2") == nil

      # Internal terminals never enter fact dedup or recall candidates; a
      # normal fact write from the same human still works.
      assert {:ok, %{status: :inserted}} = Claims.write_fact(fact_attrs(), human.uid)

      # The unique terminal index fences a concurrent rerun of the same
      # slice: the second commit fails instead of double-writing memory.
      # This raise aborts the sandbox transaction, so it stays last.
      assert_raise Ecto.ConstraintError, fn ->
        Claims.write_extraction_terminal(channel.id, "token-1", :complete,
          boundary: {boundary_at, "entry-9"}
        )
      end
    end
  end

  defp insert_channel! do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      Ankole.SignalsGateway.Channel.changeset(%Ankole.SignalsGateway.Channel{}, %{
        id: "test:channel-#{System.unique_integer([:positive])}",
        kind: :im_group,
        reply_mode: :entry,
        metadata: %{},
        raw_payload: %{},
        first_seen_at: now,
        last_seen_at: now
      })
    )
  end
end
