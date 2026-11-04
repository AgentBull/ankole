defmodule Ankole.Connectors.ConnectionDisableProtocolTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.Eventually, only: [eventually: 1]
  import Ankole.E2E.Harness, only: [put_slack_test_client_opts!: 1]

  alias Ankole.Connectors.Store
  alias Ankole.E2E.FakeSlack.{Server, State}
  alias Ankole.Plugins.SlackAdapter.{Config, ConnectionReconciler}

  setup do
    existing = ConnectionReconciler.registered_keys()
    fake = Server.start!()
    put_slack_test_client_opts!(base_url: fake.base_url, req_options: [plug: nil])

    on_exit(fn ->
      Enum.each(ConnectionReconciler.registered_keys() -- existing, &ConnectionReconciler.stop/1)
    end)

    %{principal: admin} = human_fixture()
    %{principal: agent} = agent_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)

    {:ok, root} =
      Store.create_auth_config(admin, %{
        "plugin_id" => "slack",
        "slug" => "live-slack",
        "auth_scheme" => "platform_app",
        "secret" => %{
          "botToken" => "xoxb-fake",
          "appToken" => "xapp-fake",
          "clientID" => "slack-client",
          "clientSecret" => "slack-secret"
        }
      })

    {:ok, %{binding: binding}} =
      Ankole.Signals.Bindings.put_binding(agent.uid, "slack", "live", %{
        "config" => %{"authConfigId" => root.id}
      })

    %{fake: fake, admin: admin, root: root, binding: binding}
  end

  test "disabling a root closes its actual shared IM and directory WebSocket, and enabling reconnects",
       ctx do
    assert {:ok, _} =
             Ankole.IdentityProviders.save_provider("live-slack", "slack", %{
               "authConfigId" => ctx.root.id,
               "sync" => %{"contacts" => true, "websocket" => true}
             })

    {key, owner} = connected(ctx)
    assert %{started: 1, errors: []} = ConnectionReconciler.reconcile()
    ref = Process.monitor(owner)
    assert {:ok, _} = Store.update_auth_config(ctx.admin, ctx.root.id, %{"status" => "disabled"})
    assert %{started: 0, stopped: 1, errors: []} = ConnectionReconciler.reconcile()
    assert_receive {:DOWN, ^ref, :process, ^owner, :shutdown}, 2_000
    assert eventually(fn -> State.connection_count(ctx.fake.state) == 0 end)
    assert {:error, :no_connections} = State.push_event(ctx.fake.state, %{"type" => "events_api"})
    refute key in ConnectionReconciler.registered_keys()

    assert %{started: 0, stopped: 0, errors: []} = ConnectionReconciler.reconcile()
    assert {:ok, _} = Store.update_auth_config(ctx.admin, ctx.root.id, %{"status" => "active"})
    assert %{started: 1, errors: []} = ConnectionReconciler.reconcile()
    assert eventually(fn -> State.connection_count(ctx.fake.state) == 1 end)

    assert [{replacement, _}] =
             Registry.lookup(Ankole.Plugins.SlackAdapter.ConnectionRegistry, key)

    refute replacement == owner
  end

  test "an unreadable snapshot retains a live socket, but never retains a disabled root", ctx do
    {key, owner} = connected(ctx)
    %{principal: other_agent} = agent_fixture()

    assert {:ok, _} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: other_agent.uid,
               name: "broken",
               adapter: "slack",
               config_ref: "app-config://signals.slack.bindings.missing-other"
             })

    assert {:ok, _} =
             Ankole.SignalsFixtures.raw_binding_fixture(ctx.binding, %{
               config_ref: "app-config://signals.slack.bindings.missing-own"
             })

    assert %{stopped: 0, errors: [_, _]} = ConnectionReconciler.reconcile()
    assert Process.alive?(owner)
    assert State.connection_count(ctx.fake.state) == 1

    assert {:ok, _} = Store.update_auth_config(ctx.admin, ctx.root.id, %{"status" => "disabled"})
    assert %{started: 0, stopped: 1, errors: [_, _]} = ConnectionReconciler.reconcile()
    refute Process.alive?(owner)
    assert eventually(fn -> State.connection_count(ctx.fake.state) == 0 end)
    assert {:error, :no_connections} = State.push_event(ctx.fake.state, %{"type" => "events_api"})
    refute key in ConnectionReconciler.registered_keys()

    assert %{started: 0, stopped: 0, errors: [_, _]} = ConnectionReconciler.reconcile()
    assert State.connection_count(ctx.fake.state) == 0
  end

  defp connected(ctx) do
    assert %{started: 1, errors: []} = ConnectionReconciler.reconcile()
    assert eventually(fn -> State.connection_count(ctx.fake.state) == 1 end)
    {:ok, config} = Ankole.Signals.Bindings.binding_config(ctx.binding, Config)
    assert config["authConfigId"] == ctx.root.id

    assert {:ok, transaction_config} =
             Repo.transact_top_level(fn ->
               Ankole.Signals.Bindings.binding_config_in_tx(ctx.binding, Config)
             end)

    assert transaction_config["authConfigId"] == ctx.root.id
    key = Config.connection_key(config)
    assert [{owner, _}] = Registry.lookup(Ankole.Plugins.SlackAdapter.ConnectionRegistry, key)
    # The fake server counts the socket before the client handles the upgrade response.
    assert eventually(fn -> SlackOpenAPI.SocketMode.Client.status(owner) == :connected end)
    {key, owner}
  end
