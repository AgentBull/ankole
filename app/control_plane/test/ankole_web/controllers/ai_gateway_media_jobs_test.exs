defmodule AnkoleWeb.AIGatewayMediaJobsTest do
  use AnkoleWeb.ConnCase, async: false
  use Oban.Testing, repo: Ankole.Repo

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

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
end
