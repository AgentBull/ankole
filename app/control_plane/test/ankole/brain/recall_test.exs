defmodule Ankole.Brain.RecallTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  import Ankole.BrainFixtures
  alias Ankole.Brain.{Recall, Claims, Access}
  alias Ankole.Files.Access, as: DriveAccess

  setup do
    %{principal: member} = human_fixture()
    %{principal: outsider} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: member.uid})

    {:ok, public} =
      page_fixture_result(
        %{
          slug: "concepts/hormuz",
          title: "Hormuz",
          body: "Crude oil public overview.",
          meta: %{"aliases" => ["Hormuz"]}
        },
        :system
      )

    {:ok, restricted} =
      page_fixture_result(
        %{
          slug: "concepts/hormuz/internal",
          title: "Internal",
          body: "Crude oil confidential allocation."
        },
        :system
      )

    {:ok, _} =
      Repo.transact(fn ->
        {:ok, node} = Ankole.Files.Nodes.fetch(restricted.id)

        {:ok, node} =
          DriveAccess.update_anchor_in_tx(node, :sharing, %{inherit_permissions: false})

        for uid <- [member.uid, agent.uid],
            do:
              :ok = DriveAccess.put_role(%{principal_uid: uid}, "drive:**:#{node.id}:**", "view")

        {:ok, node}
      end)

    world = fact(public.id, public.id, "Crude oil transits Hormuz daily")
    private = fact(public.id, restricted.id, "Crude oil futures allocation is confidential")

    %{
      member: member,
      outsider: outsider,
      agent: agent,
      public: public,
      restricted: restricted,
      world: world,
      private: private
    }
  end

  test "claims attached to one public entity follow their independent sources", ctx do
    assert {:ok, own} = Recall.recall(ctx.member.uid, %{query: "crude oil"})
    assert ctx.private.id in Enum.map(own.claims, & &1.id)
    assert {:ok, outside} = Recall.recall(ctx.outsider.uid, %{query: "crude oil"})
    assert ctx.world.id in Enum.map(outside.claims, & &1.id)
    refute ctx.private.id in Enum.map(outside.claims, & &1.id)
    refute ctx.restricted.id in Enum.map(outside.chunks, & &1.subject_page_id)
  end

  test "strict disclosure intersects Agent, requester and every present recipient", ctx do
    disclosure = %{
      mode: :strict,
      asker_uid: ctx.member.uid,
      present_uids: [ctx.member.uid, ctx.outsider.uid]
    }

    assert {:ok, result} =
             Recall.recall(ctx.agent.uid, %{query: "crude oil"}, disclosure: disclosure)

    assert ctx.world.id in Enum.map(result.claims, & &1.id)
    refute ctx.private.id in Enum.map(result.claims, & &1.id)

    assert {:ok, none} =
             Recall.recall(ctx.agent.uid, %{query: "crude oil"},
               disclosure: %{disclosure | asker_uid: nil, present_uids: []}
             )

    assert none.claims == []
    assert none.chunks == []
  end

  test "author attribution grants no independent read permission", ctx do
    {:ok, _} =
      Repo.transact(fn ->
        grants =
          DriveAccess.page_grants(ctx.restricted.id)
          |> Enum.filter(&(&1.principal_uid == ctx.member.uid))

        DriveAccess.remove_grants(grants)
        {:ok, :revoked}
      end)

    assert {:ok, access} = Access.for_querier(ctx.member.uid)
    refute Access.visible?(access, ctx.restricted.id)
    assert {:ok, result} = Recall.recall(ctx.member.uid, %{query: "crude oil"})
    refute ctx.private.id in Enum.map(result.claims, & &1.id)
  end

  test "aliases resolve cards while an unknown entity never falls back to global search", ctx do
    assert {:ok, result} = Recall.recall(ctx.member.uid, %{query: "Hormuz"})
    assert Enum.any?(result.entities, &(&1.id == ctx.public.id))

    assert {:error, {:entity_not_found, "missing"}} =
             Recall.recall(ctx.member.uid, %{query: "oil", entity: "missing"})
  end

  test "the complete response fits its budget without clipping evidence or provenance", ctx do
    for number <- 1..8 do
      assert {:ok, _} =
               Claims.write_fact(
                 %{
                   subject_page_id: ctx.public.id,
                   source_node_id: ctx.public.id,
                   claim: "Crude oil quotation condition #{number}",
                   kind: "fact",
                   holder: "world",
                   notability: "medium",
                   confidence: 0.9,
                   valid_from: DateTime.utc_now(:microsecond),
                   provenance:
                     String.duplicate("Quotation #{number}: source with \"quoted\" terms.\n", 80),
                   context: "Only applies to shipments of at least #{number * 100} units."
                 },
                 ctx.agent.uid
               )
    end

    assert {:ok, full} =
             Recall.recall(ctx.member.uid, %{query: "crude oil", budget_tokens: 12_000})

    assert response_tokens(full) > 4_000

    for budget <- [256, 700, 4_000] do
      assert {:ok, packed} =
               Recall.recall(ctx.member.uid, %{query: "crude oil", budget_tokens: budget})

      assert response_tokens(packed) <= budget
      assert length(packed.claims) < length(full.claims)

      for key <- [:claims, :entities, :chunks], entry <- packed[key] do
        assert entry in full[key]
      end
    end
  end

  defp response_tokens(result),
    do:
      result
      |> Ankole.JSON.plain()
      |> Ankole.JSON.encode!()
      |> Ankole.Brain.Chunker.estimate_tokens()

  defp fact(subject, source, text) do
    {:ok, %{claim: claim}} =
      Claims.write_fact(
        %{
          subject_page_id: subject,
          source_node_id: source,
          claim: text,
          kind: "fact",
          holder: "world",
          notability: "medium",
          confidence: 0.8,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "recall acceptance"
        },
        :system,
        embed: false
      )

    claim
  end
end
