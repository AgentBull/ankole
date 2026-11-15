defmodule Ankole.Brain.SynthesisScopeTest do
  # `synthesize` writes a page whose body a model composed from recalled
  # evidence, so the audience of that page is the whole guarantee: an
  # untagged body reads as `world`, which every Principal reaches. The
  # provider upstream is faked; everything after it is the real write and
  # the real recall boundary.
  use Ankole.AIGatewayCase
  import Ankole.BrainFixtures

  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Synthesis

  @analysis_body "Acme plans to cut the renewal to one seat."

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])

    test_pid = self()

    base_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
        send(test_pid, {:synthesis_request, body})
        answer = Ankole.JSON.encode!(%{"title" => "Renewal risk", "body" => @analysis_body})
        {:json, 200, chat_completion_body(body["model"], answer)}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-synthesis",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    configure_brain_maintainer_profile!("heavy", "brain-synthesis", "fake-dreaming")

    %{principal: owner} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})
    %{principal: alice} = human_fixture()
    %{principal: bob} = human_fixture()

    {:ok, _object} =
      page_fixture_result(
        %{
          slug: "companies/acme",
          type: "company",
          title: "Acme",
          body: "Acme has zephyr lineage renewal evidence."
        },
        agent.uid
      )

    %{agent: agent, alice: alice, bob: bob}
  end

  test "private synthesis stays scoped to the requester and does not auto-share with raw source readers",
       ctx do
    shared_source =
      shared_evidence(ctx.agent.uid, [ctx.alice.uid, ctx.bob.uid], "Shared")

    disclosure = %{mode: :strict, asker_uid: ctx.alice.uid, present_uids: [ctx.alice.uid]}

    assert {:ok, result} =
             Synthesis.synthesize(ctx.agent.uid, "Acme renewal", disclosure: disclosure)

    assert shared_source.id in result.source_node_ids

    for uid <- [ctx.agent.uid, ctx.alice.uid] do
      assert {:ok, access} = Ankole.Brain.Access.for_querier(uid)
      assert Ankole.Brain.Access.visible?(access, result.page_id)
    end

    assert {:ok, bob_access} = Ankole.Brain.Access.for_querier(ctx.bob.uid)
    refute Ankole.Brain.Access.visible?(bob_access, result.page_id)

    # Explicit publication uses the report's own ACL, and revoking raw source
    # access afterward preserves the published report snapshot.
    alice_actor = actor_fixture(ctx.alice)

    assert {:ok, _} =
             Ankole.Pod.Pages.update_sharing(alice_actor, result.page_id, %{
               upserts: [%{principal_uid: ctx.bob.uid, role: "view", target_scope: "self"}]
             })

    assert {:ok, _} = Ankole.Pod.Pages.get(actor_fixture(ctx.bob), result.page_id)

    {:ok, :ok} =
      Repo.transact(fn ->
        shared_source.id
        |> Ankole.Pod.Access.page_grants()
        |> Enum.filter(&(&1.principal_uid == ctx.bob.uid))
        |> Ankole.Pod.Access.remove_grants()

        {:ok, :ok}
      end)

    Ankole.Pod.Access.broadcast_change()

    assert {:error, :forbidden} = Ankole.Pod.Pages.get(actor_fixture(ctx.bob), shared_source.id)
    assert {:ok, _} = Ankole.Pod.Pages.get(actor_fixture(ctx.bob), result.page_id)
  end

  test "conversation synthesis shares with the room, respects relaxed disclosure, and enforces edit access on explicit target spaces",
       ctx do
    private_source = source(ctx.agent.uid, ctx.alice.uid, "AliceOnly")
    Ankole.ConversationsFixtures.grant_chat(ctx.alice.uid, ctx.agent.uid)
    Ankole.ConversationsFixtures.grant_chat(ctx.bob.uid, ctx.agent.uid)

    conversation_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Ankole.ConversationsFixtures.create(ctx.alice.uid, %{
               conversation_id: conversation_id,
               message_id: Ecto.UUID.generate(),
               agent_uid: ctx.agent.uid,
               room_mode: :group,
               participant_uids: [ctx.bob.uid],
               text: "Summarize renewal risk."
             })

    relaxed = %{mode: :relaxed, asker_uid: ctx.alice.uid, present_uids: []}

    assert {:ok, conv_result} =
             Synthesis.synthesize(ctx.agent.uid, "Acme renewal",
               disclosure: relaxed,
               conversation_id: conversation_id
             )

    assert private_source.id in conv_result.source_node_ids
    assert {:ok, _} = Ankole.Pod.Pages.get(actor_fixture(ctx.alice), conv_result.page_id)
    assert {:ok, _} = Ankole.Pod.Pages.get(actor_fixture(ctx.bob), conv_result.page_id)

    %{principal: outsider} = human_fixture()

    assert {:error, :forbidden} =
             Ankole.Pod.Pages.get(actor_fixture(outsider), conv_result.page_id)

    # Explicit target space requires node_edit for the requester and Agent.
    bob_actor = actor_fixture(ctx.bob)
    {:ok, folder} = Ankole.Pod.Pages.create(bob_actor, %{title: "Team Space"})

    {:ok, _} =
      Ankole.Pod.Pages.update_sharing(bob_actor, folder.id, %{
        inherit_permissions: false,
        upserts: [
          %{principal_uid: ctx.alice.uid, role: "view", target_scope: "container"},
          %{principal_uid: ctx.agent.uid, role: "edit", target_scope: "container"}
        ]
      })

    assert {:error, :forbidden} =
             Synthesis.synthesize(ctx.agent.uid, "Acme renewal",
               disclosure: relaxed,
               source_node_id: folder.id
             )

    {:ok, _} =
      Ankole.Pod.Pages.update_sharing(bob_actor, folder.id, %{
        upserts: [%{principal_uid: ctx.alice.uid, role: "edit", target_scope: "container"}]
      })

    assert {:ok, folder_result} =
             Synthesis.synthesize(ctx.agent.uid, "Acme renewal",
               disclosure: relaxed,
               source_node_id: folder.id
             )

    assert {:ok, _} = Ankole.Pod.Pages.get(bob_actor, folder_result.page_id)
  end

  test "requester intersection applies before model evidence assembly", ctx do
    first = source(ctx.agent.uid, ctx.alice.uid, "First")
    second = source(ctx.agent.uid, ctx.bob.uid, "Second")
    disclosure = %{mode: :strict, asker_uid: ctx.alice.uid, present_uids: [ctx.alice.uid]}

    assert {:ok, result} =
             Synthesis.synthesize(ctx.agent.uid, "Acme renewal", disclosure: disclosure)

    assert first.id in result.source_node_ids
    refute second.id in result.source_node_ids
    assert_receive {:synthesis_request, request}
    prompt = request["messages"] |> List.first() |> Map.fetch!("content")
    assert prompt =~ "First renewal evidence"
    refute prompt =~ "Second renewal evidence"
  end

  test "synthesis sends temporal claim evidence as JSON and persists the analysis", ctx do
    evidence = source(ctx.agent.uid, ctx.alice.uid, "Temporal")
    valid_from = ~U[2026-01-01 00:00:00Z]

    assert {:ok, %{claim: claim}} =
             Ankole.Brain.write_fact(
               %{
                 subject_page_id: page_id("companies/acme"),
                 source_node_id: evidence.id,
                 claim: "Acme renewal starts on the first day of 2026",
                 kind: "fact",
                 holder: "world",
                 notability: "medium",
                 confidence: 0.75,
                 valid_from: valid_from,
                 provenance: "Synthesis regression"
               },
               ctx.agent.uid
             )

    assert {:ok, result} = Synthesis.synthesize(ctx.agent.uid, "Acme renewal")
    assert evidence.id in result.source_node_ids
    assert {:ok, page} = Objects.get_by_slug(result.page_id)
    assert page.meta["role"] == "synthesis"
    assert page.body == @analysis_body
    assert_receive {:synthesis_request, request}
    prompt = request["messages"] |> List.first() |> Map.fetch!("content")
    assert prompt =~ claim.id
    assert prompt =~ DateTime.to_iso8601(claim.valid_from)
  end

  defp source(agent_uid, reader_uid, label),
    do: shared_evidence(agent_uid, [reader_uid], label)

  defp shared_evidence(agent_uid, reader_uids, label) do
    {:ok, page} =
      page_fixture_result(
        %{
          slug: "notes/" <> String.downcase(label),
          title: label,
          body: "#{label} renewal evidence for Acme."
        },
        :system
      )

    {:ok, _} =
      Repo.transact(fn ->
        {:ok, node} = Ankole.Pod.Pages.Tree.fetch(page.id)

        {:ok, node} =
          Ankole.Pod.Access.update_anchor_in_tx(node, :sharing, %{inherit_permissions: false})

        for uid <- Enum.uniq([agent_uid | reader_uids]),
            do:
              :ok =
                Ankole.Pod.Access.put_role(
                  %{principal_uid: uid},
                  "drive:**:#{node.id}:**",
                  "view"
                )

        {:ok, node}
      end)

    page
  end
end
