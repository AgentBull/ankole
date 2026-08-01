defmodule Ankole.Brain.RecallTest do
  use Ankole.AIGatewayCase

  import Ecto.Query
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.Brain
  alias Ankole.Brain.Config
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Recall.Channels
  alias Ankole.Brain.Schemas.{Entry, EntryBlock, Episode}
  alias Ankole.Brain.Scope
  alias Ankole.AppConfigure
  alias Ankole.AuthZ.Group
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.BindingMembership
  alias Ankole.SignalsGateway.Channel
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

  test "an exact chat quote ranks before older weak knowledge without leaking private stores" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    binding_fixture(agent.uid, "brain-recall", :record_only)
    recent = DateTime.add(DateTime.utc_now(:microsecond), -1, :day)

    assert {:ok, %{signal_entry: signal_entry}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-recall",
               group_entry(%{
                 source_event_id: "brain-recall-event",
                 source_entry_id: "brain-recall-message",
                 text: "国际化渠道的季度数据已经发布",
                 provider_time: recent
               }),
               now: recent
             )

    {:ok, shared_scope} = Scope.for_store(agent.uid, "shared")
    {:ok, other_shared_scope} = Scope.for_store(other_agent.uid, "shared")
    {:ok, other_self_scope} = Scope.for_store(other_agent.uid, "self")
    {:ok, private_scope} = Scope.for_store(agent.uid, "dm:private-peer")

    shared_entry =
      create_entry_with_block(
        shared_scope,
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

    other_shared_entry =
      create_entry_with_block(
        other_shared_scope,
        other_agent.uid,
        "跨 Agent 国际化知识",
        "另一个 principal 写入的共享国际化内容",
        :agent
      )

    old = DateTime.add(DateTime.utc_now(:microsecond), -365, :day)

    for entry <- [shared_entry, other_shared_entry] do
      Entry
      |> where([stored], stored.id == ^entry.id)
      |> Repo.update_all(set: [updated_at: old])

      EntryBlock
      |> where([block], block.entry_id == ^entry.id)
      |> Repo.update_all(set: [updated_at: old])
    end

    _other_self_entry =
      create_entry_with_block(
        other_self_scope,
        other_agent.uid,
        "其他 Agent 自身秘密",
        "另一个 principal 的国际化自身知识",
        :agent
      )

    {:ok, conversation_scope} =
      Scope.from_metadata(agent.uid, %{
        "brain" => %{
          "visibility" => "shared",
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
    assert result["status"] == "degraded"
    assert result["result_completeness"] == "incomplete"
    assert result["degraded_reasons"] != []

    assert match?([%{"layer" => "chat"} | _rest], result["results"]),
           inspect(result["degraded_reasons"])

    result_entry_ids =
      result["results"]
      |> Enum.filter(&(&1["layer"] == "knowledge"))
      |> MapSet.new(& &1["entry_id"])

    assert MapSet.subset?(MapSet.new([shared_entry.id, other_shared_entry.id]), result_entry_ids)

    assert result["results"]
           |> Enum.filter(&(&1["entry_id"] in [shared_entry.id, other_shared_entry.id]))
           |> Enum.all?(&(&1["decay_multiplier"] == 0.5))

    assert result["results"]
           |> Enum.find(&(&1["layer"] == "chat"))
           |> Map.fetch!("decay_multiplier") > 0.5

    assert Enum.any?(result["results"], fn hit ->
             hit["layer"] == "knowledge" and is_number(hit["bm25_entry_score"])
           end)

    assert Enum.any?(result["results"], fn hit ->
             hit["layer"] == "chat" and
               Enum.any?(hit["messages"], &(&1["document_id"] == signal_entry.document_id))
           end),
           inspect(result["degraded_reasons"])

    refute Enum.any?(result["results"], &(&1["name"] == "私聊国际化秘密"))
    refute Enum.any?(result["results"], &(&1["name"] == "其他 Agent 自身秘密"))

    assert {:ok, browse} =
             Brain.browse(conversation_scope, %{"document_id" => signal_entry.document_id})

    assert browse["document_id"] == signal_entry.document_id
    assert Enum.any?(browse["entries"], &(&1["anchor"] == true))
  end

  test "a chat message without a thread expands to two adjacent messages on each side" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "brain-adjacent-recall", :record_only)
    channel_id = "lark:chat:adjacent-recall"

    entries =
      Enum.map(0..6, fn index ->
        text = if index == 3, do: "邻接召回唯一锚点", else: "ordinary message #{index}"

        assert {:ok, %{signal_entry: signal_entry}} =
                 Ingress.emit_entry(
                   agent.uid,
                   "brain-adjacent-recall",
                   group_entry(%{
                     source_event_id: "adjacent-event-#{index}",
                     signal_channel_id: channel_id,
                     source_entry_id: "adjacent-message-#{index}",
                     provider_thread_id: nil,
                     text: text,
                     provider_time: DateTime.add(base_time(), index, :second)
                   }),
                   now: DateTime.add(base_time(), index, :second)
                 )

        signal_entry
      end)

    {:ok, scope} =
      Scope.from_metadata(agent.uid, %{
        "brain" => %{
          "visibility" => "shared",
          "channel_id" => channel_id,
          "channel_kind" => "im_group"
        }
      })

    assert {:ok, result} =
             Brain.search(scope, %{
               "query" => "邻接召回唯一锚点",
               "layer" => "chat",
               "channel_scope" => "current_channel",
               "limit" => 1
             })

    assert [%{"kind" => "chat_message", "messages" => messages}] = result["results"]

    assert Enum.map(messages, & &1["document_id"]) ==
             entries |> Enum.slice(1, 5) |> Enum.map(& &1.document_id)

    assert Enum.find(messages, & &1["anchor"])["document_id"] == Enum.at(entries, 3).document_id
  end

  test "a reply hit expands its complete reply graph without unrelated neighbors" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "brain-thread-recall", :record_only)
    channel_id = "lark:chat:thread-recall"

    inputs = [
      {"thread-root", nil, "provider-thread", "thread root"},
      {"thread-reply", "thread-root", "provider-thread", "回复图唯一锚点"},
      {"unrelated", nil, nil, "unrelated adjacent message"},
      {"thread-leaf", "thread-reply", nil, "thread leaf"}
    ]

    entries =
      inputs
      |> Enum.with_index()
      |> Map.new(fn {{source_entry_id, reply_to_source_entry_id, provider_thread_id, text}, index} ->
        assert {:ok, %{signal_entry: signal_entry}} =
                 Ingress.emit_entry(
                   agent.uid,
                   "brain-thread-recall",
                   group_entry(%{
                     source_event_id: "thread-event-#{index}",
                     signal_channel_id: channel_id,
                     source_entry_id: source_entry_id,
                     provider_thread_id: provider_thread_id,
                     reply_to_source_entry_id: reply_to_source_entry_id,
                     text: text,
                     provider_time: DateTime.add(base_time(), index, :second)
                   }),
                   now: DateTime.add(base_time(), index, :second)
                 )

        {source_entry_id, signal_entry}
      end)

    {:ok, scope} =
      Scope.from_metadata(agent.uid, %{
        "brain" => %{
          "visibility" => "shared",
          "channel_id" => channel_id,
          "channel_kind" => "im_group"
        }
      })

    assert {:ok, result} =
             Brain.search(scope, %{
               "query" => "回复图唯一锚点",
               "layer" => "chat",
               "channel_scope" => "current_channel"
             })

    assert [%{"kind" => "chat_message", "messages" => messages}] = result["results"]

    assert Enum.map(messages, & &1["document_id"]) ==
             Enum.map(["thread-root", "thread-reply", "thread-leaf"], &entries[&1].document_id)

    refute Enum.any?(messages, &(&1["document_id"] == entries["unrelated"].document_id))
  end

  test "a long thread keeps its hit anchor within the per-candidate expansion cap" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "brain-long-thread-recall", :record_only)
    channel_id = "lark:chat:long-thread-recall"
    thread_id = "provider-long-thread"

    thread_entries =
      Enum.map(0..7, fn index ->
        source_entry_id = "long-thread-message-#{index}"

        text =
          if index == 7 do
            "长线程预算唯一锚点 " <> String.duplicate("anchor detail ", 180)
          else
            String.duplicate("oversized earlier context #{index} ", 180)
          end

        assert {:ok, %{signal_entry: signal_entry}} =
                 Ingress.emit_entry(
                   agent.uid,
                   "brain-long-thread-recall",
                   group_entry(%{
                     source_event_id: "long-thread-event-#{index}",
                     signal_channel_id: channel_id,
                     source_entry_id: source_entry_id,
                     provider_thread_id: thread_id,
                     reply_to_source_entry_id:
                       if(index == 0, do: nil, else: "long-thread-message-#{index - 1}"),
                     text: text,
                     provider_time: DateTime.add(base_time(), index, :second)
                   }),
                   now: DateTime.add(base_time(), index, :second)
                 )

        signal_entry
      end)

    assert {:ok, %{signal_entry: independent}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-long-thread-recall",
               group_entry(%{
                 source_event_id: "long-thread-independent-event",
                 signal_channel_id: channel_id,
                 source_entry_id: "long-thread-independent-message",
                 provider_thread_id: "provider-independent-thread",
                 text: "长线程预算唯一锚点 independent evidence",
                 provider_time: DateTime.add(base_time(), 20, :second)
               }),
               now: DateTime.add(base_time(), 20, :second)
             )

    {:ok, scope} =
      Scope.from_metadata(agent.uid, %{
        "brain" => %{
          "visibility" => "shared",
          "channel_id" => channel_id,
          "channel_kind" => "im_group"
        }
      })

    assert {:ok, result} =
             Brain.search(scope, %{
               "query" => "长线程预算唯一锚点",
               "layer" => "chat",
               "channel_scope" => "current_channel"
             })

    long_thread_result =
      Enum.find(result["results"], fn candidate ->
        Enum.any?(
          candidate["messages"],
          &(&1["document_id"] == List.last(thread_entries).document_id)
        )
      end)

    assert long_thread_result
    assert Enum.any?(long_thread_result["messages"], & &1["anchor"])
    assert length(long_thread_result["messages"]) < length(thread_entries)

    assert long_thread_result["messages"]
           |> Ankole.JSON.encode!()
           |> Ankole.Kernel.estimate_o200k_base_tokens() <= 400

    assert Enum.any?(result["results"], fn candidate ->
             Enum.any?(candidate["messages"], &(&1["document_id"] == independent.document_id))
           end)

    assert {:ok, browse} =
             Brain.browse(scope, %{"document_id" => List.last(thread_entries).document_id})

    assert length(browse["entries"]) == length(thread_entries)
  end

  test "chat candidates share each source message at most once without dropping a ranked result" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "brain-chat-dedup", :record_only)

    assert {:ok, %{signal_entry: source}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-chat-dedup",
               group_entry(%{
                 source_event_id: "brain-chat-dedup-event",
                 source_entry_id: "brain-chat-dedup-message",
                 provider_thread_id: nil,
                 text: "跨候选消息去重唯一锚点"
               }),
               now: base_time()
             )

    for topic <- ["First covering episode", "Second covering episode"] do
      %Episode{}
      |> Episode.changeset(%{
        signal_channel_id: source.signal_channel_id,
        topic: topic,
        summary: "AI navigation summary over the same source message",
        source_entry_ids: [source.source_entry_id],
        started_at: base_time(),
        ended_at: base_time(),
        metadata: %{
          "version" => 2,
          "question" => nil,
          "resolution" => nil,
          "systems" => [],
          "resolution_source_entry_id" => nil
        }
      })
      |> Repo.insert!()
    end

    {:ok, scope} =
      Scope.from_metadata(agent.uid, %{
        "brain" => %{
          "visibility" => "shared",
          "channel_id" => source.signal_channel_id,
          "channel_kind" => "im_group"
        }
      })

    assert {:ok, result} =
             Brain.search(scope, %{
               "query" => "跨候选消息去重唯一锚点",
               "layer" => "chat"
             })

    returned_document_ids =
      result["results"]
      |> Enum.flat_map(& &1["messages"])
      |> Enum.map(& &1["document_id"])

    assert returned_document_ids == [source.document_id]

    assert result["results"]
           |> MapSet.new(& &1["topic"])
           |> MapSet.equal?(MapSet.new(["First covering episode", "Second covering episode"]))

    assert [[%{"document_id" => document_id, "anchor" => true}], []] =
             Enum.map(result["results"], & &1["messages"])

    assert document_id == source.document_id
  end

  test "keyword and vector hits fuse into one stronger episode candidate" do
    %{principal: agent} = agent_fixture()
    configure_recall_embedding!(agent)
    binding_fixture(agent.uid, "brain-chat-route-fusion", :record_only)
    now = DateTime.utc_now(:microsecond)

    assert {:ok, %{signal_entry: covered}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-chat-route-fusion",
               group_entry(%{
                 source_event_id: "brain-chat-route-covered-event",
                 source_entry_id: "brain-chat-route-covered-message",
                 provider_thread_id: nil,
                 text: "ROUTE_FUSION_EXACT failure signature",
                 provider_time: now
               }),
               now: now
             )

    assert {:ok, %{signal_entry: uncovered}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-chat-route-fusion",
               group_entry(%{
                 source_event_id: "brain-chat-route-uncovered-event",
                 source_entry_id: "brain-chat-route-uncovered-message",
                 provider_thread_id: nil,
                 text: "ROUTE_FUSION_EXACT second signature",
                 provider_time: DateTime.add(now, 1, :second)
               }),
               now: DateTime.add(now, 1, :second)
             )

    episode =
      %Episode{}
      |> Episode.changeset(%{
        signal_channel_id: covered.signal_channel_id,
        topic: "ROUTE_FUSION_EXACT recovery",
        summary: "The failure signature has a known recovery path.",
        source_entry_ids: [covered.source_entry_id],
        started_at: now,
        ended_at: now,
        embedding: Ankole.Brain.Embedding.storage_vector([1.0, 0.0]),
        embedding_dimensions: 2,
        embedding_model_agent_uid: agent.uid,
        embedding_state: :synced,
        metadata: %{"version" => 2}
      })
      |> Repo.insert!()

    {:ok, scope} =
      Scope.from_metadata(agent.uid, %{
        "brain" => %{
          "visibility" => "shared",
          "channel_id" => covered.signal_channel_id,
          "channel_kind" => "im_group"
        }
      })

    assert {:ok, result} =
             Brain.search(scope, %{
               "query" => "ROUTE_FUSION_EXACT",
               "layer" => "chat",
               "channel_scope" => "current_channel"
             })

    assert [
             %{
               "kind" => "chat_episode",
               "episode_id" => episode_id,
               "routes" => routes,
               "messages" => [%{"document_id" => covered_document_id}]
             }
             | rest
           ] = result["results"]

    assert episode_id == episode.id
    assert covered_document_id == covered.document_id
    assert Enum.sort(routes) == ["chat keyword", "chat vector"]
    assert Enum.count(result["results"], &(&1["episode_id"] == episode.id)) == 1

    assert Enum.any?(rest, fn candidate ->
             candidate["kind"] == "chat_message" and
               Enum.any?(candidate["messages"], &(&1["document_id"] == uncovered.document_id))
           end)
  end

  test "ordinary conversations cannot recall another confidential group's chat history" do
    %{principal: agent} = agent_fixture()
    shared_channel = visible_group_channel!(agent.uid, "shared-recall", false)
    confidential_channel = visible_group_channel!(agent.uid, "confidential-recall", true)

    {:ok, shared_scope} =
      Scope.from_metadata(agent.uid, %{
        "brain" => %{
          "visibility" => "shared",
          "channel_id" => shared_channel.id,
          "channel_kind" => "im_group"
        }
      })

    assert {:ok, shared_channel_ids} = Channels.allowed(shared_scope, "all_channels")
    assert shared_channel.id in shared_channel_ids
    refute confidential_channel.id in shared_channel_ids

    {:ok, confidential_scope} =
      Scope.from_metadata(agent.uid, %{
        "brain" => %{
          "visibility" => "channel",
          "channel_id" => confidential_channel.id,
          "channel_kind" => "im_group"
        }
      })

    assert {:ok, confidential_channel_ids} =
             Channels.allowed(confidential_scope, "all_channels")

    assert shared_channel.id in confidential_channel_ids
    assert confidential_channel.id in confidential_channel_ids
  end

  test "entry and block BM25 routes stay separate and author filtering is structural" do
    %{principal: agent} = agent_fixture()
    {:ok, scope} = Scope.for_store(agent.uid, "shared")

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
    {:ok, scope} = Scope.for_store(agent.uid, "shared")

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
    configure_recall_embedding!(agent)
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
        embedding: Ankole.Brain.Embedding.storage_vector([1.0, 0.0]),
        embedding_dimensions: 2,
        embedding_model_agent_uid: agent.uid,
        embedding_state: :synced,
        metadata: %{}
      })
      |> Repo.insert!()

    {:ok, scope} =
      Scope.from_metadata(agent.uid, %{
        "brain" => %{
          "visibility" => "shared",
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
    :ok = AppConfigure.delete_global(Config.embedding_definition())
    on_exit(fn -> AppConfigure.delete_global(Config.embedding_definition()) end)

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
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-brain-recall-test"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(model_agent.uid, "embedding", %{
               provider_id: provider_id,
               model: "openai/brain-recall-test"
             })

    assert {:ok, _stored} =
             AppConfigure.put_global(Config.embedding_definition(), %{
               "enabled" => true,
               "model_agent_uid" => model_agent.uid,
               "dimensions" => 2
             })
  end

  defp visible_group_channel!(agent_uid, suffix, confidential?) do
    binding_name = "brain-#{suffix}"

    assert {:ok, _binding} =
             SignalsGateway.upsert_binding(%{
               agent_uid: agent_uid,
               name: binding_name,
               adapter: "lark",
               config_ref: "app-config://#{binding_name}",
               unaddressed_group_message_policy: :record_only,
               confidential_memory: confidential?
             })

    now = DateTime.utc_now(:microsecond)

    group =
      %Group{}
      |> Group.changeset(%{
        name: binding_name,
        display_name: binding_name,
        domain: :im_group,
        metadata:
          BindingMembership.project(
            %{},
            AdapterContext.new(
              agent_uid: agent_uid,
              binding_name: binding_name,
              adapter: "lark",
              user_name: "Lark"
            ),
            :joined,
            now
          )
      })
      |> Repo.insert!()

    %Channel{}
    |> Channel.changeset(%{
      id: "lark:chat:#{suffix}",
      kind: :im_group,
      reply_mode: :entry,
      name: suffix,
      principal_group_id: group.id,
      metadata: %{},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert!()
  end
end
