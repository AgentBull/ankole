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

  test "synthesis keeps all visible evidence and shares only with common readers", ctx do
    first = source(ctx.agent.uid, ctx.alice.uid, "First")
    second = source(ctx.agent.uid, ctx.bob.uid, "Second")
    assert {:ok, result} = Synthesis.synthesize(ctx.agent.uid, "Acme renewal")
    assert first.id in result.source_node_ids
    assert second.id in result.source_node_ids
    assert {:ok, self_access} = Ankole.Brain.Access.for_querier(ctx.agent.uid)
    assert Ankole.Brain.Access.visible?(self_access, result.page_id)

    for uid <- [ctx.alice.uid, ctx.bob.uid] do
      assert {:ok, access} = Ankole.Brain.Access.for_querier(uid)
      refute Ankole.Brain.Access.visible?(access, result.page_id)
    end

    assert {:ok, page} = Objects.get_by_slug(result.page_id)
    assert page.meta["role"] == "synthesis"
    assert page.body == @analysis_body
    assert_receive {:synthesis_request, request}
    prompt = request["messages"] |> List.first() |> Map.fetch!("content")
    assert prompt =~ "First renewal evidence"
    assert prompt =~ "Second renewal evidence"
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

  defp source(agent_uid, reader_uid, label) do
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
        {:ok, node} = Ankole.Files.Nodes.fetch(page.id)

        {:ok, node} =
          Ankole.Files.Access.update_anchor_in_tx(node, :sharing, %{inherit_permissions: false})

        for uid <- [agent_uid, reader_uid],
            do:
              :ok =
                Ankole.Files.Access.put_role(
                  %{principal_uid: uid},
                  "drive:**:#{node.id}:**",
                  "view"
                )

        {:ok, node}
      end)

    page
  end
end
