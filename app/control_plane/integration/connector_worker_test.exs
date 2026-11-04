defmodule Ankole.ConnectorWorkerIntegrationTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Connectors.{Accounts, Store, Tokens}
  alias Ankole.Plugins.LarkAdapter.Config
  @moduletag :external
  @moduletag timeout: 120_000

  defmodule Provider do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      send(owner, {:upstream, conn.request_path, get_req_header(conn, "authorization")})

      body =
        case conn.request_path do
          "/open-apis/auth/v3/tenant_access_token/internal" ->
            %{code: 0, tenant_access_token: "lark-app-token", expire: 3600}

          "/open-apis/im/v1/chats" ->
            %{code: 0, data: %{items: [], has_more: false}}

          "/repos/owner/repo" ->
            %{id: 1}

          "/repos/octocat/Hello-World" ->
            # Public REST response from https://api.github.com/repos/octocat/Hello-World.
            __DIR__
            |> Path.join("fixtures/github_repository.json")
            |> File.read!()
            |> Torque.decode!()
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Torque.encode!(body))
    end
  end

  defmodule Git do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      expected = "Basic " <> Base.encode64("x-access-token:github-token")

      if get_req_header(conn, "authorization") == [expected] do
        send(owner, {:git_authenticated, conn.request_path})

        body =
          if String.ends_with?(conn.request_path, "/HEAD"),
            do: "ref: refs/heads/main\n",
            else: String.duplicate("a", 40) <> "\trefs/heads/main\n"

        conn |> put_resp_content_type("text/plain") |> send_resp(200, body)
      else
        conn
        |> put_resp_header("www-authenticate", ~s(Basic realm="Fixture"))
        |> send_resp(401, "Authentication required")
      end
    end
  end

  defmodule SlowMCP do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, bytes, conn} = read_body(conn)
      request = Torque.decode!(bytes)
      send(owner, {:slow_mcp, request["method"], get_req_header(conn, "authorization")})

      result =
        case request["method"] do
          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => "read_site",
                  "description" => "Read a cold website within its requested time budget.",
                  "inputSchema" => %{
                    "type" => "object",
                    "properties" => %{"timeoutMS" => %{"type" => "integer"}}
                  },
                  "annotations" => %{"readOnlyHint" => true}
                }
              ]
            }

          "tools/call" ->
            if get_in(request, ["params", "arguments", "timeoutMS"]) == 1 do
              %{"content" => [%{"type" => "text", "text" => "text-only website content"}]}
            else
              Process.sleep(61_000)

              %{
                "structuredContent" => %{"text" => "cold website content"},
                "content" => [%{"type" => "text", "text" => "cold website content"}]
              }
            end
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Torque.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    end
  end

  test "Worker mcporter and real git HTTPS exchange a live Turn through the gateway" do
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")
    root = Path.join(System.tmp_dir!(), "connector-worker-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    cert = Path.join(root, "cert.pem")
    key = Path.join(root, "key.pem")

    {_, 0} =
      System.cmd(
        "openssl",
        [
          "req",
          "-x509",
          "-newkey",
          "rsa:2048",
          "-nodes",
          "-keyout",
          key,
          "-out",
          cert,
          "-days",
          "1",
          "-subj",
          "/CN=host.docker.internal"
        ],
        stderr_to_stdout: true
      )

    git =
      start_supervised!(
        {Bandit,
         plug: {Git, self()},
         scheme: :https,
         certfile: cert,
         keyfile: key,
         ip: {0, 0, 0, 0},
         port: 0},
        id: :git
      )

    {:ok, {_, git_port}} = ThousandIsland.listener_info(git)

    upstream =
      start_supervised!({Bandit, plug: {Provider, self()}, ip: {127, 0, 0, 1}, port: 0},
        id: :provider
      )

    {:ok, {_, upstream_port}} = ThousandIsland.listener_info(upstream)

    gateway =
      start_supervised!({Bandit, plug: AnkoleWeb.Endpoint, ip: {0, 0, 0, 0}, port: 0},
        id: :gateway
      )

    {:ok, {_, gateway_port}} = ThousandIsland.listener_info(gateway)
    origin = "http://host.docker.internal:#{gateway_port}"
    previous = Application.get_env(:ankole, Config)

    Application.put_env(:ankole, Config,
      client_opts: [base_url: "http://127.0.0.1:#{upstream_port}"]
    )

    on_exit(fn -> Application.put_env(:ankole, Config, previous || []) end)
    admin = human_fixture().principal
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)

    {:ok, _} =
      Store.create_auth_config(admin, %{
        "plugin_id" => "lark",
        "slug" => "main",
        "is_default" => true,
        "auth_scheme" => "lark_app",
        "secret" => %{"appID" => "worker-app", "appSecret" => "secret"}
      })

    {:ok, github} =
      Store.create_auth_config(admin, %{
        "plugin_id" => "github",
        "slug" => "development",
        "auth_scheme" => "oauth2",
        "secret" => %{"clientID" => "worker-github", "clientSecret" => "secret"},
        "public_metadata" => %{
          "base_url" => "http://127.0.0.1:#{upstream_port}",
          "web_url" => "https://host.docker.internal:#{git_port}"
        }
      })

    {:ok, _} =
      Repo.transact_top_level(fn ->
        Accounts.put_tokens_in_tx(
          github,
          "app",
          "workspace",
          %{"access_token" => "github-token", "expires_in" => 3600},
          %{granted_scopes: ["repo"]}
        )
      end)

    agent = agent_fixture().principal
    signal = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)

    ref = %Ankole.Sessions.RunRef{
      agent_uid: agent.uid,
      session_id: signal.session_id,
      signal_id: signal.id
    }

    assert {:ok, env} = Tokens.worker(agent.uid, ref)
    token = env["ANKOLE_MCP_TOKEN"]

    File.write!(
      Path.join(root, "mcporter.json"),
      Torque.encode!(%{
        mcpServers: %{
          lark_im: %{
            baseUrl: origin <> "/api/internal/mcp/toolkits/lark_im",
            headers: %{Authorization: "Bearer " <> token}
          }
        }
      })
    )

    common = [
      "run",
      "--rm",
      "--entrypoint",
      "/bin/sh",
      "--mount",
      "type=bind,src=#{root},dst=/fixture,readonly",
      "-e",
      "ANKOLE_MCP_TOKEN=#{token}",
      "-e",
      "ANKOLE_MCP_ORIGIN=#{origin}",
      "-e",
      "ANKOLE_GITHUB_CONNECTION=development",
      "-e",
      "GIT_ASKPASS=/usr/local/bin/ankole-git-askpass",
      "-e",
      "GIT_TERMINAL_PROMPT=0",
      "-e",
      "GIT_CONFIG_PARAMETERS='credential.useHttpPath=true' 'credential.helper='",
      image,
      "-c"
    ]

    {json, 0} =
      System.cmd(
        "docker",
        common ++
          ["mcporter --config /fixture/mcporter.json call lark_im.im_list_chats --output json"],
        stderr_to_stdout: true
      )

    assert %{"items" => [], "has_more" => false} = Torque.decode!(json)
    assert_receive {:upstream, "/open-apis/im/v1/chats", ["Bearer lark-app-token"]}

    {refs, 0} =
      System.cmd(
        "docker",
        common ++
          [
            "git -c http.sslVerify=false ls-remote https://host.docker.internal:#{git_port}/owner/repo.git"
          ],
        stderr_to_stdout: true
      )

    assert refs =~ String.duplicate("a", 40) <> "\trefs/heads/main"
    assert_receive {:upstream, "/repos/owner/repo", ["Bearer github-token"]}
    assert_receive {:git_authenticated, "/owner/repo.git/info/refs"}

    {:ok, _} =
      Repo.transact_top_level(fn ->
        Ankole.Ash.update(signal, :dead_letter, %{
          dead_letter_at: DateTime.utc_now(),
          dead_letter_reason: %{"reason" => "test_finished"}
        })
      end)

    {error, code} =
      System.cmd(
        "docker",
        common ++
          [
            "git -c http.sslVerify=false ls-remote https://host.docker.internal:#{git_port}/owner/repo.git"
          ],
        stderr_to_stdout: true
      )

    assert code != 0
    assert error =~ "run_closed"
  end

  test "Worker discovers account aliases and calls only the selected workspace" do
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")

    root =
      Path.join(System.tmp_dir!(), "connector-accounts-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    upstream =
      start_supervised!({Bandit, plug: {Provider, self()}, ip: {127, 0, 0, 1}, port: 0},
        id: :provider
      )

    {:ok, {_, upstream_port}} = ThousandIsland.listener_info(upstream)

    gateway =
      start_supervised!({Bandit, plug: AnkoleWeb.Endpoint, ip: {0, 0, 0, 0}, port: 0},
        id: :gateway
      )

    {:ok, {_, gateway_port}} = ThousandIsland.listener_info(gateway)
    admin = human_fixture().principal
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)

    {:ok, config} =
      Store.create_auth_config(admin, %{
        "plugin_id" => "github",
        "slug" => "engineering",
        "auth_scheme" => "oauth2",
        "secret" => %{"clientID" => "account-discovery", "clientSecret" => "secret"},
        "public_metadata" => %{"base_url" => "http://127.0.0.1:#{upstream_port}"}
      })

    :ok =
      Repo.transact_top_level(fn ->
        for key <- ["42", "org.two"] do
          {:ok, _} =
            Accounts.put_tokens_in_tx(
              config,
              "app",
              key,
              %{"access_token" => "token-#{key}", "expires_in" => 3600},
              %{granted_scopes: ["repo"]}
            )
        end

        :ok
      end)

    agent = agent_fixture().principal
    signal = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)

    ref = %Ankole.Sessions.RunRef{
      agent_uid: agent.uid,
      session_id: signal.session_id,
      signal_id: signal.id
    }

    {:ok, env} = Tokens.worker(agent.uid, ref)

    File.write!(
      Path.join(root, "gateway.json"),
      Torque.encode!(%{
        gatewayOrigin: "http://host.docker.internal:#{gateway_port}",
        gatewayToken: env["ANKOLE_MCP_TOKEN"],
        connections: Torque.decode!(env["ANKOLE_MCP_CONNECTIONS"])
      })
    )

    common = [
      "run",
      "--rm",
      "--entrypoint",
      "/bin/sh",
      "--mount",
      "type=bind,src=#{root},dst=/fixture",
      "--mount",
      "type=bind,src=#{Path.expand("../agent_computer/src")},dst=/repo/app/agent_computer/src,readonly",
      image,
      "-c"
    ]

    renderer = """
    import { renderMCPorterConfig } from '/repo/app/agent_computer/src/tools/mcp/mcporter-config.ts';
    const options = await Bun.file('/fixture/gateway.json').json();
    await Bun.write('/fixture/mcporter.json', renderMCPorterConfig([
      {name: 'github', transport: 'connector', toolkit: 'github', sourceSkills: ['github']}
    ], options));
    """

    File.write!(Path.join(root, "render.ts"), renderer)

    {_, 0} =
      System.cmd("docker", common ++ ["bun /fixture/render.ts"], stderr_to_stdout: true)

    {listing, 0} =
      System.cmd("docker", common ++ ["mcporter --config /fixture/mcporter.json list --json"],
        stderr_to_stdout: true
      )

    assert listing =~ "github@engineering@42"
    assert listing =~ "github@engineering@org%2Etwo"

    for {name, token} <- [{"42", "token-42"}, {"org%2Etwo", "token-org.two"}] do
      {result, 0} =
        System.cmd(
          "docker",
          common ++
            [
              "mcporter --config /fixture/mcporter.json call github@engineering@#{name}.repos_get --args '{\"owner\":\"octocat\",\"repo\":\"Hello-World\"}' --output json"
            ],
          stderr_to_stdout: true
        )

      assert Torque.decode!(result)["full_name"] == "octocat/Hello-World"
      assert Torque.decode!(result)["id"] == 1_296_269
      authorization = "Bearer " <> token
      assert_receive {:upstream, "/repos/octocat/Hello-World", [^authorization]}
    end

    {error, _} =
      System.cmd(
        "docker",
        common ++
          [
            "mcporter --config /fixture/mcporter.json call github@engineering.repos_get --args '{\"owner\":\"octocat\",\"repo\":\"Hello-World\"}' --output json"
          ],
        stderr_to_stdout: true
      )

    assert error =~ "connection_account_required"
    refute_receive {:upstream, _, _}
  end

  test "Worker remote MCP supports a cold-site read beyond one minute within the Skill budget" do
    image = System.fetch_env!("ANKOLE_WORKER_PROVIDER_TEST_IMAGE")

    root =
      Path.join(System.tmp_dir!(), "connector-slow-mcp-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    upstream =
      start_supervised!({Bandit, plug: {SlowMCP, self()}, ip: {127, 0, 0, 1}, port: 0},
        id: :provider
      )

    {:ok, {_, upstream_port}} = ThousandIsland.listener_info(upstream)

    gateway =
      start_supervised!({Bandit, plug: AnkoleWeb.Endpoint, ip: {0, 0, 0, 0}, port: 0},
        id: :gateway
      )

    {:ok, {_, gateway_port}} = ThousandIsland.listener_info(gateway)
    agent = agent_fixture().principal
    url = "http://127.0.0.1:#{upstream_port}/mcp"

    yaml = """
    dependencies:
      tools:
        - type: mcp
          value: slow-site
          transport: streamable_http
          url: #{url}
          bearer_token_env_var: SLOW_SITE_TOKEN
    """

    {:ok, blob} = Ankole.Files.store(yaml)

    {:ok, _} =
      Ankole.Files.commit(agent.uid, [
        Map.merge(blob, %{path: "fixtures/slow-site", source: "agent"})
      ])

    {:ok, _} =
      Repo.transact_top_level(fn ->
        with {:ok, skill} <-
               Ankole.Ash.create(Ankole.AIAgent.Library.Schemas.Skill, :create, %{
                 slug: "slow-site",
                 name: "slow-site",
                 description: "Cold-site MCP fixture",
                 source_kind: :custom,
                 enabled_for_all: true,
                 manifest_xml: "<p>Read a cold site with a 360000 ms CLI timeout.</p>",
                 manifest_markdown: "Read a cold site with a 360000 ms CLI timeout."
               }),
             do:
               Ankole.Ash.create(Ankole.AIAgent.Library.Schemas.SkillFile, :put, %{
                 skill_id: skill.id,
                 relative_path: "agents/openai.yaml",
                 object_id: blob.object_id,
                 content_type: "application/yaml"
               })
      end)

    {:ok, _} =
      Ankole.AgentWorkers.WorkerEnv.console_put_for_agent(agent.uid, "SLOW_SITE_TOKEN", %{
        "value" => "upstream-only-token",
        "secret" => true
      })

    signal = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)

    ref = %Ankole.Sessions.RunRef{
      agent_uid: agent.uid,
      session_id: signal.session_id,
      signal_id: signal.id
    }

    {:ok, env} = Tokens.worker(agent.uid, ref)

    File.write!(
      Path.join(root, "gateway.json"),
      Torque.encode!(%{
        gatewayOrigin: "http://host.docker.internal:#{gateway_port}",
        gatewayToken: env["ANKOLE_MCP_TOKEN"]
      })
    )

    File.write!(Path.join(root, "render.ts"), """
    import { renderMCPorterConfig } from '/repo/app/agent_computer/src/tools/mcp/mcporter-config.ts';
    const options = await Bun.file('/fixture/gateway.json').json();
    await Bun.write('/fixture/mcporter.json', renderMCPorterConfig([
      {name: 'slow-site', transport: 'streamable_http', url: #{Torque.encode!(url)}, sourceSkills: ['slow-site']}
    ], options));
    """)

    common = [
      "run",
      "--rm",
      "--entrypoint",
      "/bin/sh",
      "--mount",
      "type=bind,src=#{root},dst=/fixture",
      "--mount",
      "type=bind,src=#{Path.expand("../agent_computer/src")},dst=/repo/app/agent_computer/src,readonly",
      image,
      "-c"
    ]

    {_, 0} = System.cmd("docker", common ++ ["bun /fixture/render.ts"], stderr_to_stdout: true)
    refute File.read!(Path.join(root, "mcporter.json")) =~ "upstream-only-token"

    {text_result, text_status} =
      System.cmd(
        "docker",
        common ++
          [
            "mcporter --config /fixture/mcporter.json call slow-site.read_site --args '{\"timeoutMS\":1}' --timeout 10000 --output json"
          ],
        stderr_to_stdout: true
      )

    assert text_status == 0, text_result
    assert text_result =~ "text-only website content"

    {result, status} =
      System.cmd(
        "docker",
        common ++
          [
            "mcporter --config /fixture/mcporter.json call slow-site.read_site --args '{\"timeoutMS\":300000}' --timeout 360000 --output json"
          ],
        stderr_to_stdout: true
      )

    assert status == 0, result
    assert Torque.decode!(result) == %{"text" => "cold website content"}
    assert_receive {:slow_mcp, "tools/call", ["Bearer upstream-only-token"]}

    {:ok, claims} = Tokens.verify(env["ANKOLE_MCP_TOKEN"])
    {:ok, secret} = Ankole.SecretKeyBase.fetch()

    token =
      Phoenix.Token.sign(
        secret,
        "connectors.runtime.v1",
        %{claims | "expires_at_ms" => System.system_time(:millisecond) + 2_000}
      )

    started = System.monotonic_time(:millisecond)

    assert {:ok, %{body: %{"result" => failure}}} =
             Ankole.Files.HTTP.json(
               "POST",
               "http://127.0.0.1:#{gateway_port}/api/internal/mcp/skills/slow-site/slow-site",
               [
                 {"authorization", "Bearer " <> token},
                 {"content-type", "application/json"}
               ],
               %{
                 "jsonrpc" => "2.0",
                 "id" => "short-token",
                 "method" => "tools/call",
                 "params" => %{"name" => "read_site", "arguments" => %{"timeoutMS" => 300_000}}
               }
             )

    assert failure["isError"] == true
    assert failure["structuredContent"]["error"]["code"] == "http_request_failed"
    assert System.monotonic_time(:millisecond) - started < 10_000
    assert_receive {:slow_mcp, "tools/call", ["Bearer upstream-only-token"]}
  end
end
