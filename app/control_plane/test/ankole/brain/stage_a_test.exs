defmodule Ankole.Brain.StageATest do
  use Ankole.DataCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1, chat_completion_body: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.Brain
  alias Ankole.Brain.Config
  alias Ankole.Brain.Dreaming.StageA
  alias Ankole.Brain.Jobs.EmbedPendingEpisodes
  alias Ankole.Brain.Schemas.Cursor
  alias Ankole.Brain.Schemas.Episode
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.Projection

  @base_time ~U[2026-07-01 10:00:00.000000Z]

  setup do
    # The AppConfigure cache is a process, so it outlives the sandbox transaction
    # that rolls its rows back. Without this reset the global dreaming and
    # embedding configuration leaks in both directions between this file and its
    # neighbors.
    allow_cache_database_access()
    Cache.clear_for_test()
    :ok = Brain.ensure_registered()
    :ok = AppConfigure.delete_global(Config.dreaming_definition())
    :ok = AppConfigure.delete_global(Config.embedding_definition())

    on_exit(fn ->
      AppConfigure.delete_global(Config.dreaming_definition())
      AppConfigure.delete_global(Config.embedding_definition())
      Cache.clear_for_test()
    end)

    :ok
  end

  test "disabled dreaming does not write unavailable cursor rows" do
    disable_dreaming!()
    channel = channel_fixture("brain:disabled")
    entry_fixture(channel, "msg-1", "durable note", @base_time)

    assert {:unavailable, "brain.dreaming disabled"} = Brain.enqueue_episode_summary_jobs(50)
    refute channel_cursor(channel.id)
  end

  test "an unavailable marker with a nil cursor does not block later advancement" do
    channel = channel_fixture("brain:nil-cursor")
    entry_fixture(channel, "msg-1", "old durable fact", DateTime.add(@base_time, -8, :hour))

    assert {:ok, %Cursor{cursor_entry_observed_at: nil}} =
             StageA.mark_channel_unavailable(channel.id, "model unavailable")

    assert :ok = Brain.skip_failed_summary_window(channel.id, :invalid_summary_output)

    cursor = channel_cursor!(channel.id)
    assert cursor.cursor_entry_observed_at
    assert cursor.cursor_source_entry_id == "msg-1"
  end

  test "old low-volume channels are not starved by the protected tail" do
    channel = channel_fixture("brain:low-volume")
    now = DateTime.utc_now(:microsecond)

    for index <- 1..10 do
      entry_fixture(
        channel,
        "msg-#{index}",
        "weekly durable fact #{index}",
        DateTime.add(now, -8 * 3600 + index, :second)
      )
    end

    assert :ok = Brain.skip_failed_summary_window(channel.id, :final_retry)
    assert channel_cursor!(channel.id).cursor_source_entry_id == "msg-10"
  end

  test "a first run does not reach past the configured cold start lookback" do
    enable_dreaming!(%{"episode_cold_start_lookback_days" => 5})
    channel = channel_fixture("brain:cold-start")
    skipped = attach_skipped_window!(channel.id)
    backlog_fixture(channel)

    assert :ok = Brain.skip_failed_summary_window(channel.id, :final_retry)

    assert_receive {^skipped, %{entries: 2}, %{first_source_entry_id: "recent-1"}}
    assert channel_cursor!(channel.id).cursor_source_entry_id == "recent-2"
    assert all_episode_snapshots() == []
  end

  test "a nil cold start lookback summarizes the whole retained history" do
    enable_dreaming!(%{"episode_cold_start_lookback_days" => nil})
    channel = channel_fixture("brain:cold-start-unbounded")
    skipped = attach_skipped_window!(channel.id)
    backlog_fixture(channel)

    assert :ok = Brain.skip_failed_summary_window(channel.id, :final_retry)

    assert_receive {^skipped, %{entries: 4}, %{first_source_entry_id: "old-1"}}
  end

  test "cold start seeding never moves a cursor that already exists" do
    enable_dreaming!(%{"episode_cold_start_lookback_days" => 5})
    channel = channel_fixture("brain:cold-start-resumed")
    skipped = attach_skipped_window!(channel.id)
    [old_1 | _entries] = backlog_fixture(channel)

    assert {:ok, _cursor} = StageA.advance_channel_cursor(channel.id, old_1)
    assert :ok = Brain.skip_failed_summary_window(channel.id, :final_retry)

    assert_receive {^skipped, %{entries: 3}, %{first_source_entry_id: "old-2"}}
  end

  test "enqueue skips all-young tails and makes an unusable model visible on eligible channels" do
    %{principal: model_agent} = agent_fixture()
    enable_dreaming!()
    young_channel = channel_fixture("brain:young-tail", model_agent.uid)
    old_channel = channel_fixture("brain:old-tail", model_agent.uid)
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

    reason = "no Agent that can see the channel has a resolvable light profile"
    assert {:ok, 1} = Brain.enqueue_episode_summary_jobs(50)
    refute channel_cursor(young_channel.id)

    assert :ok = Brain.summarize_channel(old_channel.id)

    assert %Cursor{unavailable_reason: ^reason, cursor_entry_observed_at: nil} =
             channel_cursor!(old_channel.id)
  end

  test "summarize_channel persists valid episodes without consuming the deferred tail" do
    %{principal: model_agent} = agent_fixture()
    test_pid = self()

    summary = %{
      "episodes" => [
        %{
          "topic" => "Retention decision",
          "question" => "What should the channel retain?",
          "summary" => "The channel agreed to retain the old durable fact.",
          "resolution" => "Retain the old durable fact.",
          "systems" => ["Brain"],
          "resolution_message" => "message_1",
          "messages" => ["message_1"]
        }
      ],
      "noise_messages" => [],
      "deferred_messages" => ["message_2"]
    }

    configure_brain_model!(model_agent, fn
      %{path: "v1/chat/completions", body: body} ->
        send(test_pid, {:stage_a_response_format, body["response_format"]})
        send(test_pid, {:stage_a_request, body})
        {:json, 200, chat_completion_body(body["model"], Ankole.JSON.encode!(summary))}

      request ->
        flunk("unexpected Brain upstream request: #{inspect(request)}")
    end)

    enable_dreaming!(%{"episode_tail_guard_rows" => 1})
    channel = channel_fixture("brain:summary-happy", model_agent.uid)
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

    assert :ok = Brain.summarize_channel(channel.id)

    assert_receive {:stage_a_response_format,
                    %{
                      "type" => "json_schema",
                      "json_schema" => %{
                        "name" => "brain_stage_a_episode_summary",
                        "strict" => true,
                        "schema" => schema
                      }
                    }}

    assert schema["required"] == [
             "episodes",
             "noise_messages",
             "deferred_messages"
           ]

    assert_receive {:stage_a_request, body}
    request_json = Ankole.JSON.encode!(body)
    assert request_json =~ "message_1"
    assert request_json =~ "message_2"
    refute request_json =~ "old-fact"
    refute request_json =~ "young-deferred"

    # Reasoning shares the output budget, and the request names the same deferrable tail that
    # validation enforces.
    assert body["max_tokens"] == 8_192
    assert body["reasoning"] == %{"effort" => "medium"}
    assert request_json =~ "Deferrable messages: message_2"

    assert [
             %Episode{
               topic: "Retention decision",
               summary: "The channel agreed to retain the old durable fact.",
               metadata: %{
                 "version" => 2,
                 "question" => "What should the channel retain?",
                 "resolution" => "Retain the old durable fact.",
                 "systems" => ["Brain"],
                 "resolution_source_entry_id" => "old-fact"
               },
               source_entry_ids: ["old-fact"],
               embedding_state: :pending
             }
           ] = all_episode_snapshots()

    assert %Cursor{cursor_source_entry_id: "old-fact", unavailable_reason: nil} =
             channel_cursor!(channel.id)
  end

  test "the summary window names the role and speaker of every message" do
    %{principal: model_agent} = agent_fixture()
    test_pid = self()

    summary = %{
      "episodes" => [],
      "noise_messages" => ["message_1", "message_2", "message_3"],
      "deferred_messages" => []
    }

    configure_brain_model!(model_agent, fn
      %{path: "v1/chat/completions", body: body} ->
        send(test_pid, {:stage_a_request, body})
        {:json, 200, chat_completion_body(body["model"], Ankole.JSON.encode!(summary))}

      request ->
        flunk("unexpected Brain upstream request: #{inspect(request)}")
    end)

    enable_dreaming!(%{"episode_tail_guard_rows" => 0})
    channel = channel_fixture("brain:speakers", model_agent.uid)
    now = DateTime.utc_now(:microsecond)

    entry_fixture(channel, "named", "the deck is wrong", DateTime.add(now, -8, :hour), %{
      "principal_uid" => "yuxin",
      "display_name" => "Yuxin"
    })

    # A provider that carries no sender name still identifies its sender, and an entry an own
    # Agent posted carries `agent_uid` alone.
    entry_fixture(channel, "unnamed", "which deck?", DateTime.add(now, -7, :hour), %{
      "id" => "Yuxin",
      "principal_uid" => "yuxin",
      "display_name" => nil
    })

    entry_fixture(channel, "agent-reply", "I stopped task 1172", DateTime.add(now, -6, :hour), %{
      "agent_uid" => "yuma-assistant"
    })

    assert :ok = Brain.summarize_channel(channel.id)

    assert_receive {:stage_a_request, body}
    request_json = Ankole.JSON.encode!(body)

    assert request_json =~ "[human] Yuxin: the deck is wrong"
    assert request_json =~ "[human] yuxin: which deck?"
    assert request_json =~ "[agent] yuma-assistant: I stopped task 1172"
    refute request_json =~ "unknown speaker"
  end

  test "embed_pending_episodes records synced and failed states" do
    %{principal: model_agent} = agent_fixture()
    test_pid = self()

    configure_brain_model!(model_agent, fn
      %{path: "v1/embeddings", body: %{"input" => input}} ->
        send(test_pid, {:episode_embedding_input, input})

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
        flunk("unexpected Brain upstream request: #{inspect(request)}")
    end)

    enable_dreaming!()
    channel = channel_fixture("brain:embedding")

    synced =
      episode_fixture(channel, "sync topic", "embedding succeeds", ["sync-source"], %{
        "version" => 2,
        "question" => "What is the embedding order?",
        "resolution" => "Use the fixed semantic order.",
        "systems" => ["Signal Gateway", "Memory"],
        "resolution_source_entry_id" => "sync-source"
      })

    failed = episode_fixture(channel, "fail embedding", "embedding fails", ["fail-source"])

    assert {:ok, 2} = Brain.embed_pending_episodes(10)

    assert_receive {:episode_embedding_input,
                    "sync topic\nWhat is the embedding order?\nembedding succeeds\nUse the fixed semantic order.\nSignal Gateway, Memory"}

    assert %Episode{
             embedding_state: :synced,
             embedding_dimensions: 2,
             embedding_model_agent_uid: model_uid,
             embedding_error: nil
           } =
             episode_snapshot!(synced.id)

    assert model_uid == model_agent.uid

    assert %Episode{embedding_state: :failed, embedding_error: error} =
             episode_snapshot!(failed.id)

    assert is_binary(error)
  end

  test "disabled episode embedding is unavailable without crashing its job" do
    assert {:unavailable, reason} = Brain.embed_pending_episodes(20)
    assert reason =~ "brain_embedding_disabled"
    assert :ok = EmbedPendingEpisodes.perform(%Oban.Job{args: %{"limit" => 20}})
  end

  test "summarize_channel rejects a resolution source outside the supplied window" do
    %{principal: model_agent} = agent_fixture()

    summary = %{
      "episodes" => [
        %{
          "topic" => "Invalid resolution source",
          "question" => nil,
          "summary" => "The summary points outside the supplied window.",
          "resolution" => "Use an unknown message.",
          "systems" => [],
          "resolution_message" => "message_2",
          "messages" => ["message_1"]
        }
      ],
      "noise_messages" => [],
      "deferred_messages" => []
    }

    configure_brain_model!(model_agent, fn
      %{path: "v1/chat/completions", body: body} ->
        {:json, 200, chat_completion_body(body["model"], Ankole.JSON.encode!(summary))}

      request ->
        flunk("unexpected Brain upstream request: #{inspect(request)}")
    end)

    enable_dreaming!(%{"episode_tail_guard_rows" => 0, "episode_tail_guard_minutes" => 0})
    channel = channel_fixture("brain:invalid-resolution-source", model_agent.uid)

    entry_fixture(
      channel,
      "known-message",
      "known durable fact",
      DateTime.add(DateTime.utc_now(:microsecond), -8, :hour)
    )

    assert {:error, :invalid_resolution_source_entry_id} = Brain.summarize_channel(channel.id)
    assert all_episode_snapshots() == []
    refute channel_cursor(channel.id)
  end

  defp disable_dreaming! do
    assert {:ok, config} = Config.dreaming()

    assert {:ok, _stored} =
             AppConfigure.put_global(
               Config.dreaming_definition(),
               Map.put(config, "enabled", false)
             )
  end

  defp enable_dreaming!(overrides \\ %{}) do
    assert {:ok, config} = Config.dreaming()

    value =
      config
      |> Map.put("enabled", true)
      |> Map.merge(overrides)

    assert {:ok, _stored} = AppConfigure.put_global(Config.dreaming_definition(), value)
  end

  defp channel_fixture(id, visible_agent_uid \\ nil) do
    channel =
      %Channel{}
      |> Channel.changeset(%{
        id: id,
        kind: :webhook_endpoint,
        reply_mode: :entry,
        name: id,
        metadata: %{},
        raw_payload: %{},
        first_seen_at: @base_time,
        last_seen_at: @base_time
      })
      |> Repo.insert!()

    if visible_agent_uid do
      assert {:ok, _event} =
               SignalsGateway.append_actor_event(%{
                 agent_uid: visible_agent_uid,
                 binding_name: "brain-stage-a-test",
                 session_id: id,
                 source_event_id: "#{id}:observed",
                 signal_channel_id: id,
                 source_entry_id: "#{id}:observed",
                 type: "brain.stage_a.test",
                 available_at: @base_time,
                 payload: %{}
               })
    end

    channel
  end

  defp entry_fixture(
         %Channel{} = channel,
         source_entry_id,
         text,
         provider_time,
         author \\ %{"principal_uid" => "alice", "display_name" => "Alice"}
       ) do
    %Entry{}
    |> Entry.changeset(%{
      signal_channel_id: channel.id,
      source_entry_id: source_entry_id,
      text: text,
      attachments: [],
      links: [],
      author: author,
      mentions: [],
      metadata: %{},
      raw_payload: %{},
      provider_time: provider_time,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: Projection.entry_document_id(channel.id, source_entry_id),
      content_hash: Projection.entry_content_hash([text, "Alice"]),
      first_seen_at: provider_time,
      last_seen_at: provider_time
    })
    |> Repo.insert!()
  end

  defp backlog_fixture(%Channel{} = channel) do
    now = DateTime.utc_now(:microsecond)

    [
      entry_fixture(channel, "old-1", "fact before the lookback", DateTime.add(now, -30, :day)),
      entry_fixture(channel, "old-2", "fact before the lookback", DateTime.add(now, -10, :day)),
      entry_fixture(
        channel,
        "recent-1",
        "fact inside the lookback",
        DateTime.add(now, -8, :hour)
      ),
      entry_fixture(channel, "recent-2", "fact inside the lookback", DateTime.add(now, -7, :hour))
    ]
  end

  # Reports the window Stage A consumed. The cursor alone cannot show the cold start boundary,
  # because a bounded and an unbounded window both end at the newest entry.
  defp attach_skipped_window!(signal_channel_id) do
    handler_id = "brain-stage-a-skipped-#{System.unique_integer([:positive])}"
    marker = make_ref()
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:ankole, :brain, :dreaming, :stage_a, :skipped],
        fn _event, measurements, metadata, _config ->
          if metadata.signal_channel_id == signal_channel_id do
            send(test_pid, {marker, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    marker
  end

  defp configure_brain_model!(agent, handler) do
    provider_id = "brain-provider-#{System.unique_integer([:positive])}"
    base_url = start_upstream_server(handler)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-brain-test"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "light", %{
               provider_id: provider_id,
               model: "openai/gpt-brain-light"
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "embedding", %{
               provider_id: provider_id,
               model: "openai/text-embedding-brain"
             })

    assert {:ok, _stored} =
             AppConfigure.put_global(Config.embedding_definition(), %{
               "enabled" => true,
               "model_agent_uid" => agent.uid,
               "dimensions" => 2
             })
  end

  defp episode_fixture(%Channel{} = channel, topic, summary, source_entry_ids, metadata \\ %{}) do
    %Episode{}
    |> Episode.changeset(%{
      signal_channel_id: channel.id,
      topic: topic,
      summary: summary,
      source_entry_ids: source_entry_ids,
      started_at: DateTime.add(@base_time, -4, :hour),
      ended_at: DateTime.add(@base_time, -3, :hour),
      embedding_state: :pending,
      metadata: metadata
    })
    |> Repo.insert!()
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
        :metadata,
        :source_entry_ids,
        :embedding_state,
        :embedding_dimensions,
        :embedding_model_agent_uid,
        :embedding_error
      ])
    )
  end

  defp channel_cursor(channel_id),
    do: Repo.get_by(Cursor, scope_kind: :channel, scope_key: channel_id)

  defp channel_cursor!(channel_id),
    do: Repo.get_by!(Cursor, scope_kind: :channel, scope_key: channel_id)
end
