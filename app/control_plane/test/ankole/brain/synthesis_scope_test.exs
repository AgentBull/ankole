defmodule Ankole.Brain.SynthesisScopeTest do
  # `synthesize` writes a page whose body a model composed from recalled
  # evidence, so the audience of that page is the whole guarantee: an
  # untagged body reads as `world`, which every Principal reaches. The
  # provider upstream is faked; everything after it is the real write and
  # the real recall boundary.
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Synthesis

  @analysis_body "Acme plans to cut the renewal to one seat."

  setup do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)

    {:ok, _result} = SchemaPacks.install_packs([])

    base_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
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

    {:ok, _value} =
      AppConfigure.put_global_by_key("brain.dreaming_model", %{
        "provider_id" => "brain-synthesis",
        "model" => "fake-dreaming"
      })

    %{principal: owner} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})
    %{principal: alice} = human_fixture()
    %{principal: bob} = human_fixture()

    {:ok, _object} =
      Objects.create_object(
        %{slug: "companies/acme", type: "company", title: "Acme"},
        agent.uid
      )

    %{agent: agent, alice: alice, bob: bob}
  end

  test "a page deduced from one Principal's evidence stays that Principal's",
       %{agent: agent, alice: alice, bob: bob} do
    write_fact!(agent, "Acme asked to renew one seat instead of ten", "principal:" <> alice.uid)

    assert {:ok, page} = Synthesis.synthesize(agent.uid, "what is the renewal risk at Acme")
    assert page.audience_scope == "principal:" <> alice.uid

    assert page.slug in recalled_slugs(alice.uid, "renewal")
    refute page.slug in recalled_slugs(bob.uid, "renewal")

    # The stored body carries the tag, so every chunk of the page carries the
    # scope; the returned body stays the plain analysis for the caller.
    assert page.body == @analysis_body
    assert {:ok, stored} = Objects.get_by_slug(page.slug)
    assert stored.body =~ ~s({% audience scope="principal:#{alice.uid}" %})
  end

  test "evidence the page cannot carry leaves the deduction",
       %{agent: agent, alice: alice, bob: bob} do
    write_fact!(agent, "Acme asked to renew one seat instead of ten", "principal:" <> alice.uid)
    write_fact!(agent, "Acme renewal talks moved to next quarter", "principal:" <> alice.uid)
    write_fact!(agent, "Acme pays the renewal by bank transfer", "principal:" <> bob.uid)
    write_fact!(agent, "Acme is a customer since 2024", "world")

    assert {:ok, page} = Synthesis.synthesize(agent.uid, "what is the renewal risk at Acme")

    # Two audiences with no common narrower value: the one carrying the most
    # evidence takes the page and the other drops. Public evidence stays,
    # because it discloses nothing inside a narrower page.
    assert page.audience_scope == "principal:" <> alice.uid
    assert page.dropped_evidence == 1
  end

  test "a page deduced from public evidence stays public", %{agent: agent, bob: bob} do
    write_fact!(agent, "Acme published its renewal terms", "world")

    assert {:ok, page} = Synthesis.synthesize(agent.uid, "what is the renewal risk at Acme")
    assert page.audience_scope == "world"
    assert page.dropped_evidence == 0
    assert page.slug in recalled_slugs(bob.uid, "renewal")
  end

  defp write_fact!(agent, claim, audience_scope) do
    {:ok, %{claim: written}} =
      Claims.write_fact(
        %{
          object_slug: "companies/acme",
          claim: claim,
          kind: "fact",
          holder: "world",
          audience_scope: audience_scope,
          notability: "medium",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "test"
        },
        agent.uid
      )

    written
  end

  defp recalled_slugs(querier_uid, query) do
    {:ok, recall} = Recall.recall(querier_uid, %{query: query})
    Enum.map(recall.chunks, & &1.object_slug)
  end
end
