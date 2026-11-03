defmodule Ankole.Files.HTTPBridgeTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Files.HTTP
  alias Ankole.Pod.{Files, Pages}

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

      for _ <- 1..2 do
        assert {:ok,
                %{
                  "status" => 200,
                  "body" => %{"structuredContent" => %{"id" => "9223372036854775807"}}
                }} =
                 Ankole.Pod.Applets.call(actor, page.id, %{
                   "method" => "POST",
                   "path" => "/",
                   "query" => %{}
                 })

        if mode == "legacy" do
          assert_receive {:rpc, "tools/list", ["2026-07-28"]}
          assert_receive {:rpc, "initialize", ["2025-11-25"]}
          assert_receive {:rpc, "notifications/initialized", ["2025-11-25"]}
        end

        assert_receive {:rpc, "tools/list", _}
        assert_receive {:rpc, "tools/call", _}
        assert_receive {:rpc, "tools/call", _}
        refute_receive {:rpc, _, _}
      end

      options = %{"skill" => mode, "server" => "demo"}
      context = %{"read_only" => true, "deadline" => System.monotonic_time(:millisecond) + 10_000}

      assert {:ok, %{"structuredContent" => %{"id" => "9223372036854775807"}}} =
               Ankole.Pod.Applets.MCP.call(actor, "read", %{}, options, context)

      assert {:error, :read_only_route} =
               Ankole.Pod.Applets.MCP.call(actor, "write", %{}, options, context)

      drain_rpc()
    end
  end

  defp drain_rpc do
    receive do
      {:rpc, _, _} -> drain_rpc()
    after
      0 -> :ok
    end
  end
end
