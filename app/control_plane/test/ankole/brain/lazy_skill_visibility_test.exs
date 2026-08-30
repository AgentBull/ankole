defmodule Ankole.Brain.LazySkillVisibilityTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Dreaming
  alias Ankole.Brain.GetPage
  alias Ankole.Brain.LibraryKnowledge
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Contradiction

  @slug "lazyload-agent-skills/idea-lineage"

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: owner} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})

    set = %{
      kind: :lazy_skills,
      set_id: "lazy-visibility-test",
      name: "Lazy visibility test inventory",
      skills: [
        %{
          name: "idea-lineage",
          description: "Use the zephyr lineage signal to trace a verified idea evolution.",
          metadata: %{"tags" => ["zephyr-lineage", "溯源"]},
          source_hash: "visibility-v1",
          files: []
        }
      ]
    }

    assert {:ok, _report} = LibraryKnowledge.sync(sets: [set])
    assert {:ok, _sync} = Library.sync_agent_skills(agent.uid)

    %{agent: agent}
  end

  test "get_page filters disabled lazy counterparts before its contradiction limit", %{
    agent: agent
  } do
    {:ok, page_object} =
      Objects.create_object(
        %{slug: "notes/visible-contradictions", type: "note", title: "Visible contradictions"},
        agent.uid
      )

    {:ok, %{claim: own_claim}} = fact(page_object.slug, "The launch date is Monday", agent.uid)

    {:ok, visible_object} =
      Objects.create_object(
        %{slug: "notes/visible-counterpart", type: "note", title: "Visible counterpart"},
        agent.uid
      )

    {:ok, %{claim: visible_counterpart}} =
      fact(visible_object.slug, "The launch date is Tuesday", agent.uid)

    assert :ok = contradiction(own_claim.id, visible_counterpart.id)

    Repo.update_all(Contradiction,
      set: [created_at: DateTime.add(DateTime.utc_now(:microsecond), -60, :second)]
    )

    for index <- 1..20 do
      {:ok, %{claim: hidden_counterpart}} =
        fact(@slug, "Hidden lazy contradiction #{index}", agent.uid)

      assert :ok = contradiction(own_claim.id, hidden_counterpart.id)
    end

    assert {:ok, _skill} =
             Library.set_agent_skill_override(
               agent.uid,
               "brain:idea-lineage",
               false
             )

    assert {:ok, page} = GetPage.get_page(agent.uid, page_object.slug)
    assert [finding] = page.contradictions
    assert finding.counterpart.id == visible_counterpart.id
  end

  defp fact(object_slug, claim, author_uid) do
    Claims.write_fact(
      %{
        object_slug: object_slug,
        claim: claim,
        kind: "fact",
        holder: "world",
        audience_scope: "world",
        notability: "medium",
        confidence: 0.75,
        valid_from: DateTime.utc_now(:microsecond),
        provenance: "test"
      },
      author_uid
    )
  end

  defp contradiction(a_claim_id, b_claim_id) do
    Dreaming.record_contradiction_verdict(
      a_claim_id,
      b_claim_id,
      "contradiction",
      0.9,
      %{"axis" => "date", "severity" => "high"}
    )
  end
end
