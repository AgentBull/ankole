defmodule AnkoleWeb.AIGatewayChinaMarketTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AIGateway.Tokens

  # Binary audio and document fixtures with non-UTF-8 bytes so every path proves
  # exact binary round-tripping through the native Rust kernel.
  @wav_bytes <<"RIFF", 0x24, 0x00, 0x00, 0x00, "WAVEfmt ", 0xFF, 0xFE, 0x01, 0x02>>
  @mp3_chunk_1 <<0xFF, 0xFB, 0x90, 0x00, 0x11, 0x22>>
  @mp3_chunk_2 <<0x33, 0x44, 0x55, 0x66>>
  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  @pdf_bytes <<"%PDF-1.7\n", 0xFF, 0xD8, 0x00, "%%EOF">>

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

  defp create_provider!(provider_id, provider_kind, base_url, credential_entry, conn_opts \\ %{}) do
    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: provider_kind,
               base_url: base_url,
               credential_pool: %{
                 "entries" => [Map.put_new(credential_entry, "label", "Default")]
               },
               connection_options: conn_opts
             })
  end

  defp put_profile!(slot, provider_id, model, provider_options \\ %{}) do
    assert {:ok, _profile} =
             ModelProfiles.put_default_model_profile(:tenant, slot, %{
               provider_id: provider_id,
               model: model,
               provider_options: provider_options
             })
  end

  test "Alibaba DashScope synthesizes WAV audio via signed OSS link, transcribes audio, and runs Qwen VL OCR",
       ctx do
    base_url =
      ctx.upstream.(fn
        %{path: "api/v1/services/aigc/multimodal-generation/generation", body: body} = req ->
          if get_in(body, ["input", "messages"]) do
            {:json, 200,
             %{
               "request_id" => "req_asr",
               "output" => %{
                 "choices" => [
                   %{
                     "message" => %{
                       "role" => "assistant",
                       "content" => [%{"text" => "阿里云语音识别结果"}],
                       "annotations" => [%{"type" => "audio_info", "language" => "zh"}]
                     }
                   }
                 ]
               },
               "usage" => %{"seconds" => 4.2}
             }}
          else
            root = String.replace_suffix(req.url, "/" <> req.path, "")

            url_path =
              case get_in(body, ["input", "text"]) do
                "html-error" -> "oss/expired.html"
                "octet-stream" -> "oss/synthesized.bin"
                _ -> "oss/synthesized.wav"
              end

            {:json, 200,
             %{
               "request_id" => "req_tts",
               "output" => %{
                 "audio" => %{
                   "url" => "#{root}/#{url_path}",
                   "id" => "aud_1"
                 }
               }
             }}
          end

        %{path: "oss/synthesized.wav"} ->
          {:raw, 200, "audio/x-wav", @wav_bytes}

        %{path: "oss/synthesized.bin"} ->
          {:raw, 200, "application/octet-stream", @wav_bytes}

        %{path: "oss/expired.html"} ->
          {:raw, 200, "text/html; charset=utf-8", "<html><body>Link expired</body></html>"}

        %{path: "compatible-mode/v1/chat/completions"} ->
          {:json, 200,
           %{
             "id" => "chatcmpl-ocr",
             "model" => "qwen-vl-ocr",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{
                   "role" => "assistant",
                   "content" => "```markdown\n# 增值税发票\n金额：100.00\n```"
                 }
               }
             ]
           }}
      end)

    create_provider!("alibaba-main", "alibaba_cn", base_url <> "/compatible-mode/v1", %{
      "api_key" => "sk-dashscope"
    })

    put_profile!("speech", "alibaba-main", "qwen3-tts-instruct-flash", %{
      "voice" => "Cherry",
      "language_type" => "Chinese"
    })

    speech_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/audio/speech", %{
        "model" => "speech.default",
        "input" => "你好，百炼语音。",
        "instructions" => "语速平稳自然"
      })

    assert response(speech_conn, 200) == @wav_bytes
    assert get_resp_header(speech_conn, "content-type") == ["audio/wav"]

    assert_receive {:gateway_request, tts_req}
    assert tts_req.headers["authorization"] == "Bearer sk-dashscope"

    assert tts_req.body == %{
             "model" => "qwen3-tts-instruct-flash",
             "input" => %{
               "text" => "你好，百炼语音。",
               "voice" => "Cherry",
               "language_type" => "Chinese",
               "instructions" => "语速平稳自然"
             }
           }

    assert_receive {:gateway_request, oss_req}
    assert oss_req.method == :get
    assert oss_req.path == "oss/synthesized.wav"
    refute Map.has_key?(oss_req.headers, "authorization")

    octet_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/audio/speech", %{
        "model" => "speech.default",
        "input" => "octet-stream"
      })

    assert response(octet_conn, 200) == @wav_bytes
    assert get_resp_header(octet_conn, "content-type") == ["audio/wav"]
    assert_receive {:gateway_request, _tts_octet_req}
    assert_receive {:gateway_request, _oss_octet_req}

    html_err_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/audio/speech", %{
        "model" => "speech.default",
        "input" => "html-error"
      })

    assert html_err_conn.status == 502
    refute get_resp_header(html_err_conn, "content-type") == ["audio/wav"]
    assert_receive {:gateway_request, _tts_html_req}
    assert_receive {:gateway_request, _oss_html_req}

    put_profile!("transcription", "alibaba-main", "qwen3-asr-flash")

    asr_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/audio/transcriptions", %{
        "model" => "transcription.default",
        "input_audio" => %{"data" => Base.encode64(@wav_bytes), "format" => "wav"},
        "language" => "zh",
        "response_format" => "verbose_json"
      })

    assert json_response(asr_conn, 200) == %{
             "model" => "alibaba-main/qwen3-asr-flash",
             "text" => "阿里云语音识别结果",
             "language" => "zh",
             "duration" => 4.2,
             "usage" => %{"seconds" => 4.2}
           }

    assert_receive {:gateway_request, asr_req}
    assert get_in(asr_req.body, ["parameters", "asr_options", "language"]) == "zh"

    put_profile!("ocr", "alibaba-main", "qwen-vl-ocr")

    ocr_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/ocr", %{
        "model" => "ocr.default",
        "document" => "data:image/png;base64,#{@png_base64}"
      })

    assert json_response(ocr_conn, 200) == %{
             "model" => "alibaba-main/qwen-vl-ocr",
             "pages" => [%{"index" => 0, "markdown" => "# 增值税发票\n金额：100.00"}],
             "usage" => %{"pages" => 1}
           }

    assert_receive {:gateway_request, _ocr_req}
    assert Enum.count(Ankole.Repo.all(UsageRecord)) == 4
  end

  test "Volcengine Speech reassembles NDJSON TTS audio, maps header errors, and transcribes flash audio",
       ctx do
    ndjson =
      [
        Ankole.JSON.encode!(%{"code" => 0, "data" => Base.encode64(@mp3_chunk_1)}),
        Ankole.JSON.encode!(%{"code" => 0, "data" => Base.encode64(@mp3_chunk_2)}),
        Ankole.JSON.encode!(%{
          "code" => 20_000_000,
          "message" => "ok",
          "usage" => %{"text_words" => 6}
        })
      ]
      |> Enum.join("\n")

    base_url =
      ctx.upstream.(fn
        %{path: "api/v3/tts/unidirectional", body: %{"req_params" => %{"text" => "bad-auth"}}} ->
          {:raw, 200,
           [{"x-api-status-code", "45000010"}, {"x-api-message", "invalid access key"}],
           "application/json", "{}"}

        %{path: "api/v3/tts/unidirectional"} ->
          {:raw, 200, [{"x-api-status-code", "20000000"}], "application/json", ndjson}

        %{path: "api/v3/auc/bigmodel/recognize/flash"} ->
          {:json, 200, [{"x-api-status-code", "20000000"}],
           %{
             "audio_info" => %{"duration" => 2600},
             "result" => %{
               "text" => "火山豆包语音识别",
               "additions" => %{"language" => "zh-CN"},
               "utterances" => [
                 %{"start_time" => 0, "end_time" => 2600, "text" => "火山豆包语音识别"}
               ]
             }
           }}
      end)

    create_provider!("volc-speech", "volcengine_speech", base_url, %{
      "app_key" => "app-volc-1",
      "access_key" => "tok-volc-1"
    })

    put_profile!("speech", "volc-speech", "seed-tts-2.0", %{
      "voice" => "zh_female_vv_uranus_bigtts"
    })

    speech_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/audio/speech", %{
        "model" => "speech.default",
        "input" => "豆包语音合成",
        "speed" => 1.5
      })

    assert response(speech_conn, 200) == @mp3_chunk_1 <> @mp3_chunk_2
    assert get_resp_header(speech_conn, "content-type") == ["audio/mpeg"]

    assert_receive {:gateway_request, tts_req}
    assert tts_req.headers["x-api-app-key"] == "app-volc-1"
    assert tts_req.headers["x-api-access-key"] == "tok-volc-1"
    assert tts_req.headers["x-api-resource-id"] == "seed-tts-2.0"

    assert tts_req.body == %{
             "user" => %{"uid" => "ankole"},
             "req_params" => %{
               "text" => "豆包语音合成",
               "speaker" => "zh_female_vv_uranus_bigtts",
               "audio_params" => %{
                 "format" => "mp3",
                 "sample_rate" => 24_000,
                 "speech_rate" => 50
               }
             }
           }

    put_profile!("transcription", "volc-speech", "volc.bigasr.auc_turbo")

    asr_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/audio/transcriptions", %{
        "model" => "transcription.default",
        "input_audio" => %{"data" => Base.encode64(@wav_bytes), "format" => "wav"},
        "response_format" => "verbose_json"
      })

    assert json_response(asr_conn, 200) == %{
             "model" => "volc-speech/volc.bigasr.auc_turbo",
             "text" => "火山豆包语音识别",
             "language" => "zh-CN",
             "duration" => 2.6,
             "segments" => [%{"start" => 0.0, "end" => 2.6, "text" => "火山豆包语音识别"}],
             "usage" => %{"seconds" => 2.6}
           }

    assert_receive {:gateway_request, asr_req}
    assert asr_req.headers["x-api-sequence"] == "-1"
    assert asr_req.headers["x-api-resource-id"] == "volc.bigasr.auc_turbo"

    # A Volcengine HTTP 200 response carrying `X-Api-Status-Code: 45000010` maps
    # to 401 and cools down the rejected credential in the pool.
    rejected_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/audio/speech", %{
        "model" => "speech.default",
        "input" => "bad-auth"
      })

    assert rejected_conn.status == 401
    assert_receive {:gateway_request, _rejected_req}
  end

  test "Volcengine Visual signs form-urlencoded OCRNormal and OCRPdf requests with HMAC-SHA256",
       ctx do
    base_url =
      ctx.upstream.(fn request ->
        case request.query_string do
          "Action=OCRNormal&Version=2020-08-26" ->
            {:json, 200,
             %{
               "code" => 10_000,
               "message" => "Success",
               "data" => %{"line_texts" => ["火山智能视觉", "通用文字识别"]}
             }}

          "Action=OCRPdf&Version=2020-08-26" ->
            {:json, 200,
             %{
               "code" => 10_000,
               "message" => "Success",
               "data" => %{
                 "page_infos" => [
                   %{"page_num" => 1, "markdown" => "# 第一页"},
                   %{"page_num" => 2, "markdown" => "第二页内容"}
                 ]
               }
             }}
        end
      end)

    create_provider!(
      "volc-visual",
      "volcengine_visual",
      base_url,
      %{
        "access_key_id" => "AKLTTEST",
        "secret_access_key" => "sk-volc-test"
      },
      %{"region" => "cn-north-1"}
    )

    put_profile!("ocr", "volc-visual", "ocr-normal")

    img_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/ocr", %{
        "model" => "ocr.default",
        "document" => "data:image/png;base64,#{@png_base64}"
      })

    assert json_response(img_conn, 200) == %{
             "model" => "volc-visual/ocr-normal",
             "pages" => [%{"index" => 0, "markdown" => "火山智能视觉\n通用文字识别"}],
             "usage" => %{"pages" => 1}
           }

    assert_receive {:gateway_request, img_req}
    assert img_req.body == %{"image_base64" => @png_base64}
    assert img_req.headers["x-date"] =~ ~r/\A\d{8}T\d{6}Z\z/
    assert img_req.headers["x-content-sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    date = String.slice(img_req.headers["x-date"], 0, 8)

    assert img_req.headers["authorization"] =~
             ~r/\AHMAC-SHA256 Credential=AKLTTEST\/#{date}\/cn-north-1\/cv\/request, SignedHeaders=content-type;host;x-content-sha256;x-date, Signature=[0-9a-f]{64}\z/

    pdf_base64 = Base.encode64(@pdf_bytes)

    pdf_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/ocr", %{
        "model" => "ocr.default",
        "document" => "data:application/pdf;base64,#{pdf_base64}"
      })

    assert json_response(pdf_conn, 200) == %{
             "model" => "volc-visual/ocr-normal",
             "pages" => [
               %{"index" => 0, "markdown" => "# 第一页"},
               %{"index" => 1, "markdown" => "第二页内容"}
             ],
             "usage" => %{"pages" => 2}
           }

    assert_receive {:gateway_request, pdf_req}

    assert pdf_req.body == %{
             "image_base64" => pdf_base64,
             "file_type" => "pdf",
             "version" => "v3"
           }
  end

  test "DeepSeek official serves LLM chat, WAV speech, multipart binary ASR, and multipart binary OCR",
       ctx do
    base_url =
      ctx.upstream.(fn
        %{path: "chat/completions"} ->
          {:json, 200,
           %{
             "id" => "chatcmpl-ds",
             "object" => "chat.completion",
             "model" => "deepseek-chat",
             "choices" => [
               %{
                 "index" => 0,
                 "message" => %{"role" => "assistant", "content" => "DeepSeek ready."},
                 "finish_reason" => "stop"
               }
             ],
             "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 3, "total_tokens" => 8}
           }}

        %{path: "v1/tools/tts"} ->
          {:raw, 200, "audio/wav", @wav_bytes}

        %{path: "v1/tools/asr"} ->
          {:json, 200,
           %{
             "request_id" => "ds_asr_1",
             "text" => "DeepSeek 语音转写",
             "duration_ms" => 3250
           }}

        %{path: "v1/tools/ocr"} ->
          {:json, 200,
           %{
             "id" => "ds_ocr_1",
             "object" => "ocr.result",
             "page_count" => 2,
             "pages" => [
               %{"index" => 0, "text" => "# 合同首页\n\n甲方：Ankole", "finish_reason" => "stop"},
               %{"index" => 1, "text" => "签章页", "finish_reason" => "stop"}
             ]
           }}
      end)

    create_provider!("deepseek-official", "deepseek", base_url, %{"api_key" => "sk-deepseek"})

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(ctx.agent.uid, "primary", %{
               provider_id: "deepseek-official",
               model: "deepseek-chat"
             })

    llm_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "Ping",
        "stream" => false
      })

    llm_body = json_response(llm_conn, 200)
    assert llm_body["status"] == "completed"
    assert_receive {:gateway_request, chat_req}
    assert chat_req.headers["authorization"] == "Bearer sk-deepseek"

    put_profile!("speech", "deepseek-official", "deepseek-tts", %{
      "voice" => "stella",
      "filter_markdown" => true
    })

    # Omitting `response_format` still succeeds because DeepSeek defaults to WAV.
    tts_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/audio/speech", %{
        "model" => "speech.default",
        "input" => "**DeepSeek** 语音合成"
      })

    assert response(tts_conn, 200) == @wav_bytes
    assert get_resp_header(tts_conn, "content-type") == ["audio/wav"]

    assert_receive {:gateway_request, tts_req}

    assert tts_req.body == %{
             "text" => "**DeepSeek** 语音合成",
             "voice_id" => "stella",
             "format" => "wav",
             "filter_markdown" => true
           }

    put_profile!("transcription", "deepseek-official", "deepseek-asr")

    asr_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/audio/transcriptions", %{
        "model" => "transcription.default",
        "input_audio" => %{"data" => Base.encode64(@wav_bytes), "format" => "wav"},
        "response_format" => "verbose_json"
      })

    assert json_response(asr_conn, 200) == %{
             "model" => "deepseek-official/deepseek-asr",
             "text" => "DeepSeek 语音转写",
             "duration" => 3.25,
             "usage" => %{"seconds" => 3.25}
           }

    assert_receive {:gateway_request, %{body: {:multipart, asr_ct, asr_raw}}}
    assert String.starts_with?(asr_ct, "multipart/form-data; boundary=")
    assert :binary.match(asr_raw, "filename=\"audio.wav\"") != :nomatch
    assert :binary.match(asr_raw, @wav_bytes) != :nomatch

    put_profile!("ocr", "deepseek-official", "deepseek-ocr", %{
      "purpose" => "rich_layout_recognition"
    })

    ocr_conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/ocr", %{
        "model" => "ocr.default",
        "document" => "data:application/pdf;base64,#{Base.encode64(@pdf_bytes)}"
      })

    assert json_response(ocr_conn, 200) == %{
             "model" => "deepseek-official/deepseek-ocr",
             "pages" => [
               %{"index" => 0, "markdown" => "# 合同首页\n\n甲方：Ankole"},
               %{"index" => 1, "markdown" => "签章页"}
             ],
             "usage" => %{"pages" => 2}
           }

    assert_receive {:gateway_request, %{body: {:multipart, ocr_ct, ocr_raw}}}
    assert String.starts_with?(ocr_ct, "multipart/form-data; boundary=")

    assert :binary.match(ocr_raw, "name=\"purpose\"\r\n\r\nrich_layout_recognition\r\n") !=
             :nomatch

    assert :binary.match(ocr_raw, @pdf_bytes) != :nomatch
  end
end
