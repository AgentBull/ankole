defmodule Ankole.Brain.RecallRerankTest do
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.Brain.Recall
  alias Ankole.Brain.SchemaPacks

  test "recall sends provider options and applies recency after rerank" do
    assert {:ok, _} = SchemaPacks.install_packs([])
    %{principal: agent} = agent_fixture()
    parent = self()

    base_url =
      start_upstream_server(fn request ->
        send(parent, {:rerank_request, request})

        results =
          request.body["documents"]
          |> Enum.with_index()
          |> Enum.map(fn {text, index} ->
            %{
              "index" => index,
              "relevance_score" => if(String.contains?(text, "archived"), do: 1.0, else: 0.9)
            }
          end)

        {:json, 200, %{"results" => results}}
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
             Ankole.Brain.create_object(
               %{
                 slug: "notes/rerank-report",
                 type: "note",
                 title: "Quasar report",
                 body: "Quasar observations belong in this report."
               },
               :system
             )

    assert {:ok, _} =
             Ankole.Brain.create_object(
               %{
                 slug: "notes/rerank-old-report",
                 type: "note",
                 title: "Quasar report",
                 body: "Quasar observations belong in this archived report.",
                 effective_date: Date.add(Date.utc_today(), -90)
               },
               :system
             )

    assert {:ok, result} = Recall.recall(agent.uid, %{query: "Quasar"})
    slugs = Enum.map(result.chunks, & &1.object_slug)
    assert "notes/rerank-report" in slugs
    assert "notes/rerank-old-report" in slugs

    assert Enum.find_index(slugs, &(&1 == "notes/rerank-report")) <
             Enum.find_index(slugs, &(&1 == "notes/rerank-old-report"))

    assert_receive {:rerank_request, %{path: "rerank", body: body}}
    assert body["return_documents"] == false
    assert body["query"] == "Quasar"
    assert Enum.any?(body["documents"], &String.contains?(&1, "Quasar"))
    refute Map.has_key?(body, "provider_options")
  end

  test "recall caps fused candidates to two chunks per page before reranking" do
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)
    assert {:ok, _} = SchemaPacks.install_packs([])
    %{principal: agent} = agent_fixture()
    parent = self()

    base_url =
      start_upstream_server(fn request ->
        send(parent, {:rerank_cap_request, request})

        results =
          request.body["documents"]
          |> Enum.with_index()
          |> Enum.map(fn {_text, index} ->
            %{"index" => index, "relevance_score" => 1.0 - index * 0.01}
          end)

        {:json, 200, %{"results" => results}}
      end)

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: "brain-rerank-cap",
               provider_kind: "jina",
               base_url: base_url,
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "test-key"}]}
             })

    assert {:ok, _} = AppConfigure.put_global_by_key("brain.maintainer_agent_uid", agent.uid)

    assert {:ok, _} =
             AppConfigure.put_global_by_key("brain.rerank_model", %{
               "provider_id" => "brain-rerank-cap",
               "model" => "jina-reranker-v3"
             })

    long_body =
      Enum.map_join(1..6, "\n\n", fn idx ->
        "Section #{idx}: Zirconium reactor telemetry anomaly #{String.duplicate("zirconium detail ", 180)}"
      end)

    assert {:ok, _} =
             Ankole.Brain.create_object(
               %{
                 slug: "notes/long-zirconium",
                 type: "note",
                 title: "Long Zirconium",
                 body: long_body
               },
               :system
             )

    assert {:ok, _} =
             Ankole.Brain.create_object(
               %{
                 slug: "companies/zirconium-labs",
                 type: "company",
                 title: "Zirconium Labs",
                 body: "Zirconium Labs manufactures control rods."
               },
               :system
             )

    assert {:ok, _result} = Recall.recall(agent.uid, %{query: "zirconium"})
    assert_receive {:rerank_cap_request, %{body: %{"documents" => docs}}}

    long_page_docs = Enum.count(docs, &String.contains?(&1, "reactor telemetry anomaly"))
    assert long_page_docs == 2
    assert Enum.any?(docs, &String.contains?(&1, "Zirconium Labs manufactures control rods."))
  end
end
