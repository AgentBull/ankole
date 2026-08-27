defmodule Ankole.Brain.RecallTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.SchemaPacks

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])

    %{principal: member} = human_fixture()
    %{principal: outsider} = human_fixture()

    %{principal: agent} =
      agent_fixture(%{owner_principal_uid: member.uid})

    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: "recall-team-#{System.unique_integer([:positive])}",
        display_name: "Recall Team",
        domain: :operator,
        kind: :static
      })

    {:ok, _membership} = AuthZ.add_principal_to_group(member.uid, group.id)

    body = """
    Hormuz strait crude oil research overview.

    {% audience scope="group:#{group.name}" %}
    Team conclusion: crude oil futures exposure should be reduced.
    {% /audience %}
    """

    {:ok, object} =
      Objects.create_object(
        %{slug: "concepts/hormuz-strait", type: "concept", title: "Hormuz Strait", body: body},
        member.uid
      )

    {:ok, %{claim: world_fact}} =
      Claims.write_fact(
        %{
          object_slug: object.slug,
          claim: "Crude oil transits the Hormuz strait daily",
          kind: "fact",
          holder: "world",
          audience_scope: "world",
          notability: "high",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "public data"
        },
        member.uid
      )

    {:ok, %{claim: team_fact}} =
      Claims.write_fact(
        %{
          object_slug: object.slug,
          claim: "The team reduced crude oil futures positions",
          kind: "event",
          holder: "people/#{member.uid}",
          audience_scope: "group:#{group.name}",
          notability: "medium",
          confidence: 0.8,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "team meeting"
        },
        member.uid
      )

    %{
      member: member,
      outsider: outsider,
      agent: agent,
      group: group,
      object: object,
      world_fact: world_fact,
      team_fact: team_fact
    }
  end

  test "knowledge boundary prefilters group-scoped hits", context do
    assert {:ok, member_result} =
             Recall.recall(context.member.uid, %{query: "crude oil futures"})

    member_claims = Enum.map(member_result.claims, & &1.id)
    assert context.world_fact.id in member_claims
    assert context.team_fact.id in member_claims

    member_scopes = Enum.map(member_result.chunks, & &1.audience_scope)
    assert "group:#{context.group.name}" in member_scopes

    assert {:ok, outsider_result} =
             Recall.recall(context.outsider.uid, %{query: "crude oil futures"})

    outsider_claims = Enum.map(outsider_result.claims, & &1.id)
    assert context.world_fact.id in outsider_claims
    refute context.team_fact.id in outsider_claims

    outsider_scopes = Enum.map(outsider_result.chunks, & &1.audience_scope)
    refute "group:#{context.group.name}" in outsider_scopes
  end

  test "authors always reach their own writes", context do
    {:ok, %{claim: private_fact}} =
      Claims.write_fact(
        %{
          object_slug: context.object.slug,
          claim: "A private note about crude oil hedging strategy",
          kind: "belief",
          holder: "people/#{context.member.uid}",
          audience_scope: "principal:#{context.member.uid}",
          notability: "medium",
          confidence: 0.7,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "dm"
        },
        context.outsider.uid
      )

    # The outsider wrote it about the member; both must reach it, a third
    # principal must not.
    assert {:ok, author_result} =
             Recall.recall(context.outsider.uid, %{query: "crude oil hedging"})

    assert private_fact.id in Enum.map(author_result.claims, & &1.id)

    assert {:ok, subject_result} =
             Recall.recall(context.member.uid, %{query: "crude oil hedging"})

    assert private_fact.id in Enum.map(subject_result.claims, & &1.id)

    %{principal: third} = human_fixture()
    assert {:ok, third_result} = Recall.recall(third.uid, %{query: "crude oil hedging"})
    refute private_fact.id in Enum.map(third_result.claims, & &1.id)
  end

  test "strict disclosure narrows to what every present member satisfies", context do
    strict = %{
      mode: :strict,
      asker_uid: context.member.uid,
      present_uids: [context.member.uid, context.outsider.uid]
    }

    assert {:ok, strict_result} =
             Recall.recall(context.member.uid, %{query: "crude oil futures"}, disclosure: strict)

    refute context.team_fact.id in Enum.map(strict_result.claims, & &1.id)
    assert context.world_fact.id in Enum.map(strict_result.claims, & &1.id)

    relaxed = %{
      mode: :relaxed,
      asker_uid: context.member.uid,
      present_uids: [context.member.uid, context.outsider.uid]
    }

    assert {:ok, relaxed_result} =
             Recall.recall(context.member.uid, %{query: "crude oil futures"}, disclosure: relaxed)

    assert context.team_fact.id in Enum.map(relaxed_result.claims, & &1.id)
  end

  test "agent owner reads the agent principal scope but not its groups", context do
    {:ok, _membership} =
      AuthZ.add_principal_to_group(context.agent.uid, context.group.id)

    {:ok, %{claim: agent_private}} =
      Claims.write_fact(
        %{
          object_slug: context.object.slug,
          claim: "Agent private crude oil watch note",
          kind: "belief",
          holder: "agents/#{context.agent.uid}",
          audience_scope: "principal:#{context.agent.uid}",
          notability: "low",
          confidence: 0.6,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "agent memory"
        },
        context.agent.uid
      )

    {:ok, %{claim: agent_group_fact}} =
      Claims.write_fact(
        %{
          object_slug: context.object.slug,
          claim: "Group crude oil knowledge through the agent",
          kind: "fact",
          holder: "agents/#{context.agent.uid}",
          audience_scope: "group:#{context.group.name}",
          notability: "medium",
          confidence: 0.8,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "group chat"
        },
        :system
      )

    # A second human owns nothing: reaches neither.
    %{principal: bystander} = human_fixture()
    assert {:ok, bystander_result} = Recall.recall(bystander.uid, %{query: "crude oil"})
    bystander_ids = Enum.map(bystander_result.claims, & &1.id)
    refute agent_private.id in bystander_ids
    refute agent_group_fact.id in bystander_ids

    # The owner is not a group member here? The member IS in the group, so
    # use a fresh owner-only human to prove the narrowed exemption.
    %{principal: pure_owner} = human_fixture()

    {:ok, _agent2} =
      Ankole.Principals.create_agent(%{
        uid: unique_uid("owned-agent"),
        display_name: "Owned",
        role: "Analyst",
        owner_principal_uid: pure_owner.uid
      })

    # Transfer: make pure_owner own the original agent too.
    {:ok, _updated} =
      Ankole.Principals.update_agent(context.agent.uid, %{
        owner_principal_uid: pure_owner.uid
      })

    assert {:ok, owner_result} = Recall.recall(pure_owner.uid, %{query: "crude oil"})
    owner_ids = Enum.map(owner_result.claims, & &1.id)

    # Owner reaches the agent's principal-scoped and holder-attributed rows,
    # but not the agent's group-shared knowledge.
    assert agent_private.id in owner_ids
    refute agent_group_fact.id in owner_ids
  end

  test "an entity that does not resolve is an explicit error, never a global query", context do
    assert {:error, {:entity_not_found, "no-such-entity"}} =
             Recall.recall(context.member.uid, %{query: "crude oil", entity: "no-such-entity"})
  end

  test "an ambiguous entity name returns candidates", context do
    {:ok, _other} =
      Objects.create_object(
        %{slug: "concepts/hormuz-shipping", type: "concept", title: "Hormuz Shipping"},
        context.member.uid
      )

    {:ok, _alias} = Ankole.Brain.Links.add_alias("concepts/hormuz-strait", "hormuz")
    {:ok, _alias} = Ankole.Brain.Links.add_alias("concepts/hormuz-shipping", "hormuz")

    assert {:error, {:ambiguous_entity, candidates}} =
             Recall.recall(context.member.uid, %{query: "crude oil", entity: "hormuz"})

    assert Enum.map(candidates, & &1.slug) == [
             "concepts/hormuz-shipping",
             "concepts/hormuz-strait"
           ]
  end
end
