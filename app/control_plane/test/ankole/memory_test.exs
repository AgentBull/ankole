defmodule Ankole.MemoryTest do
  use Ankole.DataCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1, chat_completion_body: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Actors.ActorEvent
  alias Ankole.AppConfigure
  alias Ankole.Memory
  alias Ankole.Memory.ChannelCursor
  alias Ankole.Memory.Config
  alias Ankole.Memory.Episode
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.Projection

  @base_time ~U[2026-07-01 10:00:00.000000Z]

  setup do
    :ok = Memory.ensure_registered()
    :ok = AppConfigure.delete_global(Config.recall_definition())

    on_exit(fn ->
      AppConfigure.delete_global(Config.recall_definition())
    end)

    :ok
  end

  test "disabled recall does not write unavailable cursor rows" do
    channel = channel_fixture("memory:disabled")
    entry_fixture(channel, "msg-1", "durable note", @base_time)

    assert {:unavailable, "memory.recall disabled"} = Memory.enqueue_episode_summary_jobs(50)
    refute Repo.get(ChannelCursor, channel.id)
  end

  test "nil unavailable cursor does not block later cursor advancement" do
    channel = channel_fixture("memory:nil-cursor")
    entry_fixture(channel, "msg-1", "old durable fact", DateTime.add(@base_time, -8, :hour))

    assert {:ok, %ChannelCursor{cursor_entry_observed_at: nil}} =
             Memory.mark_channel_unavailable(channel.id, "model unavailable")

    assert :ok = Memory.skip_failed_summary_window(channel.id, :invalid_summary_output)

    cursor = Repo.get!(ChannelCursor, channel.id)
    assert cursor.cursor_entry_observed_at
    assert cursor.cursor_source_entry_id == "msg-1"
  end

  test "old low-volume channels are not starved by tail guard" do
    channel = channel_fixture("memory:low-volume")

    for index <- 1..10 do
      entry_fixture(
        channel,
        "msg-#{index}",
        "weekly durable fact #{index}",
        DateTime.add(@base_time, -8 * 3600 + index, :second)
      )
    end

    assert :ok = Memory.skip_failed_summary_window(channel.id, :final_retry)

    cursor = Repo.get!(ChannelCursor, channel.id)
    assert cursor.cursor_source_entry_id == "msg-10"
  end

  test "enqueue skips all-young protected tails but keeps old low-volume channels eligible" do
    assert {:ok, config} = Config.recall()

    assert {:ok, _stored} =
             AppConfigure.put_global(
               Config.recall_definition(),
               Map.merge(config, %{"enabled" => true, "model_agent_uid" => "missing-agent"})
             )

    young_channel = channel_fixture("memory:young-tail")
    old_channel = channel_fixture("memory:old-tail")
    now = DateTime.utc_now(:microsecond)

    for index <- 1..10 do
      entry_fixture(
        young_channel,
        "young-#{index}",
        "young protected fact #{index}",
        DateTime.add(now, -index, :minute)
      )

      entry_fixture(
        old_channel,
        "old-#{index}",
        "old eligible fact #{index}",
        DateTime.add(now, -7 * 3600 + index, :second)
      )
    end

    assert {:unavailable, "memory.recall.model_agent_uid 指向的 agent 无 light/embedding profile"} =
             Memory.enqueue_episode_summary_jobs(50)

    refute Repo.get(ChannelCursor, young_channel.id)

    assert %ChannelCursor{unavailable_reason: unavailable_reason, cursor_entry_observed_at: nil} =
             Repo.get(ChannelCursor, old_channel.id)

    assert unavailable_reason ==
             "memory.recall.model_agent_uid 指向的 agent 无 light/embedding profile"
  end

  test "summarize_channel persists valid episodes and leaves deferred tail entries unadvanced" do
    %{principal: model_agent} = agent_fixture()

    summary = %{
      "episodes" => [
        %{
          "topic" => "Retention decision",
          "summary" => "The channel agreed to retain the old durable fact.",
          "source_entry_ids" => ["old-fact"]
        }
      ],
      "noise_source_entry_ids" => [],
      "deferred_source_entry_ids" => ["young-deferred"]
    }

    configure_memory_model!(model_agent, fn
      %{path: "v1/chat/completions", body: body} ->
        {:json, 200, chat_completion_body(body["model"], Ankole.JSON.encode!(summary))}

      request ->
        flunk("unexpected memory upstream request: #{inspect(request)}")
    end)

    enable_recall!(model_agent.uid, %{"episode_tail_guard_rows" => 1})

    channel = channel_fixture("memory:summary-happy")
    now = DateTime.utc_now(:microsecond)

    entry_fixture(channel, "old-fact", "old durable fact", DateTime.add(now, -8, :hour))

    entry_fixture(
      channel,
      "young-deferred",
      "young unfinished tail",
      DateTime.add(now, -10, :minute)
    )

    entry_fixture(
      channel,
      "young-protected",
      "young protected tail",
      DateTime.add(now, -5, :minute)
    )

    assert :ok = Memory.summarize_channel(channel.id)

    assert [
             %Episode{
               topic: "Retention decision",
               summary: "The channel agreed to retain the old durable fact.",
               source_entry_ids: ["old-fact"],
               embedding_state: "pending"
             }
           ] = all_episode_snapshots()

    assert %ChannelCursor{
             cursor_source_entry_id: "old-fact",
             unavailable_reason: nil
           } = Repo.get!(ChannelCursor, channel.id)
  end

  test "embed_pending_episodes records synced and failed embedding states" do
    %{principal: model_agent} = agent_fixture()

    configure_memory_model!(model_agent, fn
      %{path: "v1/embeddings", body: %{"input" => input}} ->
        if String.contains?(input, "fail embedding") do
          {:json, 500, %{"error" => %{"message" => "embedding failed"}}}
        else
          {:json, 200,
           %{
             "object" => "list",
             "data" => [%{"object" => "embedding", "embedding" => [0.9, 0.1]}],
             "usage" => %{"total_tokens" => 2}
           }}
        end

      request ->
        flunk("unexpected memory upstream request: #{inspect(request)}")
    end)

    enable_recall!(model_agent.uid)
    channel = channel_fixture("memory:embedding")

    synced = episode_fixture(channel, "sync topic", "embedding succeeds", ["sync-source"])
    failed = episode_fixture(channel, "fail embedding", "embedding fails", ["fail-source"])

    assert {:ok, 2} = Memory.embed_pending_episodes(10)

    assert %Episode{embedding_state: "synced", embedding_dimensions: 2, embedding_error: nil} =
             episode_snapshot!(synced.id)

    assert %Episode{embedding_state: "failed", embedding_error: error} =
             episode_snapshot!(failed.id)

    assert is_binary(error)
  end

  test "note limit rejects the 41st current-channel note" do
    %{principal: agent} = agent_fixture()
    channel = channel_fixture("memory:notes")

    for index <- 1..40 do
      assert {:ok, _note} = Memory.save_note(agent.uid, channel.id, "fact #{index}")
    end

    assert {:error, :memory_note_limit_reached} =
             Memory.save_note(agent.uid, channel.id, "one too many")
  end

  test "note CRUD stays scoped to the current channel" do
    %{principal: agent} = agent_fixture()
    channel = channel_fixture("memory:notes-crud")

    assert {:ok, note} = Memory.save_note(agent.uid, channel.id, "first fact")

    assert [%{"id" => note_id, "content" => "first fact"}] =
             Memory.list_notes(agent.uid, channel.id)

    assert note_id == note.id

    assert {:ok, _note} = Memory.update_note(agent.uid, channel.id, note.id, "updated fact")
    assert [%{"content" => "updated fact"}] = Memory.notes_for_context(agent.uid, channel.id)

    assert {:ok, _note} = Memory.forget_note(agent.uid, channel.id, note.id)
    assert [] = Memory.list_notes(agent.uid, channel.id)
  end

  test "search normalizes parser-hostile BM25 query and returns original message window" do
    %{principal: agent} = agent_fixture()
    target = channel_fixture("memory:search-target")
    current = channel_fixture("memory:search-current")

    old = DateTime.add(@base_time, -4, :hour)
    entry_fixture(target, "before", "setup context", DateTime.add(old, -2, :second))
    entry_fixture(target, "hit", "refund v2 plan approved", old)
    entry_fixture(target, "after", "follow up context", DateTime.add(old, 2, :second))
    entry_fixture(target, "outside", "refund v2 later", DateTime.add(@base_time, 4, :hour))
    entry_fixture(current, "current-hot", "refund v2 current hot", old)

    observed_event_fixture(agent.uid, target, "observed-target", old)
    current_event = observed_event_fixture(agent.uid, current, "current-event", @base_time)

    assert {:ok, result} =
             Memory.search(%{
               "query" => ~s/refund:("v2"),/,
               "scope" => "all_channels",
               "from" => DateTime.add(old, -60, :second) |> DateTime.to_iso8601(),
               "to" => DateTime.add(old, 60, :second) |> DateTime.to_iso8601(),
               "turn_ref" => turn_ref(agent.uid, current_event),
               "actor_event" => %{
                 "actor_event_id" => current_event.id,
                 "signal_channel_id" => current.id
               }
             })

    assert result["history_notice"] =~ "untrusted historical data"
    assert result["degraded_reasons"] == ["memory.recall disabled"]
    assert [%{"source_entry_id" => "hit", "messages" => messages}] = result["results"]
    assert Enum.map(messages, & &1["source_entry_id"]) == ["before", "hit", "after"]
    assert Enum.find(messages, &(&1["anchor"] == true))["text"] == "refund v2 plan approved"
  end

  test "current-channel search excludes hot context by recency and latest observed entries" do
    %{principal: agent} = agent_fixture()
    channel = channel_fixture("memory:hot-context")

    entry_fixture(
      channel,
      "old-hit",
      "quartile zoning durable decision",
      DateTime.add(@base_time, -4, :hour)
    )

    for index <- 1..79 do
      entry_fixture(
        channel,
        "filler-#{index}",
        "non matching filler #{index}",
        DateTime.add(@base_time, -119 * 60 + index, :second)
      )
    end

    entry_fixture(
      channel,
      "recent-hit",
      "quartile zoning hot context",
      DateTime.add(@base_time, -10, :minute)
    )

    current_event = observed_event_fixture(agent.uid, channel, "current-hot-context", @base_time)

    assert {:ok, result} =
             Memory.search(%{
               "query" => "quartile zoning",
               "scope" => "current_channel",
               "turn_ref" => turn_ref(agent.uid, current_event),
               "actor_event" => %{
                 "actor_event_id" => current_event.id,
                 "signal_channel_id" => channel.id
               }
             })

    assert Enum.map(result["results"], & &1["source_entry_id"]) == ["old-hit"]
  end

  test "search fuses BM25 and vector routes while skipping mismatched embedding dimensions" do
    %{principal: model_agent} = agent_fixture()
    target = channel_fixture("memory:fusion-target")
    current = channel_fixture("memory:fusion-current")
    old = DateTime.add(@base_time, -4, :hour)

    configure_memory_model!(model_agent, fn
      %{path: "v1/embeddings"} ->
        {:json, 200,
         %{
           "object" => "list",
           "data" => [%{"object" => "embedding", "embedding" => [1.0, 0.0]}],
           "usage" => %{"total_tokens" => 2}
         }}

      request ->
        flunk("unexpected memory upstream request: #{inspect(request)}")
    end)

    enable_recall!(model_agent.uid)

    entry_fixture(target, "bm25-hit", "bm25only launch decision", old)

    entry_fixture(
      target,
      "vector-before-2",
      "vector earlier context",
      DateTime.add(old, 10, :second)
    )

    entry_fixture(
      target,
      "vector-before",
      "vector before context",
      DateTime.add(old, 20, :second)
    )

    entry_fixture(target, "vector-anchor", "vector anchor source", DateTime.add(old, 30, :second))
    entry_fixture(target, "vector-after", "vector after context", DateTime.add(old, 40, :second))

    entry_fixture(
      target,
      "vector-after-2",
      "vector later context",
      DateTime.add(old, 50, :second)
    )

    entry_fixture(
      target,
      "mismatch-anchor",
      "mismatch vector source",
      DateTime.add(old, 60, :second)
    )

    synced_episode =
      episode_fixture(target, "Vector route", "Vector summary", ["vector-anchor"])
      |> sync_episode_embedding!("[1.0,0.0]", 2)

    mismatched_episode =
      episode_fixture(target, "Mismatched route", "Mismatched summary", ["mismatch-anchor"])
      |> sync_episode_embedding!("[1.0,0.0,0.0]", 3)

    observed_event_fixture(model_agent.uid, target, "observed-fusion-target", old)
    current_event = observed_event_fixture(model_agent.uid, current, "current-fusion", @base_time)

    assert {:ok, result} =
             Memory.search(%{
               "query" => "bm25only",
               "scope" => "all_channels",
               "turn_ref" => turn_ref(model_agent.uid, current_event),
               "actor_event" => %{
                 "actor_event_id" => current_event.id,
                 "signal_channel_id" => current.id
               }
             })

    routes = MapSet.new(result["results"], & &1["route"])
    assert MapSet.member?(routes, "bm25")
    assert MapSet.member?(routes, "vector")

    assert Enum.any?(result["results"], &(&1["source_entry_id"] == "bm25-hit"))

    vector_result = Enum.find(result["results"], &(&1["episode_id"] == synced_episode.id))
    assert vector_result["summary_notice"] =~ "AI generated index summary"

    assert Enum.map(vector_result["messages"], & &1["source_entry_id"]) == [
             "vector-before-2",
             "vector-before",
             "vector-anchor",
             "vector-after",
             "vector-after-2"
           ]

    refute Enum.any?(result["results"], &(&1["episode_id"] == mismatched_episode.id))
  end

  test "all-channel search excludes DM channels from non-DM current channels" do
    %{principal: agent} = agent_fixture()
    target = channel_fixture("memory:dm-safe-target")
    dm = channel_fixture("memory:dm-secret", %{kind: :im_dm})
    current = channel_fixture("memory:dm-current")
    old = DateTime.add(@base_time, -4, :hour)

    entry_fixture(target, "target-hit", "private budget alpha", old)
    entry_fixture(dm, "dm-hit", "private budget alpha", old)

    observed_event_fixture(agent.uid, target, "observed-target-dm-safe", old)
    observed_event_fixture(agent.uid, dm, "observed-dm-secret", old)
    current_event = observed_event_fixture(agent.uid, current, "current-dm-safe", @base_time)

    assert {:ok, result} =
             Memory.search(%{
               "query" => "private budget alpha",
               "scope" => "all_channels",
               "turn_ref" => turn_ref(agent.uid, current_event),
               "actor_event" => %{
                 "actor_event_id" => current_event.id,
                 "signal_channel_id" => current.id
               }
             })

    assert Enum.map(result["results"], & &1["channel_id"]) == [target.id]
  end

  test "browse paginates current-channel entries" do
    %{principal: agent} = agent_fixture()
    channel = channel_fixture("memory:browse")

    entry_fixture(channel, "oldest", "oldest entry", DateTime.add(@base_time, -3, :minute))
    entry_fixture(channel, "middle", "middle entry", DateTime.add(@base_time, -2, :minute))
    entry_fixture(channel, "newest", "newest entry", DateTime.add(@base_time, -1, :minute))

    current_event = observed_event_fixture(agent.uid, channel, "current-browse", @base_time)

    base_attrs = %{
      "limit" => 2,
      "turn_ref" => turn_ref(agent.uid, current_event),
      "actor_event" => %{
        "actor_event_id" => current_event.id,
        "signal_channel_id" => channel.id
      }
    }

    assert {:ok, first_page} = Memory.browse(base_attrs)
    assert first_page["history_notice"] =~ "untrusted historical data"
    assert Enum.map(first_page["entries"], & &1["source_entry_id"]) == ["newest", "middle"]
    assert is_binary(first_page["next_cursor"])

    assert {:ok, second_page} =
             base_attrs
             |> Map.put("cursor", first_page["next_cursor"])
             |> Memory.browse()

    assert Enum.map(second_page["entries"], & &1["source_entry_id"]) == ["oldest"]
    assert is_nil(second_page["next_cursor"])
  end

  defp channel_fixture(id, attrs \\ %{}) do
    now = Map.get(attrs, :now, @base_time)

    %Channel{}
    |> Channel.changeset(
      Map.merge(
        %{
          id: id,
          kind: Map.get(attrs, :kind, :im_group),
          reply_mode: :entry,
          name: id,
          metadata: %{},
          raw_payload: %{},
          first_seen_at: now,
          last_seen_at: now
        },
        Map.delete(attrs, :now)
      )
    )
    |> Repo.insert!()
  end

  defp entry_fixture(%Channel{} = channel, source_entry_id, text, provider_time) do
    %Entry{}
    |> Entry.changeset(%{
      signal_channel_id: channel.id,
      source_entry_id: source_entry_id,
      text: text,
      formatted_content: %{},
      attachments: [],
      links: [],
      author: %{"display_name" => "Alice"},
      mentions: [],
      metadata: %{},
      raw_payload: %{},
      provider_time: provider_time,
      fallback_visible_text: text,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: Projection.entry_document_id(channel.id, source_entry_id),
      search_text: text,
      metadata_text: "Alice",
      content_hash: Projection.entry_content_hash([text, "Alice"]),
      first_seen_at: provider_time,
      last_seen_at: provider_time
    })
    |> Repo.insert!()
  end

  defp observed_event_fixture(agent_uid, %Channel{} = channel, source_event_id, available_at) do
    %ActorEvent{}
    |> ActorEvent.changeset(%{
      agent_uid: agent_uid,
      binding_name: "memory-test",
      session_id: "memory-session",
      source_event_id: source_event_id,
      signal_channel_id: channel.id,
      source_entry_id: "#{source_event_id}-entry",
      type: "signal.entry.addressed",
      available_at: available_at,
      queue_sequence: System.unique_integer([:positive]),
      input_state: "open",
      payload: %{}
    })
    |> Repo.insert!()
  end

  defp turn_ref(agent_uid, %ActorEvent{} = event) do
    %{
      "actor" => %{"agent_uid" => agent_uid, "session_id" => event.session_id},
      "actor_event_id" => event.id
    }
  end

  defp configure_memory_model!(agent, handler) do
    provider_id = "memory-provider-#{System.unique_integer([:positive])}"
    base_url = start_upstream_server(handler)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "#{base_url}/v1",
               connection_options: %{"api_key" => "sk-memory-test"}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "light", %{
               provider_id: provider_id,
               model: "openai/gpt-memory-light"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "embedding", %{
               provider_id: provider_id,
               model: "openai/text-embedding-memory"
             })
  end

  defp enable_recall!(model_agent_uid, overrides \\ %{}) do
    assert {:ok, config} = Config.recall()

    assert {:ok, _stored} =
             AppConfigure.put_global(
               Config.recall_definition(),
               config
               |> Map.merge(%{"enabled" => true, "model_agent_uid" => model_agent_uid})
               |> Map.merge(overrides)
             )
  end

  defp episode_fixture(%Channel{} = channel, topic, summary, source_entry_ids) do
    %Episode{}
    |> Episode.changeset(%{
      signal_channel_id: channel.id,
      topic: topic,
      summary: summary,
      source_entry_ids: source_entry_ids,
      started_at: DateTime.add(@base_time, -4, :hour),
      ended_at: DateTime.add(@base_time, -3, :hour),
      embedding_state: "pending",
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp sync_episode_embedding!(%Episode{} = episode, vector_literal, dimensions) do
    Repo.query!(
      """
      UPDATE memory_episodes
      SET embedding = $2::text::vector,
          embedding_dimensions = $3,
          embedding_state = 'synced',
          embedding_error = NULL
      WHERE id = $1::text::uuid
      """,
      [episode.id, vector_literal, dimensions]
    )

    episode_snapshot!(episode.id)
  end

  defp all_episode_snapshots do
    Episode
    |> episode_snapshot_select()
    |> Repo.all()
  end

  defp episode_snapshot!(id) do
    Episode
    |> where([episode], episode.id == ^id)
    |> episode_snapshot_select()
    |> Repo.one!()
  end

  defp episode_snapshot_select(query) do
    select(
      query,
      [episode],
      struct(episode, [
        :id,
        :topic,
        :summary,
        :source_entry_ids,
        :embedding_state,
        :embedding_dimensions,
        :embedding_error
      ])
    )
  end
end
