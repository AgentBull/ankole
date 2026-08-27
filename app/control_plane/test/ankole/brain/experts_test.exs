defmodule Ankole.Brain.ExpertsTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Experts
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])

    %{principal: querier} = human_fixture()
    %{principal: expert} = human_fixture()
    %{principal: outsider} = human_fixture()

    {:ok, _topic} =
      Objects.create_object(
        %{slug: "concepts/quantum-sensing", type: "concept", title: "Quantum Sensing"},
        querier.uid
      )

    holder = "people/" <> expert.uid

    {:ok, _fact} =
      Claims.write_fact(
        %{
          object_slug: "concepts/quantum-sensing",
          claim: "Quantum sensing market doubles every two years",
          kind: "fact",
          holder: holder,
          audience_scope: "world",
          notability: "high",
          confidence: 0.8,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "test"
        },
        expert.uid
      )

    %{querier: querier, expert: expert, outsider: outsider, holder: holder}
  end

  test "calibration counts only takes the querier can reach", context do
    # A resolved take the querier can reach through its world scope.
    {:ok, reachable} =
      Claims.write_take(
        %{
          object_slug: "concepts/quantum-sensing",
          claim: "Quantum sensing revenue passes one billion by 2027",
          kind: "bet",
          holder: context.holder,
          audience_scope: "world",
          weight: 0.8,
          provenance: "test"
        },
        context.expert.uid
      )

    {:ok, _resolved} =
      Claims.resolve_take(
        reachable.id,
        %{resolved_quality: "correct", resolved_outcome: true},
        context.expert.uid
      )

    # A resolved take scoped to another Principal: the querier is neither in
    # scope nor the author, so it must not move resolved_count or Brier.
    {:ok, unreachable} =
      Claims.write_take(
        %{
          object_slug: "concepts/quantum-sensing",
          claim: "Quantum sensing pilot fails at the outsider site",
          kind: "bet",
          holder: context.holder,
          audience_scope: "principal:" <> context.outsider.uid,
          weight: 0.2,
          provenance: "test"
        },
        :system
      )

    {:ok, _resolved} =
      Claims.resolve_take(
        unreachable.id,
        %{resolved_quality: "incorrect", resolved_outcome: false},
        context.expert.uid
      )

    assert {:ok, [ranked | _rest]} =
             Experts.who_knows(context.querier.uid, "quantum sensing market")

    assert ranked.holder == context.holder
    assert ranked.calibration.resolved_count == 1
    # Brier over only the reachable take: (0.8 - 1.0)^2 = 0.04.
    assert ranked.calibration.brier == 0.04

    # The outsider reaches both takes (scope plus world), so its scorecard
    # sees the full history.
    assert {:ok, [for_outsider | _rest]} =
             Experts.who_knows(context.outsider.uid, "quantum sensing market")

    assert for_outsider.calibration.resolved_count == 2
  end
end
