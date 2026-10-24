defmodule Ankole.Brain.ClaimActionsTest do
  use Ankole.DataCase, async: true

  alias Ankole.Brain.{Claims, SchemaPacks}
  alias Ankole.Brain.Schemas.Claim

  setup do
    {:ok, _} = SchemaPacks.install_packs([])

    {:ok, object} =
      Ankole.Brain.create_object(
        %{slug: "notes/claim-actions", type: "note", title: "Claims"},
        :system
      )

    %{object: object}
  end

  test "record actions keep Fact and Take field families distinct", %{object: object} do
    fact = fact!(object)
    take = take!(object)
    assert fact.claim_type == :fact
    assert take.claim_type == :take
    assert fact.active == nil
    assert take.valid_from == nil

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Invalid.NoSuchInput{input: :active}]}} =
             Repo.transact(fn _ ->
               Ankole.Ash.create(Claim, :record_fact, Map.put(fact_attrs(object), :active, true))
             end)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE brain_claims SET active = true WHERE id = $1::text::uuid", [fact.id],
          mode: :savepoint
        )
      end

    assert error.postgres.constraint == "brain_claims_type_shape"

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "UPDATE brain_claims SET notability = NULL WHERE id = $1::text::uuid",
          [fact.id],
          mode: :savepoint
        )
      end

    assert error.postgres.constraint == "brain_claims_type_shape"
    Ankole.DataCase.assert_persisted_equal(Repo.get!(Claim, fact.id), fact)
  end

  test "actions reject the wrong family and stale Take resolution", %{object: object} do
    fact = fact!(object)
    take = take!(object)

    assert {:error, %Ash.Error.Invalid{errors: [%Ankole.Errors.Invalid.Stale{}]}} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(take, :expire_fact, %{at: DateTime.utc_now()})
             end)

    assert {:error, %Ash.Error.Invalid{errors: [%Ankole.Errors.Invalid.Stale{}]}} =
             Repo.transact(fn _ -> Ankole.Ash.update(fact, :deactivate_take, %{}) end)

    first = %{resolved_quality: "correct", resolved_outcome: true, resolved_by: "system"}

    assert {:ok, resolved} =
             Repo.transact(fn _ -> Ankole.Ash.update(take, :resolve_take, first) end)

    assert resolved.active == false
    assert resolved.resolved_at

    assert {:error, %Ash.Error.Invalid{errors: [%Ankole.Errors.Invalid.Stale{}]}} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(take, :resolve_take, %{
                 first
                 | resolved_quality: "incorrect",
                   resolved_outcome: false
               })
             end)

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Claim, take.id), resolved)
    Ankole.DataCase.assert_persisted_equal(Repo.get!(Claim, fact.id), fact)
  end

  test "superseding once cannot redirect history from an old snapshot", %{object: object} do
    original = fact!(object)
    replacement = fact!(object, %{claim: "The corrected assertion"})
    other = fact!(object, %{claim: "A later assertion"})

    assert {:ok, superseded} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(original, :supersede, %{superseded_by: replacement.id})
             end)

    assert superseded.expired_at

    assert {:error, %Ash.Error.Invalid{errors: [%Ankole.Errors.Invalid.Stale{}]}} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(original, :supersede, %{superseded_by: other.id})
             end)

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Claim, original.id), superseded)
  end

  test "source withdrawal applies both field families at the supplied commit clock", %{
    object: object
  } do
    source_id = Ankole.Ecto.UUIDv7.autogenerate()
    session = "source:" <> source_id
    fact = fact!(object, %{provenance_session: session})
    take = take!(object, %{provenance_session: session})
    unrelated = fact!(object, %{claim: "Unrelated fact", provenance_session: "other"})
    now = ~U[2026-10-22 12:34:56.123456Z]

    assert {:ok, :withdrawn} =
             Repo.transact(fn ->
               :ok = Claims.withdraw_source_claims_in_tx(source_id, now)
               {:ok, :withdrawn}
             end)

    assert Repo.get!(Claim, fact.id).expired_at == now
    assert Repo.get!(Claim, fact.id).updated_at == now
    assert Repo.get!(Claim, take.id).active == false
    assert Repo.get!(Claim, take.id).updated_at == now
    Ankole.DataCase.assert_persisted_equal(Repo.get!(Claim, unrelated.id), unrelated)
  end

  test "late failure cannot erase a successfully rebuilt vector", %{object: object} do
    original = take!(object)
    {:ok, vector} = Ash.Vector.new([1.0 | List.duplicate(0.0, 4095)])

    assert {:ok, :embedded} =
             Ankole.Brain.attach_claim_embedding(original, vector, "current-model")

    embedded = Repo.get!(Claim, original.id)

    assert {:ok, :stale} =
             Claims.record_embedding_error(original, "late transport failure", "older-model")

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Claim, original.id), embedded)
    assert embedded.embedding_error == nil
    assert embedded.embedding_signature == "current-model"
  end

  test "late dedup clears a failed vector as one native-valid state", %{object: object} do
    original = fact!(object)
    replacement = fact!(object, %{claim: "Equivalent current assertion"})
    assert {:ok, :updated} = Claims.record_embedding_error(original, "model failed", "old-model")
    failed = Repo.get!(Claim, original.id)

    assert {:ok, deduplicated} =
             Repo.transact(fn _ ->
               Ankole.Ash.update(failed, :deduplicate, %{superseded_by: replacement.id})
             end)

    assert deduplicated.superseded_by == replacement.id
    assert deduplicated.expired_at
    assert deduplicated.embedding == nil
    assert deduplicated.embedding_signature == nil
    assert deduplicated.embedding_error == nil
    assert deduplicated.embedded_at == nil
  end

  defp fact!(object, overrides \\ %{}) do
    {:ok, %{claim: claim}} =
      Ankole.Brain.write_fact(Map.merge(fact_attrs(object), overrides), :system, %{
        options: [embed: false]
      })

    claim
  end

  defp fact_attrs(object) do
    %{
      object_slug: object.slug,
      claim: "An assertion",
      kind: "fact",
      holder: "world",
      audience_scope: "world",
      notability: "medium",
      confidence: 0.75,
      valid_from: DateTime.utc_now(),
      provenance: "claim actions"
    }
  end

  defp take!(object, overrides \\ %{}) do
    attrs = %{
      object_slug: object.slug,
      claim: "A prediction",
      kind: "forecast",
      holder: "world",
      audience_scope: "world",
      weight: 0.75,
      provenance: "claim actions"
    }

    {:ok, claim} = Claims.write_take(Map.merge(attrs, overrides), :system, embed: false)
    claim
  end
end
