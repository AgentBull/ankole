defmodule Ankole.Pod.AppletAudioTest do
  use Ankole.AIGatewayCase

  alias Ankole.Pod.{Applets.Capabilities, Files, Pages}

  # Not valid UTF-8, as real audio is not.
  @mp3 <<0xFF, 0xFB, 0x90, 0x00, 0x01, 0x02>>
  @png_bytes Base.decode64!(
               "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
             )

  setup do
    owner = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, page} = Pages.create(actor, %{type: "applet", private_owner_uid: owner.uid})
    ctx = %{"applet" => %{"pageId" => page.id, "revision" => 1}, "method" => "POST"}
    %{actor: actor, page: page, call_ctx: ctx}
  end

  defp cloudflare(response_fun) do
    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "cloudflare-main",
        provider_kind: "cloudflare",
        base_url: start_upstream_server(response_fun),
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "cf-token"}]},
        connection_options: %{"account_id" => "acct-1"}
      })
  end

  defp profile(slot, provider_id, model) do
    {:ok, _} =
      ModelProfiles.put_default_model_profile(:tenant, slot, %{
        provider_id: provider_id,
        model: model
      })
  end

  test "ai.generateSpeech saves the audio as a Pod file, and ai.transcribe reads it back",
       %{actor: actor, page: page, call_ctx: ctx} do
    test_pid = self()

    cloudflare(fn
      %{path: "accounts/acct-1/ai/run/@cf/deepgram/aura-1"} = request ->
        send(test_pid, {:speech_request, request.body})
        {:raw, 200, "audio/mpeg", @mp3}

      %{path: "accounts/acct-1/ai/run/@cf/openai/whisper-large-v3-turbo"} = request ->
        send(test_pid, {:transcription_request, request.body})

        {:json, 200,
         %{
           "result" => %{
             "text" => "Hello.",
             "transcription_info" => %{"language" => "en", "duration" => 1.2}
           }
         }}
    end)

    profile("speech", "cloudflare-main", "@cf/deepgram/aura-1")
    profile("transcription", "cloudflare-main", "@cf/openai/whisper-large-v3-turbo")

    # A GET route cannot write, so it cannot save generated audio.
    assert {:error, %{status: 500, code: "read_only_route"}} =
             Capabilities.call(%{ctx | "method" => "GET"}, actor, "ai.generateSpeech", [
               %{"input" => "Hello."}
             ])

    assert {:ok,
            %{
              "mimeType" => "audio/mpeg",
              "file" => %{"path" => path, "name" => "greeting.mp3", "size" => 6}
            }} =
             Capabilities.call(ctx, actor, "ai.generateSpeech", [
               %{
                 "input" => "Hello.",
                 "voice" => "luna",
                 "saveTo" => %{"pageId" => page.id, "name" => "greeting"}
               }
             ])

    assert_receive {:speech_request, %{"text" => "Hello.", "speaker" => "luna"}}

    assert {:ok, %{"model" => _model, "text" => "Hello.", "usage" => %{"seconds" => 1.2}} = brief} =
             Capabilities.call(%{ctx | "method" => "GET"}, actor, "ai.transcribe", [
               %{"audio" => path, "language" => "en"}
             ])

    refute Map.has_key?(brief, "language")
    assert_receive {:transcription_request, %{"audio" => audio, "language" => "en"}}
    assert Base.decode64!(audio) == @mp3

    assert {:ok, %{"language" => "en", "duration" => 1.2}} =
             Capabilities.call(ctx, actor, "ai.transcribe", [
               %{"audio" => path, "verbose" => true}
             ])

    # The speech model accepts no delivery instructions, and says so.
    assert {:error, %{status: 400, code: "invalid_request", message: message}} =
             Capabilities.call(ctx, actor, "ai.generateSpeech", [
               %{"input" => "Hello.", "instructions" => "Whisper."}
             ])

    assert message =~ "instructions"

    assert {:error, %{status: 400, code: "invalid_request"}} =
             Capabilities.call(ctx, actor, "ai.transcribe", [%{"audio" => path, "model" => "x"}])
  end

  test "ai.ocr reads a Pod image through the Pod language model",
       %{actor: actor, call_ctx: ctx} do
    test_pid = self()

    base_url =
      start_upstream_server(fn %{path: "v1/responses"} = request ->
        send(test_pid, {:ocr_request, request.body})

        {:json, 200,
         %{
           "id" => "resp_ocr",
           "object" => "response",
           "status" => "completed",
           "output" => [
             %{
               "id" => "msg_1",
               "type" => "message",
               "role" => "assistant",
               "content" => [%{"type" => "output_text", "text" => "# Invoice"}]
             }
           ],
           "usage" => %{"input_tokens" => 900, "output_tokens" => 4}
         }}
      end)

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "openai-main",
        provider_kind: "openai",
        base_url: base_url <> "/v1",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]},
        connection_options: %{"transport" => %{}}
      })

    profile("primary", "openai-main", "gpt-5.5")

    owner_uid = actor.principal.uid
    {:ok, doc} = Pages.create(actor, %{type: "doc", private_owner_uid: owner_uid})
    {:ok, scan} = Files.upload(actor, doc.id, "asset", nil, "scan.png", @png_bytes, "image/png")

    assert {:ok,
            %{
              "model" => "openai-main/gpt-5.5",
              "pages" => [%{"index" => 0, "markdown" => "# Invoice"}],
              "usage" => %{"pages" => 1, "inputTokens" => 900, "outputTokens" => 4}
            }} =
             Capabilities.call(%{ctx | "method" => "GET"}, actor, "ai.ocr", [
               %{"image" => "pages/#{doc.id}/#{scan.file.path}"}
             ])

    assert_receive {:ocr_request, %{"model" => "gpt-5.5"}}

    # Binding an OCR model changes who reads the image, not the shape of the
    # result: the tokens are 0 and the pages are the model's count.
    mistral_url =
      start_upstream_server(fn %{path: "v1/ocr"} ->
        {:json, 200,
         %{
           "pages" => [%{"index" => 0, "markdown" => "# Invoice", "images" => []}],
           "model" => "mistral-ocr-latest",
           "usage_info" => %{"pages_processed" => 1}
         }}
      end)

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "mistral-main",
        provider_kind: "mistral",
        base_url: mistral_url <> "/v1",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-mistral"}]}
      })

    profile("ocr", "mistral-main", "mistral-ocr-latest")

    assert {:ok,
            %{
              "model" => "mistral-main/mistral-ocr-latest",
              "pages" => [%{"index" => 0, "markdown" => "# Invoice"}],
              "usage" => %{"pages" => 1, "inputTokens" => 0, "outputTokens" => 0}
            }} =
             Capabilities.call(%{ctx | "method" => "GET"}, actor, "ai.ocr", [
               %{"image" => "pages/#{doc.id}/#{scan.file.path}"}
             ])

    refute_received {:ocr_request, _body}
  end
end
