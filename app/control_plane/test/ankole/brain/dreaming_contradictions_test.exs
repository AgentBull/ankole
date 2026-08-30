defmodule Ankole.Brain.DreamingContradictionsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Dreaming
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Contradiction
  alias Ankole.Repo

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: human} = human_fixture()

    {:ok, _object} =
      Objects.create_object(
        %{slug: "companies/acme", type: "company", title: "Acme"},
        human.uid
      )

    {:ok, %{claim: a}} = write_fact(human, "Acme headquarters are in Berlin")
    {:ok, %{claim: b}} = write_fact(human, "Acme headquarters are in Munich")

    %{human: human, a: a, b: b}
  end

  defp write_fact(human, text) do
    Claims.write_fact(
      %{
        object_slug: "companies/acme",
        claim: text,
        kind: "fact",
        holder: "world",
        audience_scope: "world",
        notability: "medium",
        confidence: 0.75,
        valid_from: DateTime.utc_now(:microsecond),
        provenance: "test"
      },
      human.uid
    )
  end

  test "a confident contradiction verdict opens a triage row", %{a: a, b: b} do
    assert :ok =
             Dreaming.record_contradiction_verdict(a.id, b.id, "contradiction", 0.9, %{
               "axis" => "headquarters city",
               "severity" => "high"
             })

    assert %Contradiction{status: "open", verdict: "contradiction", severity: "high"} =
             Repo.get_by(Contradiction, a_claim_id: a.id, b_claim_id: b.id)
  end

  test "negative and low-confidence verdicts are recorded as dismissed", %{a: a, b: b} do
    assert :ok = Dreaming.record_contradiction_verdict(a.id, b.id, "no_contradiction", 0.9, %{})

    assert %Contradiction{status: "dismissed", verdict: "no_contradiction"} =
             Repo.get_by(Contradiction, a_claim_id: a.id, b_claim_id: b.id)
  end

  test "a recorded verdict removes the pair from later candidate rounds", %{a: a, b: b} do
    ids = {a.id, b.id}

    assert Enum.any?(Dreaming.contradiction_candidates(), fn {left, right} ->
             {left.id, right.id} == ids or {right.id, left.id} == ids
           end)

    assert :ok = Dreaming.record_contradiction_verdict(a.id, b.id, "no_contradiction", 0.8, %{})

    refute Enum.any?(Dreaming.contradiction_candidates(), fn {left, right} ->
             {left.id, right.id} == ids or {right.id, left.id} == ids
           end)
  end

  test "only an open contradiction accepts an operator decision", %{a: a, b: b} do
    assert :ok = Dreaming.record_contradiction_verdict(a.id, b.id, "contradiction", 0.9, %{})
    contradiction = Repo.get_by!(Contradiction, a_claim_id: a.id, b_claim_id: b.id)

    assert {:ok, %Contradiction{status: "resolved"} = decided} =
             Dreaming.decide_contradiction(contradiction.id, "resolved", "kept claim A")

    assert decided.resolution_note == "kept claim A"
    assert decided.decided_at

    # A decided row must not flip again, and a missing row is its own error.
    assert {:error, :conflict} =
             Dreaming.decide_contradiction(contradiction.id, "dismissed", nil)

    assert {:error, :not_found} =
             Dreaming.decide_contradiction(Ecto.UUID.generate(), "resolved", nil)
  end
end
