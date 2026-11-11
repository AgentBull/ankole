defmodule AnkoleWeb.AIGatewayAudioTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AIGateway.Tokens

  # Not valid UTF-8, as real audio is not.
  @mp3 <<0xFF, 0xFB, 0x90, 0x00, 0x01, 0x02>>
  @wav_base64 Base.encode64("RIFF....WAVEfmt ")

  setup %{conn: conn} do
    %{principal: agent} = agent_fixture()
    {:ok, api_key} = Tokens.mint_for_agent(agent.uid)
    test_pid = self()

    upstream = fn response_fun ->
      start_upstream_server(fn request ->
        send(test_pid, {:gateway_request, request})
        response_fun.(request)
      end)
    end

    %{
      agent: agent,
      upstream: upstream,
      conn: put_req_header(conn, "authorization", "Bearer #{api_key.api_key}")
    }
  end

  defp provider(kind, base_url, connection_options \\ %{}) do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "#{kind}-main",
               provider_kind: kind,
               base_url: base_url,
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]},
               connection_options: connection_options
             })
  end

  defp profile(slot, provider_id, model) do
    assert {:ok, _profile} =
             ModelProfiles.put_default_model_profile(:tenant, slot, %{
               provider_id: provider_id,
               model: model
             })
  end

  defp speak(conn, request),
    do: post(conn, ~p"/api/v1/ai-gateway/audio/speech", Map.put_new(request, "model", "default"))

  defp transcribe(conn, request) do
    post(
      conn,
      ~p"/api/v1/ai-gateway/audio/transcriptions",
      Map.put_new(request, "model", "default")
    )
  end

  test "a speech request returns the audio bytes of a Cloudflare Aura model", ctx do
    base_url =
      ctx.upstream.(fn %{path: "accounts/acct-1/ai/run/@cf/deepgram/aura-1"} ->
        {:raw, 200, "audio/mpeg", @mp3}
      end)

    provider("cloudflare", base_url, %{"account_id" => "acct-1"})
    profile("speech", "cloudflare-main", "@cf/deepgram/aura-1")

    # A client that asks for audio gets it; the route does not insist on JSON.
    conn =
      ctx.conn
      |> put_req_header("accept", "audio/mpeg")
      |> speak(%{"input" => "Hello, Ankole.", "voice" => "luna"})

    assert response(conn, 200) == @mp3
    assert get_resp_header(conn, "content-type") == ["audio/mpeg"]

    assert_receive {:gateway_request, request}
    assert request.headers["authorization"] == "Bearer sk-test"
    assert request.body == %{"text" => "Hello, Ankole.", "speaker" => "luna"}

    assert [row] = Ankole.Repo.all(UsageRecord)
    assert {row.capability, row.origin} == {:speech, :agent}
    assert {row.unit, row.quantity} == {:character, 14}
    assert row.model == "cloudflare-main/@cf/deepgram/aura-1"
  end

  test "a speech request passes its delivery options to OpenRouter", ctx do
    base_url =
      ctx.upstream.(fn %{path: "v1/audio/speech"} -> {:raw, 200, "audio/pcm", @mp3} end)

    provider("openrouter", base_url <> "/v1")
    profile("speech", "openrouter-main", "openai/gpt-4o-mini-tts")

    conn =
      speak(ctx.conn, %{
        "model" => "speech.default",
        "input" => "Hello.",
        "voice" => "alloy",
        "response_format" => "pcm",
        "speed" => 1.25,
        "instructions" => "Speak calmly."
      })

    assert response(conn, 200) == @mp3
    assert get_resp_header(conn, "content-type") == ["audio/pcm"]

    assert_receive {:gateway_request, request}

    assert request.body == %{
             "model" => "openai/gpt-4o-mini-tts",
             "input" => "Hello.",
             "voice" => "alloy",
             "response_format" => "pcm",
             "speed" => 1.25,
             "instructions" => "Speak calmly."
           }
  end

  test "a speech response keeps its size and the audio type that the Provider names", ctx do
    # Longer than the 16 MiB that the kernel reads by default.
    long_audio = :binary.copy(<<0xFF, 0xFB>>, 9 * 1024 * 1024)

    base_url =
      ctx.upstream.(fn %{path: "v1/audio/speech", body: body} ->
        case body["input"] do
          "long" -> {:raw, 200, "audio/mpeg", long_audio}
          "ogg" -> {:raw, 200, "audio/ogg", @mp3}
          "bytes" -> {:raw, 200, "application/octet-stream", @mp3}
        end
      end)

    provider("openrouter", base_url <> "/v1")
    profile("speech", "openrouter-main", "openai/gpt-4o-mini-tts")

    conn = speak(ctx.conn, %{"input" => "long"})
    assert byte_size(response(conn, 200)) == byte_size(long_audio)

    conn = speak(ctx.conn, %{"input" => "ogg"})
    assert get_resp_header(conn, "content-type") == ["audio/ogg"]

    # A Provider that only says "bytes" sent the format that the request asked for.
    conn = speak(ctx.conn, %{"input" => "bytes", "response_format" => "pcm"})
    assert response(conn, 200) == @mp3
    assert get_resp_header(conn, "content-type") == ["audio/pcm"]
  end

  test "the next credential still receives audio beyond the kernel's default limit", ctx do
    long_audio = :binary.copy(<<0xFF, 0xFB>>, 9 * 1024 * 1024)
    calls = :counters.new(1, [])

    # The first credential that the pool tries is rate limited.
    base_url =
      ctx.upstream.(fn %{path: "v1/audio/speech"} ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1,
          do: {:json, 429, %{"error" => %{"message" => "rate limited"}}},
          else: {:raw, 200, "audio/mpeg", long_audio}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-pool",
               provider_kind: "openrouter",
               base_url: base_url <> "/v1",
               credential_pool: %{
                 "entries" => [
                   %{"label" => "First", "api_key" => "sk-first"},
                   %{"label" => "Second", "api_key" => "sk-second"}
                 ]
               }
             })

    profile("speech", "openrouter-pool", "openai/gpt-4o-mini-tts")

    conn = speak(ctx.conn, %{"input" => "long"})
    assert byte_size(response(conn, 200)) == byte_size(long_audio)

    assert_receive {:gateway_request, first}
    assert_receive {:gateway_request, second}
    assert first.headers["authorization"] != second.headers["authorization"]
  end

  test "a Cloudflare speech model rejects the options that it cannot honor", ctx do
    provider("cloudflare", "http://127.0.0.1:9", %{"account_id" => "acct-1"})
    profile("speech", "cloudflare-main", "@cf/deepgram/aura-1")

    for {option, value} <- [
          {"response_format", "pcm"},
          {"speed", 1.5},
          {"instructions", "Whisper."}
        ] do
      conn = speak(ctx.conn, %{"input" => "Hello.", option => value})

      assert %{"error" => %{"param" => ^option, "code" => "unsupported_value"}} =
               json_response(conn, 400)
    end

    refute_received {:gateway_request, _request}
  end

  test "speech and transcription fail without a configured profile", ctx do
    assert %{"error" => %{"code" => "model_profile_not_configured"}} =
             ctx.conn |> speak(%{"input" => "Hello."}) |> json_response(422)

    assert %{"error" => %{"code" => "model_profile_not_configured"}} =
             ctx.conn
             |> transcribe(%{"input_audio" => %{"data" => @wav_base64, "format" => "wav"}})
             |> json_response(422)
  end

  test "a speech request names the field that is invalid", ctx do
    for {request, param} <- [
          {%{}, "input"},
          {%{"input" => "  "}, "input"},
          {%{"input" => "Hello.", "voice" => ""}, "voice"},
          {%{"input" => "Hello.", "response_format" => "wav"}, "response_format"},
          {%{"input" => "Hello.", "speed" => 0}, "speed"}
        ] do
      assert %{"error" => %{"param" => ^param}} =
               ctx.conn |> speak(request) |> json_response(400)
    end
  end

  test "a transcription request returns the text of a Cloudflare Whisper model", ctx do
    base_url =
      ctx.upstream.(fn %{path: "accounts/acct-1/ai/run/@cf/openai/whisper-large-v3-turbo"} ->
        {:json, 200,
         %{
           "success" => true,
           "result" => %{
             "text" => "Hello there.",
             "word_count" => 2,
             "transcription_info" => %{"language" => "en", "duration" => 3.5},
             "segments" => [
               %{"start" => 0.0, "end" => 3.5, "text" => "Hello there.", "words" => []}
             ]
           }
         }}
      end)

    provider("cloudflare", base_url, %{"account_id" => "acct-1"})
    profile("transcription", "cloudflare-main", "@cf/openai/whisper-large-v3-turbo")
    audio = %{"data" => @wav_base64, "format" => "wav"}

    conn =
      transcribe(ctx.conn, %{"input_audio" => audio, "language" => "en", "vad_filter" => true})

    assert json_response(conn, 200) == %{
             "model" => "cloudflare-main/@cf/openai/whisper-large-v3-turbo",
             "text" => "Hello there.",
             "usage" => %{"seconds" => 3.5}
           }

    assert_receive {:gateway_request, request}
    assert request.body == %{"audio" => @wav_base64, "language" => "en", "vad_filter" => true}

    # A started second counts as a whole one.
    assert [row] = Ankole.Repo.all(UsageRecord)
    assert {row.capability, row.unit, row.quantity} == {:transcription, :second, 4}

    conn = transcribe(ctx.conn, %{"input_audio" => audio, "response_format" => "verbose_json"})

    assert conn |> json_response(200) |> Map.take(~w(language duration segments)) == %{
             "language" => "en",
             "duration" => 3.5,
             "segments" => [%{"start" => 0.0, "end" => 3.5, "text" => "Hello there."}]
           }
  end

  test "a transcription request records the cost that OpenRouter reports", ctx do
    base_url =
      ctx.upstream.(fn %{path: "v1/audio/transcriptions"} ->
        {:json, 200,
         %{
           "text" => "Hello there.",
           "usage" => %{"seconds" => 9.2, "cost" => 0.000508, "total_tokens" => 113}
         }}
      end)

    provider("openrouter", base_url <> "/v1")
    profile("transcription", "openrouter-main", "openai/whisper-large-v3")
    audio = %{"data" => @wav_base64, "format" => "wav"}

    conn = transcribe(ctx.conn, %{"model" => "transcription.default", "input_audio" => audio})

    assert json_response(conn, 200) == %{
             "model" => "openrouter-main/openai/whisper-large-v3",
             "text" => "Hello there.",
             "usage" => %{"seconds" => 9.2}
           }

    assert_receive {:gateway_request, request}
    assert request.body == %{"model" => "openai/whisper-large-v3", "input_audio" => audio}

    assert [row] = Ankole.Repo.all(UsageRecord)
    assert {row.unit, row.quantity} == {:second, 10}
    assert Decimal.equal?(row.provider_cost, Decimal.new("0.000508"))
  end

  test "a transcription request names the field that is invalid", ctx do
    audio = %{"data" => @wav_base64, "format" => "wav"}

    for {request, param} <- [
          {%{}, "input_audio"},
          {%{"input_audio" => %{"data" => "not base64!", "format" => "wav"}}, "input_audio"},
          {%{"input_audio" => %{"data" => @wav_base64, "format" => "audio/wav"}}, "input_audio"},
          {%{"input_audio" => audio, "response_format" => "text"}, "response_format"},
          {%{"input_audio" => audio, "vad_filter" => "yes"}, "vad_filter"}
        ] do
      assert %{"error" => %{"param" => ^param}} =
               ctx.conn |> transcribe(request) |> json_response(400)
    end
  end
end
