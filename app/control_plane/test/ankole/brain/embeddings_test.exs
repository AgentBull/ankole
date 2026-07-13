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
    :ok = AppConfigure.delete_global(Config.dreaming_definition())
    on_exit(fn -> AppConfigure.delete_global(Config.dreaming_definition()) end)
    :ok
  end

  test "pending blocks become searchable vectors and body edits invalidate the old vector" do
    %{principal: owner} = agent_fixture()
    %{principal: model_agent} = agent_fixture()

    configure_embedding_model!(model_agent, fn
      %{path: "v1/embeddings", body: %{"input" => input}} ->
        if String.contains?(input, "FAIL_VECTOR") do
          {:json, 500, %{"error" => %{"message" => "embedding failed"}}}
        else
          embedding_response([0.8, 0.2])
        end

      request ->
        flunk("unexpected embedding request: #{inspect(request)}")
    end)

    {:ok, scope} = Scope.for_store(owner.uid, "public")

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
             embedding_error: nil
           } = Repo.get!(EntryBlock, synced_id)

    assert %EntryBlock{embedding_state: :failed, embedding_error: error} =
             Repo.get!(EntryBlock, failed_id)

    assert is_binary(error)

    assert {:ok, %{"results" => [%{"entry_id" => ^entry_id, "route" => "vector"} | _]}} =
             Brain.search(scope, %{
               "query" => "meaning-equivalent words absent from the stored text",
               "layer" => "knowledge"
             })

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
            {:json, 500, %{"error" => %{"message" => "stale failure"}}}
        end

      request ->
        flunk("unexpected embedding request: #{inspect(request)}")
    end)

    {:ok, scope} = Scope.for_store(owner.uid, "public")

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
        embedding_response(["not-a-number"])

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

    {:ok, scope} = Scope.for_store(owner.uid, "public")
    block = pending_block!(scope, owner.uid, "Malformed Vector Topic", "malformed vector body")

    assert {:ok, 1} = Brain.embed_pending_blocks(1)

    assert %EntryBlock{embedding_state: :failed, embedding_error: error} =
             Repo.get!(EntryBlock, block.id)

    assert error =~ "invalid_embedding_vector"

    assert {:ok, %{"results" => results, "degraded_reasons" => degraded}} =
             Brain.search(scope, %{
               "query" => "Malformed Vector Topic",
               "layer" => "knowledge"
             })

    assert Enum.any?(results, &(&1["entry_id"] == block.entry_id))
    assert Enum.any?(degraded, &String.contains?(&1, "invalid_embedding_vector"))
  end

  defp configure_embedding_model!(model_agent, handler) do
    base_url = start_upstream_server(handler)
    provider_id = "brain-block-embedding-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "#{base_url}/v1",
               connection_options: %{"api_key" => "sk-brain-embedding-test"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(model_agent.uid, "embedding", %{
               provider_id: provider_id,
               model: "openai/embedding-test"
             })

    assert {:ok, config} = Config.dreaming()

    assert {:ok, _stored} =
             AppConfigure.put_global(
               Config.dreaming_definition(),
               Map.merge(config, %{
                 "enabled" => true,
                 "model_agent_uid" => model_agent.uid
               })
             )
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
