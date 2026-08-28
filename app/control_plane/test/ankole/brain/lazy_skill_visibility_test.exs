defmodule Ankole.Brain.LazySkillVisibilityTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.Brain.Claims
  alias Ankole.Brain.ContextPack
  alias Ankole.Brain.Dreaming
  alias Ankole.Brain.GetPage
  alias Ankole.Brain.LibraryKnowledge
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Contradiction
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Synthesis
  alias Ankole.Brain.Timelines

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

  test "Agent enablement hides lazy Skills from every model read without withdrawing projection",
       %{
         agent: agent
       } do
    assert {:ok, page} = GetPage.get_page(agent.uid, @slug)
    assert page.type == "agent-skills"
    assert {:ok, %{slug: @slug}} = GetPage.get_page(agent.uid, "zephyr-lineage")

    assert [%{slug: @slug}] =
             ContextPack.volunteer_pointers(agent.uid, "Please use zephyr-lineage")

    assert {:ok, before_disable} =
             Recall.recall(agent.uid, %{query: "zephyr lineage signal", limit: 5})

    assert Enum.any?(before_disable.chunks, &(&1.object_slug == @slug))

    assert {:ok, _timeline} =
             Timelines.write_timeline(
               %{
                 object_slug: @slug,
                 date: ~D[2026-08-28],
                 summary: "Lineage method was reviewed",
                 provenance: "test",
                 audience_scope: "world"
               },
               agent.uid
             )

    assert {:ok, _skill} =
             Library.set_agent_skill_override(
               agent.uid,
               "brain:idea-lineage",
               false
             )

    assert {:error, :not_found} = GetPage.get_page(agent.uid, @slug)
    assert {:error, :not_found} = GetPage.get_page(agent.uid, "zephyr-lineage")
    assert ContextPack.volunteer_pointers(agent.uid, "Please use zephyr-lineage") == []

    assert {:error, {:entity_not_found, "zephyr-lineage"}} =
             Synthesis.delta(agent.uid, %{entity: "zephyr-lineage"})

    assert {:ok, delta} = Synthesis.delta(agent.uid, %{})
    refute Enum.any?(delta.timeline_events, &(&1.object_slug == @slug))

    assert {:ok, after_disable} =
             Recall.recall(agent.uid, %{query: "zephyr lineage signal", limit: 5})

    refute Enum.any?(after_disable.chunks, &(&1.object_slug == @slug))

    projected = Repo.get_by!(Object, slug: @slug)
    assert projected.deleted_at == nil
    assert {:ok, %{slug: @slug}} = GetPage.get_page_admin(@slug)

    assert {:ok, _skill} =
             Library.set_agent_skill_override(agent.uid, "brain:idea-lineage", nil)

    assert {:ok, %{slug: @slug}} = GetPage.get_page(agent.uid, @slug)

    assert {:ok, _plugin} = AgentPlugins.set_agent_override(agent.uid, "brain", false)
    assert {:error, :not_found} = GetPage.get_page(agent.uid, @slug)
    assert Repo.get_by!(Object, slug: @slug).deleted_at == nil

    assert {:ok, _plugin} = AgentPlugins.set_agent_override(agent.uid, "brain", nil)
    assert {:ok, %{slug: @slug}} = GetPage.get_page(agent.uid, @slug)
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
