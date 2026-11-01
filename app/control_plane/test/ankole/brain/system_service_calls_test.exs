defmodule Ankole.Brain.SystemServiceCallsTest do
  use Ankole.AIGatewayCase

  alias Ankole.Brain.{Config, Embeddings, Recall, SchemaPacks}

  test "Agent recall uses the site embedding model and ankole_brain rerank override through real adapters" do
    {:ok, _} = SchemaPacks.install_packs([])
    agent = agent_fixture().principal

    {:ok, object} =
      Ankole.Brain.create_object(
        %{
          slug: "concepts/zirconium",
          type: "concept",
          title: "Zirconium",
          body: "Zirconium is used in nuclear reactor cladding."
        },
        :system
      )

    owner = self()

    url =
      start_upstream_server(fn request ->
        send(owner, {:brain_vector_request, request})

        case request.path do
          "embeddings" ->
            {:json, 200, %{"data" => [%{"index" => 0, "embedding" => [0.1, 0.2, 0.3]}]}}

          "rerank" ->
            {:json, 200, %{"results" => [%{"index" => 0, "relevance_score" => 0.99}]}}
        end
      end)

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-vectors",
        provider_kind: "openrouter",
        base_url: url,
        credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "test"}]},
        connection_options: %{"transport" => %{}}
      })

    {:ok, _} =
      Ankole.AppConfigure.put_global_by_key("brain.embedding_model", %{
        "provider_id" => "brain-vectors",
        "model" => "site-embedding",
        "dimensions" => 3
      })

    {:ok, _} =
      ModelProfiles.put_default_model_profile(:tenant, "rerank", %{
        provider_id: "brain-vectors",
        model: "pod-rerank"
      })

    {:ok, _} =
      ModelProfiles.put_system_model_profile("ankole_brain", "rerank", %{
        provider_id: "brain-vectors",
        model: "brain-rerank"
      })

    {:ok, _} =
      ModelProfiles.put_system_model_profile("system", "rerank", %{
        provider_id: "brain-vectors",
        model: "applet-rerank"
      })

    assert {:ok, result} = Recall.recall(agent.uid, %{query: "zirconium"})
    assert Enum.any?(result.chunks, &(&1.object_slug == object.slug))

    assert_receive {:brain_vector_request,
                    %{path: "embeddings", body: %{"model" => "site-embedding"}}}

    assert_receive {:brain_vector_request,
                    %{
                      path: "rerank",
                      body: %{"model" => "brain-rerank", "documents" => documents}
                    }}

    assert Enum.any?(documents, &String.contains?(&1, "Zirconium"))

    assert {:ok, _} =
             AIGateway.create_rerank("ankole_brain", %{
               "model" => "rerank.default",
               "query" => "zirconium",
               "documents" => documents
             })

    assert_receive {:brain_vector_request, %{path: "rerank", body: %{"model" => "brain-rerank"}}}

    assert {:ok, principal} = Ankole.Principals.system_principal("ankole_brain")
    assert {:ok, _} = Ankole.Ash.destroy(principal, :delete_in_tx)
    assert {:error, :system_principal_missing} = Embeddings.embed_texts(["zirconium"])
    assert {:error, :system_principal_missing} = Config.execution_subject_uid()
    refute_receive {:brain_vector_request, _}
  end
end
