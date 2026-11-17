defmodule AnkoleWeb.AIGatewayMediaJobsTest do
  use AnkoleWeb.ConnCase, async: false
  use Oban.Testing, repo: Ankole.Repo

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.Jobs.RunMediaJob
  alias Ankole.AIGateway.MediaJobs
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Schemas.MediaJob
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AIGateway.Tokens

  @mp4 <<0, 0, 0, 0x18, "ftypmp42", 0, 0, 0, 0, "mp42isom">>
  @mp3 <<0xFF, 0xFB, 0x90, 0x00, 0x01, 0x02>>

  setup %{conn: conn} do
    %{principal: agent} = agent_fixture()
    {:ok, api_key} = Tokens.mint_for_agent(agent.uid)
    test_pid = self()

    # The test queues the upstream's answers in the order of the requests.
    {:ok, answers} = Agent.start_link(fn -> [] end)

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:upstream, request})
        Agent.get_and_update(answers, fn [answer | rest] -> {answer, rest} end)
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-main",
               provider_kind: "openrouter",
               base_url: base_url <> "/v1",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-or"}]}
             })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "cloudflare-main",
               provider_kind: "cloudflare",
               base_url: base_url,
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "cf-token"}]},
               connection_options: %{"account_id" => "acct-1"}
             })

    %{
      answers: answers,
      base_url: base_url,
      conn: put_req_header(conn, "authorization", "Bearer #{api_key.api_key}")
    }
  end

  defp profile(slot, provider_id, model) do
    assert {:ok, _profile} =
             ModelProfiles.put_default_model_profile(:tenant, slot, %{
               provider_id: provider_id,
               model: model
             })
  end

  defp answer(ctx, answer), do: Agent.update(ctx.answers, &(&1 ++ [answer]))

  defp run(id), do: perform_job(RunMediaJob, %{"media_job_id" => id})

  test "a video job submits, waits for OpenRouter, and saves the file", ctx do
    profile("video", "openrouter-main", "google/veo-3.1")

    conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/videos", %{
        "model" => "video.default",
        "prompt" => "A red kite over a beach",
        "duration" => 8
      })

    assert %{"id" => id, "status" => "pending", "model" => "openrouter-main/google/veo-3.1"} =
             json_response(conn, 202)

    assert_enqueued(worker: RunMediaJob, args: %{"media_job_id" => id})
    refute_received {:upstream, _request}

    # OpenRouter accepts the generation and answers before the video exists.
    answer(ctx, {:json, 202, %{"id" => "gen-1", "status" => "pending"}})
    assert {:snooze, 10} = run(id)
    assert_receive {:upstream, %{method: :post, path: "v1/videos"} = submission}

    assert submission.body == %{
             "model" => "google/veo-3.1",
             "prompt" => "A red kite over a beach",
             "duration" => 8
           }

    assert %{"status" => "in_progress"} =
             ctx.conn |> get(~p"/api/v1/ai-gateway/videos/#{id}") |> json_response(200)

    assert %{"error" => %{"code" => "media_not_ready"}} =
             ctx.conn |> get(~p"/api/v1/ai-gateway/videos/#{id}/content") |> json_response(409)

    answer(ctx, {:json, 200, %{"id" => "gen-1", "status" => "in_progress"}})
    assert {:snooze, 10} = run(id)
    assert_receive {:upstream, %{method: :get, path: "v1/videos/gen-1", body: nil}}

    # The finished generation links to OpenRouter's own content endpoint,
    # which the gateway reads with the Provider credential.
    answer(
      ctx,
      {:json, 200,
       %{
         "id" => "gen-1",
         "status" => "completed",
         "unsigned_urls" => ["#{ctx.base_url}/v1/videos/gen-1/content?index=0"],
         "usage" => %{"cost" => 0.4}
       }}
    )

    answer(ctx, {:raw, 200, "video/mp4", @mp4})
    assert :ok = run(id)
    assert_receive {:upstream, %{method: :get, path: "v1/videos/gen-1"}}
    assert_receive {:upstream, %{method: :get, path: "v1/videos/gen-1/content"} = download}
    assert download.headers["authorization"] == "Bearer sk-or"

    assert %{"status" => "completed", "content_type" => "video/mp4", "size" => size} =
             ctx.conn |> get(~p"/api/v1/ai-gateway/videos/#{id}") |> json_response(200)

    assert size == byte_size(@mp4)

    content = get(ctx.conn, ~p"/api/v1/ai-gateway/videos/#{id}/content")
    assert response(content, 200) == @mp4
    assert ["video/mp4" <> _charset] = get_resp_header(content, "content-type")

    assert [row] = Ankole.Repo.all(UsageRecord)
    assert {row.capability, row.unit, row.quantity} == {:video, :second, 8}
    assert Decimal.equal?(row.provider_cost, Decimal.new("0.4"))

    # A finished job is not run again, and another caller does not see it.
    assert :ok = run(id)
    refute_received {:upstream, _request}

    %{principal: other} = agent_fixture()
    {:ok, other_key} = Tokens.mint_for_agent(other.uid)

    assert %{"error" => %{"code" => _code}} =
             build_conn()
             |> put_req_header("authorization", "Bearer #{other_key.api_key}")
             |> get(~p"/api/v1/ai-gateway/videos/#{id}")
             |> json_response(404)

    # The music route does not serve a video job.
    assert ctx.conn |> get(~p"/api/v1/ai-gateway/audio/music/#{id}") |> json_response(404)
  end

  test "a music job saves the audio that Cloudflare links to", ctx do
    profile("music", "cloudflare-main", "minimax/music-2.6")

    conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/audio/music", %{
        "model" => "music.default",
        "prompt" => "Slow piano",
        "instrumental" => true
      })

    assert %{"id" => id, "status" => "pending"} = json_response(conn, 202)

    # The link names another host than the Provider's, so it gets no credential.
    link = String.replace(ctx.base_url, "127.0.0.1", "localhost") <> "/files/song.mp3"

    answer(ctx, {:json, 200, %{"state" => "Completed", "result" => %{"audio" => link}}})

    answer(ctx, {:raw, 200, "audio/mpeg", @mp3})
    assert :ok = run(id)

    assert_receive {:upstream, %{method: :post, path: "accounts/acct-1/ai/run"} = submission}
    assert submission.headers["authorization"] == "Bearer cf-token"

    assert submission.body == %{
             "model" => "minimax/music-2.6",
             "input" => %{
               "prompt" => "Slow piano",
               "is_instrumental" => true,
               "lyrics_optimizer" => false
             }
           }

    assert_receive {:upstream, %{method: :get, path: "files/song.mp3"} = download}
    refute is_map_key(download.headers, "authorization")

    content = get(ctx.conn, ~p"/api/v1/ai-gateway/audio/music/#{id}/content")
    assert response(content, 200) == @mp3
    assert ["audio/mpeg" <> _charset] = get_resp_header(content, "content-type")

    assert [row] = Ankole.Repo.all(UsageRecord)
    assert {row.capability, row.unit, row.quantity} == {:music, nil, nil}
  end

  test "a failed generation and a rejected submission fail the job", ctx do
    profile("video", "openrouter-main", "google/veo-3.1")

    create = fn ->
      ctx.conn
      |> post(~p"/api/v1/ai-gateway/videos", %{"model" => "default", "prompt" => "A kite"})
      |> json_response(202)
      |> Map.fetch!("id")
    end

    failed = create.()
    answer(ctx, {:json, 202, %{"id" => "gen-2", "status" => "pending"}})
    assert {:snooze, 10} = run(failed)

    answer(
      ctx,
      {:json, 200, %{"id" => "gen-2", "status" => "failed", "error" => "Blocked by moderation."}}
    )

    assert :ok = run(failed)

    assert %{
             "status" => "failed",
             "error" => %{
               "code" => "media_generation_failed",
               "message" => "Blocked by moderation."
             }
           } = ctx.conn |> get(~p"/api/v1/ai-gateway/videos/#{failed}") |> json_response(200)

    rejected = create.()
    answer(ctx, {:json, 400, %{"error" => %{"message" => "Unknown model."}}})
    assert :ok = run(rejected)

    assert %{"status" => "failed", "error" => %{"code" => _code}} =
             ctx.conn |> get(~p"/api/v1/ai-gateway/videos/#{rejected}") |> json_response(200)

    assert Ankole.Repo.all(UsageRecord) == []
  end

  test "a job that stopped while it sent the request does not send it again", ctx do
    profile("video", "openrouter-main", "google/veo-3.1")

    id =
      ctx.conn
      |> post(~p"/api/v1/ai-gateway/videos", %{"model" => "default", "prompt" => "A kite"})
      |> json_response(202)
      |> Map.fetch!("id")

    [job] = Ankole.Repo.all(MediaJob)
    assert {:ok, _job} = Ankole.Ash.update(job, :advance, %{status: :in_progress})

    assert :ok = run(id)
    refute_received {:upstream, _request}

    assert %{"status" => "failed", "error" => %{"code" => "media_job_interrupted"}} =
             ctx.conn |> get(~p"/api/v1/ai-gateway/videos/#{id}") |> json_response(200)
  end

  for {capability, provider_id, model, route, upstream_path} <- [
        {"video", "openrouter-main", "google/veo-3.1", "/api/v1/ai-gateway/videos", "v1/videos"},
        {"music", "cloudflare-main", "minimax/music-2.6", "/api/v1/ai-gateway/audio/music",
         "accounts/acct-1/ai/run"}
      ],
      status <- [502, 503, 504] do
    test "#{capability} submission is not replayed after HTTP #{status}", ctx do
      profile(unquote(capability), unquote(provider_id), unquote(model))

      id =
        ctx.conn
        |> post(unquote(route), %{"model" => "default", "prompt" => "A quiet beach"})
        |> json_response(202)
        |> Map.fetch!("id")

      failure = {:json, unquote(status), %{"error" => %{"message" => "Upstream unavailable"}}}
      answer(ctx, failure)
      answer(ctx, failure)
      assert :ok = run(id)
      assert_receive {:upstream, %{method: :post, path: unquote(upstream_path)}}
      refute_received {:upstream, _request}
      assert Agent.get(ctx.answers, &length/1) == 1

      assert %{"status" => "failed"} =
               ctx.conn |> get(unquote(route) <> "/" <> id) |> json_response(200)

      assert :ok = run(id)
      refute_received {:upstream, _request}
    end
  end

  for status <- [401, 429] do
    test "a video submission rotates credentials after HTTP #{status}", ctx do
      assert {:ok, _provider} =
               ProviderConfigs.create_provider(%{
                 provider_id: "video-pool",
                 provider_kind: "openrouter",
                 base_url: ctx.base_url <> "/v1",
                 credential_pool: %{
                   "entries" => [
                     %{"label" => "First", "api_key" => "sk-first"},
                     %{"label" => "Second", "api_key" => "sk-second"}
                   ]
                 }
               })

      profile("video", "video-pool", "google/veo-3.1")

      id =
        ctx.conn
        |> post(~p"/api/v1/ai-gateway/videos", %{"model" => "default", "prompt" => "A kite"})
        |> json_response(202)
        |> Map.fetch!("id")

      answer(ctx, {:json, unquote(status), %{"error" => %{"message" => "Request rejected"}}})
      answer(ctx, {:json, 202, %{"id" => "gen-accepted", "status" => "pending"}})
      assert {:snooze, 10} = run(id)
      assert_receive {:upstream, %{method: :post, path: "v1/videos"} = first}
      assert_receive {:upstream, %{method: :post, path: "v1/videos"} = second}
      refute first.headers["authorization"] == second.headers["authorization"]
      refute_received {:upstream, _request}
    end
  end

  test "video polling retries a route failure and a failed download resumes from its link", ctx do
    profile("video", "openrouter-main", "google/veo-3.1")

    id =
      ctx.conn
      |> post(~p"/api/v1/ai-gateway/videos", %{"model" => "default", "prompt" => "A kite"})
      |> json_response(202)
      |> Map.fetch!("id")

    answer(ctx, {:json, 202, %{"id" => "gen-retry", "status" => "pending"}})
    assert {:snooze, 10} = run(id)
    assert_receive {:upstream, %{method: :post, path: "v1/videos"}}

    answer(ctx, {:json, 503, %{"error" => %{"message" => "Temporarily unavailable"}}})

    answer(
      ctx,
      {:json, 200,
       %{
         "id" => "gen-retry",
         "status" => "completed",
         "unsigned_urls" => [ctx.base_url <> "/files/video.mp4"]
       }}
    )

    answer(ctx, {:json, 503, %{"error" => %{"message" => "Download unavailable"}}})
    assert {:error, _reason} = run(id)
    assert_receive {:upstream, %{method: :get, path: "v1/videos/gen-retry"}}
    assert_receive {:upstream, %{method: :get, path: "v1/videos/gen-retry"}}
    assert_receive {:upstream, %{method: :get, path: "files/video.mp4"}}

    answer(ctx, {:raw, 200, "video/mp4", @mp4})
    assert :ok = run(id)
    assert_receive {:upstream, %{method: :get, path: "files/video.mp4"}}
    refute_received {:upstream, _request}
    assert response(get(ctx.conn, ~p"/api/v1/ai-gateway/videos/#{id}/content"), 200) == @mp4
  end

  test "a request needs a prompt and a configured profile", ctx do
    assert %{"error" => %{"code" => "model_profile_not_configured"}} =
             ctx.conn
             |> post(~p"/api/v1/ai-gateway/audio/music", %{
               "model" => "music.default",
               "prompt" => "Slow piano"
             })
             |> json_response(422)

    profile("music", "cloudflare-main", "minimax/music-2.6")

    assert %{"error" => %{"param" => "prompt", "code" => "missing_required_parameter"}} =
             ctx.conn
             |> post(~p"/api/v1/ai-gateway/audio/music", %{"model" => "music.default"})
             |> json_response(400)

    assert %{"error" => %{"param" => "duration"}} =
             ctx.conn
             |> post(~p"/api/v1/ai-gateway/audio/music", %{
               "model" => "music.default",
               "prompt" => "Slow piano",
               "duration" => 0
             })
             |> json_response(400)

    assert Ankole.Repo.all(MediaJob) == []
  end

  test "the cleanup deletes a job whose retention has ended", ctx do
    profile("video", "openrouter-main", "google/veo-3.1")

    ctx.conn
    |> post(~p"/api/v1/ai-gateway/videos", %{"model" => "default", "prompt" => "A kite"})
    |> json_response(202)

    assert MediaJobs.cleanup_expired() == 0
    assert MediaJobs.cleanup_expired(DateTime.add(DateTime.utc_now(), 8, :day)) == 1
    assert Ankole.Repo.all(MediaJob) == []
  end

  test "download_headers only forwards credentials to exact same HTTPS host and port" do
    prepared = %{
      upstream: %{
        url: "https://api.provider.example/v1/videos",
        headers: [{"authorization", "Bearer secret"}]
      }
    }

    assert MediaJobs.download_headers("https://api.provider.example:443/files/out.mp4", prepared) ==
             [{"authorization", "Bearer secret"}]

    assert MediaJobs.download_headers("http://api.provider.example/files/out.mp4", prepared) == []

    assert MediaJobs.download_headers("https://api.provider.example:8443/files/out.mp4", prepared) ==
             []

    assert MediaJobs.download_headers("https://cdn.provider.example/files/out.mp4", prepared) ==
             []
  end

  test "non-streaming capability endpoints reject unknown top-level parameters and stream: true",
       ctx do
    profile("video", "openrouter-main", "google/veo-3.1")
    profile("music", "cloudflare-main", "minimax/music-2.6")

    for {path, payload} <- [
          {~p"/api/v1/ai-gateway/videos",
           %{"model" => "default", "prompt" => "A kite", "unknown_knob" => 1}},
          {~p"/api/v1/ai-gateway/videos",
           %{"model" => "default", "prompt" => "A kite", "stream" => true}},
          {~p"/api/v1/ai-gateway/audio/music",
           %{"model" => "music.default", "prompt" => "Slow piano", "extra" => "x"}},
          {~p"/api/v1/ai-gateway/audio/speech",
           %{"model" => "speech.default", "input" => "Hello", "extra" => "x"}},
          {~p"/api/v1/ai-gateway/audio/speech",
           %{"model" => "speech.default", "input" => "Hello", "stream" => true}},
          {~p"/api/v1/ai-gateway/audio/transcriptions",
           %{
             "model" => "transcription.default",
             "input_audio" => %{"data" => Base.encode64("abc"), "format" => "wav"},
             "extra" => "x"
           }},
          {~p"/api/v1/ai-gateway/ocr",
           %{
             "model" => "ocr.default",
             "document" => "data:image/png;base64," <> Base.encode64("png"),
             "extra" => "x"
           }},
          {~p"/api/v1/ai-gateway/decisions",
           %{
             "model" => "decision.default",
             "state" => nil,
             "questions" => %{"q1" => %{"type" => "noul", "instructions" => "Is it safe?"}},
             "extra" => "x"
           }}
        ] do
      assert %{"error" => %{"code" => "unsupported_parameter"}} =
               ctx.conn |> post(path, payload) |> json_response(400)
    end
  end

  test "video polling and same-origin download stay pinned to the accepting credential", ctx do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "video-pinned-pool",
               provider_kind: "openrouter",
               base_url: ctx.base_url <> "/v1",
               credential_pool: %{
                 "strategy" => "round_robin",
                 "entries" => [
                   %{"label" => "First", "api_key" => "sk-first"},
                   %{"label" => "Second", "api_key" => "sk-second"}
                 ]
               }
             })

    [first_entry, second_entry] = provider.credential_pool["entries"]
    profile("video", "video-pinned-pool", "google/veo-3.1")

    id =
      ctx.conn
      |> post(~p"/api/v1/ai-gateway/videos", %{"model" => "default", "prompt" => "A kite"})
      |> json_response(202)
      |> Map.fetch!("id")

    # Reset pool state after create-time request validation so submission starts on sk-first.
    :ok = CredentialPool.reset_for_test()

    # Submission fails over from sk-first to sk-second after HTTP 429.
    answer(ctx, {:json, 429, %{"error" => %{"message" => "Rate limited"}}})
    answer(ctx, {:json, 202, %{"id" => "gen-pinned", "status" => "pending"}})
    assert {:snooze, 10} = run(id)
    assert_receive {:upstream, %{method: :post, path: "v1/videos"} = post_1}
    assert_receive {:upstream, %{method: :post, path: "v1/videos"} = post_2}
    assert post_1.headers["authorization"] == "Bearer sk-first"
    assert post_2.headers["authorization"] == "Bearer sk-second"
    refute first_entry["id"] == second_entry["id"]
    assert Ankole.Repo.get!(MediaJob, id).credential_id == second_entry["id"]

    # Simulate cross-node execution / restart by clearing all pool memory.
    :ok = CredentialPool.reset_for_test()

    # Polling hits 429 on sk-second: it must NOT rotate to sk-first.
    answer(ctx, {:json, 429, %{"error" => %{"message" => "Poll rate limited"}}})
    assert {:error, _reason} = run(id)
    assert_receive {:upstream, %{method: :get, path: "v1/videos/gen-pinned"} = poll_429}
    assert poll_429.headers["authorization"] == "Bearer sk-second"
    refute_received {:upstream, _request}

    # Next attempt succeeds while sk-second is still marked exhausted in CredentialPool,
    # and same-origin download also uses sk-second.
    answer(
      ctx,
      {:json, 200,
       %{
         "id" => "gen-pinned",
         "status" => "completed",
         "unsigned_urls" => ["#{ctx.base_url}/v1/videos/gen-pinned/content?index=0"]
       }}
    )

    answer(ctx, {:raw, 200, "video/mp4", @mp4})
    assert :ok = run(id)
    assert_receive {:upstream, %{method: :get, path: "v1/videos/gen-pinned"} = poll_ok}
    assert_receive {:upstream, %{method: :get, path: "v1/videos/gen-pinned/content"} = download}
    assert poll_ok.headers["authorization"] == "Bearer sk-second"
    assert download.headers["authorization"] == "Bearer sk-second"
    assert response(get(ctx.conn, ~p"/api/v1/ai-gateway/videos/#{id}/content"), 200) == @mp4
  end

  test "music failover pins the winning credential for immediate and retried same-origin downloads",
       ctx do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "music-pinned-pool",
               provider_kind: "cloudflare",
               base_url: ctx.base_url,
               connection_options: %{"account_id" => "acct-1"},
               credential_pool: %{
                 "entries" => [
                   %{"label" => "First", "api_key" => "cf-first"},
                   %{"label" => "Second", "api_key" => "cf-second"}
                 ]
               }
             })

    [_first_entry, second_entry] = provider.credential_pool["entries"]
    profile("music", "music-pinned-pool", "minimax/music-2.6")

    id =
      ctx.conn
      |> post(~p"/api/v1/ai-gateway/audio/music", %{
        "model" => "music.default",
        "prompt" => "Slow piano"
      })
      |> json_response(202)
      |> Map.fetch!("id")

    link = ctx.base_url <> "/files/song.mp3"
    answer(ctx, {:json, 429, %{"error" => %{"message" => "Rate limited"}}})
    answer(ctx, {:json, 200, %{"state" => "Completed", "result" => %{"audio" => link}}})
    answer(ctx, {:json, 503, %{"error" => %{"message" => "Download temporarily unavailable"}}})

    assert {:error, {:media_download_failed, _reason}} = run(id)
    assert_receive {:upstream, %{method: :post, path: "accounts/acct-1/ai/run"} = post_1}
    assert_receive {:upstream, %{method: :post, path: "accounts/acct-1/ai/run"} = post_2}
    assert_receive {:upstream, %{method: :get, path: "files/song.mp3"} = download_1}
    assert post_1.headers["authorization"] == "Bearer cf-first"
    assert post_2.headers["authorization"] == "Bearer cf-second"
    assert download_1.headers["authorization"] == "Bearer cf-second"
    assert Ankole.Repo.get!(MediaJob, id).credential_id == second_entry["id"]

    # Retry on a clean pool node still uses cf-second.
    :ok = CredentialPool.reset_for_test()
    answer(ctx, {:raw, 200, "audio/mpeg", @mp3})
    assert :ok = run(id)
    assert_receive {:upstream, %{method: :get, path: "files/song.mp3"} = download_2}
    assert download_2.headers["authorization"] == "Bearer cf-second"
    assert response(get(ctx.conn, ~p"/api/v1/ai-gateway/audio/music/#{id}/content"), 200) == @mp3
  end

  test "removing the pinned credential fails the job instead of switching to another entry",
       ctx do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "video-removed-pool",
               provider_kind: "openrouter",
               base_url: ctx.base_url <> "/v1",
               credential_pool: %{
                 "entries" => [
                   %{"label" => "First", "api_key" => "sk-first"},
                   %{"label" => "Second", "api_key" => "sk-second"}
                 ]
               }
             })

    [first_entry, second_entry] = provider.credential_pool["entries"]
    profile("video", "video-removed-pool", "google/veo-3.1")

    id =
      ctx.conn
      |> post(~p"/api/v1/ai-gateway/videos", %{"model" => "default", "prompt" => "A kite"})
      |> json_response(202)
      |> Map.fetch!("id")

    answer(ctx, {:json, 202, %{"id" => "gen-removed", "status" => "pending"}})
    assert {:snooze, 10} = run(id)
    assert_receive {:upstream, %{method: :post, path: "v1/videos"} = submission}
    assert submission.headers["authorization"] == "Bearer sk-first"
    assert Ankole.Repo.get!(MediaJob, id).credential_id == first_entry["id"]

    assert {:ok, _updated} =
             ProviderConfigs.update_provider("video-removed-pool", %{
               "credential_pool" => %{
                 "entries" => [%{"id" => second_entry["id"]}]
               }
             })

    assert :ok = run(id)
    refute_received {:upstream, _request}

    assert %{
             "status" => "failed",
             "error" => %{"code" => "credential_removed"}
           } = ctx.conn |> get(~p"/api/v1/ai-gateway/videos/#{id}") |> json_response(200)
  end
end
