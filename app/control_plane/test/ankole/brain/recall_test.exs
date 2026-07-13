defmodule Ankole.Brain.RecallTest do
  use Ankole.AIGatewayCase

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.Brain
  alias Ankole.Brain.Config
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Schemas.Episode
  alias Ankole.Brain.Scope
  alias Ankole.AppConfigure
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Ingress

  test "pg_search provides Jieba and every Brain BM25 index uses it" do
    assert %{rows: [[tokens]]} =
             Repo.query!(
               "SELECT pdb.tokenize_jieba(($1::text)::pdb.jieba)",
               ["小明硕士毕业于中国科学院计算所，专注自然语言处理。"]
             )

    assert "中国科学院" in tokens
    assert "自然语言" in tokens

    index_names = [
      "brain_entries_bm25_index",
      "brain_entry_blocks_bm25_index",
      "signal_gateway_entries_brain_bm25_index"
    ]

    assert %{rows: rows} =
             Repo.query!(
               """
               SELECT indexname, indexdef
               FROM pg_indexes
               WHERE schemaname = 'public' AND indexname = ANY($1)
               ORDER BY indexname
               """,
               [index_names]
             )

    assert Enum.map(rows, &hd/1) == Enum.sort(index_names)
    assert Enum.all?(rows, fn [_name, definition] -> definition =~ "::pdb.jieba" end)
  end

  test "all-layer Jieba search ranks scoped knowledge before original chat evidence" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    binding_fixture(agent.uid, "brain-recall", :record_only)

    assert {:ok, %{signal_entry: signal_entry}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-recall",
               group_entry(%{
                 source_event_id: "brain-recall-event",
                 source_entry_id: "brain-recall-message",
                 text: "国际化渠道的季度数据已经发布"
               }),
               now: base_time()
             )

    # Current-channel recall deliberately excludes the latest 80 mirrored rows
    # because they are already present in the live turn context. Keep the cited
    # source just outside that protected tail so this test exercises retrieval.
    for index <- 1..81 do
      assert {:ok, _result} =
               Ingress.emit_entry(
                 agent.uid,
                 "brain-recall",
                 group_entry(%{
                   source_event_id: "brain-recall-filler-event-#{index}",
                   source_entry_id: "brain-recall-filler-#{index}",
                   text: "无关填充消息 #{index}",
                   provider_time: DateTime.add(base_time(), index, :second)
                 }),
                 now: DateTime.add(base_time(), index, :second)
               )
    end

    {:ok, public_scope} = Scope.for_store(agent.uid, "public")
    {:ok, other_scope} = Scope.for_store(other_agent.uid, "public")
    {:ok, private_scope} = Scope.for_store(agent.uid, "dm:private-peer")

    public_entry =
      create_entry_with_block(
        public_scope,
        agent.uid,
        "国际化战略",
        "渠道国际化增长有连续三个季度证据",
        :agent
      )

    _private_entry =
      create_entry_with_block(
        private_scope,
        agent.uid,
        "私聊国际化秘密",
        "私聊国际化内容绝不能出现在公共会话",
        :agent
      )

    _other_owner_entry =
      create_entry_with_block(
        other_scope,
        other_agent.uid,
        "其他人的国际化",
        "另一个 principal 的国际化内容",
        :agent
      )

    {:ok, conversation_scope} =
      Scope.from_metadata(agent.uid, %{
        "brain" => %{
          "visibility" => "public",
          "channel_id" => signal_entry.signal_channel_id,
          "channel_kind" => "im_group"
        }
      })

    assert {:ok, result} =
             Brain.search(conversation_scope, %{
               "query" => "国际化",
               "layer" => "all",
               "channel_scope" => "current_channel"
             })

    assert result["history_notice"] =~ "untrusted historical content"
    assert [%{"layer" => "knowledge", "entry_id" => entry_id} | _rest] = result["results"]
    assert entry_id == public_entry.id

    assert Enum.any?(result["results"], fn hit ->
             hit["layer"] == "knowledge" and is_number(hit["bm25_entry_score"])
           end)

    assert Enum.any?(result["results"], fn hit ->
             hit["layer"] == "chat" and
               Enum.any?(hit["messages"], &(&1["document_id"] == signal_entry.document_id))
           end),
           inspect(result["degraded_reasons"])

    refute Enum.any?(result["results"], &(&1["name"] == "私聊国际化秘密"))
    refute Enum.any?(result["results"], &(&1["name"] == "其他人的国际化"))

    assert {:ok, browse} =
             Brain.browse(conversation_scope, %{"document_id" => signal_entry.document_id})

    assert browse["document_id"] == signal_entry.document_id
    assert Enum.any?(browse["entries"], &(&1["anchor"] == true))
  end

  test "entry and block BM25 routes stay separate and author filtering is structural" do
    %{principal: agent} = agent_fixture()
    {:ok, scope} = Scope.for_store(agent.uid, "public")

    entry_route =
      create_entry_with_block(
        scope,
        agent.uid,
        "航天目录专名",
        "正文没有目录检索词",
        :agent
      )

    block_route =
      create_entry_with_block(
        scope,
        agent.uid,
        "普通词条",
        "海狸星云只存在于正文块",
        :dreaming
      )

    assert {:ok, entry_result} =
             Brain.search(scope, %{
               "query" => "航天目录专名",
               "layer" => "knowledge",
               "author_kind" => "agent"
             })

    assert [%{"entry_id" => entry_id, "bm25_entry_score" => score} | _rest] =
             entry_result["results"]

    assert entry_id == entry_route.id
    assert is_number(score)

    assert {:ok, block_result} =
             Brain.search(scope, %{
               "query" => "海狸星云",
               "layer" => "knowledge",
               "author_kind" => "dreaming"
             })

    assert [
             %{
               "entry_id" => block_id,
               "matched_block_id" => matched_block_id,
               "bm25_block_score" => block_score
             }
           ] = block_result["results"]

    assert block_id == block_route.id
    assert is_binary(matched_block_id)
    assert is_number(block_score)

    assert {:ok, excluded} =
             Brain.search(scope, %{
               "query" => "海狸星云",
               "layer" => "knowledge",
               "author_kind" => "agent"
             })

    assert excluded["results"] == []
  end

  test "search response obeys the hard result token budget" do
    %{principal: agent} = agent_fixture()
    {:ok, scope} = Scope.for_store(agent.uid, "public")

    create_entry_with_block(
      scope,
      agent.uid,
      "预算裁剪词条",
      "预算裁剪命中 " <> String.duplicate("很长的策展内容 ", 4_000),
      :agent
    )

    assert {:ok, result} =
             Brain.search(scope, %{"query" => "预算裁剪", "layer" => "knowledge"})

    assert result["results"] != []

    assert result["results"]
           |> Ankole.JSON.encode!()
           |> Ankole.Kernel.estimate_o200k_base_tokens() <= 2_000
  end

  test "episode navigation disappears when any source message is withdrawn" do
    %{principal: agent} = agent_fixture()
    %{principal: model_agent} = agent_fixture()
    configure_recall_embedding!(model_agent)
    binding_fixture(agent.uid, "brain-episode-withdrawal", :record_only)

    assert {:ok, %{signal_entry: source}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-episode-withdrawal",
               group_entry(%{
                 source_event_id: "brain-episode-source-event",
                 source_entry_id: "brain-episode-source-message",
                 text: "Ground truth for a semantic episode"
               }),
               now: base_time()
             )

    episode =
      %Episode{}
      |> Episode.changeset(%{
        signal_channel_id: source.signal_channel_id,
        topic: "Semantic episode",
        summary: "AI navigation summary over the source",
        source_entry_ids: [source.source_entry_id],
        started_at: base_time(),
        ended_at: base_time(),
        embedding: "[1,0]",
        embedding_dimensions: 2,
        embedding_state: :synced,
        metadata: %{}
      })
      |> Repo.insert!()

    {:ok, scope} =
      Scope.from_metadata(agent.uid, %{
        "brain" => %{
          "visibility" => "public",
          "channel_id" => source.signal_channel_id,
          "channel_kind" => "im_group"
        }
      })

    assert {:ok, before_withdrawal} =
             Brain.search(scope, %{
               "query" => "semantic episode query",
               "layer" => "chat"
             })

    assert Enum.any?(before_withdrawal["results"], fn result ->
             result["episode_id"] == episode.id and
               Enum.any?(result["messages"], &(&1["document_id"] == source.document_id))
           end)

    assert {:ok, %{deleted_mirror_entries: 1}} =
             Ingress.emit_entry_removed(
               agent.uid,
               "brain-episode-withdrawal",
               lifecycle_entry(%{
                 source_event_id: "brain-episode-source-removed",
                 source_entry_id: source.source_entry_id
               }),
               now: DateTime.add(base_time(), 1, :second)
             )

    assert {:ok, after_withdrawal} =
             Brain.search(scope, %{
               "query" => "semantic episode query",
               "layer" => "chat"
             })

    refute Enum.any?(after_withdrawal["results"], &(&1["episode_id"] == episode.id))
  end

  defp create_entry_with_block(scope, actor_uid, name, body, author_kind) do
    assert {:ok, %{results: [%{entry_id: entry_id, entry_lock_version: 1}]}} =
             Knowledge.apply_operations(
               scope,
               %{operation: "create_entry", name: name, type: "topic", summary: ""},
               %{kind: author_kind, uid: actor_uid}
             )

    assert {:ok, _result} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 1,
                 body: body
               },
               %{kind: author_kind, uid: actor_uid}
             )

    Knowledge.open(scope, entry_id, block_limit: :all) |> elem(1) |> Map.fetch!(:entry)
  end

  defp configure_recall_embedding!(model_agent) do
    :ok = Brain.ensure_registered()
    :ok = AppConfigure.delete_global(Config.dreaming_definition())
    on_exit(fn -> AppConfigure.delete_global(Config.dreaming_definition()) end)

    base_url =
      start_upstream_server(fn
        %{path: "v1/embeddings"} ->
          {:json, 200,
           %{
             "object" => "list",
             "data" => [%{"object" => "embedding", "embedding" => [1.0, 0.0]}]
           }}

        request ->
          flunk("unexpected embedding request: #{inspect(request)}")
      end)

    provider_id = "brain-recall-embedding-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "#{base_url}/v1",
               connection_options: %{"api_key" => "sk-brain-recall-test"}
             })

    for profile <- ["light", "embedding"] do
      assert {:ok, _profile} =
               ModelProfiles.put_model_profile(model_agent.uid, profile, %{
                 provider_id: provider_id,
                 model: "openai/brain-recall-test"
               })
    end

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
end
