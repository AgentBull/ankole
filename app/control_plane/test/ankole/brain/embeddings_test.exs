defmodule Ankole.Brain.EmbeddingsTest do
  use Ankole.AIGatewayCase

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AppConfigure
  alias Ankole.Brain
  alias Ankole.Brain.Config
  alias Ankole.Brain.Embedding
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Scope
  alias Ankole.Repo

  setup do
    :ok = Brain.ensure_registered()
    :ok = AppConfigure.delete_global(Config.embedding_definition())
    on_exit(fn -> AppConfigure.delete_global(Config.embedding_definition()) end)
    :ok
  end

  test "the global embedding owner defines the installation vector space" do
    %{principal: owner} = agent_fixture()

    configure_embedding_profile!(owner, fn
      %{path: "v1/embeddings"} -> embedding_response([0.7, 0.3])
      request -> flunk("unexpected embedding request: #{inspect(request)}")
    end)

    assert {:ok, %{agent_uid: owner_uid, dimensions: 2}} = Embedding.resolve_model()
    assert owner_uid == owner.uid

    {:ok, scope} = Scope.for_store(owner.uid, "shared")
    block = pending_block!(scope, owner.uid, "Owner profile fallback", "stored vector content")

    assert {:ok, 1} = Brain.embed_pending_blocks(1)

    assert %EntryBlock{
             embedding_state: :synced,
             embedding_dimensions: 2,
             embedding_model_agent_uid: ^owner_uid
           } =
             Repo.get!(EntryBlock, block.id)

    assert {:ok,
            %{
              "status" => "ok",
              "result_completeness" => "complete",
              "degraded_reasons" => [],
              "results" => [%{"entry_id" => entry_id, "routes" => routes} | _rest]
            }} =
             Brain.search(scope, %{
               "query" => "semantically related words absent from the stored text",
               "layer" => "knowledge"
             })

    assert entry_id == block.entry_id
    assert "knowledge vector" in routes
  end

  test "the fixed vector storage envelope rejects more than 4096 dimensions" do
    %{principal: owner} = agent_fixture()

    assert {:error, {:invalid_integer, "dimensions", %{min: 1, max: 4_096}}} =
             AppConfigure.put_global(Config.embedding_definition(), %{
               "enabled" => true,
               "model_agent_uid" => owner.uid,
               "dimensions" => 4_097
             })
  end

  test "pending blocks become searchable vectors and body edits invalidate the old vector" do
    %{principal: owner} = agent_fixture()
    %{principal: model_agent} = agent_fixture()

    configure_embedding_model!(model_agent, fn
      %{path: "v1/embeddings", body: %{"input" => input}} ->
        if String.contains?(input, "FAIL_VECTOR") do
          {:json, 400, %{"error" => %{"message" => "embedding failed"}}}
        else
          embedding_response([0.8, 0.2])
        end

      request ->
        flunk("unexpected embedding request: #{inspect(request)}")
    end)

    {:ok, scope} = Scope.for_store(owner.uid, "shared")

    assert {:ok, %{results: [%{entry_id: entry_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{operation: "create_entry", name: "Embedding Topic", type: "topic"},
               %{kind: :agent, uid: owner.uid}
             )

    assert {:ok, %{results: [%{block_id: synced_id, entry_lock_version: entry_version}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 1,
                 body: "semantic block"
               },
               %{kind: :agent, uid: owner.uid}
             )

    assert {:ok, %{results: [%{block_id: failed_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: entry_version,
                 body: "FAIL_VECTOR"
               },
               %{kind: :agent, uid: owner.uid}
             )

    assert {:ok, 2} = Brain.embed_pending_blocks(10)

    assert %EntryBlock{
             embedding_state: :synced,
             embedding_dimensions: 2,
             embedding_model_agent_uid: model_uid,
             embedding_error: nil
           } = Repo.get!(EntryBlock, synced_id)

    assert model_uid == model_agent.uid

    assert %EntryBlock{embedding_state: :failed, embedding_error: error} =
             Repo.get!(EntryBlock, failed_id)

    assert is_binary(error)

    assert {:ok, %{"results" => [%{"entry_id" => ^entry_id, "routes" => routes} | _]}} =
             Brain.search(scope, %{
               "query" => "meaning-equivalent words absent from the stored text",
               "layer" => "knowledge"
             })

    assert "knowledge vector" in routes

    synced = Repo.get!(EntryBlock, synced_id)

    assert {:ok, _result} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "edit_block",
                 entry_id: entry_id,
                 block_id: synced.id,
                 expected_block_lock_version: synced.lock_version,
                 body: "changed semantic block"
               },
               %{kind: :agent, uid: owner.uid}
             )

    assert %EntryBlock{
             embedding_state: :pending,
             embedding: nil,
             embedding_dimensions: nil,
             embedding_model_agent_uid: nil,
             embedding_error: nil
           } = Repo.get!(EntryBlock, synced_id)
  end

  test "an embedding response cannot overwrite a block edited while the request is in flight" do
    %{principal: owner} = agent_fixture()
    %{principal: model_agent} = agent_fixture()
    test_pid = self()

    configure_embedding_model!(model_agent, fn
      %{path: "v1/embeddings", body: %{"input" => input}} ->
        send(test_pid, {:embedding_in_flight, self(), input})

        receive do
          {:finish_embedding, :success} ->
            embedding_response([0.6, 0.4])

          {:finish_embedding, :failure} ->
            {:json, 400, %{"error" => %{"message" => "stale failure"}}}
        end

      request ->
        flunk("unexpected embedding request: #{inspect(request)}")
    end)

    {:ok, scope} = Scope.for_store(owner.uid, "shared")

    for outcome <- [:success, :failure] do
      block = pending_block!(scope, owner.uid, "Fence #{outcome}", "old #{outcome} body")
      task = Task.async(fn -> Brain.embed_pending_blocks(1) end)

      assert_receive {:embedding_in_flight, upstream_pid, input}, 5_000
      assert input =~ "old #{outcome} body"

      assert {:ok, _result} =
               Knowledge.apply_operations(
                 scope,
                 %{
                   operation: "edit_block",
                   entry_id: block.entry_id,
                   block_id: block.id,
                   expected_block_lock_version: block.lock_version,
                   body: "new #{outcome} body"
                 },
                 %{kind: :agent, uid: owner.uid}
               )

      send(upstream_pid, {:finish_embedding, outcome})
      assert {:ok, 1} = Task.await(task, 10_000)
      expected_body = "new #{outcome} body"

      assert %EntryBlock{
               body: ^expected_body,
               lock_version: next_version,
               embedding_state: :pending,
               embedding: nil,
               embedding_dimensions: nil,
               embedding_model_agent_uid: nil,
               embedding_error: nil
             } = stored = Repo.get!(EntryBlock, block.id)

      assert next_version == block.lock_version + 1
      Repo.delete!(stored)
    end
  end

  test "malformed provider vectors become explicit failures without crashing jobs or search" do
    %{principal: owner} = agent_fixture()
    %{principal: model_agent} = agent_fixture()

    configure_embedding_model!(model_agent, fn
      %{path: "v1/embeddings", body: %{"input" => "non-numeric vector"}} ->
        embedding_response(["not-a-number", 0.0])

      %{path: "v1/embeddings", body: %{"input" => "zero vector"}} ->
        embedding_response([0.0, 0.0])

      %{path: "v1/embeddings"} ->
        embedding_response([])

      request ->
        flunk("unexpected embedding request: #{inspect(request)}")
    end)

    assert {:error, {:invalid_embedding_vector, {:invalid_component, 0}}} =
             Embedding.create(model_agent.uid, "non-numeric vector")

    assert {:error, {:invalid_embedding_vector, :zero_norm}} =
             Embedding.create(model_agent.uid, "zero vector")

    {:ok, scope} = Scope.for_store(owner.uid, "shared")
    block = pending_block!(scope, owner.uid, "Malformed Vector Topic", "malformed vector body")

    assert {:ok, 1} = Brain.embed_pending_blocks(1)

    assert %EntryBlock{embedding_state: :failed, embedding_error: error} =
             Repo.get!(EntryBlock, block.id)

    assert error =~ "invalid_embedding_vector"

    assert {:ok,
            %{
              "status" => "degraded",
              "result_completeness" => "incomplete",
              "results" => results,
              "degraded_reasons" => degraded
            }} =
             Brain.search(scope, %{
               "query" => "Malformed Vector Topic",
               "layer" => "knowledge"
             })

    assert Enum.any?(results, &(&1["entry_id"] == block.entry_id))
    assert Enum.any?(degraded, &String.contains?(&1, "invalid_embedding_vector"))
  end

  test "changing the global embedding owner replaces the old vector space" do
    %{principal: owner} = agent_fixture()
    %{principal: first_model} = agent_fixture()
    %{principal: next_model} = agent_fixture()

    configure_embedding_model!(first_model, fn
      %{path: "v1/embeddings"} -> embedding_response([1.0, 0.0])
      request -> flunk("unexpected first embedding request: #{inspect(request)}")
    end)

    {:ok, scope} = Scope.for_store(owner.uid, "shared")
    block = pending_block!(scope, owner.uid, "Vector space replacement", "stable source text")

    assert {:ok, 1} = Brain.embed_pending_blocks(1)

    assert %EntryBlock{
             embedding_state: :synced,
             embedding_dimensions: 2,
             embedding_model_agent_uid: first_uid
           } = Repo.get!(EntryBlock, block.id)

    assert first_uid == first_model.uid

    configure_embedding_model!(
      next_model,
      fn
        %{path: "v1/embeddings"} -> embedding_response([0.0, 1.0, 0.0])
        request -> flunk("unexpected replacement embedding request: #{inspect(request)}")
      end,
      3
    )

    assert {:ok, 1} = Brain.embed_pending_blocks(1)

    assert %EntryBlock{
             embedding_state: :synced,
             embedding_dimensions: 3,
             embedding_model_agent_uid: next_uid
           } = Repo.get!(EntryBlock, block.id)

    assert next_uid == next_model.uid
  end

  test "4096-dimensional vectors use indexed candidate search and full-vector scoring" do
    %{principal: owner} = agent_fixture()
    vector = [1.0 | List.duplicate(0.0, 4_095)]

    configure_embedding_profile!(
      owner,
      fn
        %{path: "v1/embeddings"} -> embedding_response(vector)
        request -> flunk("unexpected 4096-dimensional embedding request: #{inspect(request)}")
      end,
      4_096
    )

    {:ok, scope} = Scope.for_store(owner.uid, "shared")
    block = pending_block!(scope, owner.uid, "Wide vector", "indexed 4096-dimensional content")

    assert {:ok, 1} = Brain.embed_pending_blocks(1)

    assert %EntryBlock{
             embedding_state: :synced,
             embedding_dimensions: 4_096,
             embedding_model_agent_uid: owner_uid
           } = Repo.get!(EntryBlock, block.id)

    assert owner_uid == owner.uid

    assert {:ok, %{"results" => [%{"entry_id" => entry_id, "routes" => routes} | _]}} =
             Brain.search(scope, %{
               "query" => "different words that require vector retrieval",
               "layer" => "knowledge"
             })

    assert entry_id == block.entry_id
    assert "knowledge vector" in routes
  end

  defp configure_embedding_model!(model_agent, handler, dimensions \\ 2) do
    configure_embedding_profile!(model_agent, handler, dimensions)
  end

  defp configure_embedding_profile!(model_agent, handler, dimensions \\ 2) do
    base_url = start_upstream_server(handler)
    provider_id = "brain-block-embedding-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-brain-embedding-test"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(model_agent.uid, "embedding", %{
               provider_id: provider_id,
               model: "openai/embedding-test"
             })

    assert {:ok, _stored} =
             AppConfigure.put_global(Config.embedding_definition(), %{
               "enabled" => true,
               "model_agent_uid" => model_agent.uid,
               "dimensions" => dimensions
             })
  end

  defp pending_block!(scope, owner_uid, name, body) do
    assert {:ok, %{results: [%{entry_id: entry_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{operation: "create_entry", name: name, type: "topic"},
               %{kind: :agent, uid: owner_uid}
             )

    assert {:ok, %{results: [%{block_id: block_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 1,
                 body: body
               },
               %{kind: :agent, uid: owner_uid}
             )

    Repo.get!(EntryBlock, block_id)
  end

  defp embedding_response(vector) do
    {:json, 200,
     %{
       "object" => "list",
       "data" => [%{"object" => "embedding", "embedding" => vector}],
       "usage" => %{"total_tokens" => 2}
     }}
  end
end
