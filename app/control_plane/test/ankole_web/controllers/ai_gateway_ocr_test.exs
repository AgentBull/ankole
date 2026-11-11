defmodule AnkoleWeb.AIGatewayOCRTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AIGateway.Tokens

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  @pdf_base64 Base.encode64("%PDF-1.7 scanned")

  setup %{conn: conn} do
    %{principal: agent} = agent_fixture()
    {:ok, api_key} = Tokens.mint_for_agent(agent.uid)
    test_pid = self()

    # The model answers with the text that the `:ocr_answer` Agent holds.
    base_url =
      start_upstream_server(fn %{path: "v1/responses"} = request ->
        send(test_pid, {:gateway_request, request})
        text = Agent.get(:ocr_answer, & &1)

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
               "content" => [%{"type" => "output_text", "text" => text}]
             }
           ],
           "usage" => %{"input_tokens" => 900, "output_tokens" => 12}
         }}
      end)

    start_supervised!(%{
      id: :ocr_answer,
      start:
        {Agent, :start_link,
         [fn -> "```markdown\n# Invoice\n\nTotal: 42\n```" end, [name: :ocr_answer]]}
    })

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-main",
               provider_kind: "openai",
               base_url: base_url <> "/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{"transport" => %{}}
             })

    %{agent: agent, conn: put_req_header(conn, "authorization", "Bearer #{api_key.api_key}")}
  end

  defp language_model(agent, profile, model) do
    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, profile, %{
               provider_id: "openai-main",
               model: model
             })
  end

  defp ocr(conn, request),
    do: post(conn, ~p"/api/v1/ai-gateway/ocr", Map.put_new(request, "model", "default"))

  test "the primary language model reads the document image as Markdown", ctx do
    language_model(ctx.agent, "primary", "gpt-5.5")
    document = "data:image/png;base64,#{@png_base64}"

    conn = ocr(ctx.conn, %{"model" => "ocr.default", "document" => document})

    # The code fence that the model put around the transcription is gone.
    assert json_response(conn, 200) == %{
             "model" => "openai-main/gpt-5.5",
             "pages" => [%{"index" => 0, "markdown" => "# Invoice\n\nTotal: 42"}],
             "usage" => %{"pages" => 1, "input_tokens" => 900, "output_tokens" => 12}
           }

    assert_receive {:gateway_request, request}
    assert request.body["model"] == "gpt-5.5"

    assert [%{"content" => [%{"type" => "input_image", "image_url" => ^document}]}] =
             request.body["input"]

    assert [%UsageRecord{capability: :llm, input_tokens: 900}] = Ankole.Repo.all(UsageRecord)
  end

  test "the vision fallback model reads the document when it is configured", ctx do
    language_model(ctx.agent, "primary", "gpt-5.5")
    language_model(ctx.agent, "vision_fallback", "gpt-vision")

    conn =
      ocr(ctx.conn, %{"document" => %{"content_type" => "image/png", "base64" => @png_base64}})

    assert %{"model" => "openai-main/gpt-vision"} = json_response(conn, 200)
    assert_receive {:gateway_request, %{body: %{"model" => "gpt-vision"}}}
  end

  test "a page without text is empty, and a reading without any answer fails", ctx do
    language_model(ctx.agent, "primary", "gpt-5.5")
    document = "data:image/png;base64,#{@png_base64}"

    Agent.update(:ocr_answer, fn _text -> "[no text]" end)

    assert %{"pages" => [%{"index" => 0, "markdown" => ""}]} =
             ctx.conn |> ocr(%{"document" => document}) |> json_response(200)

    # Two fences are the document's own, so both stay.
    two_fences = "```\na\n```\ntext\n```\nb\n```"
    Agent.update(:ocr_answer, fn _text -> two_fences end)

    assert %{"pages" => [%{"markdown" => ^two_fences}]} =
             ctx.conn |> ocr(%{"document" => document}) |> json_response(200)

    Agent.update(:ocr_answer, fn _text -> "" end)

    assert %{"error" => %{"code" => "invalid_ocr_output"}} =
             ctx.conn |> ocr(%{"document" => document}) |> json_response(502)
  end

  test "a configured OCR profile sends a PDF and its pages to the OCR model", ctx do
    test_pid = self()

    base_url =
      start_upstream_server(fn %{path: "v1/ocr"} = request ->
        send(test_pid, {:ocr_request, request})

        {:json, 200,
         %{
           "pages" => [
             %{"index" => 3, "markdown" => "", "images" => []},
             %{"index" => 0, "markdown" => "# Invoice", "images" => [], "dimensions" => %{}}
           ],
           "model" => "mistral-ocr-2503-completion",
           "usage_info" => %{"pages_processed" => 2, "doc_size_bytes" => nil}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "mistral-main",
               provider_kind: "mistral",
               base_url: base_url <> "/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-mistral"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_default_model_profile(:tenant, "ocr", %{
               provider_id: "mistral-main",
               model: "mistral-ocr-latest"
             })

    conn =
      ocr(ctx.conn, %{
        "document" => %{"content_type" => "application/pdf", "base64" => @pdf_base64},
        "pages" => [3, 0]
      })

    # The pages come back in page order, and a page without text is empty.
    assert json_response(conn, 200) == %{
             "model" => "mistral-main/mistral-ocr-latest",
             "pages" => [
               %{"index" => 0, "markdown" => "# Invoice"},
               %{"index" => 3, "markdown" => ""}
             ],
             "usage" => %{"pages" => 2}
           }

    assert_receive {:ocr_request, request}
    assert request.headers["authorization"] == "Bearer sk-mistral"

    assert request.body == %{
             "model" => "mistral-ocr-latest",
             "document" => %{
               "type" => "document_url",
               "document_url" => "data:application/pdf;base64,#{@pdf_base64}"
             },
             "pages" => [3, 0]
           }

    assert [row] = Ankole.Repo.all(UsageRecord)
    assert {row.capability, row.unit, row.quantity} == {:ocr, :page, 2}

    assert {row.model, row.provider_model} ==
             {"mistral-main/mistral-ocr-latest", "mistral-ocr-2503-completion"}

    # The provider serves OCR only, so the Agent's model list gains nothing
    # that a Responses request could not use.
    models = ctx.conn |> get(~p"/api/v1/ai-gateway/models") |> json_response(200)
    refute Enum.any?(models["data"], &String.starts_with?(&1["id"], "mistral-main/"))

    # The OCR model also reads an image, which no language model sees.
    conn = ocr(ctx.conn, %{"document" => "data:image/png;base64,#{@png_base64}"})
    assert %{"model" => "mistral-main/mistral-ocr-latest"} = json_response(conn, 200)
    assert_receive {:ocr_request, %{body: %{"document" => %{"type" => "image_url"}}}}
    refute_received {:gateway_request, _request}
  end

  test "without an OCR profile a PDF is rejected, because a language model reads images", ctx do
    language_model(ctx.agent, "primary", "gpt-5.5")

    conn = ocr(ctx.conn, %{"document" => "data:application/pdf;base64,#{@pdf_base64}"})

    assert %{
             "error" => %{
               "param" => "document",
               "code" => "unsupported_value",
               "message" => message
             }
           } =
             json_response(conn, 400)

    assert message =~ "Configure an OCR model"
    refute_received {:gateway_request, _request}
  end

  test "an OCR request names the field that is invalid", ctx do
    language_model(ctx.agent, "primary", "gpt-5.5")
    image = "data:image/png;base64,#{@png_base64}"
    pdf = "data:application/pdf;base64,#{@pdf_base64}"

    for {request, param} <- [
          {%{}, "document"},
          {%{"document" => "data:text/plain;base64,aGVsbG8="}, "document"},
          {%{"document" => "data:image/png;base64,not base64!"}, "document"},
          {%{"document" => image, "pages" => [0]}, "pages"},
          {%{"document" => pdf, "pages" => []}, "pages"},
          {%{"document" => pdf, "pages" => [1, 1]}, "pages"},
          {%{"document" => pdf, "pages" => [-1]}, "pages"},
          {%{"document" => pdf, "pages" => Enum.to_list(0..100)}, "pages"}
        ] do
      assert %{"error" => %{"param" => ^param}} = ctx.conn |> ocr(request) |> json_response(400)
    end

    # `model` is required, so a caller always names what it is allowed to use.
    conn = post(ctx.conn, ~p"/api/v1/ai-gateway/ocr", %{"document" => image})
    assert %{"error" => %{"param" => "model"}} = json_response(conn, 400)

    refute_received {:gateway_request, _request}
  end
end
