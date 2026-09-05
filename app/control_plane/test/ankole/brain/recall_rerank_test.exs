defmodule Ankole.Brain.RecallRerankTest do
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.Brain.{Objects, Recall, SchemaPacks}

  test "recall sends the configured rerank options through the provider adapter" do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)
    assert {:ok, _} = SchemaPacks.install_packs([])
    %{principal: agent} = agent_fixture()
    parent = self()

    base_url =
      start_upstream_server(fn request ->
        send(parent, {:rerank_request, request})
        {:json, 200, %{"results" => [%{"index" => 0, "relevance_score" => 0.9}]}}
      end)

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: "brain-rerank-options",
               provider_kind: "jina",
               base_url: base_url,
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "test-key"}]}
             })

    assert {:ok, _} = AppConfigure.put_global_by_key("brain.maintainer_agent_uid", agent.uid)

    assert {:ok, _} =
             AppConfigure.put_global_by_key("brain.rerank_model", %{
               "provider_id" => "brain-rerank-options",
               "model" => "jina-reranker-v3",
               "provider_options" => %{"return_documents" => false}
             })

    assert {:ok, _} =
             Objects.create_object(
               %{
                 slug: "notes/rerank-report",
                 type: "note",
                 title: "Quasar report",
                 body: "Quasar observations belong in this report."
               },
               :system
             )

    assert {:ok, result} = Recall.recall(agent.uid, %{query: "Quasar"})
    assert Enum.any?(result.chunks, &(&1.object_slug == "notes/rerank-report"))
    assert_receive {:rerank_request, %{path: "rerank", body: body}}
    assert body["return_documents"] == false
    assert body["query"] == "Quasar"
    assert Enum.any?(body["documents"], &String.contains?(&1, "Quasar"))
    refute Map.has_key?(body, "provider_options")
  end
end