end

defmodule Ankole.Connectors.LarkSharedConnectionProtocolTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.Eventually, only: [eventually: 1]
  import Ankole.E2E.Harness, only: [start_fake_feishu!: 1]

  alias Ankole.Connectors.Store
  alias Ankole.Plugins.LarkAdapter.{Config, ConnectionReconciler}

  test "IM and directory consumers share the root's real Lark socket and stop together" do
    fake = start_fake_feishu!(apps: [{"cli_shared_root", "shared-secret"}])
    existing = ConnectionReconciler.registered_keys()

    on_exit(fn ->
      Enum.each(ConnectionReconciler.registered_keys() -- existing, &ConnectionReconciler.stop/1)
    end)

    %{principal: admin} = human_fixture()
    %{principal: agent} = agent_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)

    {:ok, root} =
      Store.create_auth_config(admin, %{
        "plugin_id" => "lark",
        "slug" => "live-lark",
        "auth_scheme" => "lark_app",
        "secret" => %{"appID" => "cli_shared_root", "appSecret" => "shared-secret"}
      })

    assert {:ok, _} =
             Ankole.IdentityProviders.save_provider("live-lark", "lark", %{
               "authConfigId" => root.id,
               "sync" => %{"contacts" => true, "websocket" => true}
             })

    assert {:ok, %{binding: binding}} =
             Ankole.Signals.Bindings.put_binding(agent.uid, "lark", "live", %{
               "config" => %{"authConfigId" => root.id, "identityProvider" => "live-lark"}
             })

    assert {:ok, config} = Ankole.Signals.Bindings.binding_config(binding, Config)
    assert config["authConfigId"] == root.id

    assert {:ok, transaction_config} =
             Repo.transact_top_level(fn ->
               Ankole.Signals.Bindings.binding_config_in_tx(binding, Config)
             end)

    assert transaction_config["authConfigId"] == root.id

    assert %{started: 1, errors: []} = ConnectionReconciler.reconcile()
    assert eventually(fn -> FakeFeishu.State.connection_count(fake.state) == 1 end)
    key = {Repo.tenant_id!(), root.id}
    assert [{owner, _}] = Registry.lookup(Ankole.Plugins.LarkAdapter.ConnectionRegistry, key)
    assert {:ok, _} = Store.update_auth_config(admin, root.id, %{"status" => "disabled"})
    assert %{started: 0, stopped: 1, errors: []} = ConnectionReconciler.reconcile()
    refute Process.alive?(owner)
    assert eventually(fn -> FakeFeishu.State.connection_count(fake.state) == 0 end)
    assert %{started: 0, errors: []} = ConnectionReconciler.reconcile()
  end
end
