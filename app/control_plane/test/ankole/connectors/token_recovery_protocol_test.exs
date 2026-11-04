defmodule Ankole.Connectors.TokenRecoveryProtocolTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Connectors.{Accounts, Credentials, Gateway, GitCredentials, Store, Triggers}
  alias Ankole.Plugins.GitHubAdapter.Connector, as: GitHub
  alias Ankole.Pod.{Files, Pages}

  defmodule Provider do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, body, conn} = read_body(conn)

      send(
        owner,
        {:provider, self(), conn.method, conn.request_path, get_req_header(conn, "authorization"),
         body}
      )

      receive do
        {:reply, status, body} when is_binary(body) ->
          send_resp(conn, status, body)

        {:reply, status, body} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Torque.encode!(body))
      after
        5_000 -> send_resp(conn, 500, "Provider fixture response missing")
      end
    end
  end

  setup do
    server = start_supervised!({Bandit, plug: {Provider, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}"
    %{principal: human} = human_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(human.uid) end)

    {:ok, config} =
      Store.create_auth_config(human, %{
        "plugin_id" => "github",
        "slug" => "selected",
        "auth_scheme" => "oauth2",
        "secret" => %{"client_id" => "client-#{human.uid}", "client_secret" => "secret"},
        "public_metadata" => %{"base_url" => url, "web_url" => url, "uploads_url" => url}
      })

    %{human: human, actor: actor_fixture(human.uid), config: config, url: url}
  end

  test "read calls recover a rejected token within the selected account", ctx do
    account = account(ctx, %{"refresh_token" => "refresh-selected"})
    call = call(ctx, "issues_list")
    reject_request("GET", "/repos/owner/repo/issues", "rejected")
    refresh_token("refresh-selected", "renewed")
    reply_request("GET", "/repos/owner/repo/issues", "renewed", 200, [])
    assert {:ok, %{"structuredContent" => %{"result" => []}}} = Task.await(call)
    assert {:ok, current} = Accounts.get_by_id(account.id)
    assert current.credentials_version == account.credentials_version + 1
    assert {:ok, %{"access_token" => "renewed"}} = Credentials.account_credentials(current)
    refute_receive {:provider, _, _, _, _, _}
  end

  test "a rejected write refreshes credentials but is sent only once until explicitly retried",
       ctx do
    account(ctx, %{"refresh_token" => "refresh-write"})
    args = %{"issue_number" => 42, "labels" => ["bug"]}
    call = call(ctx, "issues_manage_labels", args)
    reject_request("PUT", "/repos/owner/repo/issues/42/labels", "rejected")
    refresh_token("refresh-write", "renewed-write")
    assert {:error, %{status: 401, retryable: true, request_sent: true}} = Task.await(call)
    refute_receive {:provider, _, _, _, _, _}

    retry = call(ctx, "issues_manage_labels", args)
    reply_request("PUT", "/repos/owner/repo/issues/42/labels", "renewed-write", 200, [])
    assert {:ok, %{"structuredContent" => %{"result" => []}}} = Task.await(retry)
    refute_receive {:provider, _, _, _, _, _}
  end

  test "a late rejection cannot invalidate a token another call already refreshed", ctx do
    account(ctx, %{"refresh_token" => "refresh-selected"})
    call = call(ctx, "issues_list")

    assert_receive {:provider, request, "GET", "/repos/owner/repo/issues", ["Bearer rejected"],
                    _},
                   2_000

    {:ok, _} =
      Accounts.put_human_tokens(
        ctx.config.id,
        ctx.human.uid,
        %{"access_token" => "already-refreshed", "refresh_token" => "next-refresh"},
        %{external_subject_id: "employee", granted_scopes: ["repo"]}
      )

    send(request, {:reply, 401, %{"message" => "Bad credentials"}})
    reply_request("GET", "/repos/owner/repo/issues", "already-refreshed", 200, [])
    assert {:ok, _} = Task.await(call)
    refute_receive {:provider, _, _, _, _, _}
  end

  test "a non-expiring OAuth token without a refresh grant becomes an actionable reconnect",
       ctx do
    account = account(ctx, %{})
    assert is_nil(account.expires_at)
    call = call(ctx, "issues_list")
    reject_request("GET", "/repos/owner/repo/issues", "rejected")
    assert {:error, %{code: "oauth_consent_required", authorization_url: url}} = Task.await(call)
    assert URI.decode_query(URI.parse(url).query)["connection"] == "selected"
    assert {:ok, %{status: "expired"}} = Accounts.get_by_id(account.id)
    refute_receive {:provider, _, _, _, _, _}
  end

  test "a revoked refresh grant asks for consent, while a temporary refresh failure permits retry",
       ctx do
    for {response, expected} <- [
          {{503, %{"message" => "try later"}}, "oauth_refresh_failed"},
          {{400, %{"error" => "invalid_grant"}}, "oauth_consent_required"}
        ] do
      account(ctx, %{"refresh_token" => "refresh-error"})
      call = call(ctx, "issues_list")
      reject_request("GET", "/repos/owner/repo/issues", "rejected")
      assert_receive {:provider, request, "POST", "/login/oauth/access_token", _, _}, 2_000
      {status, body} = response
      send(request, {:reply, status, body})
      assert {:error, %{code: ^expected} = error} = Task.await(call)
      assert error.retryable == (status == 503)
      refute_receive {:provider, _, _, _, _, _}
    end
  end

  test "a second 401 after a successful refresh is not retried in a loop", ctx do
    account(ctx, %{"refresh_token" => "refresh-once"})
    call = call(ctx, "issues_list")
    reject_request("GET", "/repos/owner/repo/issues", "rejected")
    refresh_token("refresh-once", "still-rejected")
    reject_request("GET", "/repos/owner/repo/issues", "still-rejected")
    assert {:error, %{status: 401, retryable: false}} = Task.await(call)
    refute_receive {:provider, _, _, _, _, _}
  end

  test "installation tokens rejected before expiry are reacquired without personal OAuth", ctx do
    key = :public_key.generate_key({:rsa, 2048, 65537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    {:ok, config} =
      Store.create_auth_config(ctx.human, %{
        "plugin_id" => "github",
        "slug" => "installed",
        "auth_scheme" => "github_app",
        "secret" => %{"app_id" => "app-#{ctx.human.uid}", "private_key" => pem},
        "public_metadata" => Map.put(ctx.config.public_metadata, "installation_id", "123")
      })

    call = call(%{ctx | config: config}, "issues_list")
    issue_installation_token("installation-old")
    reject_request("GET", "/repos/owner/repo/issues", "installation-old")
    issue_installation_token("installation-new")
    reply_request("GET", "/repos/owner/repo/issues", "installation-new", 200, [])
    assert {:ok, _} = Task.await(call)
    refute_receive {:provider, _, _, _, _, _}
  end

  test "Git credential exchange returns the refreshed token that passed the repository check",
       ctx do
    account(ctx, %{"refresh_token" => "refresh-git"})

    call =
      async_tenant(fn ->
        GitCredentials.resolve(%{actor: ctx.actor}, %{
          "connection" => ctx.config.slug,
          "url" => String.replace_prefix(ctx.url, "http:", "https:") <> "/owner/repo.git"
        })
      end)

    reject_request("GET", "/repos/owner/repo", "rejected")
    refresh_token("refresh-git", "git-renewed")
    reply_request("GET", "/repos/owner/repo", "git-renewed", 200, %{"id" => 42})
    assert {:ok, %{password: "git-renewed"}} = Task.await(call)
  end

  test "streaming download rejection refreshes the token without changing the destination", ctx do
    account(ctx, %{"refresh_token" => "refresh-file"})

    {:ok, page} =
      Pages.create(ctx.actor, %{
        type: "file",
        title: "artifact.zip",
        private_owner_uid: ctx.human.uid
      })

    args = %{
      "artifact_id" => 42,
      "destination" => %{
        "page_id" => page.id,
        "role" => "file",
        "name" => page.title,
        "content_type" => "application/octet-stream"
      }
    }

    call = call(ctx, "actions_download_artifact", args)
    reject_request("GET", "/repos/owner/repo/actions/artifacts/42/zip", "rejected")
    refresh_token("refresh-file", "file-renewed")
    assert {:error, %{status: 401, retryable: true}} = Task.await(call)
    assert {:ok, %{object_id: nil}} = Pages.fetch(page.id)
    refute_receive {:provider, _, _, _, _, _}

    retry = call(ctx, "actions_download_artifact", args)
    bytes = <<80, 75, 3, 4, 0, 255, 10>>
    reply_request("GET", "/repos/owner/repo/actions/artifacts/42/zip", "file-renewed", 200, bytes)
    assert {:ok, %{"structuredContent" => %{"file_ref" => _}}} = Task.await(retry)
    assert {:ok, _, ^bytes} = Files.read(ctx.actor, page.id, page.title)
  end

  test "upload rejection refreshes credentials without replaying the file upload", ctx do
    account(ctx, %{"refresh_token" => "refresh-upload"})

    {:ok, page} =
      Files.create_from_upload(
        ctx.actor,
        %{private_owner_uid: ctx.human.uid},
        "asset.bin",
        "release bytes",
        "application/octet-stream"
      )

    call =
      call(ctx, "releases_upload_asset", %{
        "release_id" => 42,
        "name" => "asset.bin",
        "content_type" => "application/octet-stream",
        "file_ref" => "pages/#{page.id}/asset.bin"
      })

    assert_receive {:provider, request, "POST", "/repos/owner/repo/releases/42/assets",
                    ["Bearer rejected"], "release bytes"},
                   2_000

    send(request, {:reply, 401, %{"message" => "rejected token rejected"}})
    refresh_token("refresh-upload", "upload-renewed")
    assert {:error, %{status: 401, retryable: true, details: details}} = Task.await(call)
    refute inspect(details) =~ "rejected"
    refute_receive {:provider, _, _, _, _, _}
  end

  test "hook creation preserves provider diagnostics while hiding access and signing secrets",
       ctx do
    trigger = trigger(ctx)
    call = async_tenant(fn -> GitHub.reconcile_trigger(ctx.config, %{}, trigger, true) end)
    reply_request("GET", "/repos/owner/repo/hooks", "rejected", 200, [])

    assert_receive {:provider, request, "POST", "/repos/owner/repo/hooks", ["Bearer rejected"],
                    body},
                   2_000

    signing_secret = Torque.decode!(body)["config"]["secret"]
    assert is_binary(signing_secret)

    send(
      request,
      {:reply, 422,
       %{"message" => "permission denied", "context" => ["rejected", signing_secret]}}
    )

    assert {:error, %{status: 422, message: "permission denied", details: details}} =
             Task.await(call)

    assert details["message"] == "permission denied"
    refute inspect(details) =~ "rejected"
    refute inspect(details) =~ signing_secret
  end

  test "hook rejection refreshes the same account and the next reconciliation uses the new token",
       ctx do
    trigger = trigger(ctx)
    account(ctx, %{"refresh_token" => "refresh-hook"})
    call = async_tenant(fn -> GitHub.reconcile_trigger(ctx.config, %{}, trigger, true) end)
    reply_request("GET", "/repos/owner/repo/hooks", "rejected", 200, [])
    reject_request("POST", "/repos/owner/repo/hooks", "rejected")
    refresh_token("refresh-hook", "hook-renewed")
    assert {:error, %{status: 401, retryable: true}} = Task.await(call)
    refute_receive {:provider, _, _, _, _, _}

    retry = async_tenant(fn -> GitHub.reconcile_trigger(ctx.config, %{}, trigger, true) end)
    reply_request("GET", "/repos/owner/repo/hooks", "hook-renewed", 200, [])
    reply_request("POST", "/repos/owner/repo/hooks", "hook-renewed", 201, %{"id" => 42})
    assert {:ok, %{external_subscription_id: "42"}} = Task.await(retry)
  end

  test "hook listing and removal preserve diagnostics and redact the selected access token",
       ctx do
    trigger = trigger(ctx)
    call = async_tenant(fn -> GitHub.reconcile_trigger(ctx.config, %{}, trigger, true) end)

    reply_request("GET", "/repos/owner/repo/hooks", "rejected", 403, %{
      "message" => "permission denied for rejected"
    })

    assert {:error, %{status: 403, message: message, details: details}} = Task.await(call)
    assert details["message"] == message
    assert message =~ "permission denied"
    refute message =~ "rejected"

    call = async_tenant(fn -> GitHub.reconcile_trigger(ctx.config, %{}, trigger, false) end)

    callback =
      AnkoleWeb.Endpoint.url() <>
        "/webhooks/connectors/#{ctx.config.tenant_id}/triggers/#{trigger.id}"

    reply_request("GET", "/repos/owner/repo/hooks", "rejected", 200, [
      %{"id" => 42, "config" => %{"url" => callback}}
    ])

    reply_request(
      "DELETE",
      "/repos/owner/repo/hooks/42",
      "rejected",
      503,
      "temporarily unavailable for rejected"
    )

    assert {:error, %{status: 503, retryable: true, message: message, details: details}} =
             Task.await(call)

    assert details == message
    assert message =~ "temporarily unavailable"
    refute message =~ "rejected"
  end

  defp trigger(ctx) do
    account = account(ctx, %{})

    {:ok, public} =
      Triggers.create(ctx.human, %{
        "auth_config_id" => ctx.config.id,
        "connected_account_id" => account.id,
        "trigger_type" => "github_repository",
        "scope_key" => "owner/repo"
      })

    {:ok, trigger} = Triggers.get(public.id)
    trigger
  end

  defp account(ctx, tokens) do
    {:ok, account} =
      Accounts.put_human_tokens(
        ctx.config.id,
        ctx.human.uid,
        Map.put(tokens, "access_token", "rejected"),
        %{external_subject_id: "employee", granted_scopes: ["repo", "admin:repo_hook"]}
      )

    account
  end

  defp call(ctx, name, args \\ %{}) do
    async_tenant(fn ->
      Gateway.request(
        {:toolkit, "github"},
        %{
          "method" => "tools/call",
          "params" => %{
            "name" => name,
            "arguments" => Map.merge(%{"owner" => "owner", "repo" => "repo"}, args)
          }
        },
        %{actor: ctx.actor, read_only: false},
        %{"connection" => ctx.config.slug}
      )
    end)
  end

  defp reject_request(method, path, token),
    do: reply_request(method, path, token, 401, %{"message" => "Bad credentials"})

  defp reply_request(method, path, token, status, body) do
    assert_receive {:provider, request, ^method, ^path, ["Bearer " <> ^token], _}, 2_000
    send(request, {:reply, status, body})
  end

  defp refresh_token(expected, token) do
    assert_receive {:provider, request, "POST", "/login/oauth/access_token", _, body}, 2_000
    assert Torque.decode!(body)["refresh_token"] == expected

    send(
      request,
      {:reply, 200,
       %{"access_token" => token, "refresh_token" => "next-refresh", "expires_in" => 7200}}
    )
  end

  defp issue_installation_token(token) do
    assert_receive {:provider, request, "POST", "/app/installations/123/access_tokens", _, _},
                   2_000

    send(
      request,
      {:reply, 201,
       %{
         "token" => token,
         "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600))
       }}
    )
  end

  defp async_tenant(fun) do
    tenant = Repo.tenant_id!()
    Task.async(fn -> Repo.with_tenant(tenant, fun) end)
  end
end
