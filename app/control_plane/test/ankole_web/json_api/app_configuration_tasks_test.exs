defmodule AnkoleWeb.JSONAPI.AppConfigurationTasksTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.{AppConfigure, Repo}
  alias Ankole.AppConfigure.{Cache, Registry}

  setup do
    Registry.clear_for_test()
    :ok
  end

  test "a trace task commits together, protects raw writes, and keeps secrets out of projections",
       %{conn: conn} do
    conn = console_conn(conn)
    assert {:ok, false} = AppConfigure.get_by_key("observability.traces.enabled")

    # The first write is valid by itself, but the complete connection is not.
    conn
    |> task("observability", %{
      "observability.traces.enabled" => true,
      "observability.traces.provider" => "opentelemetry"
    })
    |> json_response(422)

    assert {:ok, false} = AppConfigure.get_by_key("observability.traces.enabled")
    assert :error = AppConfigure.get_by_key("observability.traces.provider")

    values = %{
      "observability.traces.enabled" => true,
      "observability.traces.provider" => "opentelemetry",
      "observability.traces.otlp_endpoint" => "https://collector.example.test",
      "observability.traces.otlp_headers" => %{"Authorization" => "secret-token"}
    }

    saved = conn |> task("observability", values) |> json_response(200)
    refute Jason.encode!(saved) =~ "secret-token"
    assert Enum.all?(saved["app_configurations"], &(&1["runtime_status"] == "pending_restart"))
    assert {:ok, true} = AppConfigure.get_by_key("observability.traces.enabled")

    # A later schema failure rolls back the earlier enabled write and its cache.
    conn
    |> task("observability", %{
      "observability.traces.enabled" => false,
      "observability.traces.otlp_headers" => ["invalid"]
    })
    |> json_response(422)

    assert {:ok, true} = AppConfigure.get_by_key("observability.traces.enabled")

    assert {:ok, %{"Authorization" => "secret-token"}} =
             AppConfigure.get_by_key("observability.traces.otlp_headers")

    # Removing a required member while enabled obeys the same complete-task check.
    conn
    |> task("observability", %{}, ["observability.traces.otlp_endpoint"])
    |> json_response(422)

    assert {:ok, "https://collector.example.test"} =
             AppConfigure.get_by_key("observability.traces.otlp_endpoint")

    for method <- [:put, :delete] do
      response =
        api(conn, method, "/api/v2/site/app-configurations/observability.traces.enabled", %{
          value: false
        })

      assert %{"errors" => [%{"code" => "key_managed_by_owner"}]} = json_response(response, 422)
    end

    conn |> task("observability", %{}, ["observability.traces.enabled"]) |> json_response(200)
    assert {:ok, false} = AppConfigure.get_by_key("observability.traces.enabled")
  end

  test "task membership and ownership cannot be bypassed through a batch", %{conn: conn} do
    conn = console_conn(conn)

    for {group, values, resets} <- [
          {"brain", %{"system.timezone" => "Asia/Singapore"}, []},
          {"brain", %{"brain.enabled" => false}, ["brain.enabled"]},
          {"unknown", %{"brain.enabled" => false}, []},
          {"library", %{"ai_agent.library.skill_defaults" => %{"missing" => true}}, []}
        ] do
      conn |> task(group, values, resets) |> json_response(422)
    end

    assert {:ok, true} = AppConfigure.get_by_key("brain.enabled")

    assert %{"errors" => [%{"code" => "key_managed_by_owner"}]} =
             conn
             |> api(:put, "/api/v2/app-configurations/ai_agent.library.skill_defaults", %{
               value: %{"missing" => true}
             })
             |> json_response(422)
  end

  test "OTP policies commit atomically and retain independent counter dimensions", %{conn: conn} do
    conn = console_conn(conn)

    limits = %{
      "window_seconds" => 120,
      "per_email" => 20,
      "per_source" => 10,
      "per_channel" => 100
    }

    conn
    |> task("otp", %{
      "authn.email.code_ttl_seconds" => 120,
      "authn.email.send_limits" => Map.put(limits, "per_channel", 0)
    })
    |> json_response(422)

    assert {:ok, 600} = AppConfigure.get_by_key("authn.email.code_ttl_seconds")

    conn
    |> task("otp", %{"authn.email.code_ttl_seconds" => 120, "authn.email.send_limits" => limits})
    |> json_response(200)

    assert {:ok, 120} = AppConfigure.get_by_key("authn.email.code_ttl_seconds")
    assert {:ok, ^limits} = Ankole.Authn.Config.get("send_limits")
  end

  test "a task requires each touched key permission and separate reset permission", %{conn: conn} do
    {conn, operator} = console_conn_with_principal(conn)
    Repo.delete_all(Ankole.AuthZ.Grant)

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: operator,
        resource_pattern: "site_console:app_configuration:observability.traces.enabled",
        action: "update"
      })

    conn
    |> task("observability", %{
      "observability.traces.enabled" => false,
      "observability.traces.provider" => "opentelemetry"
    })
    |> json_response(403)

    conn |> task("observability", %{}, ["observability.traces.enabled"]) |> json_response(403)
    assert :error = AppConfigure.get_by_key("observability.traces.provider")

    conn
    |> task("observability", %{"observability.traces.enabled" => false})
    |> json_response(200)
  end

  test "site visitor defaults and tenant overrides publish real access changes", %{
    conn: conn,
    tenant: tenant
  } do
    conn = console_conn(conn)
    other = Ankole.DataCase.create_tenant()
    Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-access:" <> tenant.id)
    Phoenix.PubSub.subscribe(Ankole.PubSub, "drive-access:" <> other.id)
    conn |> task("pod-access", %{"pod.allow_external_guests" => false}) |> json_response(200)
    assert_receive :recheck_access
    assert_receive :recheck_access
    refute Ankole.Pod.Config.allow_external_guests?()

    conn
    |> task("pod-access", %{"pod.allow_external_guests" => true}, [], :tenant)
    |> json_response(200)

    assert_receive :recheck_access
    assert Ankole.Pod.Config.allow_external_guests?()
    Repo.with_tenant(other.id, fn -> refute Ankole.Pod.Config.allow_external_guests?() end)

    %{"app_configuration" => item} =
      conn
      |> api(:get, "/api/v2/app-configurations/pod.allow_external_guests")
      |> json_response(200)

    assert item["fallback_value"] == false
    assert item["fallback_source"] == "global"
    conn |> task("pod-access", %{}, ["pod.allow_external_guests"], :tenant) |> json_response(200)
    refute Ankole.Pod.Config.allow_external_guests?()
  end

  test "the tenant Brain task exposes its site foundation but cannot overwrite it", %{conn: conn} do
    conn = console_conn(conn)

    %{"app_configurations" => items} =
      conn |> api(:get, "/api/v2/app-configurations") |> json_response(200)

    for key <- ~w(brain.embedding_model brain.search_tokenizer) do
      assert %{"editable" => false, "scope" => "global"} = Enum.find(items, &(&1["key"] == key))
    end

    conn
    |> task(
      "brain",
      %{"brain.enabled" => false, "brain.search_tokenizer" => "jieba"},
      [],
      :tenant
    )
    |> json_response(422)

    assert {:ok, true} = AppConfigure.get_by_key("brain.enabled")
  end

  test "SMTP tests use the draft over a real TLS peer and never change saved transport", %{
    conn: conn
  } do
    conn = console_conn(conn)
    previous = Application.fetch_env!(:ankole, Ankole.Authn.Mailer)
    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: Swoosh.Adapters.SMTP)
    smtp = Ankole.Authn.SMTPFixture.start(self())

    on_exit(fn ->
      Application.put_env(:ankole, Ankole.Authn.Mailer, previous)
      Ankole.Authn.SMTPFixture.stop(smtp)
    end)

    saved = %{"server" => "old.invalid", "from" => "old@example.test", "password" => "keep-me"}
    {:ok, _} = AppConfigure.put_global_by_key("authn.email.mail", saved)

    draft = %{
      "server" => "127.0.0.1",
      "port" => smtp.port,
      "ssl" => true,
      "from" => "draft@example.test",
      "cacertfile" => smtp.ca_path
    }

    assert %{"accepted" => true} =
             conn
             |> api(:post, "/api/v2/site/app-configurations/authn.email.mail/tests", %{
               settings: draft,
               recipient: "operator@example.test"
             })
             |> json_response(201)

    assert_receive {:smtp_message, "draft@example.test", ["operator@example.test"], body}, 5_000
    assert body =~ "Ankole email delivery test"
    refute body =~ "verification code is"
    assert {:ok, ^saved} = AppConfigure.get_by_key("authn.email.mail")

    %{"app_configurations" => [item]} =
      conn |> task("smtp", %{"authn.email.mail" => draft}) |> json_response(200)

    assert item["public_value"]["server"] == "127.0.0.1"
    assert item["secret_present"] == true
    assert item["fallback_present"] == false
    assert item["fallback_source"] == "default"
    refute Jason.encode!(item) =~ "keep-me"
    assert {:ok, %{"password" => "keep-me"}} = AppConfigure.get_by_key("authn.email.mail")

    conn
    |> task("smtp", %{"authn.email.mail" => Map.put(draft, "password", "")})
    |> json_response(200)

    assert {:ok, %{"password" => ""}} = AppConfigure.get_by_key("authn.email.mail")
  end

  test "Agent inspection resolves only consumed overrides in the current tenant", %{conn: conn} do
    conn = console_conn(conn)
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    key = "ai_agent.max_iterations"
    {:ok, _} = AppConfigure.put_tenant_by_key(key, 12)

    {:ok, _} =
      Ankole.Ash.create(Ankole.AppConfigure.AppConfig, :put, %{
        scope: "agent:" <> agent.uid,
        key: key,
        input: 4
      })

    Cache.clear_for_test()

    assert %{
             "app_configuration" => %{
               "value" => 4,
               "source" => "agent",
               "agent_override_supported" => true
             }
           } =
             conn
             |> api(:get, "/api/v2/app-configurations/#{key}/agents/#{agent.uid}")
             |> json_response(200)

    assert {:ok, 12} = AppConfigure.get_by_key(key)
    other = Ankole.DataCase.create_tenant()

    foreign =
      Repo.with_tenant(other.id, fn -> Ankole.PrincipalsFixtures.agent_fixture().principal end)

    conn
    |> api(:get, "/api/v2/app-configurations/#{key}/agents/#{foreign.uid}")
    |> json_response(422)

    conn
    |> api(:get, "/api/v2/app-configurations/brain.enabled/agents/#{agent.uid}")
    |> json_response(422)
  end

  test "Library owns validated site defaults independently of a tenant's overrides", %{conn: conn} do
    conn = console_conn(conn)

    conn
    |> api(:put, "/api/v2/agent-library/agent-plugins/lark", %{
      enabled: true,
      defaults_scope: "global"
    })
    |> json_response(200)

    assert {:ok, %{"lark" => true}} =
             AppConfigure.get_by_key("ai_agent.library.agent_plugin_defaults", scope: :global)

    conn
    |> api(:put, "/api/v2/agent-library/agent-plugins/lark", %{
      enabled: false,
      defaults_scope: "tenant"
    })
    |> json_response(200)

    assert {:ok, %{"lark" => false}} =
             AppConfigure.get_by_key("ai_agent.library.agent_plugin_defaults")

    conn
    |> api(:put, "/api/v2/agent-library/agent-plugins/missing-plugin", %{
      enabled: true,
      defaults_scope: "global"
    })
    |> json_response(404)

    assert {:ok, %{"lark" => true}} =
             AppConfigure.get_by_key("ai_agent.library.agent_plugin_defaults", scope: :global)
  end

  defp task(conn, group, values, resets \\ [], scope \\ :global) do
    prefix = if scope == :global, do: "/api/v2/site", else: "/api/v2"

    api(conn, :put, prefix <> "/app-configurations/groups/" <> group, %{
      values: values,
      reset_keys: resets
    })
  end

  defp api(conn, method, path, attrs \\ %{}) do
    conn =
      conn
      |> recycle_api()
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")

    send_request(conn, method, path, attrs)
  end

  defp send_request(conn, :get, path, _), do: get(conn, path)
  defp send_request(conn, :delete, path, _), do: delete(conn, path)
  defp send_request(conn, :put, path, attrs), do: put(conn, path, Jason.encode!(%{data: attrs}))
  defp send_request(conn, :post, path, attrs), do: post(conn, path, Jason.encode!(%{data: attrs}))
end
