defmodule Ankole.Brain.StageATest do
  use Ankole.DataCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1, chat_completion_body: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AppConfigure
  alias Ankole.Brain
  alias Ankole.Brain.Config
  alias Ankole.Brain.Dreaming.StageA
  alias Ankole.Brain.Schemas.Cursor
  alias Ankole.Brain.Schemas.Episode
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.Projection

  @base_time ~U[2026-07-01 10:00:00.000000Z]

  setup do
    :ok = Brain.ensure_registered()
    :ok = AppConfigure.delete_global(Config.dreaming_definition())

    on_exit(fn -> AppConfigure.delete_global(Config.dreaming_definition()) end)
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

    for index <- 1..10 do
      entry_fixture(
        channel,
        "msg-#{index}",
        "weekly durable fact #{index}",
        DateTime.add(@base_time, -8 * 3600 + index, :second)
      )
    end

    assert :ok = Brain.skip_failed_summary_window(channel.id, :final_retry)
    assert channel_cursor!(channel.id).cursor_source_entry_id == "msg-10"
  end

  test "enqueue skips all-young tails and makes an unusable model visible on eligible channels" do
    enable_dreaming!("missing-agent")
    young_channel = channel_fixture("brain:young-tail")
    old_channel = channel_fixture("brain:old-tail")
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

    reason = "brain.dreaming.model_agent_uid 指向的 agent 无 light/embedding profile"
    assert {:unavailable, ^reason} = Brain.enqueue_episode_summary_jobs(50)
    refute channel_cursor(young_channel.id)

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
          "summary" => "The channel agreed to retain the old durable fact.",
          "source_entry_ids" => ["old-fact"]
        }
      ],
      "noise_source_entry_ids" => [],
      "deferred_source_entry_ids" => ["young-deferred"]
    }

    configure_brain_model!(model_agent, fn
      %{path: "v1/chat/completions", body: body} ->
        send(test_pid, {:stage_a_response_format, body["response_format"]})
        {:json, 200, chat_completion_body(body["model"], Ankole.JSON.encode!(summary))}

      request ->
        flunk("unexpected Brain upstream request: #{inspect(request)}")
    end)

    enable_dreaming!(model_agent.uid, %{"episode_tail_guard_rows" => 1})
    channel = channel_fixture("brain:summary-happy")
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
             "noise_source_entry_ids",
             "deferred_source_entry_ids"
           ]

    assert [
             %Episode{
               topic: "Retention decision",
               summary: "The channel agreed to retain the old durable fact.",
               source_entry_ids: ["old-fact"],
               embedding_state: :pending
             }
           ] = all_episode_snapshots()

    assert %Cursor{cursor_source_entry_id: "old-fact", unavailable_reason: nil} =
             channel_cursor!(channel.id)
  end

  test "embed_pending_episodes records synced and failed states" do
    %{principal: model_agent} = agent_fixture()

    configure_brain_model!(model_agent, fn
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
        flunk("unexpected Brain upstream request: #{inspect(request)}")
    end)

    enable_dreaming!(model_agent.uid)
    channel = channel_fixture("brain:embedding")
    synced = episode_fixture(channel, "sync topic", "embedding succeeds", ["sync-source"])
    failed = episode_fixture(channel, "fail embedding", "embedding fails", ["fail-source"])

    assert {:ok, 2} = Brain.embed_pending_episodes(10)

    assert %Episode{embedding_state: :synced, embedding_dimensions: 2, embedding_error: nil} =
             episode_snapshot!(synced.id)

    assert %Episode{embedding_state: :failed, embedding_error: error} =
             episode_snapshot!(failed.id)

    assert is_binary(error)
  end

  defp disable_dreaming! do
    assert {:ok, config} = Config.dreaming()

    assert {:ok, _stored} =
             AppConfigure.put_global(
               Config.dreaming_definition(),
               Map.put(config, "enabled", false)
             )
  end

  defp enable_dreaming!(model_agent_uid, overrides \\ %{}) do
    assert {:ok, config} = Config.dreaming()

    value =
      config
      |> Map.merge(%{"enabled" => true, "model_agent_uid" => model_agent_uid})
      |> Map.merge(overrides)

    assert {:ok, _stored} = AppConfigure.put_global(Config.dreaming_definition(), value)
  end

  defp channel_fixture(id) do
    %Channel{}
    |> Channel.changeset(%{
      id: id,
      kind: :im_group,
      reply_mode: :entry,
      name: id,
      metadata: %{},
      raw_payload: %{},
      first_seen_at: @base_time,
      last_seen_at: @base_time
    })
    |> Repo.insert!()
  end

  defp entry_fixture(%Channel{} = channel, source_entry_id, text, provider_time) do
    %Entry{}
    |> Entry.changeset(%{
      signal_channel_id: channel.id,
      source_entry_id: source_entry_id,
      text: text,
      attachments: [],
      links: [],
      author: %{"display_name" => "Alice"},
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

  defp configure_brain_model!(agent, handler) do
    provider_id = "brain-provider-#{System.unique_integer([:positive])}"
    base_url = start_upstream_server(handler)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "#{base_url}/v1",
               connection_options: %{"api_key" => "sk-brain-test"}
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
      embedding_state: :pending,
      metadata: %{}
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
        :source_entry_ids,
        :embedding_state,
        :embedding_dimensions,
        :embedding_error
      ])
    )
  end

  defp channel_cursor(channel_id),
    do: Repo.get_by(Cursor, scope_kind: :channel, scope_key: channel_id)

  defp channel_cursor!(channel_id),
    do: Repo.get_by!(Cursor, scope_kind: :channel, scope_key: channel_id)
end
