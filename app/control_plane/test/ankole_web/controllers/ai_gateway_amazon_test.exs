defmodule AnkoleWeb.AIGatewayAmazonTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AIGateway.Tokens

  @mp3 <<0xFF, 0xFB, 0x90, 0x00, 0x01, 0x02>>
  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  setup %{conn: conn} do
    %{principal: agent} = agent_fixture()
    {:ok, api_key} = Tokens.mint_for_agent(agent.uid)
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:aws_request, request})

        case request.path do
          "v1/speech" ->
            {:raw, 200, "audio/mpeg", @mp3}

          "" ->
            {:json, 200,
             %{
               "DocumentMetadata" => %{"Pages" => 1},
               "DetectDocumentTextModelVersion" => "1.0",
               "Blocks" => [
                 %{"BlockType" => "PAGE", "Page" => 1},
                 %{"BlockType" => "LINE", "Page" => 1, "Text" => "Invoice 42"},
                 %{"BlockType" => "WORD", "Page" => 1, "Text" => "Invoice"},
                 %{"BlockType" => "LINE", "Page" => 1, "Text" => "Total: 10"}
               ]
             }}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "aws-main",
               provider_kind: "amazon",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{
                     "label" => "Default",
                     "access_key_id" => "AKIDTEST",
                     "secret_access_key" => "secret-test"
                   }
                 ]
               },
               connection_options: %{"region" => "eu-west-1"}
             })

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key.api_key}")}
  end

  defp profile(slot, model, provider_options \\ %{}) do
    assert {:ok, _profile} =
             ModelProfiles.put_default_model_profile(:tenant, slot, %{
               provider_id: "aws-main",
               model: model,
               provider_options: provider_options
             })
  end

  test "Polly speaks with the profile's voice and receives a signed request", ctx do
    profile("speech", "neural", %{"voice" => "Joanna"})

    conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/audio/speech", %{
        "model" => "speech.default",
        "input" => "Hello, Ankole."
      })

    assert response(conn, 200) == @mp3
    assert get_resp_header(conn, "content-type") == ["audio/mpeg"]

    assert_receive {:aws_request, request}

    assert request.body == %{
             "Engine" => "neural",
             "Text" => "Hello, Ankole.",
             "VoiceId" => "Joanna",
             "OutputFormat" => "mp3"
           }

    # The request carries a Signature Version 4 for Polly in the row's region.
    assert request.headers["x-amz-date"] =~ ~r/\A\d{8}T\d{6}Z\z/
    date = String.slice(request.headers["x-amz-date"], 0, 8)

    assert request.headers["authorization"] =~
             ~r/\AAWS4-HMAC-SHA256 Credential=AKIDTEST\/#{date}\/eu-west-1\/polly\/aws4_request, SignedHeaders=content-type;host;x-amz-date, Signature=[0-9a-f]{64}\z/

    assert [row] = Ankole.Repo.all(UsageRecord)
    assert {row.capability, row.unit, row.quantity} == {:speech, :character, 14}
  end

  test "Polly needs a voice and keeps its own delivery", ctx do
    profile("speech", "neural")

    speak = fn request ->
      ctx.conn
      |> post(~p"/api/v1/ai-gateway/audio/speech", Map.put(request, "model", "default"))
      |> json_response(400)
    end

    assert %{"error" => %{"param" => "voice", "code" => "missing_required_parameter"}} =
             speak.(%{"input" => "Hello."})

    assert %{"error" => %{"param" => "speed", "code" => "unsupported_value"}} =
             speak.(%{"input" => "Hello.", "voice" => "Joanna", "speed" => 1.5})

    refute_received {:aws_request, _request}
  end

  test "Textract reads an image as the lines that it found", ctx do
    profile("ocr", "detect-document-text")

    conn =
      post(ctx.conn, ~p"/api/v1/ai-gateway/ocr", %{
        "model" => "ocr.default",
        "document" => "data:image/png;base64,#{@png_base64}"
      })

    assert json_response(conn, 200) == %{
             "model" => "aws-main/detect-document-text",
             "pages" => [%{"index" => 0, "markdown" => "Invoice 42\nTotal: 10"}],
             "usage" => %{"pages" => 1}
           }

    assert_receive {:aws_request, request}
    assert request.body == %{"Document" => %{"Bytes" => @png_base64}}
    assert request.headers["x-amz-target"] == "Textract.DetectDocumentText"
    assert request.headers["content-type"] == "application/x-amz-json-1.1"

    assert request.headers["authorization"] =~
             ~r/\/eu-west-1\/textract\/aws4_request, SignedHeaders=content-type;host;x-amz-date;x-amz-target, /

    assert [row] = Ankole.Repo.all(UsageRecord)
    assert {row.capability, row.unit, row.quantity} == {:ocr, :page, 1}
  end

  test "Textract takes no WebP image and no page selection", ctx do
    profile("ocr", "detect-document-text")

    ocr = fn request ->
      ctx.conn
      |> post(~p"/api/v1/ai-gateway/ocr", Map.put(request, "model", "default"))
      |> json_response(400)
    end

    assert %{"error" => %{"param" => "document", "code" => "unsupported_value"}} =
             ocr.(%{"document" => "data:image/webp;base64,#{@png_base64}"})

    assert %{"error" => %{"param" => "pages", "code" => "unsupported_value"}} =
             ocr.(%{
               "document" => "data:application/pdf;base64,#{Base.encode64("%PDF-1.7")}",
               "pages" => [0]
             })

    refute_received {:aws_request, _request}
  end
end
