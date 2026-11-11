defmodule AnkoleWeb.AIGatewayImagesTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.AIGatewayCase, only: [start_upstream_server: 1]
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Tokens

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  setup %{conn: conn} do
    %{principal: agent} = agent_fixture()
    {:ok, api_key} = Tokens.mint_for_agent(agent.uid)
    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:gateway_request, request})

        case {request.method, request.path} do
          {:post, "accounts/acct-1/ai/run"} ->
            file =
              if request.body["input"]["prompt"] == "A broken link",
                do: "gone.png",
                else: "out.png"

            {:json, 200,
             %{
               "state" => "Completed",
               "result" => %{"image" => "http://#{request.headers["host"]}/files/#{file}"}
             }}

          {:get, "files/out.png"} ->
            {:raw, 200, "image/png", Base.decode64!(@png_base64)}

          {:get, "files/gone.png"} ->
            {:raw, 503, "text/plain", "unavailable"}

          {:post, "accounts/acct-1/ai/run/@cf/black-forest-labs/flux-1-schnell"} ->
            {:json, 200, %{"success" => true, "result" => %{"image" => @png_base64}}}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "cloudflare-main",
               provider_kind: "cloudflare",
               base_url: base_url,
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "cf-token"}]},
               connection_options: %{"account_id" => "acct-1", "transport" => %{}}
             })

    %{agent: agent, conn: put_req_header(conn, "authorization", "Bearer #{api_key.api_key}")}
  end

  defp create(conn, request), do: post(conn, ~p"/api/v1/ai-gateway/images", request)

  test "the image_generate profile edits an image through a Black Forest Labs model", ctx do
    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(ctx.agent.uid, "image_generate", %{
               provider_id: "cloudflare-main",
               model: "black-forest-labs/flux-2-pro-preview",
               provider_options: %{"seed" => 7}
             })

    reference = "data:image/png;base64,#{@png_base64}"

    conn =
      create(ctx.conn, %{
        "model" => "image_generate.default",
        "prompt" => "Make the sky orange",
        "images" => [reference],
        "size" => "1024x768",
        "output_format" => "png"
      })

    assert %{
             "created" => created,
             "data" => [%{"b64_json" => @png_base64, "media_type" => "image/png"}],
             "usage" => %{}
           } = json_response(conn, 200)

    assert is_integer(created)

    assert_receive {:gateway_request, %{method: :post} = request}
    assert request.headers["authorization"] == "Bearer cf-token"

    assert request.body == %{
             "model" => "black-forest-labs/flux-2-pro-preview",
             "input" => %{
               "prompt" => "Make the sky orange",
               "width" => 1024,
               "height" => 768,
               "output_format" => "png",
               "seed" => 7,
               "input_images" => [reference]
             }
           }

    assert_receive {:gateway_request, %{method: :get, path: "files/out.png"} = download}
    refute Map.has_key?(download.headers, "authorization")
  end

  test "a failed image download does not repeat the generation that the provider billed", ctx do
    conn =
      create(ctx.conn, %{
        "model" => "cloudflare-main/black-forest-labs/flux-2-pro-preview",
        "prompt" => "A broken link"
      })

    assert %{"error" => %{"code" => "upstream_error"}} = json_response(conn, 502)

    assert_received {:gateway_request, %{method: :post}}
    assert_received {:gateway_request, %{method: :get, path: "files/gone.png"}}
    # HTTP 503 from the provider itself would send the request once more.
    refute_received {:gateway_request, %{method: :post}}
  end

  test "an explicit selector reaches FLUX.1 [schnell] on Workers AI", ctx do
    conn =
      create(ctx.conn, %{
        "model" => "cloudflare-main/@cf/black-forest-labs/flux-1-schnell",
        "prompt" => "A paper boat",
        "provider_options" => %{"steps" => 6}
      })

    assert %{"data" => [%{"b64_json" => @png_base64, "media_type" => "image/png"}]} =
             json_response(conn, 200)

    assert_receive {:gateway_request, request}
    assert request.body == %{"prompt" => "A paper boat", "steps" => 6}
  end

  test "a request that the image model cannot serve is rejected before the provider call", ctx do
    schnell = "cloudflare-main/@cf/black-forest-labs/flux-1-schnell"

    for {request, code} <- [
          {%{"prompt" => "A paper boat"}, "missing_model"},
          {%{"model" => schnell}, "missing_required_parameter"},
          {%{"model" => schnell, "prompt" => "x", "size" => "512x512"}, "unsupported_value"},
          {%{
             "model" => schnell,
             "prompt" => "x",
             "images" => ["data:image/png;base64,#{@png_base64}"]
           }, "unsupported_value"},
          {%{"model" => "cloudflare-main/recraft/recraftv4", "prompt" => "x"}, "model_not_found"},
          {%{"model" => schnell, "prompt" => "x", "n" => 2}, "unknown_parameter"}
        ] do
      assert %{"error" => %{"code" => ^code}} = json_response(create(ctx.conn, request), 400)
    end

    refute_received {:gateway_request, _request}
  end

  test "an image profile accepts only a model that the provider serves", ctx do
    assert {:error, :image_model_unavailable} =
             ModelProfiles.put_model_profile(ctx.agent.uid, "image_generate", %{
               provider_id: "cloudflare-main",
               model: "recraft/recraftv4"
             })
  end
end
