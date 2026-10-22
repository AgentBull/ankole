defmodule Ankole.Signals.BindingTenancyTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.IdentityProviders
  alias Ankole.Signals.Bindings
  alias Ankole.Signals.Binding

  setup do
    Req.Test.set_req_test_to_shared()

    modules = [
      Ankole.Plugins.DiscordAdapter.Config,
      Ankole.Plugins.TelegramAdapter.Config,
      Ankole.Plugins.SlackAdapter.Config
    ]

    previous = Enum.map(modules, &{&1, Application.fetch_env(:ankole, &1)})

    on_exit(fn ->
      # Finish the saved bindings' asynchronous reads before Sandbox stops.
      :sys.get_state(Ankole.Plugins.LarkAdapter.ConnectionReconciler)
      :sys.get_state(Ankole.Plugins.SlackAdapter.ConnectionReconciler)

      Ankole.Plugins.SlackAdapter.ConnectionReconciler.stop(
        Ankole.Plugins.SlackAdapter.Config.connection_key(bot_config("slack", "test"))
      )

      Enum.each(previous, fn
        {module, {:ok, value}} -> Application.put_env(:ankole, module, value)
        {module, :error} -> Application.delete_env(:ankole, module)
      end)
    end)

    Enum.each(modules, fn module ->
      opts =
        if module == Ankole.Plugins.SlackAdapter.Config,
          do: [req_options: [plug: {Req.Test, __MODULE__}]],
          else: [plug: {Req.Test, __MODULE__}]

      Application.put_env(:ankole, module, client_opts: opts)
    end)

    :ok
  end

  test "Teams permits sharing inside one tenant and rejects another tenant", %{tenant: tenant} do
    app_id = Ecto.UUID.generate()
    %{principal: first} = agent_fixture()
    %{principal: second} = agent_fixture()
    attrs = %{"config" => teams_config(app_id)}

    assert {:ok, %{binding: first_binding}} =
             Bindings.put_binding(first.uid, "teams", "main", attrs)

    assert {:ok, %{binding: second_binding}} =
             Bindings.put_binding(second.uid, "teams", "main", attrs)

    refute first_binding.config_ref == second_binding.config_ref
    assert {:ok, first_config} = Bindings.stored_binding_config(first_binding)
    assert {:ok, ^first_config} = Bindings.stored_binding_config(second_binding)

    assert Repo.get_by!(Ankole.AppConfigure.SiteConfig,
             scope: "global",
             key: String.replace_prefix(first_binding.config_ref, "app-config://", "")
           )

    assert Repo.get_by!(Ankole.AppConfigure.SiteConfig,
             scope: "global",
             key: String.replace_prefix(second_binding.config_ref, "app-config://", "")
           )

    assert {:ok, _} = Bindings.disable_binding(first.uid, "main")
    assert {:ok, _} = Bindings.disable_binding(second.uid, "main")

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      %{principal: third} = agent_fixture()

      assert {:error, :platform_app_bound_to_another_tenant} =
               Bindings.put_binding(third.uid, "teams", "main", attrs)

      refute Repo.get_by(Binding, agent_uid: third.uid, name: "main")
    end)

    assert Repo.tenant_id!() == tenant.id
  end

  test "same-named Slack bindings retain independent encrypted configuration rows" do
    stub_bot_identity()
    %{principal: first} = agent_fixture()
    %{principal: second} = agent_fixture()

    for {agent, suffix} <- [{first, "first"}, {second, "second"}] do
      assert {:ok, %{binding: binding}} =
               Bindings.put_binding(agent.uid, "slack", "main", %{
                 "config" => bot_config("slack", suffix)
               })

      assert {:ok, stored} = Bindings.stored_binding_config(binding)
      assert stored["botToken"] == "xoxb-" <> suffix
    end

    first_binding = Repo.get_by!(Binding, agent_uid: first.uid, name: "main")
    second_binding = Repo.get_by!(Binding, agent_uid: second.uid, name: "main")
    refute first_binding.config_ref == second_binding.config_ref

    assert {:ok, _} =
             Bindings.update_binding(first.uid, first.uid, "main", %{
               "config" => %{"botToken" => "xoxb-rotated"}
             })

    assert {:ok, stored} = Bindings.stored_binding_config(second_binding)
    assert stored["botToken"] == "xoxb-second"
  end

  test "another tenant's invalid credentials are not decoded or requested during save" do
    stub_bot_identity()
    %{principal: first} = agent_fixture()

    assert {:ok, %{binding: binding}} =
             Bindings.put_binding(first.uid, "slack", "main", %{
               "config" => bot_config("slack", "old")
             })

    key = String.replace_prefix(binding.config_ref, "app-config://", "")
    row = Repo.get_by!(Ankole.AppConfigure.SiteConfig, scope: "global", key: key)
    # An unreadable credential still owns its stored application identity.
    Repo.query!(
      "UPDATE site_app_configurations SET value = $1 WHERE scope = 'global' AND key = $2",
      [Map.put(row.value, "value", "invalid"), key]
    )

    {:ok, definition} = Ankole.AppConfigure.Registry.require_key(key)

    assert {:error, _} =
             Ankole.AppConfigure.Codec.load(
               definition,
               row.scope,
               key,
               Map.put(row.value, "value", "invalid")
             )

    Req.Test.stub(__MODULE__, fn _ -> flunk("Teams save must not query Slack credentials") end)
    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      %{principal: second} = agent_fixture()

      assert {:ok, _} =
               Bindings.put_binding(second.uid, "teams", "main", %{
                 "config" => teams_config(Ecto.UUID.generate())
               })
    end)
  end

  test "an Entra provider reserves its application against another tenant's Teams binding" do
    app_id = Ecto.UUID.generate()

    assert {:ok, _} =
             IdentityProviders.save_provider("directory", "entra-id", entra_config(app_id), false)

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      %{principal: agent} = agent_fixture()

      assert {:error, :platform_app_bound_to_another_tenant} =
               Bindings.put_binding(agent.uid, "teams", "main", %{
                 "config" => teams_config(app_id)
               })
    end)
  end

  test "a Teams binding reserves its application against another tenant's Entra provider" do
    app_id = Ecto.UUID.generate()
    %{principal: agent} = agent_fixture()

    assert {:ok, _} =
             Bindings.put_binding(agent.uid, "teams", "main", %{"config" => teams_config(app_id)})

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert {:error, :platform_app_bound_to_another_tenant} =
               IdentityProviders.save_provider(
                 "directory",
                 "entra-id",
                 entra_config(String.upcase(app_id)),
                 false
               )
    end)
  end

  for adapter <- ["slack", "discord", "telegram"] do
    @adapter adapter
    test "#{adapter} rejects a rotated credential for another tenant's stable application" do
      stub_bot_identity()
      %{principal: agent} = agent_fixture()

      assert {:ok, _} =
               Bindings.put_binding(agent.uid, @adapter, "main", %{
                 "config" => bot_config(@adapter, "original")
               })

      assert {:ok, _} = Bindings.disable_binding(agent.uid, "main")
      other = create_tenant()

      Repo.with_tenant(other.id, fn ->
        %{principal: agent} = agent_fixture()

        assert {:error, :platform_app_bound_to_another_tenant} =
                 Bindings.put_binding(agent.uid, @adapter, "main", %{
                   "config" => bot_config(@adapter, "rotated")
                 })

        refute Repo.get_by(Binding, agent_uid: agent.uid, name: "main")
      end)
    end
  end

  for adapter <- ["slack", "lark", "dingtalk", "entra-id", "wecom", "google-workspace"] do
    @adapter adapter
    test "#{adapter} login-only providers can share an application across tenants" do
      Req.Test.stub(__MODULE__, fn _ ->
        flunk("login-only providers must not request a bot identity")
      end)

      if @adapter == "wecom" do
        assert {:ok, _} = Ankole.Plugins.put_configured_enabled("wecom-adapter", true)
      end

      config = login_config(@adapter)

      assert {:ok, _} = IdentityProviders.save_provider("login", @adapter, config, false)
      other = create_tenant()

      Repo.with_tenant(other.id, fn ->
        assert {:ok, _} = IdentityProviders.save_provider("login", @adapter, config, false)
      end)
    end
  end

  test "a login-only provider does not reserve a binding application, but enabling sync does" do
    config = login_config("lark")
    assert {:ok, _} = IdentityProviders.save_provider("login", "lark", config, false)
    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      %{principal: agent} = agent_fixture()
      assert {:ok, _} = Bindings.put_binding(agent.uid, "lark", "main", %{"config" => config})
    end)

    assert {:error, :platform_app_bound_to_another_tenant} =
             IdentityProviders.save_provider(
               "login",
               "lark",
               put_in(config, ["sync", "contacts"], true),
               false
             )

    assert {:ok, provider} = IdentityProviders.fetch_configured_provider("login")
    assert provider["config"]["sync"]["contacts"] == false
  end

  test "Slack directory credentials share application exclusion with chat bindings" do
    stub_bot_identity()
    %{principal: agent} = agent_fixture()

    assert {:ok, _} =
             Bindings.put_binding(agent.uid, "slack", "main", %{
               "config" => bot_config("slack", "original")
             })

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert {:error, :platform_app_bound_to_another_tenant} =
               IdentityProviders.save_provider(
                 "directory",
                 "slack",
                 %{
                   "clientID" => "client",
                   "clientSecret" => "secret",
                   "botToken" => "xoxb-rotated",
                   "sync" => %{"contacts" => true, "websocket" => false}
                 },
                 false
               )
    end)
  end

  test "unverifiable bot credentials fail without saving a binding" do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    %{principal: agent} = agent_fixture()

    assert {:error, %Ankole.Plugins.TelegramAdapter.Client.Error{kind: :transport}} =
             Bindings.put_binding(agent.uid, "telegram", "main", %{
               "config" => bot_config("telegram", "bad")
             })

    refute Repo.get_by(Binding, agent_uid: agent.uid, name: "main")
  end

  defp login_config(adapter) do
    base = %{"oidc" => %{"enabled" => true}, "sync" => %{"contacts" => false}}

    credentials =
      case adapter do
        "slack" ->
          %{"clientID" => "same-client", "clientSecret" => "secret"}

        "lark" ->
          %{"appID" => "same-app", "appSecret" => "secret", "domain" => "feishu"}

        "dingtalk" ->
          %{"clientId" => "same-app", "clientSecret" => "secret"}

        "entra-id" ->
          %{
            "tenantID" => Ecto.UUID.generate(),
            "clientID" => "same-app",
            "clientSecret" => "secret"
          }

        "wecom" ->
          %{"corpId" => "same-corp", "agentId" => "same-app", "appSecret" => "secret"}

        "google-workspace" ->
          %{
            "clientID" => "same-client",
            "clientSecret" => "secret",
            "oidc" => %{"allowedDomains" => ["example.com"]}
          }
      end

    Map.merge(base, credentials)
  end

  defp bot_config("slack", suffix),
    do: %{"botToken" => "xoxb-#{suffix}", "appToken" => "xapp-test"}

  defp bot_config(_, suffix), do: %{"botToken" => "test-#{suffix}"}

  defp stub_bot_identity do
    Req.Test.stub(__MODULE__, fn conn ->
      cond do
        String.ends_with?(conn.request_path, "/auth.test") ->
          Req.Test.json(conn, %{"ok" => true, "user_id" => "U1", "bot_id" => "B1"})

        String.ends_with?(conn.request_path, "/bots.info") ->
          Req.Test.json(conn, %{"ok" => true, "bot" => %{"id" => "B1", "app_id" => "A1"}})

        String.ends_with?(conn.request_path, "/apps.connections.open") ->
          Req.Test.json(conn, %{"ok" => false, "error" => "service_unavailable"})

        String.ends_with?(conn.request_path, "/applications/@me") ->
          Req.Test.json(conn, %{"id" => "42"})

        String.ends_with?(conn.request_path, "/getMe") ->
          Req.Test.json(conn, %{"ok" => true, "result" => %{"id" => 42, "is_bot" => true}})
      end
    end)
  end

  defp teams_config(app_id),
    do: %{
      "appID" => app_id,
      "appPassword" => "test-secret",
      "botTenancy" => "multi_tenant"
    }

  defp entra_config(client_id),
    do: %{
      "tenantID" => Ecto.UUID.generate(),
      "clientID" => client_id,
      "clientSecret" => "test-secret",
      "oidc" => %{"enabled" => false},
      "sync" => %{"contacts" => true, "realtime" => false}
    }
end
