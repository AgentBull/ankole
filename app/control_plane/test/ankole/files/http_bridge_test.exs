defmodule Ankole.Files.HTTPBridgeTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Files.HTTP
  alias Ankole.Pod.{Files, Pages}

  defmodule GatewayHTTP do
    use Plug.Builder
    plug Plug.Parsers, parsers: [:json], json_decoder: Torque
    plug AnkoleWeb.Router
  end

  defmodule Upstream do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      case conn.request_path do
        "/unicode" ->
          conn = send_chunked(conn, 200)
          bytes = ~s({"text":"汉字"})
          <<first::binary-size(10), rest::binary>> = bytes
          {:ok, conn} = chunk(conn, first)
          {:ok, conn} = chunk(conn, rest)
          conn

        path when path in ["/gzip", "/deflate", "/gzip-large"] ->
          bytes =
            if path == "/gzip-large",
              do: Torque.encode!(%{text: String.duplicate("x", 5_000_001)}),
              else: ~s({"text":"汉字"})

          {encoding, bytes} =
            if path == "/deflate",
              do: {"deflate", :zlib.compress(bytes)},
              else: {"gzip", :zlib.gzip(bytes)}

          conn |> put_resp_header("content-encoding", encoding) |> send_resp(200, bytes)

        "/large" ->
          send_resp(conn, 200, String.duplicate("x", 5_000_001))

        "/download" ->
          conn = send_chunked(conn, 200)

          Enum.reduce(1..17, conn, fn _, conn ->
            {:ok, conn} = chunk(conn, :binary.copy(<<65>>, 1024 * 1024))
            conn
          end)

        "/upload" ->
          {conn, count, digest} = body(conn, 0, :crypto.hash_init(:sha256))
          send(owner, {:uploaded, count, Base.encode16(:crypto.hash_final(digest), case: :lower)})
          send_resp(conn, 200, "{}")

        "/lost" ->
          {:ok, _, conn} = read_body(conn)
          send(owner, :write_received)
          Process.sleep(150)
          send_resp(conn, 200, "{}")

        _ ->
          mcp(conn, owner)
      end
    end

    defp body(conn, count, hash) do
      case read_body(conn, length: 1024 * 1024) do
        {:more, bytes, conn} ->
          body(conn, count + byte_size(bytes), :crypto.hash_update(hash, bytes))

        {:ok, bytes, conn} ->
          {conn, count + byte_size(bytes), :crypto.hash_update(hash, bytes)}
      end
    end

    defp mcp(conn, owner) do
      {:ok, bytes, conn} = read_body(conn)
      request = Torque.decode!(bytes)
      send(owner, {:rpc, request["method"], get_req_header(conn, "mcp-protocol-version")})

      if conn.request_path == "/legacy" and
           get_req_header(conn, "mcp-protocol-version") == ["2026-07-28"] do
        send_resp(conn, 400, "Initialize first")
      else
        result =
          case request["method"] do
            "initialize" ->
              %{"protocolVersion" => "2025-11-25", "capabilities" => %{}}

            "notifications/initialized" ->
              nil

            "tools/list" ->
              %{
                "tools" =>
                  Enum.map(["read", "write"], fn name ->
                    %{
                      "name" => name,
                      "inputSchema" => %{"type" => "object"},
                      "annotations" => %{"readOnlyHint" => name == "read"},
                      "outputSchema" => %{
                        "type" => "object",
                        "properties" => %{"id" => %{"type" => "integer", "format" => "int64"}}
                      }
                    }
                  end)
              }

            "tools/call" ->
              %{"content" => [], "structuredContent" => %{"id" => 9_223_372_036_854_775_807}}
          end

        if result,
          do:
            send_resp(
              conn,
              200,
              Torque.encode!(%{jsonrpc: "2.0", id: request["id"], result: result})
            ),
          else: send_resp(conn, 202, "")
      end
    end
  end

  setup do
    server = start_supervised!({Bandit, plug: {Upstream, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}", actor: actor_fixture(human_fixture().principal.uid)}
  end

  test "JSON limits count bytes and UTF-8 is decoded only after the complete response", %{
    url: url
  } do
    assert {:ok, %{body: %{"text" => "汉字"}}} =
             HTTP.json("GET", url <> "/unicode", [], %{}, idempotent: true)

    assert {:error, %{reason: ":json_too_large"}} =
             HTTP.request("GET", url <> "/large", [], nil, idempotent: true)

    assert {:error, %{code: :json_too_large}} =
             HTTP.json("POST", url, [], %{text: String.duplicate("汉", 1_700_000)})

    assert {:error, %{code: "upstream_outcome_unknown", retryable: false, request_sent: true}} =
             HTTP.json("POST", url <> "/lost", [], %{}, timeout: 20)

    assert_receive :write_received
    refute_receive :write_received
  end

  test "compressed JSON is decoded with the same byte limit and invalid URLs return an error",
       ctx do
    for path <- ["/gzip", "/deflate"] do
      assert {:ok, %{body: %{"text" => "汉字"}}} =
               HTTP.json("GET", ctx.url <> path, [], %{}, idempotent: true)
    end

    assert {:error, %{reason: ":json_too_large"}} =
             HTTP.json("GET", ctx.url <> "/gzip-large", [], %{}, idempotent: true)

    for url <- ["file:///tmp/data", "https:///missing-host", "relative/path"] do
      assert {:error, %{reason: ":invalid_url", retryable: false, request_sent: false}} =
               HTTP.json("GET", url, [], %{})
    end
  end

  test "17 MiB transfers stream through immutable objects without a database transaction", ctx do
    {:ok, page} = Pages.create(ctx.actor, %{type: "file"})

    assert {:ok, downloaded} =
             Ankole.Files.download_http(ctx.actor, ctx.url <> "/download", [], %{
               page_id: page.id,
               role: "file",
               name: "payload.bin",
               content_type: "application/octet-stream"
             })

    assert downloaded.file.size == 17 * 1024 * 1024
    path = "pages/#{page.id}/#{downloaded.file.path}"

    assert {:ok, %{status: 200}} =
             Ankole.Files.upload_http(ctx.actor, path, "POST", ctx.url <> "/upload", [],
               idempotent: true
             )

    assert_receive {:uploaded, size, digest}
    assert size == downloaded.file.size and digest == downloaded.file.sha256
    assert {:ok, _} = Files.manifest(ctx.actor, page.id)
  end

  test "Skill MCP declarations use stateless POST, legacy discovery and server annotations",
       ctx do
    gateway =
      start_supervised!({Bandit, plug: GatewayHTTP, ip: {0, 0, 0, 0}, port: 0}, id: :gateway)

    {:ok, {_, port}} = ThousandIsland.listener_info(gateway)
    origin = Application.get_env(:ankole, :runtime_fabric_internal_origin)

    Application.put_env(
      :ankole,
      :runtime_fabric_internal_origin,
      "http://host.docker.internal:#{port}"
    )

    on_exit(fn -> Application.put_env(:ankole, :runtime_fabric_internal_origin, origin) end)
    agent = agent_fixture().principal
    actor = actor_fixture(agent.uid)

    for mode <- ["modern", "legacy"] do
      metadata =
        "dependencies:\n  tools:\n    - type: mcp\n      value: demo\n      transport: streamable_http\n      url: #{ctx.url}/#{mode}\n"

      {:ok, blob} = Ankole.Files.store(metadata)

      {:ok, _} =
        Ankole.Files.commit(agent.uid, [Map.merge(blob, %{path: "mcp/#{mode}", source: "agent"})])

      {:ok, _} =
        Repo.transact_top_level(fn ->
          {:ok, skill} =
            Ankole.Ash.create(Ankole.AIAgent.Library.Schemas.Skill, :create, %{
              slug: mode,
              name: mode,
              description: "HTTP fixture",
              source_kind: :custom,
              enabled_for_all: true,
              manifest_xml: "<p>Use the test server.</p>",
              manifest_markdown: "Use the test server."
            })

          Ankole.Ash.create(Ankole.AIAgent.Library.Schemas.SkillFile, :put, %{
            skill_id: skill.id,
            relative_path: "agents/openai.yaml",
            object_id: blob.object_id,
            content_type: "application/yaml"
          })
        end)

      {:ok, page} = Pages.create(ctx.actor, %{type: "applet"})

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.actor.principal.uid, page.id, %{
          grants: [%{principal_uid: actor.principal.uid, role: "view"}]
        })

      Ankole.FilesFixtures.publish_applet_fixture(%{actor: ctx.actor, page: page}, """
      export default {'POST /':async()=>{
        const options={skill:'#{mode}',server:'demo'};
        await AnkoleRuntime.mcp.call('read',{},options);
        return AnkoleRuntime.mcp.call('read',{},options);
      }}
      """)

      version = if mode == "legacy", do: "2025-11-25", else: "2026-07-28"

      for iteration <- 1..2 do
        assert {:ok,
                %{
                  "status" => 200,
                  "body" => %{"id" => "9223372036854775807"}
                }} =
                 Ankole.Pod.Applets.call(actor, page.id, %{
                   "method" => "POST",
                   "path" => "/",
                   "query" => %{}
                 })

        if iteration == 1 do
          if mode == "legacy" do
            assert_receive {:rpc, "tools/list", ["2026-07-28"]}
            assert_receive {:rpc, "initialize", [^version]}
            assert_receive {:rpc, "notifications/initialized", [^version]}
          end

          assert_receive {:rpc, "tools/list", [^version]}
        end

        assert_receive {:rpc, "tools/call", [^version]}
        assert_receive {:rpc, "tools/call", [^version]}
        refute_receive {:rpc, _, _}
      end

      context = %{
        actor: actor,
        read_only: true,
        deadline: System.monotonic_time(:millisecond) + 10_000
      }

      assert {:ok, %{"structuredContent" => %{"id" => "9223372036854775807"}}} =
               Ankole.Connectors.Gateway.request(
                 {:skill, mode, "demo"},
                 %{"method" => "tools/call", "params" => %{"name" => "read", "arguments" => %{}}},
                 context,
                 %{}
               )

      assert {:error, :read_only_route} =
               Ankole.Connectors.Gateway.request(
                 {:skill, mode, "demo"},
                 %{
                   "method" => "tools/call",
                   "params" => %{"name" => "write", "arguments" => %{}}
                 },
                 context,
                 %{}
               )

      assert_receive {:rpc, "tools/call", [^version]}
      refute_receive {:rpc, _, _}
    end
  end

  test "Files.HTTP.safe_redirect_headers strips credentials on cross-origin or HTTPS downgrade redirects" do
    headers = [
      {"Authorization", "Bearer secret-token"},
      {"Cookie", "sid=123"},
      {"X-Api-Key", "k-secret"},
      {"Accept", "text/html"}
    ]

    assert Ankole.Files.HTTP.safe_redirect_headers(
             "https://api.example.com/v1/a",
             "https://api.example.com:443/v1/b",
             headers
           ) == headers

    assert Ankole.Files.HTTP.safe_redirect_headers(
             "https://api.example.com/v1/a",
             "http://api.example.com/v1/b",
             headers
           ) == [{"Accept", "text/html"}]

    assert Ankole.Files.HTTP.safe_redirect_headers(
             "https://api.example.com/v1/a",
             "https://cdn.example.com/v1/b",
             headers
           ) == [{"Accept", "text/html"}]

    assert Ankole.Files.HTTP.safe_redirect_headers(
             "https://api.example.com:8443/v1/a",
             "https://api.example.com:443/v1/b",
             headers
           ) == [{"Accept", "text/html"}]
  end

  test "Files.HTTP.with_stream bounds streamed bytes and LinkPreview resolves titles over safe streaming" do
    Ankole.AppConfigure.put_tenant_by_key("security.ssrf_filter.enabled", false)

    {:ok, preview_server} =
      Bandit.start_link(
        plug: fn conn, _opts ->
          case conn.request_path do
            "/bounce" ->
              conn
              |> Plug.Conn.put_resp_header("location", "http://localhost:#{conn.port}/article")
              |> Plug.Conn.send_resp(302, "")

            "/article" ->
              assert Plug.Conn.get_req_header(conn, "authorization") == []

              Plug.Conn.send_resp(
                conn,
                200,
                "<html><head><title>First Principles Title</title></head><body>" <>
                  String.duplicate("x", 128_000) <> "</body></html>"
              )
          end
        end,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(preview_server)
    base = "http://127.0.0.1:#{port}"

    collected =
      Ankole.Files.HTTP.with_stream(
        "GET",
        "#{base}/bounce",
        [{"Authorization", "Bearer should-not-leak"}],
        nil,
        [max_bytes: 1024],
        fn %{status: 200}, stream ->
          Enum.reduce_while(stream, <<>>, fn chunk, acc ->
            next = acc <> chunk
            if byte_size(next) >= 256, do: {:halt, binary_part(next, 0, 256)}, else: {:cont, next}
          end)
        end
      )

    assert byte_size(collected) == 256
    assert collected =~ "First Principles Title"

    assert {:ok, %{title: "First Principles Title"}} =
             Ankole.Pod.Pages.LinkPreview.fetch_metadata("#{base}/article", ssrf_filter: false)
  end
end
