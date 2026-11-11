defmodule Ankole.Brain.BrowserMyContextTest do
  use Ankole.DataCase, async: false
  import Ankole.BrainFixtures
  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.{Browser, SchemaPacks, Scope}

  setup do
    {:ok, _} = SchemaPacks.install_packs([])
    alice = human_fixture(%{display_name: "Alice Chen"}).principal
    bob = human_fixture(%{display_name: "Bob Lin"}).principal

    alice_pa =
      agent_fixture(%{type: :personal_assistant, owner_principal_uid: alice.uid}).principal

    bob_pa =
      agent_fixture(%{type: :personal_assistant, owner_principal_uid: bob.uid}).principal

    %{
      alice: alice,
      alice_actor: actor_fixture(alice),
      alice_pa: alice_pa,
      bob: bob,
      bob_actor: actor_fixture(bob),
      bob_pa: bob_pa
    }
  end

  test "graph exposes viewer_uid and assistant_uid for Focus-on-me lens", ctx do
    assert {:ok, graph} = Ankole.Ash.run_action(Browser, :graph, %{}, actor: ctx.alice_actor)

    assert graph.viewer_uid == ctx.alice.uid
    assert graph.assistant_uid == ctx.alice_pa.uid
  end

  test "my_context unions personal memories and workspace facts/commitments while isolating other users",
       ctx do
    # 1. Add a personal memory via :add_my_fact (ensures people/<alice> + private scope out-of-tx)
    assert {:ok, %{status: "inserted", claim: personal_claim}} =
             Ankole.Ash.run_action(
               Browser,
               :add_my_fact,
               %{
                 claim: "Alice prefers concise bullet-point weekly updates",
                 kind: "preference",
                 notability: "high"
               },
               actor: ctx.alice_actor
             )

    assert personal_claim.bucket == "personal"
    assert personal_claim.source_node_id == Scope.principal(ctx.alice.uid)
    assert is_nil(personal_claim.source_title)
    assert personal_claim.can_edit == true
    assert personal_claim.can_forget == true

    # 2. Bob also writes a personal memory in his own private scope
    assert {:ok, %{claim: bob_private}} =
             Ankole.Ash.run_action(
               Browser,
               :add_my_fact,
               %{
                 claim: "Bob's private salary target is confidential",
                 kind: "preference",
                 notability: "high"
               },
               actor: ctx.bob_actor
             )

    # 3. Write a shared workspace fact about Alice on a public Brain page
    {:ok, project} =
      page_fixture_result(
        %{slug: "projects/apollo", type: "project", title: "Project Apollo"},
        ctx.bob.uid
      )

    {:ok, alice_canonical_id} = Scope.canonical_page_id(ctx.alice.uid)

    {:ok, %{claim: workspace_fact}} =
      Ankole.Brain.write_fact(
        %{
          subject_page_id: alice_canonical_id,
          claim: "Alice owns the Project Apollo Q4 launch review",
          kind: "commitment",
          holder: "people/" <> ctx.alice.uid,
          source_node_id: project.id,
          notability: "medium",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "apollo kickoff"
        },
        ctx.bob.uid
      )

    # 3b. Write a private PA DM conversation memory whose subject is Project Apollo (not Alice)
    # and a workspace memory attributed to Alice's Personal Assistant.
    {:ok, pa_dm_detail} =
      Ankole.ConversationsFixtures.create(ctx.alice.uid, %{
        conversation_id: Ankole.Kernel.gen_uuid_v7(),
        message_id: Ankole.Kernel.gen_uuid_v7(),
        agent_uid: ctx.alice_pa.uid,
        text: "Keep track of my private Q4 launch checklist"
      })

    {:ok, pa_dm_source_id} = Scope.conversation(pa_dm_detail.conversation.id)

    {:ok, %{claim: pa_dm_memory}} =
      Ankole.Brain.write_fact(
        %{
          subject_page_id: project.id,
          claim: "Check private Q4 vendor pricing before Apollo kickoff",
          kind: "commitment",
          holder: "world",
          source_node_id: pa_dm_source_id,
          notability: "high",
          confidence: 0.95,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "pa private chat"
        },
        ctx.alice_pa.uid
      )

    {:ok, %{claim: assistant_holder_fact}} =
      Ankole.Brain.write_fact(
        %{
          subject_page_id: project.id,
          claim: "Alice PA compiles the Friday Apollo digest",
          kind: "commitment",
          holder: "agents/" <> ctx.alice_pa.uid,
          source_node_id: project.id,
          notability: "medium",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "pa workflow"
        },
        ctx.alice_pa.uid
      )

    # 4. Query Alice's :my_context
    assert {:ok, my_ctx} =
             Ankole.Ash.run_action(Browser, :my_context, %{}, actor: ctx.alice_actor)

    assert my_ctx.viewer_uid == ctx.alice.uid
    assert my_ctx.assistant_uid == ctx.alice_pa.uid
    assert my_ctx.canonical_page_id == alice_canonical_id

    returned_ids = MapSet.new(my_ctx.claims, & &1.id)
    assert MapSet.member?(returned_ids, personal_claim.id)
    assert MapSet.member?(returned_ids, workspace_fact.id)
    assert MapSet.member?(returned_ids, pa_dm_memory.id)
    assert MapSet.member?(returned_ids, assistant_holder_fact.id)
    refute MapSet.member?(returned_ids, bob_private.id)

    pa_dm_item = Enum.find(my_ctx.claims, &(&1.id == pa_dm_memory.id))
    assert pa_dm_item.bucket == "personal"
    assert is_nil(pa_dm_item.source_title)

    assert {:ok, bob_ctx} =
             Ankole.Ash.run_action(Browser, :my_context, %{}, actor: ctx.bob_actor)

    refute Enum.any?(bob_ctx.claims, &(&1.id == pa_dm_memory.id))

    ws_item = Enum.find(my_ctx.claims, &(&1.id == workspace_fact.id))
    assert ws_item.bucket == "workspace"
    assert ws_item.source_title == "Project Apollo"

    # 5. Node claims inspector returns active claims on Project Apollo without leaking Bob's private memory
    assert {:ok, %{claims: node_claims}} =
             Ankole.Ash.run_action(
               Browser,
               :node_claims,
               %{page_id: project.id},
               actor: ctx.alice_actor
             )

    assert Enum.any?(node_claims, &(&1.id == workspace_fact.id))
    refute Enum.any?(node_claims, &(&1.id == bob_private.id))

    # 6. Cross-user isolation on mutations: Alice cannot supersede or forget Bob's private memory
    assert {:error, error} =
             Ankole.Ash.run_action(
               Browser,
               :supersede_my_claim,
               %{
                 claim_id: bob_private.id,
                 claim: "Tampered"
               },
               actor: ctx.alice_actor
             )

    assert Exception.message(error) != ""

    assert {:error, _} =
             Ankole.Ash.run_action(
               Browser,
               :forget_my_claim,
               %{
                 claim_id: bob_private.id,
                 reason: "Attempted cross-user delete"
               },
               actor: ctx.alice_actor
             )

    # 7. Alice supersedes her own personal memory, then forgets the replacement
    assert {:ok, %{claim: updated_claim}} =
             Ankole.Ash.run_action(
               Browser,
               :supersede_my_claim,
               %{
                 claim_id: personal_claim.id,
                 claim: "Alice prefers concise Markdown tables for weekly updates"
               },
               actor: ctx.alice_actor
             )

    assert updated_claim.id != personal_claim.id
    assert updated_claim.claim == "Alice prefers concise Markdown tables for weekly updates"

    assert {:ok, %{forgotten_id: forgotten_id}} =
             Ankole.Ash.run_action(
               Browser,
               :forget_my_claim,
               %{
                 claim_id: updated_claim.id,
                 reason: "Outdated preference"
               },
               actor: ctx.alice_actor
             )

    assert forgotten_id == updated_claim.id

    assert {:ok, refreshed_ctx} =
             Ankole.Ash.run_action(Browser, :my_context, %{}, actor: ctx.alice_actor)

    refute Enum.any?(refreshed_ctx.claims, &(&1.id in [personal_claim.id, updated_claim.id]))
  end
end
