defmodule Ankole.Connectors.ProviderProtocolTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Connectors.{Accounts, Gateway, HTTP, Store, ToolSpec}
  alias Ankole.Pod.{Files, Pages}
  alias Ankole.Plugins.GitHubAdapter.Connector, as: GitHub
  alias Ankole.Plugins.LarkAdapter.{Connector, ConnectorArguments, Config}

  defmodule Provider do
    import Plug.Conn
    def init(options), do: options

    def call(conn, {owner, hooks}) do
      {:ok, body, conn} = read_body(conn)
      decoded = if body == "", do: nil, else: Torque.decode!(body)
      conn = fetch_query_params(conn)

      send(
        owner,
        {:request, conn.method, conn.request_path, conn.query_params, decoded, conn.req_headers}
      )

      {status, body} =
        case conn.request_path do
          "/mcp-errors" ->
            envelope = %{"jsonrpc" => "2.0", "id" => decoded["id"]}

            if decoded["method"] == "tools/list" do
              {200, Map.put(envelope, "result", %{"tools" => []})}
            else
              case get_in(decoded, ["params", "arguments", "failure"]) do
                "http" ->
                  {500, %{"error" => %{"code" => -32603}}}

                "rpc" ->
                  {200,
                   Map.put(envelope, "error", %{"code" => -32603, "message" => "Internal error"})}

                "tool" ->
                  {200,
                   Map.put(envelope, "result", %{
                     "isError" => true,
                     "content" => [%{"type" => "text", "text" => "Could not confirm write"}]
                   })}

                "credential" ->
                  {200,
                   Map.put(envelope, "result", %{
                     "isError" => true,
                     "content" => [
                       %{
                         "type" => "text",
                         "text" => "Invalid bearer app-token; expected team scope"
                       }
                     ]
                   })}
              end
            end

          "/repos/owner/repo/hooks" ->
            if conn.method == "GET" do
              {200, Agent.get(hooks, & &1)}
            else
              hook = Map.put(decoded, "id", 7)
              Agent.update(hooks, fn _ -> [hook] end)
              {201, hook}
            end

          "/repos/owner/repo/hooks/7" ->
            Agent.update(hooks, fn _ -> [] end)
            {204, nil}

          "/repos/owner/failing/issues" ->
            {500, %{"message" => "Server lost outcome after saving issue"}}

          "/repos/owner/invalid/issues" ->
            {422,
             %{
               "message" => "Validation failed for app-token",
               "errors" => [
                 %{"resource" => "Issue", "field" => "title", "code" => "missing_field"}
               ]
             }}

          path
          when path in [
                 "/repos/owner/repo/actions/runs/42/logs",
                 "/repos/owner/repo/actions/artifacts/42/zip",
                 "/open-apis/im/v1/messages/message/resources/resource"
               ] ->
            {200, <<80, 75, 3, 4, 0, 255, 10>>}

          "/open-apis/auth/v3/tenant_access_token/internal" ->
            {200, %{"code" => 0, "tenant_access_token" => "application-token", "expire" => 7200}}

          path
          when path in [
                 "/open-apis/approval/v4/approvals/approval/subscribe",
                 "/open-apis/approval/v4/approvals/approval/unsubscribe",
                 "/open-apis/calendar/v4/calendars/cal/events/subscription",
                 "/open-apis/calendar/v4/calendars/cal/events/unsubscription"
               ] ->
            {200, %{"code" => 0}}

          "/open-apis/authen/v2/oauth/token" ->
            if(decoded["refresh_token"] == "invalid",
              do: {400, %{"code" => 20024}},
              else:
                {200,
                 %{
                   "code" => 0,
                   "access_token" => "next",
                   "refresh_token" => "rotated",
                   "expires_in" => 3600
                 }}
            )

          "/login/oauth/access_token" ->
            if(decoded["refresh_token"] == "invalid",
              do: {200, %{"error" => "bad_refresh_token"}},
              else:
                {200,
                 %{"access_token" => "next", "refresh_token" => "rotated", "expires_in" => 3600}}
            )

          "/app/installations/42/access_tokens" ->
            {201,
             %{
               "token" => "installation",
               "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
             }}

          "/open-apis/calendar/v4/calendars/cal/events" ->
            {200, %{"code" => 0, "data" => %{"event" => %{"event_id" => "event-1"}}}}

          "/open-apis/calendar/v4/calendars/cal/events/event-1/attendees" ->
            {200, %{"code" => 9999}}

          "/open-apis/task/v2/tasks/done" ->
            {200,
             %{"code" => 0, "data" => %{"task" => %{"guid" => "done", "completed_at" => "123"}}}}

          "/repos/owner/slow" ->
            Process.sleep(200)
            {200, %{"id" => 42}}

          "/open-apis/approval/v4/approvals/definition" ->
            {200,
             %{
               "code" => 0,
               "data" => %{
                 "form" =>
                   Torque.encode!([
                     %{"id" => "amount-id", "name" => "Amount", "type" => "amount"}
                   ])
               }
             }}

          _ ->
            {200, %{"id" => 42}}
        end

      if is_binary(body) do
        conn |> put_resp_content_type("application/octet-stream") |> send_resp(status, body)
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, Torque.encode!(body))
      end
    end
  end

  setup do
    hooks = start_supervised!({Agent, fn -> [] end})

    server =
      start_supervised!({Bandit, plug: {Provider, {self(), hooks}}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}"
    previous = Application.get_env(:ankole, Config)
    Application.put_env(:ankole, Config, client_opts: [base_url: url])
    on_exit(fn -> Application.put_env(:ankole, Config, previous || []) end)

    config = %{
      id: Ash.UUIDv7.generate(),
      tenant_id: Repo.tenant_id!(),
      public_metadata: %{"base_url" => url, "web_url" => url, "installation_id" => "42"}
    }

    %{
      url: url,
      config: config,
      context: %{
        auth_config: config,
        actor: actor_fixture(human_fixture().principal.uid),
        access_token: "app-token",
        external_user_id: "employee",
        account: nil
      }
    }
  end

  test "Git HTTPS selects the matching host and preserves explicit connection choice", ctx do
    context = Map.take(ctx.context, [:actor])
    principal = context.actor.principal
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(principal.uid) end)

    create = fn slug, host, default ->
      {:ok, config} =
        Store.create_auth_config(principal, %{
          "plugin_id" => "github",
          "slug" => slug,
          "auth_scheme" => "oauth2",
          "is_default" => default,
          "secret" => %{"clientID" => slug, "clientSecret" => "secret"},
          "public_metadata" => %{"base_url" => ctx.url, "web_url" => "https://" <> host}
        })

      {:ok, _} =
        Accounts.put_human_tokens(
          config.id,
          principal.uid,
          %{"access_token" => slug <> "-token", "expires_in" => 3600},
          %{external_subject_id: "employee", granted_scopes: ["repo"]}
        )

      config
    end

    public = create.("public-github", "github.com", true)
    enterprise = create.("enterprise-github", "git.example.com", false)
    params = %{"url" => "https://git.example.com/owner/repo.git"}

    assert {:ok, %{username: "x-access-token", password: "enterprise-github-token"}} =
             Ankole.Connectors.GitCredentials.resolve(context, params)

    assert_receive {:request, "GET", "/repos/owner/repo", _, _, headers}
    assert {"authorization", "Bearer enterprise-github-token"} in headers

    assert {:error, :github_repository_url_required} =
             Ankole.Connectors.GitCredentials.resolve(
               context,
               Map.put(params, "connection", public.slug)
             )

    refute_receive {:request, "GET", "/repos/owner/repo", _, _, _}

    create.("other-enterprise", "git.example.com", false)

    assert {:error, :connection_required} =
             Ankole.Connectors.GitCredentials.resolve(context, params)

    refute_receive {:request, "GET", "/repos/owner/repo", _, _, _}

    assert {:ok, %{password: "enterprise-github-token"}} =
             Ankole.Connectors.GitCredentials.resolve(
               context,
               Map.put(params, "connection", enterprise.slug)
             )
  end

  test "read-only gateway calls cannot save external downloads, while write calls retain that capability",
       ctx do
    connections = download_connections(ctx)

    for {toolkit, name, args, path} <- downloads() do
      filename = name <> ".bin"

      {:ok, page} =
        Pages.create(ctx.context.actor, %{
          type: "file",
          title: filename,
          private_owner_uid: ctx.context.actor.principal.uid
        })

      args = Map.put(args, "destination", download_destination(page))
      context = %{actor: ctx.context.actor, read_only: true}
      options = %{"connection" => connections[toolkit]}
      request = tool_request(name, args)

      assert {:error, %{code: "read_only_route", request_sent: false}} =
               Gateway.request({:toolkit, toolkit}, request, context, options)

      refute_receive {:request, "GET", ^path, _, _, _}
      assert {:ok, %{object_id: nil}} = Pages.fetch(page.id)

      assert {:ok, %{"structuredContent" => %{"file_ref" => file_ref}}} =
               Gateway.request(
                 {:toolkit, toolkit},
                 request,
                 %{context | read_only: false},
                 options
               )

      assert file_ref == "pages/#{page.id}/#{filename}"
      assert_receive {:request, "GET", ^path, _, _, _}

      assert {:ok, _, <<80, 75, 3, 4, 0, 255, 10>>} =
               Files.read(ctx.context.actor, page.id, filename)
    end
  end

  test "download destinations can replace the observed file version and reject a stale version",
       ctx do
    connections = download_connections(ctx)

    for {toolkit, name, args, path} <- downloads() do
      filename = name <> ".bin"

      {:ok, page} =
        Files.create_from_upload(
          ctx.context.actor,
          %{private_owner_uid: ctx.context.actor.principal.uid},
          filename,
          "previous download",
          "application/octet-stream"
        )

      destination = Map.put(download_destination(page), "base_object_id", page.object_id)
      request = tool_request(name, Map.put(args, "destination", destination))
      context = %{actor: ctx.context.actor, read_only: false}
      options = %{"connection" => connections[toolkit]}

      assert {:ok, %{"structuredContent" => %{"file_ref" => file_ref}}} =
               Gateway.request({:toolkit, toolkit}, request, context, options)

      assert file_ref == "pages/#{page.id}/#{filename}"
      assert_receive {:request, "GET", ^path, _, _, _}
      assert {:ok, current} = Pages.fetch(page.id)
      refute current.object_id == page.object_id

      assert {:error, :manifest_changed} =
               Gateway.request({:toolkit, toolkit}, request, context, options)

      assert {:ok, %{object_id: object_id}} = Pages.fetch(page.id)
      assert object_id == current.object_id

      assert {:ok, _, <<80, 75, 3, 4, 0, 255, 10>>} =
               Files.read(ctx.context.actor, page.id, filename)
    end
  end

  defp download_connections(ctx) do
    principal = ctx.context.actor.principal
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(principal.uid) end)

    Map.new([{"github", "github"}, {"lark", "lark_im"}], fn {plugin, toolkit} ->
      {:ok, config} =
        Store.create_auth_config(principal, %{
          "plugin_id" => plugin,
          "slug" => plugin <> "-downloads",
          "auth_scheme" => if(plugin == "github", do: "oauth2", else: "lark_app"),
          "secret" =>
            if(plugin == "github",
              do: %{"clientID" => "download-client", "clientSecret" => "secret"},
              else: %{"appID" => "download-app", "appSecret" => "secret"}
            ),
          "public_metadata" => %{"base_url" => ctx.url}
        })

      if plugin == "github" do
        {:ok, _} =
          Accounts.put_human_tokens(
            config.id,
            principal.uid,
            %{"access_token" => "download-token", "expires_in" => 3600},
            %{external_subject_id: "employee", granted_scopes: ["repo"]}
          )
      end

      assert Ankole.Connectors.Registry.plugin_id(toolkit) == plugin
      assert {:ok, %{id: id}} = Store.get_auth_config(config.slug, plugin)
      assert id == config.id
      {toolkit, config.slug}
    end)
  end

  defp downloads do
    [
      {"github", "actions_get_run_logs", %{"owner" => "owner", "repo" => "repo", "run_id" => 42},
       "/repos/owner/repo/actions/runs/42/logs"},
      {"github", "actions_download_artifact",
       %{"owner" => "owner", "repo" => "repo", "artifact_id" => 42},
       "/repos/owner/repo/actions/artifacts/42/zip"},
      {"lark_im", "im_download_resource",
       %{"message_id" => "message", "file_key" => "resource", "type" => "file"},
       "/open-apis/im/v1/messages/message/resources/resource"}
    ]
  end

  defp download_destination(page),
    do: %{
      "page_id" => page.id,
      "role" => "file",
      "name" => page.title,
      "content_type" => "application/octet-stream"
    }

  defp tool_request(name, args),
    do: %{"method" => "tools/call", "params" => %{"name" => name, "arguments" => args}}

  test "provider subscriptions create, adopt and remove through real HTTP and shared credentials",
       ctx do
    alias Ankole.Connectors.{Accounts, Store, Triggers}
    principal = ctx.context.actor.principal
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(principal.uid) end)

    for plugin <- ["github", "lark"] do
      {:ok, config} =
        Store.create_auth_config(principal, %{
          "plugin_id" => plugin,
          "slug" => plugin <> "-subscription",
          "auth_scheme" => if(plugin == "github", do: "oauth2", else: "lark_app"),
          "secret" =>
            if(plugin == "github",
              do: %{"clientID" => "hooks", "clientSecret" => "secret"},
              else: %{"appID" => "hooks", "appSecret" => "secret"}
            ),
          "public_metadata" => %{"base_url" => ctx.url}
        })

      {:ok, account} =
        Accounts.put_human_tokens(
          config.id,
          principal.uid,
          %{"access_token" => "personal-hook-token", "expires_in" => 3600},
          %{
            external_subject_id: "employee",
            granted_scopes: if(plugin == "lark", do: ["calendar:calendar.event:read"], else: [])
          }
        )

      subscriptions =
        if(plugin == "github",
          do: [{"github_repository", "owner/repo", account.id}],
          else: [{"lark_approval", "approval", nil}, {"lark_calendar", "cal", account.id}]
        )

      adapter = if(plugin == "github", do: GitHub, else: Connector)

      for {type, scope, account_id} <- subscriptions do
        {:ok, public} =
          Triggers.create(principal, %{
            "auth_config_id" => config.id,
            "connected_account_id" => account_id,
            "trigger_type" => type,
            "scope_key" => scope
          })

        {:ok, trigger} = Triggers.get(public.id)

        assert {:ok, %{external_subscription_id: remote_id}} =
                 adapter.reconcile_trigger(config, %{}, trigger, true)

        assert is_binary(remote_id)

        if plugin == "github" do
          assert {:ok, %{external_subscription_id: ^remote_id}} =
                   adapter.reconcile_trigger(config, %{}, trigger, true)

          assert_receive {:request, "POST", "/repos/owner/repo/hooks", _,
                          %{"config" => %{"secret" => signing_secret}}, headers}

          assert is_binary(signing_secret)
          assert {"authorization", "Bearer personal-hook-token"} in headers
          refute_receive {:request, "POST", "/repos/owner/repo/hooks", _, _, _}
        end

        assert {:ok, %{external_subscription_id: nil}} =
                 adapter.reconcile_trigger(config, %{}, trigger, false)
      end
    end

    assert_receive {:request, "POST", "/open-apis/approval/v4/approvals/approval/subscribe", _, _,
                    approval_headers}

    assert {"authorization", "Bearer application-token"} in approval_headers

    assert_receive {:request, "POST", "/open-apis/calendar/v4/calendars/cal/events/subscription",
                    _, _, calendar_headers}

    assert {"authorization", "Bearer personal-hook-token"} in calendar_headers
  end

  test "each public tool has valid schemas and static retry annotations" do
    tools = Connector.tools() ++ GitHub.tools() ++ Ankole.Plugins.LinearAdapter.Connector.tools()
    assert length(tools) == 125

    for tool <- tools do
      assert %ExJsonSchema.Schema.Root{} = ExJsonSchema.Schema.resolve(tool.input_schema)
      assert %ExJsonSchema.Schema.Root{} = ExJsonSchema.Schema.resolve(tool.output_schema)
      assert is_boolean(tool.annotations["readOnlyHint"])
      assert is_boolean(tool.annotations["idempotentHint"])
    end

    create = Connector.find_tool("approvals_create_instance")
    assert {:error, _} = ToolSpec.validate_input(create, %{"approval_code" => "a", "form" => %{}})
    assert create.annotations["idempotentHint"]
    refute Connector.find_tool("im_send_message").annotations["idempotentHint"]

    assert {:error, _} =
             ToolSpec.validate_input(Connector.find_tool("approvals_approve"), %{
               "approval_code" => "a",
               "instance_code" => "i",
               "task_id" => "t",
               "user_id" => "someone-else"
             })

    assert Connector.find_tool("approvals_add_sign").upstream_auth == :human_oauth_token

    assert Connector.scopes_satisfied?(
             ["calendar:calendar.event:read"],
             ["calendar:calendar:readonly"],
             %{}
           )

    refute Connector.scopes_satisfied?(
             ["calendar:calendar.event:create"],
             ["calendar:calendar:readonly"],
             %{}
           )

    assert Connector.scopes_satisfied?(
             ["task:task:read", "calendar:calendar.event:create"],
             [
               "task:task:write",
               "calendar:calendar"
             ],
             %{}
           )
  end

  test "GitHub App single installation exchanges signed JWT and OAuth refresh preserves errors",
       ctx do
    key = :public_key.generate_key({:rsa, 2048, 65537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    assert {:ok, %{access_token: "installation"}} =
             GitHub.fetch_app_token(ctx.config, %{"appID" => "123", "privateKey" => pem}, nil)

    assert_receive {:request, "POST", "/app/installations/42/access_tokens", _, %{}, headers}
    "Bearer " <> jwt = Enum.find_value(headers, fn {k, v} -> if k == "authorization", do: v end)
    [head, payload, signature] = String.split(jwt, ".")
    assert %{"iss" => "123"} = payload |> Base.url_decode64!(padding: false) |> Torque.decode!()
    {:RSAPrivateKey, _, modulus, exponent, _, _, _, _, _, _, _} = key

    assert :public_key.verify(
             head <> "." <> payload,
             :sha256,
             Base.url_decode64!(signature, padding: false),
             {:RSAPublicKey, modulus, exponent}
           )

    secret = %{"clientID" => "client", "clientSecret" => "secret"}

    assert {:ok, %{"access_token" => "next", "refresh_token" => "rotated"}} =
             GitHub.refresh_token(ctx.config, secret, %{"refresh_token" => "valid"})

    assert {:error, :invalid_grant} =
             GitHub.refresh_token(ctx.config, secret, %{"refresh_token" => "invalid"})

    refute_receive {:request, "GET", "/user", _, _, _}
  end

  test "REST paths encode segments and query arrays, GitHub calls own endpoint", ctx do
    assert {:ok, url, nil} =
             HTTP.request_parts(
               %{"path" => "/items/:id", "method" => "GET", "query" => ["ids"]},
               %{"id" => "one/two", "ids" => ["a", "b"]},
               ctx.url
             )

    assert url == ctx.url <> "/items/one%2Ftwo?ids=a&ids=b"
    tool = Enum.find(GitHub.tools(), &(&1.name == "repos_get"))

    assert {:ok, %{"id" => 42}} =
             GitHub.call(tool, %{"owner" => "owner", "repo" => "repo"}, ctx.context)

    assert_receive {:request, "GET", "/repos/owner/repo", _, nil, headers}
    assert {"authorization", "Bearer app-token"} in headers
  end

  test "REST calls honor the remaining caller deadline", ctx do
    tool = Enum.find(GitHub.tools(), &(&1.name == "repos_get"))
    context = Map.put(ctx.context, :deadline, System.monotonic_time(:millisecond) + 30)

    assert {:error, %{code: "http_request_failed"}} =
             GitHub.call(tool, %{"owner" => "owner", "repo" => "slow"}, context)

    expired = Map.put(ctx.context, :deadline, System.monotonic_time(:millisecond) - 1)

    assert {:error, %{code: "http_request_failed", request_sent: false}} =
             GitHub.call(tool, %{"owner" => "owner", "repo" => "expired"}, expired)

    refute_receive {:request, _, "/repos/owner/expired", _, _, _}
  end

  test "REST rejections preserve field errors and redact only the injected credential", ctx do
    tool = Enum.find(GitHub.tools(), &(&1.name == "issues_create"))

    assert {:error,
            %{code: "upstream_rejected", status: 422, request_sent: true, details: details}} =
             GitHub.call(
               tool,
               %{"owner" => "owner", "repo" => "invalid", "title" => "Bad issue"},
               ctx.context
             )

    assert details["message"] == "Validation failed for [REDACTED]"

    assert details["errors"] == [
             %{"resource" => "Issue", "field" => "title", "code" => "missing_field"}
           ]

    assert_receive {:request, "POST", "/repos/owner/invalid/issues", _, _, headers}
    assert {"authorization", "Bearer app-token"} in headers
  end

  test "declared file paths preserve nested segments and ordinary identifiers cannot traverse",
       ctx do
    operation = %{
      "path" => "/repos/:owner/:repo/contents/:path",
      "path_segments" => ["path"],
      "method" => "GET"
    }

    assert {:ok, nested, nil} =
             HTTP.request_parts(
               operation,
               %{"owner" => "org", "repo" => "repo", "path" => "dir/a b.txt"},
               ctx.url
             )

    assert nested == ctx.url <> "/repos/org/repo/contents/dir/a%20b.txt"

    assert {:ok, root, nil} =
             HTTP.request_parts(
               operation,
               %{"owner" => "org", "repo" => "repo", "path" => ""},
               ctx.url
             )

    assert root == ctx.url <> "/repos/org/repo/contents/"

    for value <- ["", ".", ".."] do
      assert {:error, %{code: "invalid_arguments", field: "owner", request_sent: false}} =
               HTTP.request_parts(
                 operation,
                 %{"owner" => value, "repo" => "repo", "path" => "dir/file"},
                 ctx.url
               )
    end

    for path <- ["../file", "dir/../file", "dir//file", "/file"] do
      assert {:error, %{code: "invalid_arguments", field: "path", request_sent: false}} =
               HTTP.request_parts(
                 operation,
                 %{"owner" => "org", "repo" => "repo", "path" => path},
                 ctx.url
               )
    end
  end

  test "a failed non-idempotent write never recommends replay after HTTP500", ctx do
    create = Enum.find(GitHub.tools(), &(&1.name == "issues_create"))
    list = Enum.find(GitHub.tools(), &(&1.name == "issues_list"))
    args = %{"owner" => "owner", "repo" => "failing", "title" => "Create once"}

    assert {:error, %{code: "upstream_outcome_unknown", retryable: false, status: 500}} =
             GitHub.call(create, args, ctx.context)

    assert_receive {:request, "POST", "/repos/owner/failing/issues", _, _, _}
    refute_receive {:request, "POST", "/repos/owner/failing/issues", _, _, _}

    assert {:error, %{code: "upstream_rejected", retryable: true, status: 500}} =
             GitHub.call(list, Map.delete(args, "title"), ctx.context)

    assert {:error, %{code: "upstream_rate_limited", retryable: true, retryAfterSeconds: 4}} =
             HTTP.decode(%{status: 429, headers: [{"retry-after", "4"}]})
  end

  test "remote MCP uncertain writes differ from completed tool rejections", ctx do
    for failure <- ["http", "rpc"] do
      assert {:error, %{code: "upstream_outcome_unknown", retryable: false}} =
               Ankole.Connectors.RemoteMCP.call(
                 ctx.url <> "/mcp-errors",
                 [],
                 "write",
                 %{"failure" => failure},
                 idempotent: false
               )
    end

    assert {:error, %{code: "upstream_rejected", retryable: true}} =
             Ankole.Connectors.RemoteMCP.call(
               ctx.url <> "/mcp-errors",
               [],
               "read",
               %{"failure" => "http"},
               idempotent: true
             )

    for safe <- [false, true] do
      assert {:ok, %{"isError" => true, "content" => [%{"text" => "Could not confirm write"}]}} =
               Ankole.Connectors.RemoteMCP.call(
                 ctx.url <> "/mcp-errors",
                 [],
                 "write",
                 %{"failure" => "tool"},
                 idempotent: safe
               )
    end
  end

  test "remote MCP discovery reuses the connection's catalog for subsequent calls", ctx do
    for _ <- 1..2 do
      assert {:ok, []} = Ankole.Connectors.RemoteMCP.list_tools(ctx.url <> "/mcp-errors", [])

      assert {:ok, %{"isError" => true}} =
               Ankole.Connectors.RemoteMCP.call(ctx.url <> "/mcp-errors", [], "write", %{
                 "failure" => "tool"
               })
    end

    assert_receive {:request, "POST", "/mcp-errors", _, %{"method" => "tools/list"}, _}
    refute_receive {:request, "POST", "/mcp-errors", _, %{"method" => "tools/list"}, _}
    url = ctx.url <> "/mcp-errors"
    key = {Repo.tenant_id!(), nil, url, :crypto.hash(:sha256, :erlang.term_to_binary([]))}
    [{^key, connection, session_expires}] = :ets.lookup(Ankole.Connectors.RemoteMCP, key)

    :ets.insert(
      Ankole.Connectors.RemoteMCP,
      {key, %{connection | tools_expires_at: System.monotonic_time(:millisecond) - 1},
       session_expires}
    )

    assert {:ok, []} = Ankole.Connectors.RemoteMCP.list_tools(url, [])
    assert_receive {:request, "POST", "/mcp-errors", _, %{"method" => "tools/list"}, _}
  end

  test "remote MCP errors retain their explanation without the injected bearer", ctx do
    assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} =
             Ankole.Connectors.RemoteMCP.call(
               ctx.url <> "/mcp-errors",
               [{"authorization", "Bearer app-token"}],
               "write",
               %{"failure" => "credential"}
             )

    assert text == "Invalid bearer [REDACTED]; expected team scope"
  end

  test "Lark refresh persists rotated tokens without fetching profile again", ctx do
    secret = %{"appID" => "app", "appSecret" => "secret"}

    assert {:ok, %{"access_token" => "next", "refresh_token" => "rotated"}} =
             Connector.refresh_token(ctx.config, secret, %{"refresh_token" => "valid"})

    assert {:error, :invalid_grant} =
             Connector.refresh_token(ctx.config, secret, %{"refresh_token" => "invalid"})

    refute_receive {:request, "GET", "/open-apis/authen/v1/user_info", _, _, _}
  end

  test "provider authorization scopes retain refresh and actor semantics", ctx do
    params = %{:subject_kind => "human", "scope" => "task:task:read", "state" => "state"}
    assert {:ok, url} = Connector.oauth_authorize_url(ctx.config, %{"appID" => "app"}, params)
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    scopes = String.split(query["scope"], " ")
    assert "task:task:read" in scopes
    assert "offline_access" in scopes
    assert "contact:user.employee_id:readonly" in scopes
    refute Map.has_key?(query, "subject_kind")

    assert {:ok, url} =
             Ankole.Plugins.LinearAdapter.Connector.oauth_authorize_url(
               ctx.config,
               %{"clientID" => "client"},
               %{:subject_kind => "app", "scope" => "read write"}
             )

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["scope"] == "read,write"
    assert query["actor"] == "app"
    refute Map.has_key?(query, "subject_kind")

    for {kind, expected} <- [{"app", ["read", "write"]}, {"human", ["read"]}] do
      assert {:ok, url} =
               Ankole.Plugins.LinearAdapter.Connector.oauth_authorize_url(
                 ctx.config,
                 %{"clientID" => "client"},
                 %{:subject_kind => kind, "scope" => ""}
               )

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["scope"] |> String.split(",") |> Enum.sort() == expected
    end

    oauth_config =
      struct!(Ankole.Connectors.AuthConfig, Map.put(ctx.config, :auth_scheme, "oauth2"))

    for {kind, expected} <- [
          {"app", ~w(admin:org_hook admin:repo_hook repo workflow)},
          {"human", ["repo"]}
        ] do
      assert {:ok, url} =
               GitHub.oauth_authorize_url(oauth_config, %{"clientID" => "client"}, %{
                 :subject_kind => kind,
                 "scope" => ""
               })

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["scope"] |> String.split(" ") |> Enum.sort() == expected
    end

    github_app = %{oauth_config | auth_scheme: "github_app"}

    assert {:ok, url} =
             GitHub.oauth_authorize_url(github_app, %{"clientID" => "client"}, %{
               :subject_kind => "human",
               "scope" => "repo"
             })

    refute Map.has_key?(url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query(), "scope")

    assert GitHub.scopes_satisfied?(["repo"], [], github_app)
    refute GitHub.scopes_satisfied?(["repo"], [], %{auth_scheme: "oauth2"})

    assert {:ok, %{"external_subject_id" => "42", "scope" => []}} =
             GitHub.oauth_exchange(
               github_app,
               %{"clientID" => "client", "clientSecret" => "secret"},
               %{"code" => "authorized"}
             )
  end

  test "Lark normalizes forms and time precision, keeps RFC3339 freebusy values", ctx do
    tool = Connector.find_tool("approvals_create_instance")

    assert {:ok, args} =
             ConnectorArguments.prepare(
               tool,
               %{
                 "approval_code" => "definition",
                 "form" => %{"Amount" => "12"},
                 "uuid" => "stable"
               },
               ctx.context
             )

    assert args["user_id"] == "employee"

    assert [%{"id" => "amount-id", "type" => "amount", "value" => "12"}] =
             Torque.decode!(args["form"])

    assert {:ok, args} =
             ConnectorArguments.prepare(
               Connector.find_tool("tasks_create"),
               %{"summary" => "task", "due" => %{"timestamp" => "2026-11-04T12:00:00Z"}},
               ctx.context
             )

    assert get_in(args, ["due", "timestamp"]) == "1793793600000"
    input = %{"time_min" => "2026-11-04T12:00:00Z", "time_max" => "2026-11-04T13:00:00Z"}

    assert {:ok, ^input} =
             ConnectorArguments.prepare(
               Connector.find_tool("calendar_query_freebusy"),
               input,
               ctx.context
             )

    assert {:ok, %{"start_time" => "1793793600", "end_time" => "1793797200"}} =
             ConnectorArguments.prepare(
               Connector.find_tool("calendar_list_events"),
               %{
                 "calendar_id" => "cal",
                 "start_time" => "2026-11-04T12:00:00Z",
                 "end_time" => "2026-11-04T13:00:00Z"
               },
               ctx.context
             )
  end

  test "calendar attendee and task member UIDs use the corresponding verified employee fields",
       ctx do
    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "protocol-people",
        "lark",
        %{"appID" => "protocol-app", "appSecret" => "secret", "sync" => %{"websocket" => false}},
        true
      )

    external_identity_fixture(%{
      human: %{principal: ctx.context.actor.principal},
      provider: "protocol-people",
      external_id: "employee",
      metadata: %{"user_id" => "employee"}
    })

    uid = ctx.context.actor.principal.uid
    config = put_in(ctx.config, [:public_metadata, "identityProvider"], "protocol-people")
    context = %{ctx.context | auth_config: config}

    assert {:error, :oauth_consent_required} = Connector.bound_user_id(ctx.config, uid)
    assert {:ok, "employee"} = Connector.bound_user_id(config, uid)

    for name <- ["calendar_create_event", "calendar_manage_attendees"] do
      tool = Connector.find_tool(name)
      assert tool.input_schema["properties"]["attendees"]["items"]["properties"]["principal_uid"]

      assert {:ok, %{"attendees" => [%{"user_id" => "employee", "type" => "user"}]}} =
               ConnectorArguments.prepare(
                 tool,
                 %{"calendar_id" => "cal", "attendees" => [%{"principal_uid" => uid}]},
                 context
               )
    end

    assert {:ok, %{"members" => [%{"id" => "employee", "role" => "assignee"}]}} =
             ConnectorArguments.prepare(
               Connector.find_tool("tasks_create"),
               %{"members" => [%{"principal_uid" => uid, "role" => "assignee"}]},
               context
             )
  end

  test "calendar attendee failure exposes created event, completed task never writes twice",
       ctx do
    assert {:error,
            %{
              code: "partial_write_completed",
              resource_id: "event-1",
              completed_step: "create_event",
              failed_step: "add_attendees",
              retryable: false
            }} =
             Connector.call(
               Connector.find_tool("calendar_create_event"),
               %{
                 "calendar_id" => "cal",
                 "summary" => "Meeting",
                 "start_time" => "2026-11-04T12:00:00Z",
                 "end_time" => "2026-11-04T13:00:00Z",
                 "attendees" => [%{"type" => "user", "user_id" => "employee"}]
               },
               ctx.context
             )

    assert {:ok, %{"task" => %{"completed_at" => "123"}}} =
             Connector.call(
               Connector.find_tool("tasks_complete"),
               %{"task_guid" => "done"},
               ctx.context
             )

    refute_receive {:request, "PATCH", "/open-apis/task/v2/tasks/done", _, _, _}
  end

  test "Linear projects upstream JSON into stable typed pages" do
    tool = Enum.find(Ankole.Plugins.LinearAdapter.Connector.tools(), &(&1.name == "list_issues"))

    upstream = %{
      "content" => [
        %{
          "type" => "text",
          "text" =>
            Torque.encode!(%{
              "issues" => [%{"id" => "issue", "title" => "Repair"}],
              "hasNextPage" => true,
              "cursor" => "next"
            })
        }
      ]
    }

    assert {:ok, page} = Ankole.Plugins.LinearAdapter.Connector.normalize_result(tool, upstream)

    assert page == %{
             "items" => [%{"id" => "issue", "title" => "Repair"}],
             "has_next_page" => true,
             "cursor" => "next"
           }

    assert {:ok, _} = ToolSpec.validate_output(tool, %{"result" => page})

    assert {:error, %{code: "upstream_contract_changed"}} =
             Ankole.Plugins.LinearAdapter.Connector.normalize_result(tool, %{
               "structuredContent" => %{"different" => []}
             })
  end

  test "GitHub webhook signatures authenticate exact bytes and event ID", ctx do
    body = ~s({"action":"opened"})

    signature =
      "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, "hook-secret", body), case: :lower)

    headers = [
      {"x-hub-signature-256", signature},
      {"x-github-delivery", "delivery-1"},
      {"x-github-event", "issues"}
    ]

    assert {:ok, %{"id" => "delivery-1", "type" => "github.issues"}} =
             GitHub.webhook(ctx.config, %{"webhookSecret" => "hook-secret"}, body, headers)

    assert {:error, :invalid_webhook_signature} =
             GitHub.webhook(ctx.config, %{"webhookSecret" => "hook-secret"}, body <> " ", headers)

    assert {:error, :invalid_webhook_signature} = Connector.webhook(ctx.config, %{}, body, [])
  end
end
