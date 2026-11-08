defmodule Ankole.Pod.AppletWebAndImageTest do
  use Ankole.AIGatewayCase

  alias Ankole.Files, as: Drive
  alias Ankole.Pod.{Applets.Capabilities, Files, Pages}

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  @png_bytes Base.decode64!(@png_base64)

  test "web.search and admin.web.search resolve caller vs owner authority and normalize results" do
    owner = human_fixture().principal
    viewer = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: owner.uid}).principal

    {:ok, parent} = Pages.create(actor_fixture(owner), %{private_owner_uid: owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, parent.id, %{
        grants: [
          %{principal_uid: agent.uid, role: "edit"},
          %{principal_uid: viewer.uid, role: "view"}
        ]
      })

    {:ok, page} = Pages.create(actor_fixture(agent), %{type: "applet", parent_id: parent.id})
    assert page.owner_uid == agent.uid

    base_url =
      start_upstream_server(fn
        %{path: "web-search/v1/search", headers: %{"authorization" => "Bearer sk-system-search"}} ->
          {:json, 200,
           %{
             "query" => "caller query",
             "sources" => ["exa"],
             "items" => [
               %{
                 "title" => "Caller Hit",
                 "url" => "https://example.com/caller",
                 "snippet" => "Caller search result"
               }
             ]
           }}

        %{path: "web-search/v1/search", headers: %{"authorization" => "Bearer sk-agent-search"}} ->
          {:json, 200,
           %{
             "query" => "owner query",
             "sources" => ["exa"],
             "items" => [
               %{
                 "title" => "Owner Hit",
                 "url" => "https://example.com/owner",
                 "snippet" => "Owner search result"
               }
             ]
           }}
      end)

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "sys-search",
        provider_kind: "agentbull_cloud",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Sys", "api_key" => "sk-system-search"}]}
      })

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "agent-search",
        provider_kind: "agentbull_cloud",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Agent", "api_key" => "sk-agent-search"}]}
      })

    {:ok, _} =
      ModelProfiles.put_default_provider_hosted_capabilities(:tenant, %{"web_search" => false})

    {:ok, _} =
      ModelProfiles.put_default_model_profile(:tenant, "web_search", %{
        provider_id: "sys-search",
        model: "default"
      })

    {:ok, _} = ModelProfiles.put_provider_hosted_capabilities(agent.uid, %{"web_search" => false})

    {:ok, _} =
      ModelProfiles.put_model_profile(agent.uid, "web_search", %{
        provider_id: "agent-search",
        model: "default"
      })

    ctx = %{"applet" => %{"pageId" => page.id, "revision" => 1}, "method" => "GET"}

    assert {:ok,
            %{
              "query" => "caller query",
              "results" => [
                %{
                  "title" => "Caller Hit",
                  "url" => "https://example.com/caller",
                  "snippet" => "Caller search result",
                  "position" => 1
                }
              ]
            }} =
             Capabilities.call(ctx, actor_fixture(viewer), "web.search", [
               %{"query" => "caller query", "limit" => 3}
             ])

    assert {:ok,
            %{
              "query" => "owner query",
              "results" => [
                %{
                  "title" => "Owner Hit",
                  "url" => "https://example.com/owner",
                  "snippet" => "Owner search result",
                  "position" => 1
                }
              ]
            }} =
             Capabilities.call(ctx, actor_fixture(viewer), "admin.web.search", [
               %{"query" => "owner query", "limit" => 3}
             ])

    assert {:error, %{status: 400, code: "invalid_request"}} =
             Capabilities.call(ctx, actor_fixture(viewer), "web.search", [%{"query" => "   "}])
  end

  test "web.fetch allocates maxChars via water-filling, reports renderWarning, and rejects invalid URLs" do
    owner = human_fixture().principal

    {:ok, page} =
      Pages.create(actor_fixture(owner), %{type: "applet", private_owner_uid: owner.uid})

    short_text = "Short note."

    long_text =
      Enum.join(
        [
          "HEADER: Q4 Financial Overview",
          "SECTION 1: Operating Metrics",
          Enum.map_join(1..25, "\n", &"Row #{&1}: intermediate commentary and segment breakdown"),
          "SUMMARY: Operating margin expanded by 310 bps",
          "CONCLUSION: Approved for publication"
        ],
        "\n"
      )

    js_shell = "Please enable JavaScript to view this application."

    base_url =
      start_upstream_server(fn request ->
        case request.body["url"] do
          "https://example.com/short" ->
            {:json, 200,
             %{
               "data" => %{
                 "url" => "https://example.com/short",
                 "title" => "Short",
                 "content" => short_text
               }
             }}

          "https://example.com/long" ->
            {:json, 200,
             %{
               "data" => %{
                 "url" => "https://example.com/long",
                 "title" => "Long",
                 "content" => long_text
               }
             }}

          "https://example.com/shell" ->
            {:json, 200,
             %{
               "data" => %{
                 "url" => "https://example.com/shell",
                 "title" => "SPA",
                 "content" => js_shell
               }
             }}
        end
      end)

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "applet-jina",
        provider_kind: "jina_reader",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Jina", "api_key" => "jina-key"}]},
        connection_options: %{"transport" => %{}}
      })

    {:ok, _} =
      ModelProfiles.put_default_model_profile(:tenant, "web_fetch", %{
        provider_id: "applet-jina",
        model: "default"
      })

    ctx = %{"applet" => %{"pageId" => page.id, "revision" => 1}, "method" => "GET"}
    actor = actor_fixture(owner)

    # Budget = 300 chars across 3 URLs:
    # short (11) + shell (50) fit inside initial 100-char equal share, leaving 239 chars for long -> head + tail line-boundary slice!
    assert {:ok,
            %{
              "success" => true,
              "results" => [short_res, long_res, shell_res]
            }} =
             Capabilities.call(ctx, actor, "web.fetch", [
               %{
                 "urls" => [
                   "https://example.com/short",
                   "https://example.com/long",
                   "https://example.com/shell"
                 ],
                 "maxChars" => 300
               }
             ])

    assert short_res["text"] == short_text
    assert short_res["truncated"] == false
    refute Map.has_key?(short_res, "renderWarning")

    allocated_long = 300 - String.length(short_text) - String.length(js_shell)
    assert String.length(long_res["text"]) <= allocated_long
    assert long_res["truncated"] == true

    assert String.starts_with?(
             long_res["text"],
             "HEADER: Q4 Financial Overview\nSECTION 1: Operating Metrics"
           )

    assert String.contains?(long_res["text"], "\n...\n")

    assert String.ends_with?(
             long_res["text"],
             "SUMMARY: Operating margin expanded by 310 bps\nCONCLUSION: Approved for publication"
           )

    assert shell_res["text"] == js_shell
    assert shell_res["truncated"] == false
    assert shell_res["renderWarning"] == "script_shell"

    # Reject non-HTTPS and >5 URLs
    assert {:error, %{status: 400, code: "invalid_request"}} =
             Capabilities.call(ctx, actor, "web.fetch", [
               %{"urls" => ["http://example.com/plain"]}
             ])

    assert {:error, %{status: 400, code: "invalid_request"}} =
             Capabilities.call(ctx, actor, "web.fetch", [
               %{"urls" => Enum.map(1..6, &"https://example.com/#{&1}")}
             ])
  end

  test "ai.generateImage writes Applet assets readable by viewers, preserves them across code re-publish, supports saveTo, and enforces GET guard" do
    owner = human_fixture().principal
    viewer = human_fixture().principal
    contributor = human_fixture().principal
    outsider = human_fixture().principal
    owner_actor = actor_fixture(owner)

    {:ok, applet_page} =
      Pages.create(owner_actor, %{type: "applet", private_owner_uid: owner.uid})

    {:ok, base_page} = Pages.create(owner_actor, %{type: "base", private_owner_uid: owner.uid})
    {:ok, doc_page} = Pages.create(owner_actor, %{type: "doc", private_owner_uid: owner.uid})

    {:ok, secret_doc} =
      Pages.create(actor_fixture(outsider), %{type: "doc", private_owner_uid: outsider.uid})

    {:ok, secret_asset} =
      Files.upload(
        actor_fixture(outsider),
        secret_doc.id,
        "asset",
        nil,
        "ref.png",
        @png_bytes,
        "image/png"
      )

    {:ok, shared_asset} =
      Files.upload(owner_actor, doc_page.id, "asset", nil, "source.png", @png_bytes, "image/png")

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, applet_page.id, %{
        grants: [
          %{principal_uid: viewer.uid, role: "view"},
          %{principal_uid: contributor.uid, role: "contribute"}
        ]
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, base_page.id, %{
        grants: [%{principal_uid: contributor.uid, role: "contribute"}]
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, doc_page.id, %{
        grants: [
          %{principal_uid: viewer.uid, role: "view"},
          %{principal_uid: contributor.uid, role: "contribute"}
        ]
      })

    test_pid = self()

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:applet_img_upstream, request.body})

        {:json, 200,
         %{
           "id" => "resp_applet_img",
           "object" => "response",
           "status" => "completed",
           "output" => [
             %{
               "id" => "ig_applet_1",
               "type" => "image_generation_call",
               "status" => "completed",
               "result" => @png_base64,
               "mime_type" => "image/png",
               "revised_prompt" => "Polished poster"
             }
           ],
           "usage" => %{"input_tokens" => 11, "output_tokens" => 5, "total_tokens" => 16}
         }}
      end)

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "applet-img-openai",
        provider_kind: "openai",
        base_url: base_url <> "/v1",
        credential_pool: %{"entries" => [%{"label" => "Main", "api_key" => "sk-img"}]},
        connection_options: %{"transport" => %{}}
      })

    {:ok, _} =
      ModelProfiles.put_default_model_profile(:tenant, "primary", %{
        provider_id: "applet-img-openai",
        model: "gpt-5"
      })

    get_ctx = %{"applet" => %{"pageId" => applet_page.id, "revision" => 1}, "method" => "GET"}
    post_ctx = %{"applet" => %{"pageId" => applet_page.id, "revision" => 1}, "method" => "POST"}

    # 1. GET route guard rejects ai.generateImage before calling AIGateway
    assert {:error, %{status: 500, code: "read_only_route"}} =
             Capabilities.call(get_ctx, actor_fixture(viewer), "ai.generateImage", [
               %{"prompt" => "Poster"}
             ])

    refute_receive {:applet_img_upstream, _}

    # 2. Viewer on POST route generates default asset on Applet Page + passes authorized input image
    shared_ref_path = "pages/#{doc_page.id}/#{shared_asset.file.path}"

    assert {:ok,
            %{
              "url" => asset_url,
              "mimeType" => "image/png",
              "revisedPrompt" => "Polished poster",
              "file" => %{
                "path" => asset_full_path,
                "pageId" => page_id,
                "name" => "generated.png",
                "mime" => "image/png",
                "size" => size
              },
              "usage" => %{"inputTokens" => 11, "outputTokens" => 5, "totalTokens" => 16}
            }} =
             Capabilities.call(post_ctx, actor_fixture(viewer), "ai.generateImage", [
               %{
                 "prompt" => "Edit into a poster",
                 "action" => "edit",
                 "images" => [shared_ref_path]
               }
             ])

    assert page_id == applet_page.id
    assert size == byte_size(@png_bytes)

    assert String.starts_with?(
             asset_url,
             "/api/v2/pod/pages/#{applet_page.id}/files/content?path=assets%2F"
           )

    assert_receive {:applet_img_upstream, upstream_body}
    [user_msg] = upstream_body["input"]
    assert Enum.any?(user_msg["content"], &(&1["type"] == "input_image"))

    # Viewer can read the generated asset, and re-publishing Applet code preserves assets/!
    "pages/" <> rest = asset_full_path
    [_id, rel_asset_path] = String.split(rest, "/", parts: 2)

    assert {:ok, _, @png_bytes} =
             Files.read(actor_fixture(viewer), applet_page.id, rel_asset_path)

    manifest =
      for {path, content} <- [
            {"src/main.tsx", "export default null"},
            {"dist/index.html", "<div/>"}
          ] do
        {:ok, stored} = Drive.store(content)
        source_path = "pub/#{path}"

        {:ok, _} =
          Drive.commit(owner.uid, [Map.merge(stored, %{path: source_path, source: "agent"})])

        %{path: path, object_id: stored.object_id, source_path: source_path}
      end

    assert {:ok, %{revision: 1}} = Files.publish(owner_actor, applet_page.id, 0, manifest)

    assert {:ok, _, @png_bytes} =
             Files.read(actor_fixture(viewer), applet_page.id, rel_asset_path)

    # 3. Unauthorized input image reference returns 403 forbidden
    secret_ref_path = "pages/#{secret_doc.id}/#{secret_asset.file.path}"

    assert {:error, %{status: 403, code: "forbidden"}} =
             Capabilities.call(post_ctx, actor_fixture(viewer), "ai.generateImage", [
               %{"prompt" => "Steal image", "images" => [secret_ref_path]}
             ])

    # 4. saveTo Base attachment works for contributor, while saveTo Doc asset requires node_edit
    assert {:ok,
            %{
              "file" => %{
                "pageId" => saved_base_id,
                "name" => "hero.png",
                "mime" => "image/png"
              }
            }} =
             Capabilities.call(post_ctx, actor_fixture(contributor), "ai.generateImage", [
               %{
                 "prompt" => "Record hero",
                 "saveTo" => %{"pageId" => base_page.id, "name" => "hero"}
               }
             ])

    assert saved_base_id == base_page.id

    assert {:error, %{status: 403, code: "forbidden"}} =
             Capabilities.call(post_ctx, actor_fixture(contributor), "ai.generateImage", [
               %{
                 "prompt" => "Doc banner",
                 "saveTo" => %{"pageId" => doc_page.id, "name" => "banner"}
               }
             ])

    # 5. Explicit saveTo Applet Page succeeds for node_edit and rejects viewer/contributor without node_edit
    assert {:error, %{status: 403, code: "forbidden"}} =
             Capabilities.call(post_ctx, actor_fixture(contributor), "ai.generateImage", [
               %{
                 "prompt" => "Unauthorized explicit Applet asset",
                 "saveTo" => %{"pageId" => applet_page.id, "name" => "custom-banner"}
               }
             ])

    assert {:ok,
            %{
              "file" => %{
                "pageId" => saved_applet_id,
                "name" => "custom-banner.png",
                "path" => saved_applet_path,
                "mime" => "image/png"
              }
            }} =
             Capabilities.call(post_ctx, owner_actor, "ai.generateImage", [
               %{
                 "prompt" => "Authorized explicit Applet asset",
                 "saveTo" => %{"pageId" => applet_page.id, "name" => "custom-banner"}
               }
             ])

    assert saved_applet_id == applet_page.id
    assert String.starts_with?(saved_applet_path, "pages/#{applet_page.id}/assets/")
    assert String.ends_with?(saved_applet_path, "/custom-banner.png")
  end

  test "pinning authentication_ref onto generateImage result.url preserves private Applet image reads when another tab switches the browser default account",
       %{tenant: tenant} do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    owner = human_fixture(%{display_name: "Tab A Owner"}).principal
    outsider = human_fixture(%{display_name: "Tab B Outsider"}).principal
    owner_actor = actor_fixture(owner)

    {:ok, applet_page} =
      Pages.create(owner_actor, %{type: "applet", private_owner_uid: owner.uid})

    base_url =
      start_upstream_server(fn _request ->
        {:json, 200,
         %{
           "id" => "resp_tab_auth_img",
           "object" => "response",
           "status" => "completed",
           "output" => [
             %{
               "id" => "ig_tab_auth_1",
               "type" => "image_generation_call",
               "status" => "completed",
               "result" => @png_base64,
               "mime_type" => "image/png"
             }
           ],
           "usage" => %{"input_tokens" => 5, "output_tokens" => 5, "total_tokens" => 10}
         }}
      end)

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "tab-auth-img-openai",
        provider_kind: "openai",
        base_url: base_url <> "/v1",
        credential_pool: %{"entries" => [%{"label" => "Main", "api_key" => "sk-img"}]},
        connection_options: %{"transport" => %{}}
      })

    {:ok, _} =
      ModelProfiles.put_default_model_profile(:tenant, "primary", %{
        provider_id: "tab-auth-img-openai",
        model: "gpt-5"
      })

    post_ctx = %{"applet" => %{"pageId" => applet_page.id, "revision" => 1}, "method" => "POST"}

    assert {:ok, %{"url" => bare_url}} =
             Capabilities.call(post_ctx, owner_actor, "ai.generateImage", [
               %{"prompt" => "Private workspace diagram"}
             ])

    refute bare_url =~ "authentication_ref="

    source = """
    export default {
      'POST /generate': async (req) => ({
        generated: await AnkoleRuntime.ai.generateImage({ prompt: req.body.prompt }),
        original: `/api/v2/pod/pages/${req.applet.pageId}/files/content?path=assets%2Fa.png`
      })
    }
    """

    manifest =
      for {path, content} <- [
            {"src/main.tsx", "export default null"},
            {"dist/index.html", "<div/>"},
            {"server/main.js", source}
          ] do
        {:ok, stored} = Drive.store(content)
        source_path = "pub-tab-auth/#{path}"

        {:ok, _} =
          Drive.commit(owner.uid, [Map.merge(stored, %{path: source_path, source: "agent"})])

        %{path: path, object_id: stored.object_id, source_path: source_path}
      end

    assert {:ok, %{revision: published_revision}} =
             Files.publish(owner_actor, applet_page.id, applet_page.revision, manifest)

    shared =
      AnkoleWeb.ConnCase.build_conn()
      |> AnkoleWeb.ConnCase.pod_conn(tenant)
      |> Plug.Test.init_test_session(%{})
      |> AnkoleWeb.Session.ensure_browser()

    browser_ref = AnkoleWeb.Session.browser_reference(shared)

    {:ok, %{browser: browser, authentication: auth_owner}} =
      Ankole.BrowserSessions.authenticate(browser_ref, %{
        "principal_uid" => owner.uid,
        "access_version" => owner.access_version,
        "provider_id" => "lark-main",
        "external_id" => "tab-a-owner"
      })

    owner_conn =
      shared
      |> AnkoleWeb.Session.put_authentication(browser, auth_owner)
      |> Phoenix.ConnTest.dispatch(AnkoleWeb.Endpoint, :get, "/api/v2/browser/session")

    owner_ref =
      shared
      |> AnkoleWeb.Session.put_authentication(browser, auth_owner)
      |> AnkoleWeb.Session.authentication_reference()
      |> Ankole.BrowserSessions.encode_reference()

    csrf = Plug.CSRFProtection.get_csrf_token()

    route_resp =
      owner_conn
      |> AnkoleWeb.ConnCase.recycle()
      |> AnkoleWeb.ConnCase.pod_conn(tenant)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-csrf-token", csrf)
      |> Plug.Conn.put_req_header("x-ankole-authentication", owner_ref)
      |> Plug.Conn.put_req_header(
        "x-ankole-applet-revision",
        Integer.to_string(published_revision)
      )
      |> Phoenix.ConnTest.dispatch(
        AnkoleWeb.Endpoint,
        :post,
        "/api/v2/pod/pages/#{applet_page.id}/routes/generate",
        Jason.encode!(%{"prompt" => "Tab-pinned poster"})
      )

    assert %{
             "generated" => %{
               "url" => route_url,
               "file" => %{"path" => route_file_path}
             },
             "original" => raw_business_string
           } = Phoenix.ConnTest.json_response(route_resp, 200)

    assert route_url =~ "authentication_ref=" <> URI.encode_www_form(owner_ref)
    refute route_file_path =~ "authentication_ref="

    assert raw_business_string ==
             "/api/v2/pod/pages/#{applet_page.id}/files/content?path=assets%2Fa.png"

    {:ok, %{browser: browser, authentication: auth_outsider}} =
      Ankole.BrowserSessions.authenticate(browser_ref, %{
        "principal_uid" => outsider.uid,
        "access_version" => outsider.access_version,
        "provider_id" => "lark-main",
        "external_id" => "tab-b-outsider"
      })

    # Another tab in the same browser activates `outsider` as the default session account
    switched_browser =
      owner_conn
      |> AnkoleWeb.ConnCase.recycle()
      |> AnkoleWeb.ConnCase.pod_conn(tenant)
      |> Plug.Test.init_test_session(Plug.Conn.get_session(owner_conn))
      |> AnkoleWeb.Session.put_authentication(browser, auth_outsider)
      |> Phoenix.ConnTest.dispatch(AnkoleWeb.Endpoint, :get, "/api/v2/browser/session")
      |> AnkoleWeb.ConnCase.recycle()
      |> AnkoleWeb.ConnCase.pod_conn(tenant)

    denied =
      Phoenix.ConnTest.dispatch(switched_browser, AnkoleWeb.Endpoint, :get, bare_url)

    assert denied.status in [403, 404]

    pinned =
      switched_browser
      |> AnkoleWeb.ConnCase.recycle()
      |> AnkoleWeb.ConnCase.pod_conn(tenant)
      |> Phoenix.ConnTest.dispatch(AnkoleWeb.Endpoint, :get, route_url)

    assert pinned.status == 200
    assert pinned.resp_body == @png_bytes
  end
end
